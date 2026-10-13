import Foundation
import Testing
@testable import AndcintoshCore

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
    func record(_ event: SyncEvent) {
        switch event {
        case .completed(_, let id): complete.insert(id)
        case .received(_, let manifest, let file): received[manifest.id] = file
        case .transportChanged(let peer, let route): routes[peer] = route
        case .progress(_, _, let offset, _): sent = offset
        case .failed(_, _, let error): errors.append(error)
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
