import CryptoKit
import Foundation
import Testing
@testable import AncintoshCore

private func vector() throws -> [String: String] {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/v2.json")))
}

@Test func x25519RFCVectorAndTrafficKeyBoundary() throws {
    let v = try vector()
    let a = try Hello.decode(Data(hex: v["macHello"]!)!)
    let b = try Hello.decode(Data(hex: v["androidHello"]!)!)
    let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: v["macPrivateKey"]!)!)
    let shared = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: b.publicKey)).withUnsafeBytes { Data($0) }
    #expect(shared.hex == v["sharedSecret"])
    let key = Data(hex: v["key"]!)!
    var tx = try CryptoSession(key: key, local: a, remote: b, transport: .ble, sharedSecret: shared)
    var rx = try CryptoSession(key: key, local: b, remote: a, transport: .ble, sharedSecret: shared)
    tx.txSequence = (1 << 20) - 1; rx.rxSequence = (1 << 20) - 1
    let record = Record(.data, bytes: Data([1, 2, 3]))
    for _ in 0..<3 {
        let frame = try tx.seal(record)
        let result = try rx.open(frame)
        #expect(result == record)
    }
    #expect(throws: ProtocolFailure.invalidHandshake) {
        try CryptoSession(key: key, local: a, remote: b, transport: .ble, sharedSecret: Data(count: 32))
    }
}

private actor ForgedFinishedChannel: ByteChannel {
    let remote: Hello
    let key: Data
    var local: Hello?
    var read = 0
    init(remote: Hello, key: Data) { self.remote = remote; self.key = key }
    func write(_ bytes: Data) throws { if local == nil { local = try Hello.decode(bytes) } }
    func readExactly(_ count: Int) throws -> Data {
        defer { read += 1 }
        switch read {
        case 0: return Data(remote.encoded().prefix(8))
        case 1: return Data(remote.encoded().dropFirst(8))
        case 2:
            return Crypto.proof(key: key, transcript: Crypto.transcript(local: local!, remote: remote, transport: .ble), role: remote.role)
        default: return Data(count: 32)
        }
    }
    func close() {}
}

@Test func validSharedKeyProofDoesNotBypassFinished() async throws {
    let remoteKey = Curve25519.KeyAgreement.PrivateKey()
    let remote = try Hello(role: .android, peerID: UUID(), nonce: Data(repeating: 2, count: 32), publicKey: remoteKey.publicKey.rawRepresentation)
    let key = Data(repeating: 3, count: 32)
    let channel = ForgedFinishedChannel(remote: remote, key: key)
    await #expect(throws: ProtocolFailure.authenticationFailed) {
        try await Handshake.authenticate(channel: channel, role: .mac, identity: UUID(), key: key, transport: .ble, expectedPeer: remote.peerID)
    }
}

private actor LegacyChannel: ByteChannel {
    func write(_ data: Data) {}
    func readExactly(_ count: Int) throws -> Data {
        #expect(count == 8)
        return Wire.magic + Data([1])
    }
    func close() {}
}
@Test func legacyVersionFailsBeforeReadingBody() async {
    await #expect(throws: ProtocolFailure.unsupportedVersion) { try await Handshake.readHello(channel: LegacyChannel()) }
}
