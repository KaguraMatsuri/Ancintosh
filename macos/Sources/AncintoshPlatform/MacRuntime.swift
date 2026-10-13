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
}

@MainActor @Observable
public final class MacRuntime {
    public private(set) var configuration: MacConfiguration
    public private(set) var discovered: [UUID: BLEPeer] = [:]
    public private(set) var connected: Set<UUID> = []
    public private(set) var routes: [UUID: TransportKind] = [:]
    public private(set) var switching: Set<UUID> = []
    public private(set) var activities: [UUID: [LinkActivity]] = [:]
    public let packetTraffic = ConnectionTraffic()
    public private(set) var progress: [UUID: (UInt64, UInt64)] = [:]
    public private(set) var failures: [UUID: ProtocolFailure] = [:]
    public private(set) var preparing = false
    public private(set) var running = false
    public private(set) var transfers: [UUID: MacTransfer] = [:]
    public private(set) var clipboardAllowed = false
    public private(set) var lockAllowed = false
    public private(set) var lockAuthorizationRequested = false
    private let preferences: UserDefaults
    private let store: TransferStore
    private let pasteboard = PasteboardBridge()
    private let locker = LockController()
    private var monitor: NWPathMonitor?
    private var restored = false
    private var lan = false
    private var offers: [UUID: Task<Void, Never>] = [:]
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
    @ObservationIgnored private lazy var bluetooth: BLEClient = {
        let client = BLEClient(identity: configuration.identity, coordinator: coordinator)
        client.discovered = { [weak self] peer in self?.discovered[peer.identifier] = peer }
        client.failed = { [weak self] id, failure in self?.failures[id] = failure }
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
        if let data = preferences.data(forKey: "Andcintosh.configuration") {
            configuration = try Wire.decodeJSON(MacConfiguration.self, data)
        } else { configuration = MacConfiguration() }
        let manager = FileManager.default
        let dataRoot = try root ?? manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Andcintosh")
        let outputRoot = try downloads ?? manager.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Ancintosh")
        store = try TransferStore(root: dataRoot, downloads: outputRoot)
    }

    public func start() {
        guard !running else { return }
        running = true
        refreshPermissions()
        _ = bluetooth
        configureLock()
        for profile in configuration.peers {
            do { try bluetooth.connect(identifier: profile.id, key: KeychainStore.load(peer: profile.id), expectedIdentity: profile.identity) }
            catch { failures[profile.id] = error as? ProtocolFailure ?? .peerUnavailable }
        }
        pasteboard.changed = { [weak self] file, text, mime in
            guard let self else { return }
            self.queueClipboard(file: file, text: text, mime: mime, targets: self.connected)
        }
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
        Task {
            if !restored {
                do {
                    try await coordinator.restore(); restored = true
                    for job in await coordinator.outgoingFiles() {
                        transfers[job.manifest.id] = MacTransfer(id: job.manifest.id, peer: job.peer, name: job.manifest.name,
                                                               size: job.manifest.size, bytes: job.offset, failure: job.failure)
                    }
                } catch { failures[configuration.identity] = error as? ProtocolFailure ?? .sourceUnavailable }
            }
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
    public func refreshPermissions() { clipboardAllowed = pasteboard.permitted; lockAllowed = locker.permitted }
    public func scan() { start(); discovered.removeAll(); bluetooth.scan() }
    public func save(_ profile: PeerProfile, key: String) async throws {
        let bytes = key.isEmpty ? try KeychainStore.load(peer: profile.id) : try Crypto.key(key)
        start()
        if let existing = configuration.peers.first(where: { $0.id == profile.id }), let peer = existing.identity { await coordinator.stop(peer) }
        try KeychainStore.save(bytes, peer: profile.id)
        if let index = configuration.peers.firstIndex(where: { $0.id == profile.id }) {
            var updated = profile
            updated.kind = configuration.peers[index].kind; updated.wifi = configuration.peers[index].wifi
            updated.renameRequest = configuration.peers[index].renameRequest
            configuration.peers[index] = updated
        }
        else { configuration.peers.append(profile) }
        configurationChanged()
        try bluetooth.connect(identifier: profile.id, key: bytes, expectedIdentity: profile.identity)
    }
    public func connect(_ profile: PeerProfile) throws {
        start()
        failures.removeValue(forKey: profile.id)
        if let identity = profile.identity { failures.removeValue(forKey: identity) }
        try bluetooth.connect(identifier: profile.id, key: KeychainStore.load(peer: profile.id), expectedIdentity: profile.identity)
    }
    public func wifi(_ enabled: Bool) async {
        configuration.wifi = enabled; configurationChanged(devices: [])
        await coordinator.wifi(enabled && lan)
        if enabled && lan { for peer in connected { scheduleOffer(peer) } }
        else { for task in offers.values { task.cancel() }; offers.removeAll(); await server.stop() }
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
        guard connected.contains(peer) else { throw ProtocolFailure.peerUnavailable }
        preparing = true
        defer { preparing = false }
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
            guard values.isRegularFile == true else { throw ProtocolFailure.unsupported }
            let snapshot = try await store.snapshot(url, kind: .file, name: url.lastPathComponent,
                                                    mime: values.contentType?.preferredMIMEType ?? "application/octet-stream", origin: configuration.identity)
            transfers[snapshot.manifest.id] = MacTransfer(id: snapshot.manifest.id, peer: peer, name: snapshot.manifest.name, size: snapshot.manifest.size)
            try await coordinator.enqueue(snapshot, targets: [peer], userInitiated: true)
        }
    }
    public func retry(_ id: UUID, peer: UUID) async throws {
        transfers[id]?.failure = nil
        try await coordinator.retry(id, peer: peer)
    }
    public func cancel(_ id: UUID, peer: UUID) async { await coordinator.cancel(id, peer: peer); transfers.removeValue(forKey: id) }
    public func stop() async {
        let wasRunning = running
        running = false
        packetTraffic.stop()
        pendingClipboard = nil; clipboardPreparation?.cancel(); clipboardWorker?.cancel()
        await clipboardWorker?.value
        locker.stop(); pasteboard.stop(); monitor?.cancel(); monitor = nil; lan = false
        for task in offers.values { task.cancel() }; offers.removeAll()
        for task in configurationWorkers.values { task.cancel() }
        configurationWorkers.removeAll(); configurationWrites.removeAll(); configurationGenerations.removeAll()
        configurationReady.removeAll()
        if wasRunning { await bluetooth.stop() } else { await coordinator.stop() }
        await server.stop()
        for token in observation { NSWorkspace.shared.notificationCenter.removeObserver(token) }; observation.removeAll()
        connected.removeAll(); routes.removeAll(); switching.removeAll(); activities.removeAll()
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
                    wifi: profile.wifi ?? true, priority: index + 1, renameRequest: profile.renameRequest))
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
        packetTraffic.signal(profile.id, event)
    }
    private func persist() { preferences.set(try? Wire.encodeJSON(configuration), forKey: "Andcintosh.configuration") }
    private func configureLock() {
        try? locker.setDelay(seconds: configuration.lockDelaySeconds)
        try? locker.configure(enabled: configuration.lockEnabled,
                              primary: configuration.peers.first(where: { $0.id == configuration.primary })?.identity)
    }
    private func pathChanged(_ available: Bool) async {
        guard running else { return }
        lan = available
        await coordinator.wifi(configuration.wifi && available)
        if configuration.wifi && available { for peer in connected { scheduleOffer(peer) } }
        else { for task in offers.values { task.cancel() }; offers.removeAll(); await server.stop() }
    }
    private func scheduleOffer(_ peer: UUID) {
        offers[peer]?.cancel()
        offers[peer] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            guard let self, self.lan, self.configuration.wifi, self.connected.contains(peer),
                  await self.coordinator.permitsWifi(peer), !(await self.coordinator.usingTCP(peer)) else { return }
            do { let endpoints = try await self.server.start(); _ = try await self.coordinator.offerTCP(peer, addresses: endpoints) }
            catch { self.failures[peer] = error as? ProtocolFailure ?? .peerUnavailable }
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
                        else { try await self.coordinator.enqueue(snapshot, targets: targets, userInitiated: false) }
                    }
                } catch is CancellationError { }
                catch {
                    if !preparation.isCancelled && self.running {
                        for peer in request.targets { self.failures[peer] = error as? ProtocolFailure ?? .sourceUnavailable }
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
            failures.removeValue(forKey: peer)
            if let device = configuration.peers.first(where: { $0.identity == peer }) { failures.removeValue(forKey: device.id) }
            routes[peer] = .ble; switching.remove(peer)
            connected.insert(peer); locker.connected(peer); pasteboard.start()
            synchronizeConfiguration(targets: [peer])
            if pasteboard.permitted {
                do { let value = try pasteboard.current(); queueClipboard(file: value.0, text: value.1, mime: value.2, targets: [peer]) }
                catch { failures[peer] = error as? ProtocolFailure ?? .sourceUnavailable }
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
            offers.removeValue(forKey: peer)?.cancel()
            if connected.isEmpty { pasteboard.stop(); await server.stop() }
        case .received(let peer, let manifest, let url):
            stopActivity(peer, manifest.id, sending: false)
            if manifest.kind != .file { try pasteboard.apply(manifest, file: url) }
        case .progress(_, let id, let bytes, let size): progress[id] = (bytes, size); transfers[id]?.bytes = bytes
        case .failed(let peer, let id, let code):
            stopActivity(peer, id); failures[peer] = code; transfers[id]?.failure = code
        case .wifiChanged(let peer, let enabled):
            if let index = configuration.peers.firstIndex(where: { $0.identity == peer }), configuration.peers[index].wifi != enabled {
                configuration.peers[index].wifi = enabled; configurationChanged(devices: [peer])
            }
            if enabled { scheduleOffer(peer) }
            else {
                var eligible = false
                for candidate in connected where await coordinator.permitsWifi(candidate) { eligible = true }
                if !eligible { await server.stop() }
            }
        case .completed(let peer, let id): stopActivity(peer, id, sending: true); progress.removeValue(forKey: id); transfers.removeValue(forKey: id)
        case .deviceInformation(let peer, let value): try acceptDeviceInformation(peer, value)
        case .transferStarted(let peer, let manifest, let sending):
            stopActivity(peer, manifest.id, sending: sending)
            activities[peer, default: []].append(LinkActivity(id: manifest.id, kind: manifest.kind, sending: sending))
        case .transferStopped(let peer, let id): stopActivity(peer, id)
        case .transportChanged(let peer, let route):
            guard connected.contains(peer) else { return }
            if let route { routes[peer] = route; switching.remove(peer) }
            else { switching.insert(peer) }
        case .tcpOffer: break
        }
    }
}
