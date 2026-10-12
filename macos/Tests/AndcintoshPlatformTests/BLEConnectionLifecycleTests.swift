import Foundation
import Testing
@testable import AndcintoshPlatform

@MainActor @Test func nativeAutoReconnectCallbackIsRegistered() {
    let callback = NSSelectorFromString("centralManager:didDisconnectPeripheral:timestamp:isReconnecting:error:")
    #expect(BLEClient.instancesRespond(to: callback))
}

@Test func systemReconnectDoesNotIssueDuplicateConnectionOrTrustPhysicalLink() throws {
    var state = BLEConnectionLifecycle()
    let device = UUID()
    state.register(device)
    let first = state.beginConnection(device)
    let duplicate = state.beginConnection(device)
    #expect(first && !duplicate)
    let originalValue = state.beginOpening(device)
    let original = try #require(originalValue)
    let originalAuth = state.beginAuthentication(device)
    #expect(originalAuth == original)
    let ready = state.authenticated(device, token: original)
    #expect(ready)
    state.disconnected(device, reconnecting: true)
    #expect(state.phase(device) == .reconnecting)
    let parallel = state.beginConnection(device)
    #expect(!parallel)
    #expect(!state.isCurrent(device, token: original))
    let recoveredValue = state.beginOpening(device)
    let recovered = try #require(recoveredValue)
    #expect(state.phase(device) == .opening)
    let premature = state.authenticated(device, token: recovered)
    #expect(!premature)
    let recoveredAuth = state.beginAuthentication(device)
    #expect(recoveredAuth == recovered)
    let authenticated = state.authenticated(device, token: recovered)
    #expect(authenticated)
}

@Test func stopOrRadioLossRejectsLateAuthenticationAndAllowsExplicitRestart() throws {
    for stop in [true, false] {
        var state = BLEConnectionLifecycle()
        let device = UUID()
        state.register(device)
        let tokenValue = state.beginOpening(device)
        let token = try #require(tokenValue)
        _ = state.beginAuthentication(device)
        if stop { state.stop() } else { state.radioUnavailable() }
        let late = state.authenticated(device, token: token)
        #expect(!late)
        if stop {
            let latePhysical = state.beginOpening(device)
            #expect(latePhysical == nil)
        }
        state.register(device)
        let restart = state.beginConnection(device)
        #expect(restart)
    }
}

@Test func lostDataChannelReopensOnceWithoutOverridingSystemReconnect() throws {
    var state = BLEConnectionLifecycle()
    let device = UUID(), other = UUID()
    state.register(device); state.register(other)
    let tokenValue = state.beginOpening(device)
    let token = try #require(tokenValue)
    _ = state.beginAuthentication(device)
    _ = state.authenticated(device, token: token)
    let lost = state.sessionLost(device)
    let repeated = state.sessionLost(device)
    #expect(lost && !repeated)
    #expect(!state.isCurrent(device, token: token))
    let reopeningValue = state.beginOpening(device)
    let reopening = try #require(reopeningValue)
    state.disconnected(device, reconnecting: true)
    let physicalLossEvent = state.sessionLost(device)
    #expect(!physicalLossEvent)
    #expect(!state.isCurrent(device, token: reopening))
    #expect(state.phase(other) == .idle)
}

@Test func authenticationFailureCannotStartAnAutomaticRetryLoop() throws {
    var state = BLEConnectionLifecycle()
    let device = UUID()
    state.register(device)
    let tokenValue = state.beginOpening(device)
    let token = try #require(tokenValue)
    _ = state.beginAuthentication(device)
    state.fail(device)
    state.disconnected(device, reconnecting: true)
    state.radioUnavailable()
    let automatic = state.beginConnection(device)
    let unsolicited = state.beginOpening(device)
    let stale = state.authenticated(device, token: token)
    #expect(!automatic && unsolicited == nil && !stale)
    state.reset(device)
    let manual = state.beginConnection(device)
    #expect(manual)
}
