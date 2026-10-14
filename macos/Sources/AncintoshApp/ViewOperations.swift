import Foundation
import Observation

/// UI-only operation gates. Each scope has its own observation dependency.
@MainActor final class ViewOperations {
    enum Scope: Hashable {
        case lifecycle, wifi, lock, files, demonstration
        case peer(UUID)
    }

    @Observable fileprivate final class Status {
        var active = false
    }

    private var statuses: [Scope: Status] = [:]
    private var active: Set<Scope> = []
    private let lifecycle = Status()
    private let any = Status()

    func busy(_ scopes: Set<Scope>) -> Bool {
        if scopes.contains(.lifecycle) { return any.active }
        return lifecycle.active || scopes.contains { status($0).active }
    }

    @discardableResult func begin(_ scopes: Set<Scope>) -> Bool {
        guard !scopes.isEmpty, !busy(scopes) else { return false }
        active.formUnion(scopes)
        for scope in scopes { status(scope).active = true }
        if !any.active { any.active = true }
        return true
    }

    func finish(_ scopes: Set<Scope>) {
        for scope in scopes where active.remove(scope) != nil { status(scope).active = false }
        if any.active != !active.isEmpty { any.active = !active.isEmpty }
    }

    private func status(_ scope: Scope) -> Status {
        if scope == .lifecycle { return lifecycle }
        if let status = statuses[scope] { return status }
        let value = Status()
        statuses[scope] = value
        return value
    }
}
