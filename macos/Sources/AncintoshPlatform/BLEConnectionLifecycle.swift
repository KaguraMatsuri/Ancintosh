import Foundation

/// Tracks connection intent separately from the physical CoreBluetooth link.
struct BLEConnectionLifecycle {
    enum Phase { case idle, connecting, reconnecting, opening, authenticating, ready, failed }
    private struct Entry {
        var token = UUID()
        var phase: Phase = .idle
    }
    private var entries: [UUID: Entry] = [:]

    func phase(_ device: UUID) -> Phase? { entries[device]?.phase }
    func isCurrent(_ device: UUID, token: UUID) -> Bool { entries[device]?.token == token }
    mutating func register(_ device: UUID) { if entries[device] == nil { entries[device] = Entry() } }
    mutating func reset(_ device: UUID) { entries[device] = Entry() }
    mutating func beginConnection(_ device: UUID) -> Bool {
        guard entries[device]?.phase == .idle else { return false }
        entries[device]?.phase = .connecting
        return true
    }
    mutating func beginOpening(_ device: UUID) -> UUID? {
        guard let phase = entries[device]?.phase, phase == .idle || phase == .connecting || phase == .reconnecting else { return nil }
        let entry = Entry(token: UUID(), phase: .opening)
        entries[device] = entry
        return entry.token
    }
    mutating func beginAuthentication(_ device: UUID) -> UUID? {
        guard entries[device]?.phase == .opening else { return nil }
        entries[device]?.phase = .authenticating
        return entries[device]?.token
    }
    mutating func authenticated(_ device: UUID, token: UUID) -> Bool {
        guard isCurrent(device, token: token), entries[device]?.phase == .authenticating else { return false }
        entries[device]?.phase = .ready
        return true
    }
    mutating func disconnected(_ device: UUID, reconnecting: Bool) {
        guard let phase = entries[device]?.phase, phase != .failed else { return }
        entries[device] = Entry(token: UUID(), phase: reconnecting ? .reconnecting : .idle)
    }
    mutating func sessionLost(_ device: UUID) -> Bool {
        guard entries[device]?.phase == .ready else { return false }
        entries[device] = Entry()
        return true
    }
    mutating func fail(_ device: UUID) { if entries[device] != nil { entries[device] = Entry(token: UUID(), phase: .failed) } }
    mutating func radioUnavailable() {
        for device in entries.keys { disconnected(device, reconnecting: false) }
    }
    mutating func stop() { entries.removeAll() }
}
