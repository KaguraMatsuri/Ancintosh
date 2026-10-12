import CryptoKit
import Foundation
import Testing
@testable import AndcintoshCore

private let macID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
private let phoneID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

@Test func independentJavaFixture() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/v1.json")))
    let a = try Hello.decode(Data(hex: fixture["macHello"]!)!)
    let b = try Hello.decode(Data(hex: fixture["androidHello"]!)!)
    let key = Data(hex: fixture["key"]!)!
    var tx = try CryptoSession(key: key, local: a, remote: b, transport: .ble)
    var rx = try CryptoSession(key: key, local: b, remote: a, transport: .ble)
    #expect(tx.root.hex == fixture["root"])
    var transcript = a.encoded(); transcript.append(b.encoded())
    #expect(Crypto.proof(key: key, transcript: transcript, role: .mac).hex == fixture["macProof"])
    let record = try Record.decode(Data(hex: fixture["record"]!)!)
    let frame = try tx.seal(record)
    #expect(frame.hex == fixture["sealed"])
    let decoded = try rx.open(frame)
    #expect(decoded == record)
}

@Test func helloAndRecordRoundTrip() throws {
    let hello = try Hello(role: .mac, peerID: macID, nonce: Data(repeating: 1, count: 32))
    #expect(hello.encoded().count == 73)
    #expect(hello.encoded().prefix(7) == Data("Ciallo~".utf8))
    #expect(try Hello.decode(hello.encoded()) == hello)
    let record = Record(.data, transferID: phoneID, offset: 1 << 40, bytes: Data([0, 128, 255]))
    #expect(try Record.decode(record.encoded()) == record)
    #expect(throws: ProtocolFailure.invalidFrame) { try Record.decode(Data([1])) }
    #expect(throws: ProtocolFailure.oversizedRecord) { try Record(.data, bytes: Data(count: 65_536)).encoded() }
}

@Test func cryptographicAuthenticationAndReplay() throws {
    let a = try Hello(role: .mac, peerID: macID, nonce: Data(repeating: 1, count: 32))
    let b = try Hello(role: .android, peerID: phoneID, nonce: Data(repeating: 2, count: 32))
    let key = Data(repeating: 3, count: 32)
    var tx = try CryptoSession(key: key, local: a, remote: b, transport: .ble)
    var rx = try CryptoSession(key: key, local: b, remote: a, transport: .ble)
    let record = Record(.data, offset: 0, bytes: Data("payload".utf8))
    let sealed = try tx.seal(record)
    #expect(try rx.open(sealed) == record)
    #expect(throws: ProtocolFailure.replay) { try rx.open(sealed) }
    var tampered = try tx.seal(record)
    tampered[tampered.count - 1] ^= 1
    #expect(throws: ProtocolFailure.authenticationFailed) { try rx.open(tampered) }
    var wrong = try CryptoSession(key: Data(repeating: 4, count: 32), local: b, remote: a, transport: .ble)
    #expect(throws: ProtocolFailure.authenticationFailed) { try wrong.open(sealed) }
    var tcp = try CryptoSession(key: key, local: b, remote: a, transport: .tcp)
    #expect(throws: ProtocolFailure.authenticationFailed) { try tcp.open(sealed) }
}

@Test func keyValidationAndHKDFRFC5869() throws {
    #expect(try Crypto.key(String(repeating: "Ab", count: 32)) == Data(repeating: 0xab, count: 32))
    #expect(throws: ProtocolFailure.invalidKey) { try Crypto.key("short") }
    let result = Crypto.derive(Data(repeating: 0x0b, count: 22), salt: Data(hex: "000102030405060708090a0b0c")!,
                               info: "", count: 32)
    #expect(result.count == 32)
    let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(repeating: 0x0b, count: 22)),
                                    salt: Data(hex: "000102030405060708090a0b0c")!,
                                    info: Data(hex: "f0f1f2f3f4f5f6f7f8f9")!, outputByteCount: 42)
    #expect(key.withUnsafeBytes { Data($0).hex } == "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
}

@Test func primaryLockPolicy() {
    var lock = LockStateMachine()
    lock.configure(enabled: true, primary: phoneID)
    lock.disconnected(phoneID, intentional: false, now: .zero)
    let tick1 = lock.tick(now: .seconds(100))
    #expect(!tick1)
    lock.connected(phoneID)
    lock.disconnected(macID, intentional: false, now: .zero)
    #expect(lock.deadline == nil)
    lock.disconnected(phoneID, intentional: false, now: .zero)
    let tick2 = lock.tick(now: .seconds(14))
    #expect(!tick2)
    lock.connected(phoneID)
    let tick3 = lock.tick(now: .seconds(20))
    #expect(!tick3)
    lock.disconnected(phoneID, intentional: false, now: .seconds(20))
    let tick4 = lock.tick(now: .seconds(35))
    #expect(tick4)
    let tick5 = lock.tick(now: .seconds(50))
    #expect(!tick5)
    lock.connected(phoneID)
    lock.disconnected(phoneID, intentional: true, now: .seconds(60))
    let tick6 = lock.tick(now: .seconds(100))
    #expect(!tick6)
}

@Test func wifiFallbackAndStableRecovery() throws {
    var route = TransportCoordinator()
    route.path(true, now: .zero)
    #expect(!route.shouldUpgrade(now: .seconds(10)))
    route.authenticated(true)
    #expect(!route.shouldUpgrade(now: .seconds(4)))
    #expect(route.shouldUpgrade(now: .seconds(5)))
    try route.activateTCP()
    route.preference(remote: false)
    #expect(route.current == .ble)
    route.preference(remote: true)
    route.path(true, now: .seconds(6))
    #expect(!route.shouldUpgrade(now: .seconds(10)))
    #expect(route.shouldUpgrade(now: .seconds(11)))
    route.path(false, now: .seconds(12))
    #expect(route.current == .ble)
}

@Test func resumableBytesAndCollisionPublication() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let downloads = base.appendingPathComponent("Downloads/Andcintosh")
    let store = try TransferStore(root: base.appendingPathComponent("state"), downloads: downloads)
    let source = base.appendingPathComponent("original.bin")
    let bytes = Data((0..<200_000).map { UInt8($0 % 251) })
    try bytes.write(to: source)
    let snapshot = try await store.snapshot(source, kind: .file, name: "original.bin", mime: "application/octet-stream", origin: macID)
    #expect(try await store.begin(snapshot.manifest, peer: phoneID) == 0)
    _ = try await store.append(peer: phoneID, id: snapshot.manifest.id, offset: 0, bytes: Data(bytes.prefix(20_000)))
    try await store.checkpoint(phoneID)
    _ = try await store.append(peer: phoneID, id: snapshot.manifest.id, offset: 20_000, bytes: Data(bytes[20_000..<30_000]))
    #expect(try await store.begin(snapshot.manifest, peer: phoneID) == 20_000)
    _ = try await store.append(peer: phoneID, id: snapshot.manifest.id, offset: 20_000, bytes: Data(bytes.dropFirst(20_000)))
    let result = try await store.finish(peer: phoneID, id: snapshot.manifest.id)
    #expect(try Data(contentsOf: result.1) == bytes)
    #expect(result.2)
    try await store.delivered(peer: phoneID, id: snapshot.manifest.id)
    #expect(try await store.finish(peer: phoneID, id: snapshot.manifest.id).2 == false)
    let duplicate = try await store.snapshot(source, kind: .file, name: "original.bin", mime: "application/octet-stream", origin: macID)
    _ = try await store.begin(duplicate.manifest, peer: phoneID)
    _ = try await store.append(peer: phoneID, id: duplicate.manifest.id, offset: 0, bytes: bytes)
    let saved = try await store.finish(peer: phoneID, id: duplicate.manifest.id)
    #expect(saved.1.lastPathComponent == "original (1).bin")
}

@Test func invalidPathsAndCorruptedFilesNeverPublish() async throws {
    #expect(throws: ProtocolFailure.invalidName) {
        try TransferManifest(kind: .file, name: "../escape", mime: "x", size: 0, sha256: Crypto.digest(Data()), origin: macID)
    }
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let downloads = base.appendingPathComponent("downloads")
    let store = try TransferStore(root: base.appendingPathComponent("state"), downloads: downloads)
    let manifest = try TransferManifest(kind: .file, name: "test", mime: "x", size: 3, sha256: Crypto.digest(Data([1, 2, 3])), origin: macID)
    _ = try await store.begin(manifest, peer: phoneID)
    _ = try await store.append(peer: phoneID, id: manifest.id, offset: 0, bytes: Data([3, 2, 1]))
    await #expect(throws: ProtocolFailure.digestMismatch) { try await store.finish(peer: phoneID, id: manifest.id) }
    #expect(!FileManager.default.fileExists(atPath: downloads.appendingPathComponent("test").path))
}
