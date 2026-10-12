import AndcintoshCore
import AppKit
import CoreGraphics
import Foundation

@MainActor
public final class LockController {
    private var state = LockStateMachine()
    private let clock = ContinuousClock()
    private let start = ContinuousClock.now
    private var pending: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    public init() {}
    public var permitted: Bool { CGPreflightPostEventAccess() }
    public func requestAuthorization() -> Bool { CGRequestPostEventAccess() }
    public func configure(enabled: Bool, primary: UUID?) throws {
        if enabled && !permitted { throw ProtocolFailure.permissionDenied }
        state.configure(enabled: enabled, primary: primary)
        if state.deadline == nil { clearPending() }
    }
    public func connected(_ peer: UUID) { state.connected(peer); if state.deadline == nil { clearPending() } }
    public func disconnected(_ peer: UUID, intentional: Bool) {
        state.disconnected(peer, intentional: intentional, now: start.duration(to: clock.now))
        clearPending()
        guard let deadline = state.deadline else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Andcintosh")
        pending = Task { [weak self] in
            guard let self else { return }
            do { try await self.clock.sleep(until: self.start.advanced(by: deadline)) }
            catch { return }
            if self.state.tick(now: self.start.duration(to: self.clock.now)) { self.lock() }
            self.clearPending()
        }
    }
    public func stop() { state.stop(); clearPending() }
    private func clearPending() {
        pending?.cancel(); pending = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
    }
    private func lock() {
        guard permitted else { return }
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: down)
            event?.flags = [.maskControl, .maskCommand]
            event?.post(tap: .cghidEventTap)
        }
    }
}
