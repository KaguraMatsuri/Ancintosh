import Foundation
import Testing
@testable import AncintoshCore

private actor StalledWriter: ByteChannel {
    private var pending: CheckedContinuation<Void, Never>?
    private var stopped = false
    func readExactly(_ count: Int) throws -> Data { throw ProtocolFailure.peerUnavailable }
    func write(_ data: Data) async throws {
        guard !stopped else { throw ProtocolFailure.peerUnavailable }
        await withCheckedContinuation { pending = $0 }
        if stopped { throw ProtocolFailure.peerUnavailable }
    }
    func close() { stopped = true; pending?.resume(); pending = nil }
}
private actor PreparedCounter {
    var count = 0
    func make() -> Record { count += 1; return Record(.data, bytes: Data(count: Wire.tcpChunkSize)) }
}
private func syntheticAuthentication() throws -> Authentication {
    let a = try Hello(role: .mac, peerID: UUID(), nonce: Data(repeating: 1, count: 32), publicKey: Data(repeating: 9, count: 32))
    let b = try Hello(role: .android, peerID: UUID(), nonce: Data(repeating: 2, count: 32), publicKey: Data(repeating: 9, count: 32))
    return try Authentication(peer: b.peerID, session: CryptoSession(key: Data(repeating: 3, count: 32), local: a, remote: b, transport: .tcp, sharedSecret: Data(repeating: 9, count: 32)))
}
@Test func boundedReadAheadStopsAtSixteenAndCloseReturnsCapacity() async throws {
    for _ in 0..<10 {
        let raw = StalledWriter()
        let channel = try EncryptedChannel(raw: raw, authentication: syntheticAuthentication(), transport: .tcp)
        await channel.setDataEpoch(Wire.zeroID)
        let counter = PreparedCounter()
        let task = Task {
            for _ in 0..<17 { _ = try await channel.sendBuffered { await counter.make() } }
        }
        for _ in 0..<100 {
            if await counter.count == 16 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await counter.count == 16)
        await channel.close()
        let result = await task.result
        if case .success = result { Issue.record("Closed producer unexpectedly completed") }
    }
}
@Test func stoppedOrCancelledPermitWaitersDoNotConsumeCapacity() async throws {
    let pool = TransferSlots(count: 1), owner = ChannelLifetime()
    try await pool.acquire(owner)
    let waiter = Task { try await pool.acquire(owner) }
    waiter.cancel()
    await pool.release()
    _ = await waiter.result
    // If the waiter was granted just before cancellation, its caller owns the permit.
    if case .success = await waiter.result { await pool.release() }
    let next = ChannelLifetime()
    try await pool.acquire(next)
    owner.close(); await pool.removeClosedWaiters()
    await pool.release()
}

@MainActor @Test func boundedRepliesReturnWithoutWaitingForTheWriterAndCloseWakesWaiters() async throws {
    let raw = StalledWriter()
    let channel = try EncryptedChannel(raw: raw, authentication: syntheticAuthentication(), transport: .tcp)
    var accepted = 0
    let producer = Task {
        for _ in 0..<17 { try await channel.reply(Record(.acknowledge)); accepted += 1 }
    }
    for _ in 0..<100 { if accepted == 16 { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(accepted == 16)
    await channel.close()
    if case .success = await producer.result { Issue.record("Closed reply producer unexpectedly completed") }
}
