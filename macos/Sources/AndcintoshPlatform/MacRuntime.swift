import AndcintoshCore
import AppKit
import Foundation
import Network
import Observation
import UniformTypeIdentifiers

public struct PeerProfile: Codable, Sendable, Identifiable {
    public var id: UUID
    public var identity: UUID?
    public var name: String?
    public init(id: UUID, identity: UUID? = nil, name: String? = nil) { self.id = id; self.identity = identity; self.name = name }
}

public struct MacConfiguration: Codable, Sendable {
    public var identity = UUID()
    public var peers: [PeerProfile] = []
    public var primary: UUID?
    public var lockEnabled = false
    public var wifi = true
    public var lockDelaySeconds = 15
    public init() {}
    private enum CodingKeys: String, CodingKey { case identity, peers, primary, lockEnabled, wifi, lockDelaySeconds }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        identity = try values.decode(UUID.self, forKey: .identity)
        peers = try values.decode([PeerProfile].self, forKey: .peers)
        primary = try values.decodeIfPresent(UUID.self, forKey: .primary)
        lockEnabled = try values.decode(Bool.self, forKey: .lockEnabled)
        wifi = try values.decode(Bool.self, forKey: .wifi)
        lockDelaySeconds = try values.decodeIfPresent(Int.self, forKey: .lockDelaySeconds) ?? 15
        guard (1...3600).contains(lockDelaySeconds) else {
            throw DecodingError.dataCorruptedError(forKey: .lockDelaySeconds, in: values, debugDescription: "invalidLockDelay")
        }
    }
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
    @ObservationIgnored private lazy var server = TCPServer(identity: configuration.identity, coordinator: coordinator)
    @ObservationIgnored private lazy var bluetooth: BLEClient = {
        let client = BLEClient(identity: configuration.identity, coordinator: coordinator)
        client.discovered = { [weak self] peer in self?.discovered[peer.identifier] = peer }
        client.failed = { [weak self] id, failure in self?.failures[id] = failure }
        client.associated = { [weak self] id, identity in
            guard let self, let index = self.configuration.peers.firstIndex(where: { $0.id == id }) else { return }
            self.configuration.peers[index].identity = identity
            self.persist(); self.configureLock()
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
        let outputRoot = try downloads ?? manager.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Andcintosh")
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
        monitor.start(queue: DispatchQueue(label: "Andcintosh.path", qos: .utility))
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
        persist()
    }
    public func refreshPermissions() { clipboardAllowed = pasteboard.permitted; lockAllowed = locker.permitted }
    public func scan() { start(); discovered.removeAll(); bluetooth.scan() }
    public func save(_ profile: PeerProfile, key: String) async throws {
        let bytes = key.isEmpty ? try KeychainStore.load(peer: profile.id) : try Crypto.key(key)
        start()
        if let existing = configuration.peers.first(where: { $0.id == profile.id }), let peer = existing.identity { await coordinator.stop(peer) }
        try KeychainStore.save(bytes, peer: profile.id)
        if let index = configuration.peers.firstIndex(where: { $0.id == profile.id }) { configuration.peers[index] = profile }
        else { configuration.peers.append(profile) }
        persist()
        try bluetooth.connect(identifier: profile.id, key: bytes, expectedIdentity: profile.identity)
    }
    public func connect(_ profile: PeerProfile) throws {
        start()
        failures.removeValue(forKey: profile.id)
        if let identity = profile.identity { failures.removeValue(forKey: identity) }
        try bluetooth.connect(identifier: profile.id, key: KeychainStore.load(peer: profile.id), expectedIdentity: profile.identity)
    }
    public func wifi(_ enabled: Bool) async {
        configuration.wifi = enabled; persist()
        await coordinator.wifi(enabled && lan)
        if enabled && lan { for peer in connected { scheduleOffer(peer) } }
        else { for task in offers.values { task.cancel() }; offers.removeAll(); await server.stop() }
    }
    public func lock(enabled: Bool, primary: UUID?) throws {
        let identity = configuration.peers.first(where: { $0.id == primary })?.identity
        try locker.setDelay(seconds: configuration.lockDelaySeconds)
        try locker.configure(enabled: enabled, primary: identity)
        configuration.lockEnabled = enabled; configuration.primary = primary; persist()
        if let identity, connected.contains(identity) { locker.connected(identity) }
    }
    public func saveLockDelay(seconds: Int) throws {
        try locker.setDelay(seconds: seconds)
        configuration.lockDelaySeconds = seconds
        persist()
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
        pendingClipboard = nil; clipboardPreparation?.cancel(); clipboardWorker?.cancel()
        await clipboardWorker?.value
        locker.stop(); pasteboard.stop(); monitor?.cancel(); monitor = nil; lan = false
        for task in offers.values { task.cancel() }; offers.removeAll()
        if wasRunning { await bluetooth.stop() } else { await coordinator.stop() }
        await server.stop()
        for token in observation { NSWorkspace.shared.notificationCenter.removeObserver(token) }; observation.removeAll()
        connected.removeAll(); routes.removeAll(); switching.removeAll()
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
            if pasteboard.permitted {
                do { let value = try pasteboard.current(); queueClipboard(file: value.0, text: value.1, mime: value.2, targets: [peer]) }
                catch { failures[peer] = error as? ProtocolFailure ?? .sourceUnavailable }
            }
            scheduleOffer(peer)
        case .disconnected(let peer, let intentional):
            routes.removeValue(forKey: peer); switching.remove(peer)
            connected.remove(peer); locker.disconnected(peer, intentional: intentional)
            bluetooth.sessionDisconnected(peer, intentional: intentional)
            offers.removeValue(forKey: peer)?.cancel()
            if connected.isEmpty { pasteboard.stop(); await server.stop() }
        case .received(_, let manifest, let url): if manifest.kind != .file { try pasteboard.apply(manifest, file: url) }
        case .progress(_, let id, let bytes, let size): progress[id] = (bytes, size); transfers[id]?.bytes = bytes
        case .failed(let peer, let id, let code): failures[peer] = code; transfers[id]?.failure = code
        case .wifiChanged(let peer, let enabled):
            if enabled { scheduleOffer(peer) }
            else {
                var eligible = false
                for candidate in connected where await coordinator.permitsWifi(candidate) { eligible = true }
                if !eligible { await server.stop() }
            }
        case .completed(_, let id): progress.removeValue(forKey: id); transfers.removeValue(forKey: id)
        case .transportChanged(let peer, let route):
            guard connected.contains(peer) else { return }
            if let route { routes[peer] = route; switching.remove(peer) }
            else { switching.insert(peer) }
        case .tcpOffer: break
        }
    }
}
