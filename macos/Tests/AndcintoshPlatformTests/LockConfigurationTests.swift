import AndcintoshCore
import Foundation
import Testing
@testable import AndcintoshPlatform

private struct LegacyConfiguration: Codable {
    let identity: UUID
    let peers: [PeerProfile]
    let primary: UUID?
    let lockEnabled: Bool
    let wifi: Bool
}

@Test func legacyMacConfigurationDefaultsDelayAndPreservesPairing() throws {
    let identity = UUID(), device = UUID(), peer = UUID()
    let legacy = LegacyConfiguration(identity: identity, peers: [PeerProfile(id: device, identity: peer, name: "fixture")],
                                     primary: device, lockEnabled: true, wifi: false)
    let restored = try Wire.decodeJSON(MacConfiguration.self, Wire.encodeJSON(legacy))
    #expect(restored.lockDelaySeconds == 15)
    #expect(restored.identity == identity)
    #expect(restored.peers.count == 1)
    #expect(restored.peers.first?.id == device)
    #expect(restored.peers.first?.identity == peer)
    #expect(restored.primary == device)
    #expect(restored.lockEnabled)
    #expect(!restored.wifi)
}

@Test func configuredMacDelayRoundTripsAndRejectsInvalidStoredValues() throws {
    for seconds in [1, 15, 3600] {
        var configuration = MacConfiguration()
        configuration.lockDelaySeconds = seconds
        let restored = try Wire.decodeJSON(MacConfiguration.self, Wire.encodeJSON(configuration))
        #expect(restored.lockDelaySeconds == seconds)
        #expect(restored.identity == configuration.identity)
    }
    for seconds in [-1, 0, 3601] {
        var configuration = MacConfiguration()
        configuration.lockDelaySeconds = seconds
        let data = try Wire.encodeJSON(configuration)
        #expect(throws: DecodingError.self) { try Wire.decodeJSON(MacConfiguration.self, data) }
    }
}

@MainActor @Test func delayEditingDoesNotRequestLockPermission() throws {
    var requests = 0
    let controller = LockController(authorizationCheck: { false }, authorizationRequest: { requests += 1; return false })
    try controller.setDelay(seconds: 30)
    #expect(requests == 0)
    #expect(!controller.authorizationRequested)
    #expect(throws: LockConfigurationError.invalidDelay) { try controller.setDelay(seconds: 0) }
    #expect(throws: ProtocolFailure.permissionDenied) { try controller.configure(enabled: true, primary: UUID()) }
    #expect(requests == 0)
}
