import Foundation
import Testing
import AndcintoshCore
@testable import AndcintoshPlatform

@MainActor @Test func layoutPersistsIndependentlyOfPriorityAndPrimary() throws {
    let suite = "Andcintosh.topology.\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let a = PeerProfile(id: UUID(), identity: UUID(), name: "A"), b = PeerProfile(id: UUID(), identity: UUID(), name: "B")
    var config = MacConfiguration(); config.peers = [a,b]; config.primary = b.id
    prefs.set(try Wire.encodeJSON(config), forKey: "Andcintosh.configuration")
    let runtime = try MacRuntime(preferences: prefs, root: root, downloads: root.appendingPathComponent("downloads"))
    runtime.placeNodes([a.id: NodePosition(x: -1, y: 2), b.id: NodePosition(x: 0.7, y: 0.4), UUID(): NodePosition(x: 0, y: 0)])
    #expect(runtime.configuration.nodePositions.count == 2)
    #expect(runtime.configuration.nodePositions[a.id.uuidString] == NodePosition(x: 0, y: 1))
    #expect(runtime.configuration.peers.map(\.id) == [a.id,b.id] && runtime.configuration.primary == b.id)
    let positions = runtime.configuration.nodePositions
    runtime.placeNodes([a.id: NodePosition(x: .nan, y: 0)])
    runtime.movePeers(from: IndexSet(integer: 1), to: 0)
    #expect(runtime.configuration.nodePositions == positions && runtime.configuration.primary == b.id)
    let saved = try Wire.decodeJSON(MacConfiguration.self, #require(prefs.data(forKey: "Andcintosh.configuration")))
    #expect(saved.nodePositions == positions && saved.peers.first?.id == b.id)
}

@MainActor @Test func macOwnsNamesAndDeduplicatesOfflineRenameRequests() throws {
    let suite = "Andcintosh.config.\(UUID())", root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let prefs = try #require(UserDefaults(suiteName: suite))
    defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    let phone = UUID(), a = PeerProfile(id: UUID(), identity: phone, name: "Mac 管理的名称")
    var config = MacConfiguration(); config.peers = [a]; config.primary = a.id
    prefs.set(try Wire.encodeJSON(config), forKey: "Andcintosh.configuration")
    let runtime = try MacRuntime(preferences: prefs, root: root, downloads: root.appendingPathComponent("downloads"))
    try runtime.acceptDeviceInformation(phone, DeviceInformation(name: "系统旧名称", kind: .pad, wifi: false))
    #expect(runtime.configuration.peers[0].name == a.name)
    #expect(runtime.configuration.peers[0].kind == .pad && runtime.configuration.peers[0].wifi == false)
    let request = UUID(), change = DeviceInformation(name: "平板", kind: .pad, wifi: false, renameRequest: request)
    try runtime.acceptDeviceInformation(phone, change)
    let revision = runtime.configuration.revision
    try runtime.acceptDeviceInformation(phone, change)
    #expect(runtime.configuration.revision == revision && runtime.configuration.peers[0].renameRequest == request)
    #expect(runtime.configuration.peers[0].name == "平板" && runtime.configuration.primary == a.id)
    try runtime.renameMac("工作 Mac")
    try runtime.renamePeer(a.id, name: "Mac 新名称")
    let restored = try MacRuntime(preferences: prefs, root: root, downloads: root.appendingPathComponent("downloads"))
    try restored.acceptDeviceInformation(phone, change)
    #expect(restored.configuration.revision == revision + 2 && restored.configuration.name == "工作 Mac")
    try restored.acceptDeviceInformation(UUID(), change)
    try restored.acceptDeviceInformation(phone, DeviceInformation(name: "invalid", kind: .mac, wifi: true))
    #expect(restored.configuration.peers[0].name == "Mac 新名称")
    #expect(throws: ProtocolFailure.oversizedRecord) { try restored.renameMac(String(repeating: "x", count: Wire.maxMetadata)) }
    #expect(restored.configuration.name == "工作 Mac")
}
