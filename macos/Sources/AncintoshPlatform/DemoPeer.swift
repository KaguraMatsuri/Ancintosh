#if DEBUG
import AncintoshCore
import CryptoKit
import Foundation

public enum DemonstrationTest: String, CaseIterable, Sendable {
    case connection = "连接", clipboard = "同步", file = "文件传输", lock = "断连锁定", notification = "共享通知"
}
public struct DemonstrationResult: Sendable {
    public let peer: UUID
    public let test: DemonstrationTest
    public var passed: Bool?
    public var failure: ProtocolFailure?
}

@MainActor private final class VirtualPeer {
    var profile: PeerProfile
    let store: TransferStore
    var revision: Int64 = -1
    private let events: @Sendable (SyncEvent) async throws -> Void
    lazy var coordinator = SyncCoordinator(identity: profile.identity ?? profile.id, role: .android, store: store, events: events)
    init(profile: PeerProfile, root: URL, events: @escaping @Sendable (SyncEvent) async throws -> Void) throws {
        self.profile = profile; self.events = events
        store = try TransferStore(root: root.appendingPathComponent(profile.id.uuidString), downloads: root.appendingPathComponent(profile.id.uuidString + "/downloads"))
    }
}

@MainActor final class DemoPeer: RuntimeConnector {
    var discovered: ((BLEPeer) -> Void)?
    var failed: ((UUID, ProtocolFailure) -> Void)?
    var associated: ((UUID, UUID) -> Void)?
    var signal: (@MainActor @Sendable (UUID, ConnectionSignal) -> Void)?
    private let identity: UUID
    private let coordinator: SyncCoordinator
    private let profiles: [PeerProfile]
    private let root: URL
    private let memory: MemorySystem
    private var peers: [UUID: VirtualPeer] = [:]
    private var authenticated: Set<UUID> = []
    private var connecting: Set<UUID> = []
    private var tasks: [UUID: Task<Void, any Error>] = [:]
    private var upgrades: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]
    private var raw: [UUID: [MemoryByteChannel]] = [:]
    private var suppressed: Set<UUID> = []
    private var available: Set<UUID>
    private var stopped = false

    init(identity: UUID, coordinator: SyncCoordinator, profiles: [PeerProfile], root: URL, memory: MemorySystem) {
        self.identity = identity; self.coordinator = coordinator; self.profiles = profiles; self.root = root; self.memory = memory
        available = Set(profiles.filter { $0.name != "Galaxy Note 7" }.map(\.id))
    }
    static func key(_ peer: UUID) -> Data { Data(SHA256.hash(data: Data(("Ancintosh/demo/" + peer.uuidString).utf8))) }
    func scan() {
        stopped = false
        for profile in profiles { discovered?(BLEPeer(identifier: profile.id, name: profile.name, rssi: -40)) }
    }
    func allow(_ peer: UUID) { available.insert(peer); suppressed.remove(peer) }
    func suppress(_ peer: UUID, _ enabled: Bool) { if enabled { suppressed.insert(peer) } else { suppressed.remove(peer) } }
    func sessionAuthenticated(_ peer: UUID) -> Bool { authenticated.contains(peer) && !stopped }
    func sessionDisconnected(_ peer: UUID, intentional: Bool) {
        guard !connecting.contains(peer) else { return }
        authenticated.remove(peer)
        if !intentional, !stopped, !suppressed.contains(peer), let key = memory.keys[peer] {
            try? connect(identifier: peer, key: key, expectedIdentity: peer)
        }
    }
    func connect(identifier id: UUID, key: Data, expectedIdentity: UUID?) throws {
        guard available.contains(id), let profile = profiles.first(where: { $0.id == id }) else { throw ProtocolFailure.peerUnavailable }
        guard key.count == 32 else { throw ProtocolFailure.invalidKey }
        stopped = false
        tasks[id]?.cancel(); upgrades.removeValue(forKey: id)?.cancel()
        let previous = raw.removeValue(forKey: id) ?? []
        let peer: VirtualPeer
        if let existing = peers[id] { peer = existing }
        else {
            peer = try VirtualPeer(profile: profile, root: root) { [weak self] event in try await self?.event(id, event) }
            peers[id] = peer
        }
        let generation = UUID(); generations[id] = generation
        connecting.insert(id)
        authenticated.remove(id)
        let (left, right) = MemoryByteChannel.pair(handshakeDelay: .milliseconds(100))
        raw[id] = [left, right]
        tasks[id] = Task { [weak self] in
            guard let self else { return }
            for channel in previous { await channel.close() }
            let token = UUID(); self.signal?(id, .handshakeStarted(token))
            defer {
                self.signal?(id, .handshakeEnded(token))
                if self.generations[id] == generation { self.connecting.remove(id) }
            }
            let callback: @Sendable (Bool) -> Void = { [weak self] sending in
                Task { @MainActor in
                    guard self?.generations[id] == generation else { return }
                    self?.signal?(id, .packet(sending: sending, handshake: true))
                }
            }
            do {
                async let a = Handshake.authenticate(channel: left, role: .mac, identity: self.identity, key: key, transport: .ble,
                    expectedPeer: expectedIdentity, traffic: callback)
                async let b = Handshake.authenticate(channel: right, role: .android, identity: id, key: Self.key(id), transport: .ble, expectedPeer: self.identity)
                let (mac, phone) = try await (a, b)
                try Task.checkCancellation()
                guard self.generations[id] == generation, !self.stopped else { throw CancellationError() }
                self.authenticated.insert(id); self.associated?(id, id)
                await peer.coordinator.notificationAccess(NotificationAccess(capture: true, display: true))
                await peer.coordinator.wifi(peer.profile.wifi ?? true)
                try await peer.coordinator.installBLE(self.identity, channel: EncryptedChannel(raw: right, authentication: phone, transport: .ble))
                try await self.coordinator.installBLE(id, channel: EncryptedChannel(raw: left, authentication: mac, transport: .ble,
                    traffic: { sending in Task { @MainActor in
                        guard self.generations[id] == generation else { return }
                        self.signal?(id, .packet(sending: sending, handshake: false))
                    }}))
            } catch {
                await left.close(); await right.close()
                if self.generations[id] == generation {
                    self.authenticated.remove(id)
                    if !(error is CancellationError) { self.failed?(id, error as? ProtocolFailure ?? .peerUnavailable) }
                }
                throw error
            }
        }
    }
    func waitAuthenticated(_ peer: UUID) async throws {
        guard let task = tasks[peer] else { throw ProtocolFailure.peerUnavailable }
        try await task.value
        guard authenticated.contains(peer) else { throw ProtocolFailure.authenticationFailed }
    }
    func upgrade(_ peer: UUID) async throws {
        guard authenticated.contains(peer) else { throw ProtocolFailure.peerUnavailable }
        _ = try await coordinator.offerTCP(peer, addresses: [TCPAddress(host: "127.0.0.1", port: 1)])
    }
    private func bindTCP(_ peerID: UUID, offer: TCPOffer) async throws {
        guard let peer = peers[peerID], let generation = generations[peerID], authenticated.contains(peerID) else { return }
        let key = try await coordinator.bindingKey(peer: peerID, context: offer.id)
        let (left, right) = MemoryByteChannel.pair(handshakeDelay: .milliseconds(100))
        raw[peerID, default: []].append(contentsOf: [left, right])
        let token = UUID(); signal?(peerID, .handshakeStarted(token))
        defer { signal?(peerID, .handshakeEnded(token)) }
        do {
            async let a = Handshake.authenticate(channel: left, role: .mac, identity: identity, key: key, context: offer.id,
                transport: .tcp, expectedPeer: peerID, traffic: { [weak self] sending in Task { @MainActor in
                    guard self?.generations[peerID] == generation else { return }
                    self?.signal?(peerID, .packet(sending: sending, handshake: true))
                } })
            async let b = Handshake.authenticate(channel: right, role: .android, identity: peerID, key: key, context: offer.id, transport: .tcp, expectedPeer: identity)
            let (mac, phone) = try await (a, b)
            guard generations[peerID] == generation, !stopped else { throw CancellationError() }
            try await peer.coordinator.installTCP(identity, channel: EncryptedChannel(raw: right, authentication: phone, transport: .tcp), context: offer.id)
            try await coordinator.installTCP(peerID, channel: EncryptedChannel(raw: left, authentication: mac, transport: .tcp,
                traffic: { [weak self] sending in Task { @MainActor in self?.signal?(peerID, .packet(sending: sending, handshake: false)) } }), context: offer.id)
        } catch { await left.close(); await right.close(); throw error }
    }
    private func event(_ id: UUID, _ event: SyncEvent) async throws {
        guard !stopped, let peer = peers[id] else { return }
        switch event {
        case .configurationReady:
            try await peer.coordinator.reportDevice(DeviceInformation(name: peer.profile.name ?? id.uuidString, kind: peer.profile.kind ?? .phone,
                wifi: peer.profile.wifi ?? true, notificationAccess: NotificationAccess(capture: true, display: true)), to: identity)
        case .configuration(_, let configuration):
            guard configuration.revision >= peer.revision, let value = configuration.device, value.id == id else { return }
            peer.revision = configuration.revision; peer.profile.name = value.name
            await peer.coordinator.notificationPolicy(identity, enabled: value.notifications == true)
        case .tcpOffer(_, let offer, _):
            upgrades[id]?.cancel()
            upgrades[id] = Task { [weak self] in
                do { try await self?.bindTCP(id, offer: offer) }
                catch { if !(error is CancellationError) { self?.failed?(id, error as? ProtocolFailure ?? .peerUnavailable) } }
            }
        case .received(_, let manifest, let url):
            // Echo only Mac-originated test content. Relayed clipboard content never loops.
            guard manifest.origin == identity else { return }
            let snapshot = try await peer.store.snapshot(url, kind: manifest.kind, name: manifest.name, mime: manifest.mime, origin: id)
            try await peer.coordinator.enqueue(snapshot, targets: [identity], userInitiated: true)
        case .notification(_, let value):
            memory.phoneNotifications[id] = value
            if value.action == .upsert { try await peer.coordinator.enqueueNotification(value, to: identity) }
        default: break
        }
    }
    func stop() async {
        stopped = true; authenticated.removeAll(); connecting.removeAll(); generations.removeAll()
        let pending = Array(tasks.values), pendingUpgrades = Array(upgrades.values), channels = raw.values.flatMap { $0 }
        tasks.removeAll(); upgrades.removeAll(); raw.removeAll()
        for task in pending { task.cancel() }; for task in pendingUpgrades { task.cancel() }
        for channel in channels { await channel.close() }
        for task in pending { _ = try? await task.value }; for task in pendingUpgrades { await task.value }
        for peer in peers.values { await peer.coordinator.stop(); await peer.store.closeHandles() }
        await coordinator.stop()
    }
}
#endif
