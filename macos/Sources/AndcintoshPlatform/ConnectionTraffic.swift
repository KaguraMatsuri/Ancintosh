import Foundation
import Observation

public enum ConnectionSignal: Sendable {
    case handshakeStarted(UUID), handshakeEnded(UUID)
    case packet(sending: Bool, handshake: Bool)
}

@MainActor @Observable
public final class ConnectionTraffic {
    public private(set) var sending: Set<UUID> = []
    public private(set) var receiving: Set<UUID> = []
    public private(set) var visible: Set<UUID> = []
    private struct Direction: Hashable { let peer: UUID; let sending: Bool }
    private var handshakes: [UUID: Set<UUID>] = [:]
    private var queued: [Direction: Int] = [:]
    private var workers: [Direction: Task<Void, Never>] = [:]
    private var generations: [Direction: UUID] = [:]
    private let pause: @Sendable (Duration) async throws -> Void

    public init(pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) { self.pause = pause }
    public func signal(_ peer: UUID, _ event: ConnectionSignal) {
        switch event {
        case .handshakeStarted(let token): handshakes[peer, default: []].insert(token); visible.insert(peer)
        case .handshakeEnded(let token):
            handshakes[peer]?.remove(token)
            if handshakes[peer]?.isEmpty == true { handshakes.removeValue(forKey: peer) }
            refreshVisibility(peer)
        case .packet(let outbound, let handshake):
            let direction = Direction(peer: peer, sending: outbound)
            if handshake { queued[direction, default: 0] += 1 }
            else if queued[direction, default: 0] == 0 { queued[direction] = 1 }
            visible.insert(peer)
            guard workers[direction] == nil else { return }
            let generation = UUID(); generations[direction] = generation
            workers[direction] = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.generations[direction] == generation {
                        self.workers.removeValue(forKey: direction); self.queued.removeValue(forKey: direction)
                        self.generations.removeValue(forKey: direction); self.light(direction, false)
                        self.refreshVisibility(peer)
                    }
                }
                while !Task.isCancelled, self.generations[direction] == generation, self.queued[direction, default: 0] > 0 {
                    self.queued[direction, default: 0] -= 1
                    self.light(direction, true)
                    do {
                        try await self.pause(.milliseconds(100))
                        guard self.generations[direction] == generation else { return }
                        self.light(direction, false)
                        try await self.pause(.milliseconds(80))
                    } catch { return }
                }
            }
        }
    }
    public func stop(_ peer: UUID) {
        for direction in workers.keys.filter({ $0.peer == peer }) {
            generations.removeValue(forKey: direction); workers.removeValue(forKey: direction)?.cancel()
            queued.removeValue(forKey: direction)
        }
        sending.remove(peer); receiving.remove(peer); handshakes.removeValue(forKey: peer); visible.remove(peer)
    }
    public func stop() { for peer in visible { stop(peer) } }
    private func light(_ direction: Direction, _ on: Bool) {
        if direction.sending {
            if on { sending.insert(direction.peer) } else { sending.remove(direction.peer) }
        } else {
            if on { receiving.insert(direction.peer) } else { receiving.remove(direction.peer) }
        }
    }
    private func refreshVisibility(_ peer: UUID) {
        if handshakes[peer] == nil && !workers.keys.contains(where: { $0.peer == peer }) { visible.remove(peer) }
    }
}
