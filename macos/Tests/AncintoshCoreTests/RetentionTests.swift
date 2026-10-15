import Foundation
import Testing
@testable import AncintoshCore

private final class RetentionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(days: Int) { lock.lock(); date.addTimeInterval(Double(days) * 86400); lock.unlock() }
}

@Test func completedReceiptExpiresButPublishedFileAndUnfinishedJobRemain() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), clock = RetentionClock()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TransferStore(root: root, downloads: root.appendingPathComponent("downloads"), now: { clock.now() })
    let peer = UUID(), bytes = Data([1,2,3])
    let manifest = try TransferManifest(kind: .file, name: "keep.bin", mime: "x", size: 3, sha256: Crypto.digest(bytes), origin: peer)
    #expect(try await store.begin(manifest, peer: peer) == 0)
    _ = try await store.append(peer: peer, id: manifest.id, offset: 0, bytes: bytes)
    let (_, published, fresh) = try await store.finish(peer: peer, id: manifest.id)
    #expect(fresh)
    try await store.delivered(peer: peer, id: manifest.id)
    #expect(try await store.begin(manifest, peer: peer) == 3)
    let (_, _, repeated) = try await store.finish(peer: peer, id: manifest.id)
    #expect(!repeated)
    let pending = try TransferManifest(kind: .file, name: "pending.bin", mime: "x", size: 3, sha256: Crypto.digest(bytes), origin: peer)
    _ = try await store.begin(pending, peer: peer)
    _ = try await store.append(peer: peer, id: pending.id, offset: 0, bytes: Data([1]))
    try await store.checkpoint(peer)
    clock.advance(days: 31)
    #expect(try await store.begin(manifest, peer: peer) == 0)
    #expect(try await store.begin(pending, peer: peer) == 1)
    #expect(try Data(contentsOf: published) == bytes)
    await store.closeHandles()
}

@Test func receiptCapacityIsPerPeerAndOnlyDeletesPrivateMetadata() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let peer = UUID(), other = UUID(), now = Date(), output = root.appendingPathComponent("downloads/keep.bin")
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data([7]).write(to: output)
    for index in 0..<4098 {
        let owner = index == 4097 ? other : peer
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
        let manifest = try TransferManifest(id: id, kind: .file, name: "keep.bin", mime: "x", size: 0, sha256: Crypto.digest(Data()), origin: owner)
        let directory = root.appendingPathComponent("incoming/\(owner.uuidString)/\(id.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let object: [String: Any] = ["manifest": try JSONSerialization.jsonObject(with: Wire.encodeJSON(manifest)), "peer": owner.uuidString,
            "durable": 0, "complete": true, "delivered": true, "output": output.path,
            "completedAt": now.addingTimeInterval(Double(index - 4098)).timeIntervalSinceReferenceDate]
        try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("state.json"))
    }
    let store = try TransferStore(root: root, downloads: output.deletingLastPathComponent())
    _ = try await store.restoreOutgoing()
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("incoming/\(peer.uuidString)").path).count == 4096)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("incoming/\(other.uuidString)").path).count == 1)
    #expect(try Data(contentsOf: output) == Data([7]))
}

@Test func outgoingCollectionProtectsPreparedSnapshotsAndRemovesLegacyOrphans() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TransferStore(root: root, downloads: root.appendingPathComponent("downloads"))
    let prepared = try await store.snapshotText("keep", origin: UUID())
    let orphan = root.appendingPathComponent("outgoing/legacy.blob"); try Data([9]).write(to: orphan)
    await store.collectOutgoing(keeping: [])
    #expect(FileManager.default.fileExists(atPath: prepared.url.path))
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    await store.release(prepared.url)
    #expect(!FileManager.default.fileExists(atPath: prepared.url.path))
}
