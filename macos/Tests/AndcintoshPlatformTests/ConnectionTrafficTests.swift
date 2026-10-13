import Foundation
import Testing
@testable import AndcintoshPlatform

private actor PulseClock {
    private var pending: [(Duration, CheckedContinuation<Void, any Error>)] = []
    func pause(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { pending.append((duration, $0)) }
    }
    func first() -> Duration? { pending.first?.0 }
    func advance() { if !pending.isEmpty { pending.removeFirst().1.resume() } }
    func cancel() { let items = pending; pending.removeAll(); for item in items { item.1.resume(throwing: CancellationError()) } }
}

@MainActor @Test func handshakeFlashesEachPacketWithIndependentDirections() async throws {
    let clock = PulseClock(), peer = UUID(), token = UUID()
    let traffic = ConnectionTraffic { try await clock.pause($0) }
    defer { traffic.stop() }
    traffic.signal(peer, .handshakeStarted(token))
    for _ in 0..<3 { traffic.signal(peer, .packet(sending: true, handshake: true)) }
    for _ in 0..<3 {
        for _ in 0..<1000 { if await clock.first() != nil { break }; await Task.yield() }
        #expect(await clock.first() == .milliseconds(100))
        #expect(traffic.sending.contains(peer) && !traffic.receiving.contains(peer))
        await clock.advance()
        for _ in 0..<1000 { if await clock.first() != nil { break }; await Task.yield() }
        #expect(await clock.first() == .milliseconds(80))
        #expect(!traffic.sending.contains(peer) && traffic.visible.contains(peer))
        await clock.advance()
    }
    traffic.signal(peer, .handshakeEnded(token))
    for _ in 0..<1000 { if !traffic.visible.contains(peer) { break }; await Task.yield() }
    #expect(!traffic.visible.contains(peer))
    await clock.cancel()
}

@MainActor @Test func oldPulseCannotClearAReplacementAfterDisconnect() async {
    let clock = PulseClock(), peer = UUID()
    let traffic = ConnectionTraffic { try await clock.pause($0) }
    traffic.signal(peer, .packet(sending: false, handshake: true))
    for _ in 0..<1000 { if await clock.first() != nil { break }; await Task.yield() }
    #expect(traffic.receiving.contains(peer))
    traffic.stop(peer)
    #expect(traffic.visible.isEmpty && traffic.receiving.isEmpty)
    traffic.signal(peer, .packet(sending: false, handshake: true))
    for _ in 0..<1000 { if traffic.receiving.contains(peer) { break }; await Task.yield() }
    await clock.advance()
    for _ in 0..<20 { await Task.yield() }
    #expect(traffic.receiving.contains(peer))
    traffic.stop(); await clock.cancel()
}
