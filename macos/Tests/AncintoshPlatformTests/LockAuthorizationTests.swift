import AncintoshCore
import Testing
@testable import AncintoshPlatform

@MainActor @Test func deniedAuthorizationRequestsOnlyOnceAndSurvivesStop() throws {
    var requests = 0
    var permitted = false
    let controller = LockController(authorizationCheck: { permitted }, authorizationRequest: { requests += 1; return false })
    #expect(!controller.authorizationRequested)
    let first = controller.requestAuthorization()
    #expect(!first)
    #expect(controller.authorizationRequested)
    controller.stop()
    try controller.configure(enabled: false, primary: nil)
    for _ in 0..<5 {
        let repeated = controller.requestAuthorization()
        #expect(!repeated)
    }
    #expect(requests == 1)
    #expect(throws: ProtocolFailure.permissionDenied) { try controller.configure(enabled: true, primary: nil) }
    permitted = true
    let afterSettings = controller.requestAuthorization()
    #expect(afterSettings)
    #expect(requests == 1)
}

@MainActor @Test func authorizationIsMarkedBeforeSystemRequestCanReenter() {
    var requests = 0
    var nestedAllowed: Bool?
    var controller: LockController!
    controller = LockController(authorizationCheck: { false }, authorizationRequest: {
        requests += 1
        nestedAllowed = controller.requestAuthorization()
        return false
    })
    let allowed = controller.requestAuthorization()
    #expect(!allowed)
    #expect(nestedAllowed == false)
    #expect(requests == 1)
    controller = nil
}

@MainActor @Test func newControllerAllowsFreshRequestAndExistingPermissionSkipsPrompt() {
    var requests = 0
    let first = LockController(authorizationCheck: { false }, authorizationRequest: { requests += 1; return false })
    let second = LockController(authorizationCheck: { false }, authorizationRequest: { requests += 1; return false })
    _ = first.requestAuthorization()
    _ = second.requestAuthorization()
    #expect(requests == 2)
    let permitted = LockController(authorizationCheck: { true }, authorizationRequest: { requests += 1; return true })
    let allowed = permitted.requestAuthorization()
    #expect(allowed)
    #expect(!permitted.authorizationRequested)
    #expect(requests == 2)
}
