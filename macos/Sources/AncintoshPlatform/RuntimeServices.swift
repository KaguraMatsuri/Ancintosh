import AncintoshCore
import Foundation

@MainActor public protocol ClipboardAccess: AnyObject {
    var changed: ((URL?, String?, String?) -> Void)? { get set }
    var permitted: Bool { get }
    func start()
    func stop()
    func current() throws -> (URL?, String?, String?)
    func apply(_ manifest: TransferManifest, file: URL) throws
}

@MainActor protocol RuntimeConnector: AnyObject {
    var discovered: ((BLEPeer) -> Void)? { get set }
    var failed: ((UUID, ProtocolFailure) -> Void)? { get set }
    var associated: ((UUID, UUID) -> Void)? { get set }
    var signal: (@MainActor @Sendable (UUID, ConnectionSignal) -> Void)? { get set }
    func scan()
    func connect(identifier: UUID, key: Data, expectedIdentity: UUID?) throws
    func sessionAuthenticated(_ peer: UUID) -> Bool
    func sessionDisconnected(_ peer: UUID, intentional: Bool)
    func stop() async
}

@MainActor private final class NativeConnector: RuntimeConnector {
    private let client: BLEClient
    init(identity: UUID, coordinator: SyncCoordinator) { client = BLEClient(identity: identity, coordinator: coordinator) }
    var discovered: ((BLEPeer) -> Void)? { get { client.discovered } set { client.discovered = newValue } }
    var failed: ((UUID, ProtocolFailure) -> Void)? { get { client.failed } set { client.failed = newValue } }
    var associated: ((UUID, UUID) -> Void)? { get { client.associated } set { client.associated = newValue } }
    var signal: (@MainActor @Sendable (UUID, ConnectionSignal) -> Void)? { get { client.signal } set { client.signal = newValue } }
    func scan() { client.scan() }
    func connect(identifier: UUID, key: Data, expectedIdentity: UUID?) throws { try client.connect(identifier: identifier, key: key, expectedIdentity: expectedIdentity) }
    func sessionAuthenticated(_ peer: UUID) -> Bool { client.sessionAuthenticated(peer) }
    func sessionDisconnected(_ peer: UUID, intentional: Bool) { client.sessionDisconnected(peer, intentional: intentional) }
    func stop() async { await client.stop() }
}

@MainActor final class RuntimeServices {
    let loadKey: (UUID) throws -> Data
    let saveKey: (Data, UUID) throws -> Void
    private let clipboardFactory: () -> any ClipboardAccess
    lazy var clipboard = clipboardFactory()
    let locker: LockController
    let connector: (UUID, SyncCoordinator) -> any RuntimeConnector
    private init(loadKey: @escaping (UUID) throws -> Data, saveKey: @escaping (Data, UUID) throws -> Void,
                 clipboard: @escaping () -> any ClipboardAccess, locker: LockController,
                 connector: @escaping (UUID, SyncCoordinator) -> any RuntimeConnector) {
        self.loadKey = loadKey; self.saveKey = saveKey; clipboardFactory = clipboard; self.locker = locker; self.connector = connector
    }
    static func native() -> RuntimeServices {
        RuntimeServices(loadKey: { try KeychainStore.load(peer: $0) }, saveKey: { try KeychainStore.save($0, peer: $1) },
            clipboard: { PasteboardBridge() }, locker: LockController(), connector: { NativeConnector(identity: $0, coordinator: $1) })
    }
    #if DEBUG
    var memory: MemorySystem?
    static func demonstration(profiles: [PeerProfile], root: URL, memory: MemorySystem) -> RuntimeServices {
        for profile in profiles { memory.keys[profile.id] = DemoPeer.key(profile.id) }
        let services = RuntimeServices(loadKey: { guard let key = memory.keys[$0] else { throw ProtocolFailure.invalidKey }; return key },
            saveKey: { key, peer in guard key.count == 32 else { throw ProtocolFailure.invalidKey }; memory.keys[peer] = key },
            clipboard: { memory }, locker: LockController(authorizationCheck: { true }, authorizationRequest: { true }, lockAction: { memory.recordLock() }),
            connector: { DemoPeer(identity: $0, coordinator: $1, profiles: profiles, root: root, memory: memory) })
        services.memory = memory
        return services
    }
    #endif
}

#if DEBUG
@MainActor final class MemorySystem: ClipboardAccess {
    var keys: [UUID: Data] = [:]
    var text = ""
    var receivedText = ""
    var lockCount = 0
    var phoneNotifications: [UUID: NotificationMessage] = [:]
    private var lockWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    func recordLock() {
        lockCount += 1
        let pending = lockWaiters; lockWaiters.removeAll()
        for waiter in pending.values { waiter.resume() }
    }
    func waitForLock(after count: Int) async throws {
        if lockCount > count { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { lockWaiters[id] = $0 }
        } onCancel: { Task { @MainActor in self.lockWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError()) } }
    }
    var changed: ((URL?, String?, String?) -> Void)?
    var permitted: Bool { true }
    func start() {}
    func stop() {}
    func current() throws -> (URL?, String?, String?) { (nil, text, "text/plain;charset=utf-8") }
    func apply(_ manifest: TransferManifest, file: URL) throws {
        if manifest.kind == .text { receivedText = try String(contentsOf: file, encoding: .utf8) }
    }
}
#endif
