import Foundation
import CryptoKit

public protocol ByteChannel: Sendable {
    func readExactly(_ count: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close() async
}

public struct Authentication: Sendable {
    public let peer: UUID
    public let session: CryptoSession
}

public enum Handshake {
    public static func readHello(channel: any ByteChannel) async throws -> Hello {
        let prefix = try await channel.readExactly(8)
        guard prefix.prefix(7) == Wire.magic else { throw ProtocolFailure.invalidHandshake }
        guard prefix.last == Wire.version else { throw ProtocolFailure.unsupportedVersion }
        return try Hello.decode(prefix + (try await channel.readExactly(Wire.helloSize - 8)))
    }

    public static func authenticate(channel: any ByteChannel, role: PeerRole, identity: UUID,
                                    key: Data, context: UUID = Wire.zeroID, transport: TransportKind,
                                    expectedPeer: UUID? = nil, remoteHello: Hello? = nil,
                                    traffic: (@Sendable (Bool) -> Void)? = nil) async throws -> Authentication {
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let local = try Hello(role: role, peerID: identity, contextID: context, nonce: Crypto.random(32), publicKey: ephemeral.publicKey.rawRepresentation)
        try await channel.write(local.encoded())
        traffic?(true)
        let remote: Hello
        if let remoteHello { remote = remoteHello }
        else { remote = try await readHello(channel: channel) }
        traffic?(false)
        guard remote.role != role, remote.contextID == context,
              expectedPeer == nil || expectedPeer == remote.peerID else { throw ProtocolFailure.authenticationFailed }
        let transcript = Crypto.transcript(local: local, remote: remote, transport: transport)
        try await channel.write(Crypto.proof(key: key, transcript: transcript, role: role))
        traffic?(true)
        let proof = try await channel.readExactly(32)
        traffic?(false)
        guard Crypto.verify(proof, key: key, transcript: transcript, role: remote.role) else { throw ProtocolFailure.authenticationFailed }
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: remote.publicKey))
        let session = try CryptoSession(key: key, local: local, remote: remote, transport: transport, sharedSecret: shared.withUnsafeBytes { Data($0) })
        let finishedKey = Crypto.derive(session.root, salt: Data(), info: "finished")
        try await channel.write(Crypto.proof(key: finishedKey, transcript: transcript, role: role))
        traffic?(true)
        let finished = try await channel.readExactly(32)
        traffic?(false)
        guard Crypto.verify(finished, key: finishedKey, transcript: transcript, role: remote.role) else { throw ProtocolFailure.authenticationFailed }
        return Authentication(peer: remote.peerID, session: session)
    }
}

public actor EncryptedChannel {
    public let transport: TransportKind
    public let root: Data
    private let raw: any ByteChannel
    private var crypto: CryptoSession
    private struct Write {
        let record: Record
        let continuation: CheckedContinuation<Void, any Error>?
        let buffered: Bool
        let response: Bool
    }
    private var writes: [Write] = []
    private let lifetime = ChannelLifetime()
    private let slots = TransferSlots(count: 16)
    private let responses = TransferSlots(count: 16)
    private var writing = false
    private var closed = false
    private var dataEpoch: UUID?
    private var discarded: Set<UUID> = []
    private let traffic: (@Sendable (Bool) -> Void)?

    public init(raw: any ByteChannel, authentication: Authentication, transport: TransportKind,
                traffic: (@Sendable (Bool) -> Void)? = nil) {
        self.raw = raw; crypto = authentication.session; root = authentication.session.root; self.transport = transport
        self.traffic = traffic
    }

    public func send(_ record: Record) async throws {
        guard !closed else { throw ProtocolFailure.peerUnavailable }
        try await withCheckedThrowingContinuation { continuation in
            writes.append(Write(record: record, continuation: continuation, buffered: false, response: false))
            if !writing { writing = true; Task { await self.drain() } }
        }
    }

    /// A bounded reply must not stop the only reader while the writer is backpressured.
    public func reply(_ record: Record) async throws {
        guard record.kind != .data, record.bytes.isEmpty else { throw ProtocolFailure.invalidFrame }
        try await responses.acquire(lifetime)
        do {
            try Task.checkCancellation()
            guard !closed else { throw ProtocolFailure.peerUnavailable }
            writes.append(Write(record: record, continuation: nil, buffered: false, response: true))
            if !writing { writing = true; Task { await self.drain() } }
        } catch { await responses.release(); throw error }
    }

    public func sendBuffered(_ produce: @Sendable () async throws -> Record) async throws -> Int {
        try await slots.acquire(lifetime)
        do { try await TransferSlots.shared.acquire(lifetime) }
        catch { await slots.release(); throw error }
        do {
            try Task.checkCancellation()
            guard !closed else { throw ProtocolFailure.peerUnavailable }
            let record = try await produce()
            guard !closed, dataEpoch == record.epoch else { throw ProtocolFailure.peerUnavailable }
            guard !discarded.contains(record.transferID) else { throw ProtocolFailure.cancelled }
            guard record.kind == .data, record.bytes.count <= (transport == .tcp ? Wire.tcpChunkSize : Wire.bleChunkSize) else { throw ProtocolFailure.oversizedRecord }
            writes.append(Write(record: record, continuation: nil, buffered: true, response: false))
            if !writing { writing = true; Task { await self.drain() } }
            return record.bytes.count
        } catch { await releaseSlot(); throw error }
    }
    public func setDataEpoch(_ epoch: UUID?) async {
        dataEpoch = epoch
        let removed = writes.filter { $0.buffered && $0.record.epoch != epoch }
        writes.removeAll { $0.buffered && $0.record.epoch != epoch }
        for _ in removed { await releaseSlot() }
    }
    public func discardBuffered(_ id: UUID) async {
        discarded.insert(id)
        let removed = writes.filter { $0.buffered && $0.record.transferID == id }
        writes.removeAll { $0.buffered && $0.record.transferID == id }
        for _ in removed { await releaseSlot() }
    }
    private func releaseSlot() async { await slots.release(); await TransferSlots.shared.release() }
    private func drain() async {
        while !writes.isEmpty && !closed {
            let write = writes.removeFirst()
            do {
                if !write.buffered || (write.record.epoch == dataEpoch && !discarded.contains(write.record.transferID)) {
                    try await raw.write(crypto.seal(write.record))
                    if Self.isControl(write.record.kind) { traffic?(true) }
                }
                write.continuation?.resume()
            }
            catch { write.continuation?.resume(throwing: error); await close() }
            if write.buffered { await releaseSlot() }
            if write.response { await responses.release() }
        }
        writing = false
    }

    public func receive() async throws -> Record {
        guard !closed else { throw ProtocolFailure.peerUnavailable }
        let header = try await raw.readExactly(12)
        var reader = BinaryReader(header)
        let length = try reader.uint32()
        guard length >= 16 + Wire.recordHeaderSize, length <= Wire.maxPlaintext + 16 else { throw ProtocolFailure.invalidFrame }
        var frame = header
        frame.append(try await raw.readExactly(Int(length)))
        let record = try crypto.open(frame)
        if Self.isControl(record.kind) { traffic?(false) }
        return record
    }
    private static func isControl(_ kind: RecordKind) -> Bool {
        switch kind {
        case .begin, .data, .finish, .acknowledge, .resume: false
        default: true
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        lifetime.close()
        await slots.removeClosedWaiters(); await responses.removeClosedWaiters(); await TransferSlots.shared.removeClosedWaiters()
        let pending = writes
        writes.removeAll()
        for write in pending {
            write.continuation?.resume(throwing: ProtocolFailure.peerUnavailable)
            if write.buffered { await releaseSlot() }
            if write.response { await responses.release() }
        }
        await raw.close()
    }
}
