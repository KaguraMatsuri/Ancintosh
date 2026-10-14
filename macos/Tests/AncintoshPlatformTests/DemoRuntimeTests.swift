#if DEBUG
import Foundation
import Testing
import AncintoshCore
@testable import AncintoshPlatform

@MainActor private func fixture() throws -> (MacRuntime, UUID) {
    let id = UUID()
    var profile = PeerProfile(id: id, identity: id, name: "Galaxy S24 Ultra"); profile.kind = .phone; profile.wifi = true
    var configuration = MacConfiguration(); configuration.peers = [profile]
    return (try MacRuntime(demonstration: configuration, traffic: ConnectionTraffic()), id)
}
@MainActor private func wait(_ predicate: () -> Bool) async throws {
    for _ in 0..<2000 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
    Issue.record("stateTimeout")
}
@MainActor @Test func demoUsesRealAuthenticationEchoAndNotificationPolicy() async throws {
    let (runtime, peer) = try fixture()
    runtime.start()
    try await runtime.verify(peer)
    #expect(runtime.connected.contains(peer))
    try await runtime.test(.connection, peer: peer)
    #expect(runtime.demonstrationResult?.passed == true)
    runtime.demonstrationText = "Ciallo~ 👩🏽‍💻"
    try await runtime.test(.clipboard, peer: peer)
    #expect(runtime.demonstrationReceivedText == runtime.demonstrationText)
    try await runtime.shareNotifications(peer, enabled: true)
    try await runtime.test(.notification, peer: peer)
    #expect(runtime.receivedNotifications.values.first?.body == runtime.demonstrationText)
    #expect(runtime.demonstrationResult?.passed == true)
    await runtime.dispose()
    #expect(runtime.connected.isEmpty && runtime.packetTraffic.visible.isEmpty)
}
@MainActor @Test func demoFileRoundTripAndWifiFallback() async throws {
    let (runtime, peer) = try fixture()
    let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: source) }
    try Data(repeating: 9, count: 1_048_576).write(to: source)
    runtime.start(); try await runtime.verify(peer)
    try await wait { runtime.routes[peer] == .tcp }
    #expect(runtime.routes[peer] == .tcp)
    await runtime.wifi(false)
    try await wait { runtime.routes[peer] == .ble }
    try await runtime.files([source], peer: peer)
    try await wait { runtime.demonstrationResult?.passed != nil }
    #expect(runtime.demonstrationResult?.passed == true)
    #expect(runtime.transfers.isEmpty)
    await runtime.dispose()
}
@MainActor @Test func demoLockUsesInjectedOutputAndCanRestartAfterStop() async throws {
    let (runtime, peer) = try fixture()
    runtime.start(); try await runtime.verify(peer)
    try runtime.saveLockDelay(seconds: 1)
    try await runtime.test(.lock, peer: peer)
    #expect(runtime.demonstrationResult?.passed == true && runtime.connected.contains(peer))
    await runtime.stop()
    runtime.start(); try await runtime.verify(peer)
    #expect(runtime.connected.contains(peer))
    await runtime.dispose()
}
@MainActor @Test func demoCancellationClearsWaitersAndTemporaryState() async throws {
    let manager = FileManager.default
    let before = Set(try manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("Ancintosh-demo-") })
    let (runtime, peer) = try fixture()
    let created = Set(try manager.contentsOfDirectory(at: manager.temporaryDirectory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("Ancintosh-demo-") }).subtracting(before)
    #expect(created.count == 1)
    runtime.start(); try await runtime.verify(peer)
    try runtime.saveLockDelay(seconds: 30)
    let task = Task { try await runtime.test(.lock, peer: peer) }
    try await wait { runtime.isTesting && !runtime.connected.contains(peer) }
    await runtime.cancelTest()
    _ = try? await task.value
    #expect(runtime.demonstrationResult?.failure == .cancelled)
    await runtime.dispose()
    for root in created { #expect(!manager.fileExists(atPath: root.path)) }
}
#endif
