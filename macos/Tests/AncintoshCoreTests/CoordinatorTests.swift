import Foundation
import Testing
@testable import AncintoshCore

private actor MemoryPipe {
    var buffer = Data()
    var pending: (Int, CheckedContinuation<Data, any Error>)?
    var closed = false
    func read(_ count: Int) async throws -> Data {
        if closed { throw ProtocolFailure.peerUnavailable }
        if buffer.count >= count { let value = Data(buffer.prefix(count)); buffer.removeFirst(count); return value }
        return try await withCheckedThrowingContinuation { continuation in pending = (count, continuation) }
    }
    func write(_ bytes: Data) throws {
        if closed { throw ProtocolFailure.peerUnavailable }
        buffer.append(bytes)
        if let (count, continuation) = pending, buffer.count >= count {
            let result = Data(buffer.prefix(count)); buffer.removeFirst(count); pending = nil
            continuation.resume(returning: result)
        }
    }
    func close() {
        closed = true
        pending?.1.resume(throwing: ProtocolFailure.peerUnavailable); pending = nil
    }
}

private struct MemoryChannel: ByteChannel {
    let input: MemoryPipe
    let output: MemoryPipe
    func readExactly(_ count: Int) async throws -> Data { try await input.read(count) }
    func write(_ data: Data) async throws { try await Task.sleep(for: .milliseconds(1)); try await output.write(data) }
    func close() async { await input.close(); await output.close() }
}

private func pair() -> (MemoryChannel, MemoryChannel) {
    let a = MemoryPipe(), b = MemoryPipe()
    return (MemoryChannel(input: a, output: b), MemoryChannel(input: b, output: a))
}

private actor EventRecorder {
    var complete: Set<UUID> = []
    var received: [UUID: URL] = [:]
    var sent: UInt64 = 0
    var errors: [ProtocolFailure] = []
    var routes: [UUID: TransportKind] = [:]
    var wifiPreferences: [UUID: Bool] = [:]
    var information: [UUID: DeviceInformation] = [:]
    var active: Set<String> = []
    func record(_ event: SyncEvent) {
        switch event {
        case .completed(let peer, let id): complete.insert(id); active.remove("\(peer)/\(id)/true")
        case .received(let peer, let manifest, let file): received[manifest.id] = file; active.remove("\(peer)/\(manifest.id)/false")
        case .transportChanged(let peer, let route): routes[peer] = route
        case .wifiChanged(let peer, let enabled): wifiPreferences[peer] = enabled
        case .progress(_, _, let offset, _): sent = offset
        case .failed(_, _, let error): errors.append(error)
        case .deviceInformation(let peer, let value): information[peer] = value
        case .transferStarted(let peer, let manifest, let sending): active.insert("\(peer)/\(manifest.id)/\(sending)")
        case .transferStopped(let peer, let id): active.remove("\(peer)/\(id)/true"); active.remove("\(peer)/\(id)/false")
        default: break
        }
    }
}

@Test func authenticatedCoordinatorTransferAndWifiFallback() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let mac = UUID(), phone = UUID()
    let aStore = try TransferStore(root: base.appendingPathComponent("mac"), downloads: base.appendingPathComponent("macDownloads"))
    let bStore = try TransferStore(root: base.appendingPathComponent("phone"), downloads: base.appendingPathComponent("phoneDownloads"))
    let events = EventRecorder()
    let left = SyncCoordinator(identity: mac, role: .mac, store: aStore) { await events.record($0) }
    let right = SyncCoordinator(identity: phone, role: .android, store: bStore) { await events.record($0) }
    let (a, b) = pair()
    let key = Data(repeating: 7, count: 32)
    async let aa = Handshake.authenticate(channel: a, role: .mac, identity: mac, key: key, transport: .ble)
    async let bb = Handshake.authenticate(channel: b, role: .android, identity: phone, key: key, transport: .ble)
    let (authA, authB) = try await (aa, bb)
    try await left.installBLE(phone, channel: EncryptedChannel(raw: a, authentication: authA, transport: .ble))
    try await right.installBLE(mac, channel: EncryptedChannel(raw: b, authentication: authB, transport: .ble))
    let source = base.appendingPathComponent("source")
    let bytes = Data((0..<1_000_000).map { UInt8($0 % 251) })
    try bytes.write(to: source)
    let snapshot = try await aStore.snapshot(source, kind: .file, name: "original.bin", mime: "application/octet-stream", origin: mac)
    try await left.enqueue(snapshot, targets: [phone], userInitiated: true)
    for _ in 0..<100 { if await events.sent >= 16_384 { break }; try await Task.sleep(for: .milliseconds(5)) }
    let offer = try await left.offerTCP(phone, addresses: [TCPAddress(host: "192.0.2.1", port: 12345)])
    for _ in 0..<100 {
        if (try? await right.bindingKey(peer: mac, context: offer.id)) != nil { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    let binding = try await left.bindingKey(peer: phone, context: offer.id)
    let (c, d) = pair()
    async let ta = Handshake.authenticate(channel: c, role: .mac, identity: mac, key: binding, context: offer.id, transport: .tcp)
    async let tb = Handshake.authenticate(channel: d, role: .android, identity: phone, key: binding, context: offer.id, transport: .tcp)
    let (authC, authD) = try await (ta, tb)
    try await left.installTCP(phone, channel: EncryptedChannel(raw: c, authentication: authC, transport: .tcp), context: offer.id)
    try await right.installTCP(mac, channel: EncryptedChannel(raw: d, authentication: authD, transport: .tcp), context: offer.id)
    #expect(await left.usingTCP(phone))
    #expect(await events.routes[phone] == .tcp)
    try await Task.sleep(for: .milliseconds(3))
    await left.wifi(false)
    #expect(await events.routes[phone] == .ble)
    for _ in 0..<600 { if await events.complete.contains(snapshot.manifest.id) { break }; try await Task.sleep(for: .milliseconds(5)) }
    let delivered = await events.received[snapshot.manifest.id]
    #expect(delivered != nil)
    if let delivered { #expect(try Data(contentsOf: delivered) == bytes) }
    #expect(await events.complete.contains(snapshot.manifest.id))
    #expect(await events.active.isEmpty)
    let errors = await events.errors
    #expect(errors.isEmpty)
    await left.stop(); await right.stop()
}

@Test func schedulerPrioritizesClipboardAndRetainsFailedFiles() throws {
    let peer = UUID(), origin = UUID()
    let file = try TransferManifest(kind: .file, name: "file", mime: "x", size: 10, sha256: Crypto.digest(Data()), origin: origin)
    let clip = try TransferManifest(kind: .text, name: "text", mime: "text/plain", size: 1, sha256: Crypto.digest(Data()), origin: origin)
    var scheduler = TransferScheduler()
    scheduler.enqueue(OutboundJob(peer: peer, manifest: file, snapshot: URL(fileURLWithPath: "/unused"), userInitiated: true))
    scheduler.enqueue(OutboundJob(peer: peer, manifest: clip, snapshot: URL(fileURLWithPath: "/unused2"), userInitiated: false))
    #expect(scheduler.next(available: [peer])?.manifest.id == clip.id)
    scheduler.fail(file.id, peer: peer, error: .insufficientSpace)
    #expect(scheduler.next(available: [peer]) == nil)
    #expect(scheduler.jobs.count == 1)
    scheduler.fail(file.id, peer: peer, error: nil)
    #expect(scheduler.next(available: [peer])?.manifest.id == file.id)
}

@Test func unreadableFileCanRetryWithoutReconnecting() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let mac = UUID(), phone = UUID(), events = EventRecorder()
    let aStore = try TransferStore(root: base.appendingPathComponent("mac"), downloads: base.appendingPathComponent("macDownloads"))
    let bStore = try TransferStore(root: base.appendingPathComponent("phone"), downloads: base.appendingPathComponent("phoneDownloads"))
    let left = SyncCoordinator(identity: mac, role: .mac, store: aStore) { await events.record($0) }
    let right = SyncCoordinator(identity: phone, role: .android, store: bStore) { await events.record($0) }
    let (a, b) = pair(), key = Data(repeating: 9, count: 32)
    async let aa = Handshake.authenticate(channel: a, role: .mac, identity: mac, key: key, transport: .ble)
    async let bb = Handshake.authenticate(channel: b, role: .android, identity: phone, key: key, transport: .ble)
    let (authA, authB) = try await (aa, bb)
    try await left.installBLE(phone, channel: EncryptedChannel(raw: a, authentication: authA, transport: .ble))
    try await right.installBLE(mac, channel: EncryptedChannel(raw: b, authentication: authB, transport: .ble))
    let source = base.appendingPathComponent("source"), bytes = Data(repeating: 5, count: 8192)
    try bytes.write(to: source)
    let snapshot = try await aStore.snapshot(source, kind: .file, name: "retry.bin", mime: "application/octet-stream", origin: mac)
    await aStore.release(snapshot.url)
    try await left.enqueue(snapshot, targets: [phone], userInitiated: true)
    for _ in 0..<100 { if await events.errors.contains(.sourceUnavailable) { break }; try await Task.sleep(for: .milliseconds(5)) }
    let retained = await left.outgoingFiles()
    #expect(retained.count == 1)
    #expect(retained.first?.failure == .sourceUnavailable)
    #expect(await left.connectedPeers().contains(phone))
    try bytes.write(to: snapshot.url)
    try await left.retry(snapshot.manifest.id, peer: phone)
    for _ in 0..<200 { if await events.complete.contains(snapshot.manifest.id) { break }; try await Task.sleep(for: .milliseconds(5)) }
    let delivered = await events.received[snapshot.manifest.id]
    #expect(delivered != nil)
    if let delivered { #expect(try Data(contentsOf: delivered) == bytes) }
    #expect(await left.outgoingFiles().isEmpty)
    await left.stop(); await right.stop()
}

@Test func cancellingFileRemovesSnapshotWithoutDisconnecting() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let mac = UUID(), phone = UUID()
    let aStore = try TransferStore(root: base.appendingPathComponent("mac"), downloads: base.appendingPathComponent("macDownloads"))
    let bStore = try TransferStore(root: base.appendingPathComponent("phone"), downloads: base.appendingPathComponent("phoneDownloads"))
    let left = SyncCoordinator(identity: mac, role: .mac, store: aStore) { _ in }
    let right = SyncCoordinator(identity: phone, role: .android, store: bStore) { _ in }
    let (a, b) = pair(), key = Data(repeating: 4, count: 32)
    async let aa = Handshake.authenticate(channel: a, role: .mac, identity: mac, key: key, transport: .ble)
    async let bb = Handshake.authenticate(channel: b, role: .android, identity: phone, key: key, transport: .ble)
    let (authA, authB) = try await (aa, bb)
    try await left.installBLE(phone, channel: EncryptedChannel(raw: a, authentication: authA, transport: .ble))
    try await right.installBLE(mac, channel: EncryptedChannel(raw: b, authentication: authB, transport: .ble))
    let source = base.appendingPathComponent("source")
    try Data(repeating: 3, count: 1_000_000).write(to: source)
    let snapshot = try await aStore.snapshot(source, kind: .file, name: "cancel.bin", mime: "application/octet-stream", origin: mac)
    try await left.enqueue(snapshot, targets: [phone], userInitiated: true)
    try await Task.sleep(for: .milliseconds(10))
    await left.cancel(snapshot.manifest.id, peer: phone)
    try await Task.sleep(for: .milliseconds(10))
    #expect(!FileManager.default.fileExists(atPath: snapshot.url.path))
    #expect(await left.outgoingFiles().isEmpty)
    #expect(await left.connectedPeers().contains(phone))
    #expect(await right.connectedPeers().contains(mac))
    await left.stop(); await right.stop()
}

@Test func configurationReportsStayOnBluetoothAfterTCPUpgrade() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let mac = UUID(), phone = UUID(), key = Data(repeating: 4, count: 32), events = EventRecorder()
    let store = try TransferStore(root: root, downloads: root.appendingPathComponent("downloads"))
    let coordinator = SyncCoordinator(identity: mac, role: .mac, store: store) { await events.record($0) }
    let (a,b) = pair()
    async let aa = Handshake.authenticate(channel: a, role: .mac, identity: mac, key: key, transport: .ble)
    async let bb = Handshake.authenticate(channel: b, role: .android, identity: phone, key: key, transport: .ble)
    let (left,right) = try await (aa,bb)
    let remoteBLE = EncryptedChannel(raw: b, authentication: right, transport: .ble)
    try await coordinator.installBLE(phone, channel: EncryptedChannel(raw: a, authentication: left, transport: .ble))
    #expect(try await remoteBLE.receive().kind == .wifiPreference)
    try await remoteBLE.send(Record(.wifiPreference, metadata: Data("{\"enabled\":true,\"configuration\":true}".utf8)))
    let report = DeviceInformation(name: "Pad", kind: .pad, wifi: true, renameRequest: UUID())
    try await remoteBLE.send(Record(.deviceInformation, metadata: Wire.encodeJSON(report)))
    for _ in 0..<100 { if await events.information[phone] != nil { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await events.information[phone]?.name == "Pad")
    let offer = try await coordinator.offerTCP(phone, addresses: [TCPAddress(host: "192.0.2.1", port: 12345)])
    #expect(try await remoteBLE.receive().kind == .tcpOffer)
    let binding = try await coordinator.bindingKey(peer: phone, context: offer.id), (c,d) = pair()
    async let cc = Handshake.authenticate(channel: c, role: .mac, identity: mac, key: binding, context: offer.id, transport: .tcp)
    async let dd = Handshake.authenticate(channel: d, role: .android, identity: phone, key: binding, context: offer.id, transport: .tcp)
    let (tcpLeft,tcpRight) = try await (cc,dd)
    let remoteTCP = EncryptedChannel(raw: d, authentication: tcpRight, transport: .tcp)
    try await coordinator.installTCP(phone, channel: EncryptedChannel(raw: c, authentication: tcpLeft, transport: .tcp), context: offer.id)
    let value = ManagedConfiguration(revision: 1, mac: ManagedDevice(id: mac, name: "Mac", kind: .mac, wifi: true, priority: 0),
        device: nil, primary: phone, lockEnabled: false, lockDelaySeconds: 15)
    try await coordinator.sendConfiguration(value, to: phone)
    let update = try await remoteBLE.receive()
    #expect(update.kind == .configuration)
    #expect(try Wire.decodeJSON(ManagedConfiguration.self, update.metadata).revision == 1)
    let forbidden = DeviceInformation(name: "TCP must not rename", kind: .phone, wifi: true)
    try await remoteTCP.send(Record(.deviceInformation, metadata: Wire.encodeJSON(forbidden)))
    for _ in 0..<100 { if await !coordinator.usingTCP(phone) { break }; try await Task.sleep(for: .milliseconds(5)) }
    #expect(await !coordinator.usingTCP(phone))
    #expect(await events.wifiPreferences[phone] == true)
    #expect(await events.information[phone]?.name == "Pad")
    await coordinator.stop(); await remoteBLE.close(); await remoteTCP.close()
}

private final class PacketCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var outbound = 0, inbound = 0
    func packet(_ sending: Bool) { lock.withLock { if sending { outbound += 1 } else { inbound += 1 } } }
    var counts: (Int,Int) { lock.withLock { (outbound,inbound) } }
}

@Test func trafficObservesLogicalHandshakeMessagesAndSkipsBulkRecords() async throws {
    let (a,b) = pair(), mac = UUID(), phone = UUID(), key = Data(repeating: 4, count: 32)
    let macEvents = PacketCounter(), phoneEvents = PacketCounter()
    async let aa = Handshake.authenticate(channel: a, role: .mac, identity: mac, key: key, transport: .ble, traffic: { macEvents.packet($0) })
    async let bb = Handshake.authenticate(channel: b, role: .android, identity: phone, key: key, transport: .ble, traffic: { phoneEvents.packet($0) })
    let (left,right) = try await (aa,bb)
    #expect(macEvents.counts == (3,3) && phoneEvents.counts == (3,3))
    let tx = PacketCounter(), rx = PacketCounter()
    let first = EncryptedChannel(raw: a, authentication: left, transport: .ble, traffic: { tx.packet($0) })
    let second = EncryptedChannel(raw: b, authentication: right, transport: .ble, traffic: { rx.packet($0) })
    for kind in [RecordKind.data, .acknowledge, .begin, .resume, .finish] {
        try await first.send(Record(kind, bytes: kind == .data ? Data([1]) : Data()))
        #expect(try await second.receive().kind == kind)
    }
    #expect(tx.counts == (0,0) && rx.counts == (0,0))
    try await first.send(Record(.wifiPreference, metadata: Data("{\"enabled\":true}".utf8)))
    #expect(try await second.receive().kind == .wifiPreference)
    #expect(tx.counts == (1,0) && rx.counts == (0,1))
    await first.close(); await second.close()
}

@Test(arguments: [TransportKind.ble, .tcp])
func boundedDuplexFilesCompleteWithOriginalBytes(_ transport: TransportKind) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let mac = UUID(), phone = UUID(), events = EventRecorder()
    let leftStore = try TransferStore(root: base.appendingPathComponent("a"), downloads: base.appendingPathComponent("a-downloads"))
    let rightStore = try TransferStore(root: base.appendingPathComponent("b"), downloads: base.appendingPathComponent("b-downloads"))
    let left = SyncCoordinator(identity: mac, role: .mac, store: leftStore) { await events.record($0) }
    let right = SyncCoordinator(identity: phone, role: .android, store: rightStore) { await events.record($0) }
    let (a,b) = MemoryByteChannel.pair()
    var channels = [a,b]
    do {
        let key = Data(repeating: 11, count: 32)
        async let aa = Handshake.authenticate(channel: a, role: .mac, identity: mac, key: key, transport: .ble)
        async let bb = Handshake.authenticate(channel: b, role: .android, identity: phone, key: key, transport: .ble)
        let (authA,authB) = try await (aa,bb)
        try await left.installBLE(phone, channel: EncryptedChannel(raw: a, authentication: authA, transport: .ble))
        try await right.installBLE(mac, channel: EncryptedChannel(raw: b, authentication: authB, transport: .ble))
        if transport == .tcp {
            let offer = try await left.offerTCP(phone, addresses: [TCPAddress(host: "192.0.2.1", port: 12345)])
            for _ in 0..<100 {
                if (try? await right.bindingKey(peer: mac, context: offer.id)) != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let binding = try await left.bindingKey(peer: phone, context: offer.id), (c,d) = MemoryByteChannel.pair()
            channels += [c,d]
            async let cc = Handshake.authenticate(channel: c, role: .mac, identity: mac, key: binding, context: offer.id, transport: .tcp)
            async let dd = Handshake.authenticate(channel: d, role: .android, identity: phone, key: binding, context: offer.id, transport: .tcp)
            let (authC,authD) = try await (cc,dd)
            try await left.installTCP(phone, channel: EncryptedChannel(raw: c, authentication: authC, transport: .tcp), context: offer.id)
            try await right.installTCP(mac, channel: EncryptedChannel(raw: d, authentication: authD, transport: .tcp), context: offer.id)
        }
        let bytes = Data(repeating: 73, count: 8 * 1024 * 1024)
        let source = base.appendingPathComponent("source.bin"); try bytes.write(to: source)
        let one = try await leftStore.snapshot(source, kind: .file, name: "one.bin", mime: "application/octet-stream", origin: mac)
        let two = try await rightStore.snapshot(source, kind: .file, name: "two.bin", mime: "application/octet-stream", origin: phone)
        async let first: Void = left.enqueue(one, targets: [phone], userInitiated: true)
        async let second: Void = right.enqueue(two, targets: [mac], userInitiated: true)
        _ = try await (first,second)
        for _ in 0..<1000 { if await events.complete.count == 2 { break }; try await Task.sleep(for: .milliseconds(5)) }
        #expect(await events.complete.count == 2)
        #expect(await events.errors.isEmpty)
        for id in [one.manifest.id, two.manifest.id] {
            let url = try #require(await events.received[id])
            #expect(try Data(contentsOf: url) == bytes)
        }
        #expect(await left.outgoingFiles().isEmpty)
        #expect(await right.outgoingFiles().isEmpty)
    } catch {
        for channel in channels { await channel.close() }
        await left.disconnect(phone); await right.disconnect(mac)
        await leftStore.closeHandles(); await rightStore.closeHandles()
        throw error
    }
    for channel in channels { await channel.close() }
    await left.disconnect(phone); await right.disconnect(mac)
    await leftStore.closeHandles(); await rightStore.closeHandles()
}

@Test func disconnectReleasesUnacknowledgedClipboardSnapshot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try TransferStore(root: root, downloads: root.appendingPathComponent("downloads"))
    let mac = UUID(), peer = UUID(), key = Data(repeating: 3, count: 32)
    let coordinator = SyncCoordinator(identity: mac, role: .mac, store: store) { _ in }
    let (a,b) = MemoryByteChannel.pair()
    async let aa = Handshake.authenticate(channel: a, role: .mac, identity: mac, key: key, transport: .ble)
    async let bb = Handshake.authenticate(channel: b, role: .android, identity: peer, key: key, transport: .ble)
    let (auth,_) = try await (aa,bb)
    try await coordinator.installBLE(peer, channel: EncryptedChannel(raw: a, authentication: auth, transport: .ble))
    let snapshot = try await store.snapshotText("original clipboard bytes", origin: mac)
    try await coordinator.enqueue(snapshot, targets: [peer], userInitiated: false)
    await coordinator.disconnect(peer)
    for _ in 0..<100 { if !FileManager.default.fileExists(atPath: snapshot.url.path) { break }; await Task.yield() }
    #expect(!FileManager.default.fileExists(atPath: snapshot.url.path))
    await a.close(); await b.close(); await store.closeHandles()
}
