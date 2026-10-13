import Foundation
import Network
import Darwin
import Testing
import AncintoshCore
import AncintoshPlatform

private actor BenchmarkEvents {
    private var completions: Set<UUID> = []
    private var errors: [ProtocolFailure] = []
    func record(_ event: SyncEvent) {
        switch event {
        case .completed(_, let id): completions.insert(id)
        case .failed(_, _, let failure): errors.append(failure)
        default: break
        }
    }
    func done(_ id: UUID) throws -> Bool {
        if let first = errors.first { throw first }
        return completions.contains(id)
    }
}
private func tcpPair() async throws -> (TCPByteChannel, TCPByteChannel) {
    let serverOptions = NWProtocolTCP.Options(); serverOptions.noDelay = true
    let parameters = NWParameters(tls: nil, tcp: serverOptions)
    parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    let accepted = AsyncStream<NWConnection>.makeStream()
    let ready = AsyncThrowingStream<NWEndpoint.Port, any Error>.makeStream()
    listener.newConnectionHandler = { accepted.continuation.yield($0) }
    listener.stateUpdateHandler = { state in
        switch state {
        case .ready: if let port = listener.port { ready.continuation.yield(port) }
        case .failed(let error): ready.continuation.finish(throwing: error); accepted.continuation.finish()
        default: break
        }
    }
    listener.start(queue: DispatchQueue(label: "Ancintosh.benchmark.listener"))
    let timeout = Task {
        do { try await Task.sleep(for: .seconds(5)) } catch { return }
        ready.continuation.finish(throwing: ProtocolFailure.timeout)
        accepted.continuation.finish(); listener.cancel()
    }
    defer { timeout.cancel(); listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel(); accepted.continuation.finish(); ready.continuation.finish() }
    var readiness = ready.stream.makeAsyncIterator()
    guard let port = try await readiness.next() else { throw ProtocolFailure.peerUnavailable }
    let clientOptions = NWProtocolTCP.Options(); clientOptions.noDelay = true
    let connection = NWConnection(host: "127.0.0.1", port: port, using: NWParameters(tls: nil, tcp: clientOptions))
    connection.stateUpdateHandler = { state in
        if case .failed(let error) = state { print("BENCH connection failed: \(error)"); accepted.continuation.finish() }
        if case .waiting(let error) = state { print("BENCH connection waiting: \(error)") }
    }
    let client = TCPByteChannel(connection)
    var iterator = accepted.stream.makeAsyncIterator()
    guard let incoming = await iterator.next() else { await client.close(); throw ProtocolFailure.timeout }
    return (client, TCPByteChannel(incoming))
}
private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}
private func residentMiB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let capacity = Int(count)
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: capacity) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return status == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
}

// Explicit opt-in: tests real local TCP, crypto, file snapshots, durability and publication.
// Both endpoints run the Mac implementation; this is not a Wi-Fi or Android benchmark.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ANDCINTOSH_BENCHMARK"] == "1"))
func nativeTCPEncryptedFileBenchmark() async throws {
    for mib in [64, 1024] {
        for trial in 1...3 {
            let base = FileManager.default.temporaryDirectory.appendingPathComponent("Ancintosh-bench-\(UUID())")
            defer { try? FileManager.default.removeItem(at: base) }
            let aID = UUID(), bID = UUID()
            let aStore = try TransferStore(root: base.appendingPathComponent("a"), downloads: base.appendingPathComponent("ad"))
            let bStore = try TransferStore(root: base.appendingPathComponent("b"), downloads: base.appendingPathComponent("bd"))
            let events = BenchmarkEvents()
            let a = SyncCoordinator(identity: aID, role: .mac, store: aStore) { await events.record($0) }
            let b = SyncCoordinator(identity: bID, role: .android, store: bStore) { await events.record($0) }
            let (x,y) = try await tcpPair()
            let key = Data(repeating: 7, count: 32)
            async let ax = Handshake.authenticate(channel: x, role: .mac, identity: aID, key: key, transport: .ble)
            async let by = Handshake.authenticate(channel: y, role: .android, identity: bID, key: key, transport: .ble)
            let (axAuth, byAuth) = try await (ax, by)
            try await a.installBLE(bID, channel: EncryptedChannel(raw: x, authentication: axAuth, transport: .ble))
            try await b.installBLE(aID, channel: EncryptedChannel(raw: y, authentication: byAuth, transport: .ble))
            let offer = try await a.offerTCP(bID, addresses: [TCPAddress(host: "127.0.0.1", port: 1)])
            let binding = try await a.bindingKey(peer: bID, context: offer.id)
            for _ in 0..<1000 {
                if (try? await b.bindingKey(peer: aID, context: offer.id)) != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let (u,v) = try await tcpPair()
            async let au = Handshake.authenticate(channel: u, role: .mac, identity: aID, key: binding, context: offer.id, transport: .tcp)
            async let bv = Handshake.authenticate(channel: v, role: .android, identity: bID, key: binding, context: offer.id, transport: .tcp)
            let (auAuth, bvAuth) = try await (au,bv)
            try await a.installTCP(bID, channel: EncryptedChannel(raw: u, authentication: auAuth, transport: .tcp), context: offer.id)
            try await b.installTCP(aID, channel: EncryptedChannel(raw: v, authentication: bvAuth, transport: .tcp), context: offer.id)
            let source = base.appendingPathComponent("source.bin")
            FileManager.default.createFile(atPath: source.path, contents: nil)
            let output = try FileHandle(forWritingTo: source)
            let block = Data((0..<1_048_576).map { UInt8(($0 * 31 + 17) % 251) })
            for _ in 0..<mib { try output.write(contentsOf: block) }
            try output.synchronize(); try output.close()
            let prepareStart = ContinuousClock.now
            let snapshot = try await aStore.snapshot(source, kind: .file, name: "received.bin", mime: "application/octet-stream", origin: aID)
            let prepareSeconds = seconds(prepareStart.duration(to: .now))
            let started = ContinuousClock.now
            var peak = residentMiB()
            try await a.enqueue(snapshot, targets: [bID], userInitiated: true)
            while try await !events.done(snapshot.manifest.id) {
                guard seconds(started.duration(to: .now)) < 180 else { throw ProtocolFailure.timeout }
                peak = max(peak, residentMiB())
                try await Task.sleep(for: .milliseconds(20))
            }
            let elapsed = seconds(started.duration(to: .now))
            let target = base.appendingPathComponent("bd/received.bin")
            let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize
            #expect(size == mib * 1_048_576)
            print(String(format: "BENCH sizeMiB=%d trial=%d prepareSeconds=%.3f transferAndVerifySeconds=%.3f MiBps=%.2f peakRSSMiB=%.1f", mib, trial, prepareSeconds, elapsed, Double(mib)/elapsed, peak))
            await a.stop(); await b.stop()
        }
    }
}
