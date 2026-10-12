import Foundation

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
    public static func authenticate(channel: any ByteChannel, role: PeerRole, identity: UUID,
                                    key: Data, context: UUID = Wire.zeroID, transport: TransportKind,
                                    expectedPeer: UUID? = nil, remoteHello: Hello? = nil) async throws -> Authentication {
        let local = try Hello(role: role, peerID: identity, contextID: context, nonce: Crypto.random(32))
        try await channel.write(local.encoded())
        let remote: Hello
        if let remoteHello { remote = remoteHello }
        else { remote = try Hello.decode(await channel.readExactly(Wire.helloSize)) }
        guard remote.role != role, remote.contextID == context,
              expectedPeer == nil || expectedPeer == remote.peerID else { throw ProtocolFailure.authenticationFailed }
        let mac = role == .mac ? local : remote
        let android = role == .android ? local : remote
        var transcript = mac.encoded()
        transcript.append(android.encoded())
        try await channel.write(Crypto.proof(key: key, transcript: transcript, role: role))
        let proof = try await channel.readExactly(32)
        guard Crypto.verify(proof, key: key, transcript: transcript, role: remote.role) else { throw ProtocolFailure.authenticationFailed }
        return try Authentication(peer: remote.peerID, session: CryptoSession(key: key, local: local, remote: remote, transport: transport))
    }
}

public actor EncryptedChannel {
    public let transport: TransportKind
    public let root: Data
    private let raw: any ByteChannel
    private var crypto: CryptoSession
    private var writes: [(Record, CheckedContinuation<Void, any Error>)] = []
    private var writing = false
    private var closed = false

    public init(raw: any ByteChannel, authentication: Authentication, transport: TransportKind) {
        self.raw = raw; crypto = authentication.session; root = authentication.session.root; self.transport = transport
    }

    public func send(_ record: Record) async throws {
        guard !closed else { throw ProtocolFailure.peerUnavailable }
        try await withCheckedThrowingContinuation { continuation in
            writes.append((record, continuation))
            if !writing { writing = true; Task { await self.drain() } }
        }
    }

    private func drain() async {
        while !writes.isEmpty && !closed {
            let (record, continuation) = writes.removeFirst()
            do { try await raw.write(crypto.seal(record)); continuation.resume() }
            catch { continuation.resume(throwing: error); await close() }
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
        return try crypto.open(frame)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        let pending = writes
        writes.removeAll()
        for (_, continuation) in pending { continuation.resume(throwing: ProtocolFailure.peerUnavailable) }
        await raw.close()
    }
}
