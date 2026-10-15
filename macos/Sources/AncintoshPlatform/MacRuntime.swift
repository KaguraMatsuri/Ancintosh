import AncintoshCore
import AppKit
import Foundation
import Network
import Observation
import SystemConfiguration
import UniformTypeIdentifiers

public struct PeerProfile: Codable, Sendable, Identifiable {
    public var id: UUID
    public var identity: UUID?
    public var name: String?
    public var kind: DeviceKind?
    public var wifi: Bool?
    public var renameRequest: UUID?
    public var notifications: Bool?
    public init(id: UUID, identity: UUID? = nil, name: String? = nil) { self.id = id; self.identity = identity; self.name = name }
}

public struct NodePosition: Codable, Sendable, Equatable {
    public let x: Double
    public let y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct MacConfiguration: Codable, Sendable {
    public var identity = UUID()
    public var peers: [PeerProfile] = []
    public var primary: UUID?
    public var lockEnabled = false
    public var wifi = true
    public var lockDelaySeconds = 15
    public var nodePositions: [String: NodePosition] = [:]
    public var name = MacConfiguration.systemName
    public var revision: Int64 = 0
    public init() {}
    public static var systemName: String { SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ProcessInfo.processInfo.hostName }
    private enum CodingKeys: String, CodingKey { case identity, peers, primary, lockEnabled, wifi, lockDelaySeconds, nodePositions, name, revision }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(UUID.self, forKey: .identity)
        peers = try values.decode([PeerProfile].self, forKey: .peers)
        primary = try values.decodeIfPresent(UUID.self, forKey: .primary)
        lockEnabled = try values.decode(Bool.self, forKey: .lockEnabled)
        wifi = try values.decode(Bool.self, forKey: .wifi)
        lockDelaySeconds = try values.decodeIfPresent(Int.self, forKey: .lockDelaySeconds) ?? 15
        nodePositions = try values.decodeIfPresent([String: NodePosition].self, forKey: .nodePositions) ?? [:]
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? Self.systemName
        revision = try values.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        guard (1...3600).contains(lockDelaySeconds), revision >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .lockDelaySeconds, in: values, debugDescription: "invalidLockDelay")
        }
    }
}

public struct LinkActivity: Sendable {
    public let id: UUID
    public let kind: PayloadKind
    public let sending: Bool
    public init(id: UUID, kind: PayloadKind, sending: Bool) { self.id = id; self.kind = kind; self.sending = sending }
}

public struct MacTransfer: Identifiable, Sendable {
    public let id: UUID
    public let peer: UUID
    public let name: String
    public let size: UInt64
    public var bytes: UInt64 = 0
    public var failure: ProtocolFailure?
    public var sending = true
}

@MainActor @Observable
public final class MacRuntime {
    public private(set) var configuration: MacConfiguration
    public private(set) var discovered: [UUID: BLEPeer] = [:]
    public private(set) var connected: Set<UUID> = []
    public private(set) var routes: [UUID: TransportKind] = [:]
    public private(set) var switching: Set<UUID> = []
    public private(set) var activities: [UUID: [LinkActivity]] = [:]
    public let packetTraffic: ConnectionTraffic
    public let isDemonstration: Bool
    public private(set) var progress: [UUID: (UInt64, UInt64)] = [:]
    public private(set) var failures: [UUID: ProtocolFailure] = [:]
    enum FailureSource: Hashable { case connection, clipboard(Bool), transfer(UUID), notification, configuration }
    private struct FailureEntry { let code: ProtocolFailure; let order: UInt64 }
    @ObservationIgnored private var failureSources: [UUID: [FailureSource: FailureEntry]] = [:]
    @ObservationIgnored private var failureOrder: UInt64 = 0
    private func failurePeer(_ peer: UUID) -> UUID {
        configuration.peers.first(where: { $0.id == peer || $0.identity == peer })?.id ?? peer
    }
    func recordFailure(_ peer: UUID, _ error: ProtocolFailure, source: FailureSource) {
        let peer = failurePeer(peer)
        failureOrder &+= 1
        failureSources[peer, default: [:]][source] = FailureEntry(code: error, order: failureOrder)
        refreshFailure(peer)
    }
    func clearFailure(_ peer: UUID, source: FailureSource) {
        let peer = failurePeer(peer)
        guard failureSources[peer]?.removeValue(forKey: source) != nil else { return }
        if failureSources[peer]?.isEmpty == true { failureSources.removeValue(forKey: peer) }
        refreshFailure(peer)
    }
    private func refreshFailure(_ peer: UUID) {
        let latest = failureSources[peer]?.values.max(by: { $0.order < $1.order })?.code
        if failures[peer] != latest { failures[peer] = latest }
    }
    public private(set) var preparing = false
    public private(set) var running = false
    public private(set) var transfers: [UUID: MacTransfer] = [:]
    public private(set) var clipboardAllowed = false
    public private(set) var lockAllowed = false
    public private(set) var lockAuthorizationRequested = false
    private let preferences: UserDefaults?
    private let temporaryRoot: URL?
    private let store: TransferStore
    private let services: RuntimeServices
    private var pasteboard: any ClipboardAccess { services.clipboard }
    private var locker: LockController { services.locker }
    public private(set) var handshaking: Set<UUID> = []
    public private(set) var notificationPeers: [UUID: NotificationAccess] = [:]
    public private(set) var notificationAllowed = false
    private var notificationPermissionsTask: Task<Void, Never>?
    @ObservationIgnored private lazy var notificationPresenter: MacNotificationPresenter = {
        let presenter = MacNotificationPresenter()
        presenter.failed = { [weak self] peer, error in self?.recordFailure(peer, error, source: .notification) }
        return presenter
    }()
    @ObservationIgnored private lazy var notificationSource = makeNotificationSource()
    private func makeNotificationSource() -> MacNotificationSource {
        let source = MacNotificationSource()
        source.changed = { [weak self] value in
            guard let self, self.running else { return }
            self.capturedNotification(value)
        }
        source.failed = { [weak self] error in guard let self else { return }; self.recordFailure(self.configuration.identity, error, source: .notification) }
        return source
    }
    private func capturedNotification(_ value: NotificationMessage) {
        for peer in connected where configuration.peers.first(where: { $0.identity == peer })?.notifications == true {
            Task { try? await coordinator.enqueueNotification(value, to: peer) }
        }
    }
    public private(set) var receivedNotifications: [UUID: NotificationMessage] = [:]
    private var notificationOwners: [UUID: UUID] = [:]
    #if DEBUG
    public private(set) var demonstrationResult: DemonstrationResult?
    public var demonstrationText: String { get { services.memory?.text ?? "" } set { services.memory?.text = newValue } }
    public var demonstrationReceivedText: String { services.memory?.receivedText ?? "" }
    private var demonstrationTask: Task<Void, any Error>?
    private var expectedReplies: [UUID: [String: Int]] = [:]
    private var demonstrationJobs: Set<UUID> = []
    private var resultWaiter: CheckedContinuation<Void, any Error>?
    public var isTesting: Bool { demonstrationResult != nil && demonstrationResult?.passed == nil && demonstrationResult?.failure == nil }
    #endif
    private var monitor: NWPathMonitor?
    private var restored = false
    private var lan = false
    private var offers: [UUID: Task<Void, Never>] = [:]
    private var offerTokens: [UUID: UUID] = [:]
    private var offerBackoffs: [UUID: RecoveryBackoff] = [:]
    private var fileTasks: [UUID: Task<Void, any Error>] = [:]
    private var fileGeneration = UUID()
    private var configurationWrites: [UUID: [UUID: ManagedConfiguration]] = [:]
    private var configurationWorkers: [UUID: Task<Void, Never>] = [:]
    private var configurationGenerations: [UUID: UUID] = [:]
    private var configurationReady: Set<UUID> = []
    private var observation: [NSObjectProtocol] = []
    private struct ClipboardRequest {
        let file: URL?
        let text: String?
        let mime: String?
        var targets: Set<UUID>
    }
    private var pendingClipboard: ClipboardRequest?
    private var preparingClipboardTargets: Set<UUID> = []
    private var clipboardWorker: Task<Void, Never>?
    private var clipboardPreparation: Task<Snapshot, any Error>?

    @ObservationIgnored private lazy var coordinator = SyncCoordinator(identity: configuration.identity, role: .mac, store: store) { [weak self] event in
        try await self?.event(event)
    }
    @ObservationIgnored private lazy var server = TCPServer(identity: configuration.identity, coordinator: coordinator) { [weak self] peer, event in
        await self?.wireSignal(peer, event, logical: true)
    }
    @ObservationIgnored private lazy var bluetooth: any RuntimeConnector = {
        let client = services.connector(configuration.identity, coordinator)
        client.discovered = { [weak self] peer in self?.discovered[peer.identifier] = peer }
        client.failed = { [weak self] id, failure in self?.recordFailure(id, failure, source: .connection) }
        client.signal = { [weak self] id, event in self?.wireSignal(id, event, logical: false) }
        client.associated = { [weak self] id, identity in
            guard let self, let index = self.configuration.peers.firstIndex(where: { $0.id == id }) else { return }
            self.configuration.peers[index].identity = identity
            self.configurationChanged(); self.configureLock()
        }
        return client
    }()

    public init(preferences: UserDefaults = .standard, root: URL? = nil, downloads: URL? = nil) throws {
        self.preferences = preferences
        isDemonstration = false; temporaryRoot = nil; packetTraffic = ConnectionTraffic(); services = .native()
        if let data = preferences.data(forKey: "Andcintosh.configuration") {
            configuration = try Wire.decodeJSON(MacConfiguration.self, data)
        } else { configuration = MacConfiguration() }
        let manager = FileManager.default
        let dataRoot = try root ?? manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Andcintosh")
        let outputRoot = try downloads ?? manager.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Ancintosh")
        store = try TransferStore(root: dataRoot, downloads: outputRoot)
    }

    #if DEBUG
    public init(demonstration configuration: MacConfiguration, traffic: ConnectionTraffic) throws {
        self.configuration = configuration
        preferences = nil; isDemonstration = true; packetTraffic = traffic
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Ancintosh-demo-\(UUID().uuidString)", isDirectory: true)
        temporaryRoot = root
        services = .demonstration(profiles: configuration.peers, root: root, memory: MemorySystem())
        do { store = try TransferStore(root: root, downloads: root.appendingPathComponent("downloads")) }
        catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    deinit { if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) } }

    #endif
    public func dispose() async {
        await stop()
        await store.closeHandles()
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
    }

    public func shareNotifications(_ id: UUID, enabled: Bool) async throws {
        guard let index = configuration.peers.firstIndex(where: { $0.id == id }) else { throw ProtocolFailure.peerUnavailable }
        configuration.peers[index].notifications = enabled
        configurationChanged(devices: configuration.peers[index].identity.map { [$0] })
        if let peer = configuration.peers[index].identity {
            await coordinator.notificationPolicy(peer, enabled: enabled)
            if !enabled {
                if isDemonstration {
                    for id in notificationOwners.keys.filter({ notificationOwners[$0] == peer }) { receivedNotifications.removeValue(forKey: id); notificationOwners.removeValue(forKey: id) }
                    #if DEBUG
                    services.memory?.phoneNotifications.removeValue(forKey: peer)
                    #endif
                } else { await notificationPresenter.clear(peer: peer) }
            }
        }
        if enabled && !isDemonstration {
            await migrateNotificationIDs(id)
            _ = notificationSource.request()
            _ = try await notificationPresenter.request()
            await refreshNotificationPermissions()
            guard notificationAllowed else { throw ProtocolFailure.permissionDenied }
        }
        updateNotificationCapture()
    }
    private func migrateNotificationIDs(_ profile: UUID) async {
        guard !isDemonstration, let peer = configuration.peers.first(where: { $0.id == profile })?.identity else { return }
        let key = "Andcintosh.notificationIDs.2." + profile.uuidString
        guard preferences?.bool(forKey: key) != true else { return }
        await notificationPresenter.clear(peer: peer)
        preferences?.set(true, forKey: key)
    }
    private func refreshNotificationPermissions() async {
        if isDemonstration { notificationAllowed = true; return }
        let display = await notificationPresenter.permitted(), capture = notificationSource.permitted
        guard !Task.isCancelled else { return }
        notificationAllowed = display && capture
        await coordinator.notificationAccess(NotificationAccess(capture: capture, display: display))
        updateNotificationCapture()
    }
    private func updateNotificationCapture() {
        guard !isDemonstration else { return }
        let eligible = running && notificationSource.permitted && connected.contains { peer in
            configuration.peers.first(where: { $0.identity == peer })?.notifications == true && notificationPeers[peer]?.display == true
        }
        if eligible {
            clearFailure(configuration.identity, source: .notification)
            notificationSource.start()
        } else { notificationSource.stop() }
    }

    #if DEBUG
    public func verify(_ peer: UUID) async throws {
        guard isDemonstration, let profile = configuration.peers.first(where: { $0.identity == peer }), let driver = bluetooth as? DemoPeer else { throw ProtocolFailure.unsupported }
        try connect(profile)
        try await driver.waitAuthenticated(profile.id)
    }
    private func finishDemonstration(_ failure: ProtocolFailure? = nil) {
        demonstrationResult?.failure = failure; demonstrationResult?.passed = failure == nil
        let waiter = resultWaiter; resultWaiter = nil
        if let failure { waiter?.resume(throwing: failure) } else { waiter?.resume() }
    }
    private func waitDemonstration() async throws {
        if let failure = demonstrationResult?.failure { throw failure }
        if demonstrationResult?.passed == true { return }
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { resultWaiter = $0 }
        } onCancel: { Task { @MainActor in
            let waiter = self.resultWaiter; self.resultWaiter = nil; waiter?.resume(throwing: CancellationError())
        } }
    }
    public func test(_ test: DemonstrationTest, peer: UUID) async throws {
        guard isDemonstration, !isTesting, let driver = bluetooth as? DemoPeer,
              let profile = configuration.peers.first(where: { $0.identity == peer }) else { throw ProtocolFailure.peerUnavailable }
        demonstrationResult = DemonstrationResult(peer: peer, test: test)
        demonstrationTask = Task {
            switch test {
            case .connection:
                try await verify(peer)
                var wrong = try services.loadKey(profile.id); wrong[0] ^= 1
                try driver.connect(identifier: profile.id, key: wrong, expectedIdentity: peer)
                do { try await driver.waitAuthenticated(profile.id); throw ProtocolFailure.invalidHandshake }
                catch ProtocolFailure.authenticationFailed { }
                try await verify(peer)
                finishDemonstration()
            case .clipboard:
                guard connected.contains(peer), let memory = services.memory else { throw ProtocolFailure.peerUnavailable }
                let snapshot = try await store.snapshotText(memory.text, origin: configuration.identity)
                expectedReplies[peer, default: [:]][snapshot.manifest.sha256, default: 0] += 1; demonstrationJobs.insert(snapshot.manifest.id)
                try await coordinator.enqueue(snapshot, targets: [peer], userInitiated: true)
                try await waitDemonstration()
            case .file: throw ProtocolFailure.unsupported // The existing file picker supplies the source.
            case .lock:
                guard connected.contains(peer), let memory = services.memory else { throw ProtocolFailure.peerUnavailable }
                let oldEnabled = configuration.lockEnabled, oldPrimary = configuration.primary
                let before = memory.lockCount
                driver.suppress(peer, true)
                do {
                    try lock(enabled: true, primary: profile.id)
                    await coordinator.disconnect(peer)
                    try await memory.waitForLock(after: before)
                    try lock(enabled: oldEnabled, primary: oldPrimary); driver.suppress(peer, false)
                    if running { try await verify(peer) }
                    finishDemonstration()
                } catch {
                    try? lock(enabled: oldEnabled, primary: oldPrimary); driver.suppress(peer, false)
                    if running { try? connect(profile) }
                    throw error
                }
            case .notification:
                guard connected.contains(peer), profile.notifications == true else { throw ProtocolFailure.unsupported }
                let value = try NotificationMessage.bounded(id: UUID(), application: configuration.name, title: profile.name ?? peer.uuidString, body: services.memory?.text ?? "")
                try await coordinator.enqueueNotification(value, to: peer)
                try await waitDemonstration()
            }
        }
        do { try await demonstrationTask?.value }
        catch { finishDemonstration(error as? ProtocolFailure ?? .cancelled); throw error }
        demonstrationTask = nil
    }
    public func cancelTest() async {
        demonstrationTask?.cancel()
        for id in demonstrationJobs { if let peer = demonstrationResult?.peer { await coordinator.cancel(id, peer: peer) } }
        demonstrationJobs.removeAll(); expectedReplies.removeAll()
        _ = try? await demonstrationTask?.value; demonstrationTask = nil
        if isTesting { finishDemonstration(.cancelled) }
    }
    #endif

    public func start() {
        guard !running else { return }
        running = true
        refreshPermissions()
        _ = bluetooth
        configureLock()
        for profile in configuration.peers {
            do { try bluetooth.connect(identifier: profile.id, key: services.loadKey(profile.id), expectedIdentity: profile.identity) }
            catch { recordFailure(profile.id, error as? ProtocolFailure ?? .peerUnavailable, source: .connection) }
        }
        pasteboard.changed = { [weak self] file, text, mime in
            guard let self else { return }
            self.queueClipboard(file: file, text: text, mime: mime, targets: self.connected)
        }
        if isDemonstration {
            lan = true
        } else {
            let monitor = NWPathMonitor()
            self.monitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                let available = path.status == .satisfied && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
                Task { @MainActor in await self?.pathChanged(available) }
            }
            monitor.start(queue: DispatchQueue(label: "Ancintosh.path", qos: .utility))
            let center = NSWorkspace.shared.notificationCenter
            observation.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pasteboard.stop() }
            })
            observation.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.connected.isEmpty == false { self?.pasteboard.start() } }
            })
        }
        Task {
            if !restored {
                do {
                    try await coordinator.restore(); restored = true
                    for job in await coordinator.outgoingFiles() {
                        transfers[job.manifest.id] = MacTransfer(id: job.manifest.id, peer: job.peer, name: job.manifest.name,
                                                               size: job.manifest.size, bytes: job.offset, failure: job.failure)
                    }
                } catch { recordFailure(configuration.identity, error as? ProtocolFailure ?? .sourceUnavailable, source: .configuration) }
            }
            #if DEBUG
            if isDemonstration { await coordinator.notificationAccess(NotificationAccess(capture: true, display: true)) }
            #endif
            await coordinator.wifi(configuration.wifi && lan)
        }
    }
    public func movePeers(from offsets: IndexSet, to destination: Int) {
        guard offsets.allSatisfy({ configuration.peers.indices.contains($0) }),
              (0...configuration.peers.count).contains(destination), !offsets.isEmpty else { return }
        let moved = offsets.sorted().map { configuration.peers[$0] }
        var remaining = configuration.peers.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moved, at: destination - offsets.filter { $0 < destination }.count)
        configuration.peers = remaining
        configurationChanged()
    }
    public func renameMac(_ name: String) throws {
        try validateName(name.isEmpty ? MacConfiguration.systemName : name, mac: true)
        configuration.name = name.isEmpty ? MacConfiguration.systemName : name
        configurationChanged(devices: [])
    }
    public func renamePeer(_ id: UUID, name: String) throws {
        guard let index = configuration.peers.firstIndex(where: { $0.id == id }) else { throw ProtocolFailure.peerUnavailable }
        try validateName(name, mac: false, profile: configuration.peers[index])
        configuration.peers[index].name = name.isEmpty ? nil : name
        configurationChanged(devices: configuration.peers[index].identity.map { [$0] })
    }
    private func validateName(_ name: String, mac: Bool, profile: PeerProfile? = nil) throws {
        let owner = ManagedDevice(id: configuration.identity, name: mac ? name : configuration.name, kind: .mac, wifi: false, priority: 0)
        let profiles = mac ? configuration.peers : profile.map { [$0] } ?? []
        var devices: [ManagedDevice?] = [nil]
        devices += profiles.map { ManagedDevice(id: $0.identity ?? $0.id, name: mac ? ($0.name ?? $0.id.uuidString) : name,
            kind: .phone, wifi: false, priority: Int(Int32.max), renameRequest: $0.renameRequest ?? Wire.zeroID) }
        for device in devices {
            let value = ManagedConfiguration(revision: Int64.max, mac: owner, device: device, primary: configuration.primary ?? Wire.zeroID,
                lockEnabled: false, lockDelaySeconds: 3600)
            _ = try Record(.configuration, metadata: Wire.encodeJSON(value)).encoded()
        }
    }
    func acceptDeviceInformation(_ peer: UUID, _ value: DeviceInformation) throws {
        guard value.kind != .mac, let index = configuration.peers.firstIndex(where: { $0.identity == peer }) else { return }
        let previous = configuration.peers[index]
        if let request = value.renameRequest, previous.renameRequest != request {
            try validateName(value.name, mac: false, profile: previous)
            configuration.peers[index].name = value.name.isEmpty ? nil : value.name
            configuration.peers[index].renameRequest = request
        } else if previous.name == nil && value.renameRequest == nil {
            try validateName(value.name, mac: false, profile: previous)
            configuration.peers[index].name = value.name.isEmpty ? nil : value.name
        }
        let firstReport = configurationReady.insert(peer).inserted
        configuration.peers[index].kind = value.kind
        configuration.peers[index].wifi = value.wifi
        let updated = configuration.peers[index]
        if updated.name != previous.name || updated.kind != previous.kind || updated.wifi != previous.wifi || updated.renameRequest != previous.renameRequest {
            configurationChanged(devices: [peer])
        } else { synchronizeConfiguration(targets: [peer], devices: [peer]) }
        if firstReport { synchronizeConfiguration(targets: [peer]) }
    }
    public func placeNodes(_ positions: [UUID: NodePosition]) {
        let registered = Set(configuration.peers.map(\.id))
        var changed = false
        for (id, position) in positions where registered.contains(id) && position.x.isFinite && position.y.isFinite {
            let clamped = NodePosition(x: min(1, max(0, position.x)), y: min(1, max(0, position.y)))
            if configuration.nodePositions[id.uuidString] != clamped {
                configuration.nodePositions[id.uuidString] = clamped
                changed = true
            }
        }
        if changed { persist() }
    }
    public func refreshPermissions() {
        clipboardAllowed = pasteboard.permitted; lockAllowed = locker.permitted
        notificationPermissionsTask?.cancel()
        notificationPermissionsTask = Task { await refreshNotificationPermissions() }
    }
    public func scan() { start(); discovered.removeAll(); bluetooth.scan() }
    public func save(_ profile: PeerProfile, key: String) async throws {
        try validateName(profile.name ?? profile.id.uuidString, mac: false, profile: profile)
        let bytes = key.isEmpty ? try services.loadKey(profile.id) : try Crypto.key(key)
        start()
        if let existing = configuration.peers.first(where: { $0.id == profile.id }), let peer = existing.identity { await coordinator.stop(peer) }
        try services.saveKey(bytes, profile.id)
        if let index = configuration.peers.firstIndex(where: { $0.id == profile.id }) {
            var updated = profile
            updated.kind = configuration.peers[index].kind; updated.wifi = configuration.peers[index].wifi
            updated.renameRequest = configuration.peers[index].renameRequest
            updated.notifications = configuration.peers[index].notifications
            configuration.peers[index] = updated
        }
        else { configuration.peers.append(profile) }
        configurationChanged()
        try bluetooth.connect(identifier: profile.id, key: bytes, expectedIdentity: profile.identity)
    }
    public func connect(_ profile: PeerProfile) throws {
        start()
        clearFailure(profile.id, source: .connection)
        #if DEBUG
        if let demo = bluetooth as? DemoPeer { demo.allow(profile.id) }
        #endif
        try bluetooth.connect(identifier: profile.id, key: services.loadKey(profile.id), expectedIdentity: profile.identity)
    }
    public func wifi(_ enabled: Bool) async {
        configuration.wifi = enabled; configurationChanged(devices: [])
        await coordinator.wifi(enabled && lan)
        if enabled && lan { for peer in connected { scheduleOffer(peer, reset: true) } }
        else { cancelOffers(); if !isDemonstration { await server.stop() } }
    }
    public func lock(enabled: Bool, primary: UUID?) throws {
        let identity = configuration.peers.first(where: { $0.id == primary })?.identity
        try locker.setDelay(seconds: configuration.lockDelaySeconds)
        try locker.configure(enabled: enabled, primary: identity)
        configuration.lockEnabled = enabled; configuration.primary = primary; configurationChanged(devices: [])
        if let identity, connected.contains(identity) { locker.connected(identity) }
    }
    public func saveLockDelay(seconds: Int) throws {
        try locker.setDelay(seconds: seconds)
        configuration.lockDelaySeconds = seconds
        configurationChanged(devices: [])
    }
    public func requestLockAuthorization() -> Bool {
        let allowed = locker.requestAuthorization()
        lockAuthorizationRequested = locker.authorizationRequested
        refreshPermissions()
        return allowed
    }
    public func files(_ urls: [URL], peer: UUID) async throws {
        guard running, connected.contains(peer) else { throw ProtocolFailure.peerUnavailable }
        let token = UUID(), generation = fileGeneration
        preparing = true
        let task = Task<Void, any Error> { [self] in
            defer { fileTasks.removeValue(forKey: token); preparing = !fileTasks.isEmpty }
            for url in urls {
                try Task.checkCancellation()
                guard generation == fileGeneration, running, connected.contains(peer) else { throw ProtocolFailure.peerUnavailable }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
                guard values.isRegularFile == true else { throw ProtocolFailure.unsupported }
                let snapshot = try await store.snapshot(url, kind: .file, name: url.lastPathComponent,
                    mime: values.contentType?.preferredMIMEType ?? "application/octet-stream", origin: configuration.identity)
                if Task.isCancelled || generation != fileGeneration || !running || !connected.contains(peer) {
                    await store.release(snapshot.url)
                    throw CancellationError()
                }
                transfers[snapshot.manifest.id] = MacTransfer(id: snapshot.manifest.id, peer: peer,
                    name: snapshot.manifest.name, size: snapshot.manifest.size)
                do {
                    #if DEBUG
                    if isDemonstration {
                        demonstrationJobs.insert(snapshot.manifest.id)
                        expectedReplies[peer, default: [:]][snapshot.manifest.sha256, default: 0] += 1
                        demonstrationResult = DemonstrationResult(peer: peer, test: .file)
                    }
                    #endif
                    try await coordinator.enqueue(snapshot, targets: [peer], userInitiated: true)
                } catch {
                    if await coordinator.outgoingFiles().contains(where: { $0.peer == peer && $0.manifest.id == snapshot.manifest.id }) {
                        transfers[snapshot.manifest.id]?.failure = error as? ProtocolFailure ?? .sourceUnavailable
                    } else {
                        transfers.removeValue(forKey: snapshot.manifest.id)
                        await store.release(snapshot.url)
                    }
                    throw error
                }
            }
        }
        fileTasks[token] = task
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    public func retry(_ id: UUID, peer: UUID) async throws {
        transfers[id]?.failure = nil
        try await coordinator.retry(id, peer: peer)
    }
    public func cancel(_ id: UUID, peer: UUID) async {
        await coordinator.cancel(id, peer: peer); transfers.removeValue(forKey: id)
    }
    public func stop() async {
        fileGeneration = UUID()
        let preparingFiles = Array(fileTasks.values)
        for task in preparingFiles { task.cancel() }
        for task in preparingFiles { _ = await task.result }
        #if DEBUG
        demonstrationTask?.cancel()
        _ = try? await demonstrationTask?.value
        demonstrationTask = nil
        #endif
        notificationPermissionsTask?.cancel(); notificationPermissionsTask = nil
        if !isDemonstration { notificationSource.stop(); await notificationPresenter.stop() }
        let wasRunning = running
        running = false
        packetTraffic.stop()
        pendingClipboard = nil; clipboardPreparation?.cancel(); clipboardWorker?.cancel()
        await clipboardWorker?.value
        locker.stop(); pasteboard.stop(); monitor?.cancel(); monitor = nil; lan = false
        cancelOffers()
        for task in configurationWorkers.values { task.cancel() }
        configurationWorkers.removeAll(); configurationWrites.removeAll(); configurationGenerations.removeAll()
        configurationReady.removeAll()
        if wasRunning { await bluetooth.stop() } else { await coordinator.stop() }
        if !isDemonstration { await server.stop() }
        for token in observation { NSWorkspace.shared.notificationCenter.removeObserver(token) }; observation.removeAll()
        connected.removeAll(); routes.removeAll(); switching.removeAll(); activities.removeAll(); handshaking.removeAll(); notificationPeers.removeAll()
    }
    private func configurationChanged(devices: Set<UUID>? = nil) {
        if configuration.revision < Int64.max { configuration.revision += 1 }
        persist(); synchronizeConfiguration(devices: devices)
    }
    private func synchronizeConfiguration(targets: Set<UUID>? = nil, devices: Set<UUID>? = nil) {
        let mac = ManagedDevice(id: configuration.identity, name: configuration.name, kind: .mac, wifi: configuration.wifi, priority: 0)
        var records: [ManagedDevice?] = [nil]
        for (index, profile) in configuration.peers.enumerated() {
            if profile.kind == nil && profile.name == nil { continue }
            if let peer = profile.identity, devices == nil || devices!.contains(peer) {
                records.append(ManagedDevice(id: peer, name: profile.name ?? peer.uuidString, kind: profile.kind ?? .phone,
                    wifi: profile.wifi ?? true, priority: index + 1, renameRequest: profile.renameRequest, notifications: profile.notifications))
            }
        }
        let primary = configuration.peers.first(where: { $0.id == configuration.primary })?.identity
        for target in (targets ?? connected).intersection(connected).intersection(configurationReady) {
            for device in records {
                configurationWrites[target, default: [:]][device?.id ?? mac.id] = ManagedConfiguration(revision: configuration.revision,
                    mac: mac, device: device, primary: primary, lockEnabled: configuration.lockEnabled, lockDelaySeconds: configuration.lockDelaySeconds)
            }
            guard configurationWorkers[target] == nil else { continue }
            let generation = UUID(); configurationGenerations[target] = generation
            configurationWorkers[target] = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.configurationGenerations[target] == generation {
                        self.configurationWorkers.removeValue(forKey: target)
                        self.configurationGenerations.removeValue(forKey: target)
                    }
                }
                while !Task.isCancelled, self.configurationGenerations[target] == generation,
                      self.connected.contains(target), let next = self.configurationWrites[target]?.first {
                    self.configurationWrites[target]?.removeValue(forKey: next.key)
                    do { try await self.coordinator.sendConfiguration(next.value, to: target) }
                    catch { break } // The next authenticated connection sends a fresh snapshot.
                }
            }
        }
    }
    private func stopActivity(_ peer: UUID, _ id: UUID, sending: Bool? = nil) {
        activities[peer]?.removeAll { $0.id == id && (sending == nil || $0.sending == sending) }
        if activities[peer]?.isEmpty == true { activities.removeValue(forKey: peer) }
    }
    private func wireSignal(_ id: UUID, _ event: ConnectionSignal, logical: Bool) {
        guard running, let profile = configuration.peers.first(where: { logical ? $0.identity == id : $0.id == id }) else { return }
        if case .packet(_, false) = event, profile.identity.map({ connected.contains($0) }) != true { return }
        switch event {
        case .handshakeStarted: handshaking.insert(profile.id)
        case .handshakeEnded: handshaking.remove(profile.id)
        default: break
        }
        packetTraffic.signal(profile.id, event)
    }
    private func persist() { preferences?.set(try? Wire.encodeJSON(configuration), forKey: "Andcintosh.configuration") }
    private func configureLock() {
        try? locker.setDelay(seconds: configuration.lockDelaySeconds)
        try? locker.configure(enabled: configuration.lockEnabled,
                              primary: configuration.peers.first(where: { $0.id == configuration.primary })?.identity)
    }
    private func pathChanged(_ available: Bool) async {
        guard running else { return }
        lan = available
        await coordinator.wifi(configuration.wifi && available)
        if configuration.wifi && available { for peer in connected { scheduleOffer(peer, reset: true) } }
        else { cancelOffers(); if !isDemonstration { await server.stop() } }
    }
    private func cancelOffer(_ peer: UUID) {
        offerTokens.removeValue(forKey: peer)
        offers.removeValue(forKey: peer)?.cancel()
        offerBackoffs.removeValue(forKey: peer)
    }
    private func cancelOffers() {
        offerTokens.removeAll()
        for task in offers.values { task.cancel() }
        offers.removeAll(); offerBackoffs.removeAll()
    }
    private func scheduleOffer(_ peer: UUID, reset: Bool = false) {
        if reset { cancelOffer(peer) }
        guard offers[peer] == nil, running, lan, configuration.wifi, connected.contains(peer) else { return }
        let token = UUID(), delay = offerBackoffs[peer, default: RecoveryBackoff()].next()
        offerTokens[peer] = token
        offers[peer] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.offerTokens[peer] == token {
                    self.offerTokens.removeValue(forKey: peer); self.offers.removeValue(forKey: peer)
                    self.scheduleOffer(peer)
                }
            }
            do {
                try await Task.sleep(for: delay)
                guard !Task.isCancelled, self.running, self.lan, self.configuration.wifi, self.connected.contains(peer),
                      await self.coordinator.permitsWifi(peer), !(await self.coordinator.usingTCP(peer)) else {
                    self.cancelOffer(peer); return
                }
                #if DEBUG
                if let demo = self.bluetooth as? DemoPeer { try await demo.upgrade(peer) }
                else {
                    let endpoints = try await self.server.start()
                    _ = try await self.coordinator.offerTCP(peer, addresses: endpoints)
                }
                #else
                let endpoints = try await self.server.start()
                _ = try await self.coordinator.offerTCP(peer, addresses: endpoints)
                #endif
                try await Task.sleep(for: .seconds(10))
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled, self.running { self.recordFailure(peer, error as? ProtocolFailure ?? .peerUnavailable, source: .connection) }
            }
        }
    }
    private func queueClipboard(file: URL?, text: String?, mime: String?, targets: Set<UUID>) {
        guard running, !targets.isEmpty else { return }
        let merged = targets.union(pendingClipboard?.targets ?? []).union(preparingClipboardTargets)
        pendingClipboard = ClipboardRequest(file: file, text: text, mime: mime, targets: merged)
        clipboardPreparation?.cancel()
        guard clipboardWorker == nil else { return }
        clipboardWorker = Task { [weak self] in
            guard let self else { return }
            defer { self.clipboardWorker = nil; self.clipboardPreparation = nil; self.preparingClipboardTargets = [] }
            while self.running, !Task.isCancelled, let request = self.pendingClipboard {
                self.pendingClipboard = nil
                self.preparingClipboardTargets = request.targets
                let preparation = Task<Snapshot, any Error> { [store = self.store, origin = self.configuration.identity] in
                    try Task.checkCancellation()
                    if let file = request.file, let mime = request.mime {
                        return try await store.snapshot(file, kind: .image, name: file.lastPathComponent, mime: mime, origin: origin)
                    }
                    if let text = request.text { return try await store.snapshotText(text, origin: origin) }
                    throw ProtocolFailure.originalUnavailable
                }
                self.clipboardPreparation = preparation
                do {
                    let snapshot = try await preparation.value
                    if preparation.isCancelled || !self.running || self.pendingClipboard != nil {
                        await self.store.release(snapshot.url)
                    } else {
                        var seen: Set<UUID> = []
                        let targets = self.configuration.peers.compactMap(\.identity).filter {
                            request.targets.contains($0) && self.connected.contains($0) && seen.insert($0).inserted
                        }
                        if targets.isEmpty { await self.store.release(snapshot.url) }
                        else {
                            try await self.coordinator.enqueue(snapshot, targets: targets, userInitiated: false)
                            for peer in targets { self.clearFailure(peer, source: .clipboard(true)) }
                        }
                    }
                } catch is CancellationError { }
                catch {
                    if !preparation.isCancelled && self.running {
                        for peer in request.targets { self.recordFailure(peer, error as? ProtocolFailure ?? .sourceUnavailable, source: .clipboard(true)) }
                    }
                }
                self.clipboardPreparation = nil; self.preparingClipboardTargets = []
            }
        }
    }
    private func event(_ event: SyncEvent) async throws {
        switch event {
        case .connected(let peer):
            guard running, bluetooth.sessionAuthenticated(peer) else { return }
            if let profile = configuration.peers.first(where: { $0.identity == peer }), profile.notifications == true {
                await migrateNotificationIDs(profile.id)
            }
            await coordinator.notificationPolicy(peer, enabled: configuration.peers.first(where: { $0.identity == peer })?.notifications == true)
            clearFailure(peer, source: .connection)
            routes[peer] = .ble; switching.remove(peer)
            connected.insert(peer); locker.connected(peer); pasteboard.start()
            synchronizeConfiguration(targets: [peer])
            if pasteboard.permitted {
                do { let value = try pasteboard.current(); queueClipboard(file: value.0, text: value.1, mime: value.2, targets: [peer]) }
                catch { recordFailure(peer, error as? ProtocolFailure ?? .sourceUnavailable, source: .clipboard(true)) }
            }
            scheduleOffer(peer)
        case .disconnected(let peer, let intentional):
            routes.removeValue(forKey: peer); switching.remove(peer)
            connected.remove(peer); locker.disconnected(peer, intentional: intentional)
            activities.removeValue(forKey: peer)
            if let profile = configuration.peers.first(where: { $0.identity == peer }) { packetTraffic.stop(profile.id) }
            configurationReady.remove(peer)
            configurationWorkers.removeValue(forKey: peer)?.cancel(); configurationWrites.removeValue(forKey: peer)
            configurationGenerations.removeValue(forKey: peer)
            bluetooth.sessionDisconnected(peer, intentional: intentional)
            cancelOffer(peer)
            updateNotificationCapture()
            if connected.isEmpty { pasteboard.stop(); if !isDemonstration { await server.stop() } }
        case .received(let peer, let manifest, let url):
            guard running, bluetooth.sessionAuthenticated(peer) else { throw ProtocolFailure.peerUnavailable }
            if manifest.kind != .file {
                try pasteboard.apply(manifest, file: url)
                clearFailure(peer, source: .clipboard(false))
            } else {
                transfers.removeValue(forKey: manifest.id); progress.removeValue(forKey: manifest.id)
                clearFailure(peer, source: .transfer(manifest.id))
            }
            #if DEBUG
            if isDemonstration, let count = expectedReplies[peer]?[manifest.sha256], demonstrationResult?.peer == peer {
                if count == 1 { expectedReplies[peer]?.removeValue(forKey: manifest.sha256) } else { expectedReplies[peer]?[manifest.sha256] = count - 1 }
                if expectedReplies[peer]?.isEmpty == true { finishDemonstration() }
            }
            #endif
        case .progress(let peer, let id, let bytes, let size):
            progress[id] = (bytes, size); transfers[id]?.bytes = bytes
            if bytes > 0, transfers[id] != nil { transfers[id]?.failure = nil; clearFailure(peer, source: .transfer(id)) }
        case .failed(let peer, let id, let code):
            #if DEBUG
            if isDemonstration, demonstrationJobs.contains(id), demonstrationResult?.peer == peer { finishDemonstration(code) }
            #endif
            let activity = activities[peer]?.first(where: { $0.id == id })
            let source: FailureSource = id == Wire.zeroID ? .connection :
                (transfers[id] != nil || activity?.kind == .file ? .transfer(id) : .clipboard(activity?.sending ?? true))
            stopActivity(peer, id); recordFailure(peer, code, source: source); transfers[id]?.failure = code
        case .upgradeRequested(let peer): scheduleOffer(peer, reset: true)
        case .wifiChanged(let peer, let enabled):
            if let index = configuration.peers.firstIndex(where: { $0.identity == peer }), configuration.peers[index].wifi != enabled {
                configuration.peers[index].wifi = enabled; configurationChanged(devices: [peer])
            }
            if enabled { scheduleOffer(peer) }
            else {
                cancelOffer(peer)
                var eligible = false
                for candidate in connected where await coordinator.permitsWifi(candidate) { eligible = true }
                if !eligible && !isDemonstration { await server.stop() }
            }
        case .completed(let peer, let id):
            let file = transfers[id] != nil
            stopActivity(peer, id, sending: true); progress.removeValue(forKey: id); transfers.removeValue(forKey: id)
            clearFailure(peer, source: file ? .transfer(id) : .clipboard(true))
        case .deviceInformation(let peer, let value): try acceptDeviceInformation(peer, value)
        case .transferStarted(let peer, let manifest, let sending):
            stopActivity(peer, manifest.id, sending: sending)
            activities[peer, default: []].append(LinkActivity(id: manifest.id, kind: manifest.kind, sending: sending))
            if manifest.kind == .file, transfers[manifest.id] == nil {
                var transfer = MacTransfer(id: manifest.id, peer: peer, name: manifest.name, size: manifest.size)
                transfer.sending = sending; transfers[manifest.id] = transfer
            }
        case .transferStopped(let peer, let id):
            stopActivity(peer, id); transfers.removeValue(forKey: id); progress.removeValue(forKey: id)
            clearFailure(peer, source: .transfer(id))
        case .transportChanged(let peer, let route):
            if route == .tcp { cancelOffer(peer); clearFailure(peer, source: .connection) }
            else if route == .ble { scheduleOffer(peer) }
            guard connected.contains(peer) else { return }
            if let route { routes[peer] = route; switching.remove(peer) }
            else { switching.insert(peer); activities.removeValue(forKey: peer) }
        case .notificationAccess(let peer, let value):
            notificationPeers[peer] = value
            updateNotificationCapture()
        case .notification(let peer, let value):
            guard running else { return }
            clearFailure(peer, source: .notification)
            if isDemonstration {
                if value.action == .remove { receivedNotifications.removeValue(forKey: value.id); notificationOwners.removeValue(forKey: value.id) }
                else {
                    if receivedNotifications.count >= 128, let oldest = receivedNotifications.keys.first { receivedNotifications.removeValue(forKey: oldest); notificationOwners.removeValue(forKey: oldest) }
                    receivedNotifications[value.id] = value; notificationOwners[value.id] = peer
                }
            } else { notificationPresenter.enqueue(peer: peer, value: value) }
            #if DEBUG
            if isDemonstration, demonstrationResult?.test == .notification, demonstrationResult?.peer == peer { finishDemonstration() }
            #endif
        case .configuration, .configurationReady, .tcpOffer: break
        }
    }
}
