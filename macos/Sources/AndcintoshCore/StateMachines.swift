import Foundation

public struct TransportCoordinator: Sendable {
    public private(set) var localWifi = true
    public private(set) var remoteWifi = true
    public private(set) var bleAuthenticated = false
    public private(set) var current: TransportKind = .ble
    private var wifiAvailableSince: Duration?

    public init() {}
    public mutating func authenticated(_ value: Bool) {
        bleAuthenticated = value
        if !value { current = .ble; wifiAvailableSince = nil }
    }
    public mutating func preference(local: Bool? = nil, remote: Bool? = nil) {
        if let local { localWifi = local }
        if let remote { remoteWifi = remote }
        if !localWifi || !remoteWifi { current = .ble; wifiAvailableSince = nil }
    }
    public mutating func path(_ available: Bool, now: Duration) {
        if !available { wifiAvailableSince = nil; current = .ble }
        else if localWifi && remoteWifi && wifiAvailableSince == nil { wifiAvailableSince = now }
    }
    public func shouldUpgrade(now: Duration) -> Bool {
        guard bleAuthenticated, localWifi, remoteWifi, let since = wifiAvailableSince else { return false }
        return current == .ble && now - since >= .seconds(5)
    }
    public mutating func activateTCP() throws {
        guard bleAuthenticated && localWifi && remoteWifi else { throw ProtocolFailure.peerUnavailable }
        current = .tcp
    }
    public mutating func tcpLost() { current = .ble; wifiAvailableSince = nil }
}

public enum LockConfigurationError: Error, Sendable { case invalidDelay }

public struct LockStateMachine: Sendable {
    public private(set) var enabled = false
    public private(set) var primary: UUID?
    public private(set) var armed = false
    public private(set) var deadline: Duration?
    public private(set) var delaySeconds = 15
    public init() {}
    public mutating func setDelay(seconds: Int) throws {
        guard (1...3600).contains(seconds) else { throw LockConfigurationError.invalidDelay }
        delaySeconds = seconds
    }
    public mutating func configure(enabled: Bool, primary: UUID?) {
        if self.primary != primary || !enabled { armed = false; deadline = nil }
        self.enabled = enabled
        self.primary = primary
    }
    public mutating func connected(_ peer: UUID) {
        if enabled && peer == primary { armed = true; deadline = nil }
    }
    public mutating func disconnected(_ peer: UUID, intentional: Bool, now: Duration) {
        guard peer == primary else { return }
        if intentional { armed = false; deadline = nil }
        else if enabled && armed && deadline == nil { deadline = now + .seconds(delaySeconds) }
    }
    public mutating func tick(now: Duration) -> Bool {
        guard enabled, armed, let deadline, now >= deadline else { return false }
        armed = false
        self.deadline = nil
        return true
    }
    public mutating func stop() { armed = false; deadline = nil }
}

public struct OutboundJob: Sendable, Codable {
    public let peer: UUID
    public let manifest: TransferManifest
    public let snapshot: URL
    public let userInitiated: Bool
    public var offset: UInt64
    public var begun = false
    public var waitingForResume = false
    public var finished = false
    public var failure: ProtocolFailure?
    public init(peer: UUID, manifest: TransferManifest, snapshot: URL, userInitiated: Bool, offset: UInt64 = 0) {
        self.peer = peer; self.manifest = manifest; self.snapshot = snapshot
        self.userInitiated = userInitiated; self.offset = offset
    }
}

public struct TransferScheduler: Sendable {
    private var clipboard: [OutboundJob] = []
    private var files: [OutboundJob] = []
    public init() {}
    public var jobs: [OutboundJob] { clipboard + files }
    public func firstFilePeer(available: Set<UUID>) -> UUID? {
        files.first(where: { available.contains($0.peer) && $0.failure == nil })?.peer
    }
    public func ready(available: Set<UUID>, includeFiles: Bool = true) -> Bool {
        if clipboard.contains(where: { available.contains($0.peer) && !$0.finished && !$0.waitingForResume && $0.failure == nil }) { return true }
        guard includeFiles else { return false }
        if let file = files.first(where: { available.contains($0.peer) && $0.failure == nil }) { return !file.finished && !file.waitingForResume }
        return false
    }
    public mutating func enqueue(_ job: OutboundJob) {
        if job.manifest.kind == .file { files.append(job) }
        else {
            clipboard.removeAll { $0.peer == job.peer && !$0.begun && !$0.userInitiated }
            if job.userInitiated { clipboard.insert(job, at: 0) } else { clipboard.append(job) }
        }
    }
    public mutating func next(available: Set<UUID>, includeFiles: Bool = true) -> OutboundJob? {
        if let index = clipboard.firstIndex(where: { available.contains($0.peer) && !$0.finished && !$0.waitingForResume && $0.failure == nil }) { return clipboard.remove(at: index) }
        guard includeFiles else { return nil }
        if let index = files.firstIndex(where: { available.contains($0.peer) && $0.failure == nil }) {
            if !files[index].finished && !files[index].waitingForResume { return files.remove(at: index) }
        }
        return nil
    }
    public mutating func requeue(_ job: OutboundJob) {
        if job.manifest.kind == .file { files.insert(job, at: 0) } else { clipboard.insert(job, at: 0) }
    }
    public mutating func remove(_ id: UUID, peer: UUID) {
        clipboard.removeAll { $0.peer == peer && $0.manifest.id == id }
        files.removeAll { $0.peer == peer && $0.manifest.id == id }
    }
    public mutating func fail(_ id: UUID, peer: UUID, error: ProtocolFailure?) {
        for index in clipboard.indices where clipboard[index].peer == peer && clipboard[index].manifest.id == id { clipboard[index].failure = error; clipboard[index].begun = false; clipboard[index].waitingForResume = false; clipboard[index].finished = false }
        for index in files.indices where files[index].peer == peer && files[index].manifest.id == id { files[index].failure = error; files[index].begun = false; files[index].waitingForResume = false; files[index].finished = false }
    }
    public mutating func resume(_ id: UUID, peer: UUID, offset: UInt64) throws {
        for index in clipboard.indices where clipboard[index].peer == peer && clipboard[index].manifest.id == id {
            guard offset <= clipboard[index].manifest.size else { throw ProtocolFailure.invalidOffset }
            clipboard[index].offset = offset; clipboard[index].begun = true; clipboard[index].waitingForResume = false; clipboard[index].finished = false
        }
        for index in files.indices where files[index].peer == peer && files[index].manifest.id == id {
            guard offset <= files[index].manifest.size else { throw ProtocolFailure.invalidOffset }
            files[index].offset = offset; files[index].begun = true; files[index].waitingForResume = false; files[index].finished = false
        }
    }
    public mutating func reconnect(_ peer: UUID) {
        clipboard.removeAll { $0.peer == peer }
        for index in files.indices where files[index].peer == peer { files[index].begun = false; files[index].waitingForResume = false; files[index].finished = false }
    }
    public mutating func channelChanged(_ peer: UUID) {
        for index in clipboard.indices where clipboard[index].peer == peer { clipboard[index].begun = false; clipboard[index].waitingForResume = false; clipboard[index].finished = false }
        for index in files.indices where files[index].peer == peer { files[index].begun = false; files[index].waitingForResume = false; files[index].finished = false }
    }
}
