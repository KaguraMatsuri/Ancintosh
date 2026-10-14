#if DEBUG
import Foundation
import Testing
@testable import AncintoshCore

@Test func boundedMemoryPipePreservesBytesAndReleasesBlockedWriters() async throws {
    let (left, right) = MemoryByteChannel.pair()
    let frame = Data(repeating: 5, count: 60_000)
    try await left.write(frame); try await left.write(frame)
    let blocked = Task { try await left.write(frame) }
    #expect(try await right.readExactly(60_000) == frame)
    try await blocked.value
    #expect(try await right.readExactly(120_000) == frame + frame)
    let read = Task { try await right.readExactly(1) }
    await left.close()
    await #expect(throws: ProtocolFailure.peerUnavailable) { try await read.value }
}
@Test func memoryHandshakeRejectsDifferentPSKs() async throws {
    let (left, right) = MemoryByteChannel.pair()
    let a = Task { try await Handshake.authenticate(channel: left, role: .mac, identity: UUID(), key: Data(repeating: 1, count: 32), transport: .ble) }
    let b = Task { try await Handshake.authenticate(channel: right, role: .android, identity: UUID(), key: Data(repeating: 2, count: 32), transport: .ble) }
    await #expect(throws: ProtocolFailure.authenticationFailed) { try await a.value }
    await #expect(throws: ProtocolFailure.authenticationFailed) { try await b.value }
    await left.close()
}
@Test func notificationSharedFixtureMatchesWireFields() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let value = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("protocol/fixtures/notification.json"))) as! [String: Any]
    let upsert = try Wire.decodeJSON(NotificationMessage.self, JSONSerialization.data(withJSONObject: value["upsert"]!)).validated()
    let remove = try Wire.decodeJSON(NotificationMessage.self, JSONSerialization.data(withJSONObject: value["remove"]!)).validated()
    let access = try Wire.decodeJSON(NotificationAccess.self, JSONSerialization.data(withJSONObject: value["access"]!))
    #expect(upsert.id == remove.id && upsert.title == "Ciallo~" && access.enabled == true)
}
@Test func notificationBudgetAndLatestEventQueue() throws {
    let id = UUID(), text = String(repeating: "👩🏽‍💻\"\n", count: 2000)
    let value = try NotificationMessage.bounded(id: id, application: "Ancintosh", title: "Mac", body: text)
    #expect(try Wire.encodeJSON(value).count <= Wire.maxMetadata)
    #expect(text.hasPrefix(value.body))
    var queue = NotificationQueue()
    queue.append(value); queue.append(NotificationMessage(id: id, action: .remove))
    #expect(queue.count == 1 && queue.pop()?.action == .remove)
    for _ in 0..<256 { queue.append(NotificationMessage(id: UUID(), action: .remove)) }
    #expect(queue.count == NotificationQueue.capacity)
}
#endif
