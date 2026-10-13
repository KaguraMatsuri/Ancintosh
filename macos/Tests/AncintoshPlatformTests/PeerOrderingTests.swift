import Foundation
import Testing
import AncintoshCore
@testable import AncintoshPlatform

@MainActor @Test func deviceOrderPersistsWithoutChangingPrimaryOrPreferences() throws {
    let suite = "Ancintosh.tests.\(UUID())"
    let preferences = try #require(UserDefaults(suiteName: suite))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
    defer { preferences.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    var configuration = MacConfiguration()
    let a = PeerProfile(id: UUID(), identity: UUID(), name: "A")
    let b = PeerProfile(id: UUID(), identity: UUID(), name: "B")
    let c = PeerProfile(id: UUID(), identity: UUID(), name: "C")
    configuration.peers = [a,b,c]; configuration.primary = b.id; configuration.lockEnabled = true
    configuration.wifi = false; configuration.lockDelaySeconds = 30
    preferences.set(try Wire.encodeJSON(configuration), forKey: "Andcintosh.configuration")
    let runtime = try MacRuntime(preferences: preferences, root: root.appendingPathComponent("data"), downloads: root.appendingPathComponent("downloads"))
    runtime.movePeers(from: IndexSet(integer: 2), to: 0)
    #expect(runtime.configuration.peers.map(\.id) == [c.id,a.id,b.id])
    let saved = try Wire.decodeJSON(MacConfiguration.self, #require(preferences.data(forKey: "Andcintosh.configuration")))
    #expect(saved.peers.map(\.id) == [c.id,a.id,b.id])
    #expect(saved.primary == b.id && saved.lockEnabled && !saved.wifi && saved.lockDelaySeconds == 30)
    #expect(runtime.connected.isEmpty && !runtime.running)
    runtime.movePeers(from: IndexSet(integer: 0), to: 3)
    #expect(runtime.configuration.peers.map(\.id) == [a.id,b.id,c.id])
    runtime.movePeers(from: IndexSet(integer: 9), to: 0)
    #expect(runtime.configuration.peers.map(\.id) == [a.id,b.id,c.id])
}
