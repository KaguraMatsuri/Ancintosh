import Foundation

final class ChannelLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false
    var closed: Bool { lock.withLock { ended } }
    func close() { lock.withLock { ended = true } }
}

/// Each slot reserves at most 64 KiB of plaintext before the file is read.
actor TransferSlots {
    static let shared = TransferSlots(count: 128)
    private var available: Int
    private struct Waiter {
        let id: UUID
        let lifetime: ChannelLifetime
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var waiters: [Waiter] = []
    init(count: Int) { available = count }
    func acquire(_ lifetime: ChannelLifetime) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !lifetime.closed else { throw ProtocolFailure.peerUnavailable }
            try await withCheckedThrowingContinuation { continuation in
                if available > 0 { available -= 1; continuation.resume() }
                else { waiters.append(Waiter(id: id, lifetime: lifetime, continuation: continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    func release() {
        while !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            if waiter.lifetime.closed { waiter.continuation.resume(throwing: ProtocolFailure.peerUnavailable) }
            else { waiter.continuation.resume(); return }
        }
        available += 1
    }
    func removeClosedWaiters() {
        let closed = waiters.filter { $0.lifetime.closed }
        waiters.removeAll { $0.lifetime.closed }
        for waiter in closed { waiter.continuation.resume(throwing: ProtocolFailure.peerUnavailable) }
    }
}
