import AncintoshCore
import Foundation
import UserNotifications

@MainActor final class MacNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var requested = false
    private var allowed = false
    private var queues: [UUID: AncintoshCore.NotificationQueue] = [:]
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]
    var failed: ((UUID, ProtocolFailure) -> Void)?
    override init() { super.init(); center.delegate = self }
    func permitted() async -> Bool {
        let settings = await center.notificationSettings()
        allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        return allowed
    }
    func request() async throws -> Bool {
        if await permitted() { return true }
        guard !requested else { return false }
        requested = true
        allowed = try await center.requestAuthorization(options: [.alert])
        return allowed
    }
    func enqueue(peer: UUID, value: NotificationMessage) {
        queues[peer, default: AncintoshCore.NotificationQueue()].append(value)
        guard workers[peer] == nil else { return }
        let generation = UUID(); generations[peer] = generation
        workers[peer] = Task {
            defer { if generations[peer] == generation { workers.removeValue(forKey: peer); generations.removeValue(forKey: peer) } }
            while !Task.isCancelled, generations[peer] == generation, let value = queues[peer]?.pop() {
                do {
                    try await apply(peer: peer, value: value)
                    if Task.isCancelled || generations[peer] != generation {
                        let id = prefix(peer) + value.id.uuidString
                        center.removePendingNotificationRequests(withIdentifiers: [id]); center.removeDeliveredNotifications(withIdentifiers: [id])
                    }
                } catch { failed?(peer, .permissionDenied) }
            }
        }
    }
    private func apply(peer: UUID, value: NotificationMessage) async throws {
        let id = prefix(peer) + value.id.uuidString
        if value.action == .remove {
            center.removePendingNotificationRequests(withIdentifiers: [id]); center.removeDeliveredNotifications(withIdentifiers: [id]); return
        }
        guard allowed else { return }
        let content = UNMutableNotificationContent()
        content.title = value.title; content.subtitle = value.application; content.body = value.body
        content.threadIdentifier = peer.uuidString; content.interruptionLevel = .passive; content.sound = nil
        try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
    func clear(peer: UUID) async {
        let worker = workers.removeValue(forKey: peer)
        generations.removeValue(forKey: peer); queues.removeValue(forKey: peer); worker?.cancel(); await worker?.value
        let prefix = prefix(peer)
        let delivered = await center.deliveredNotifications().filter { $0.request.identifier.hasPrefix(prefix) }.map { $0.request.identifier }
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(prefix) }.map(\.identifier)
        center.removeDeliveredNotifications(withIdentifiers: delivered); center.removePendingNotificationRequests(withIdentifiers: pending)
    }
    func stop() async {
        let pending = Array(workers.values)
        workers.removeAll(); generations.removeAll(); queues.removeAll()
        for task in pending { task.cancel() }; for task in pending { await task.value }
    }
    private func prefix(_ peer: UUID) -> String { "Ancintosh.mirror.\(peer.uuidString)." }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}
