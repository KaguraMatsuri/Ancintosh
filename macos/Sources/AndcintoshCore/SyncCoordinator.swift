import Foundation

public enum SyncEvent: Sendable {
    case connected(UUID), disconnected(UUID, intentional: Bool)
    case received(UUID, TransferManifest, URL)
    case progress(UUID, UUID, UInt64, UInt64)
    case failed(UUID, UUID, ProtocolFailure)
    case tcpOffer(UUID, TCPOffer, Data)
    case wifiChanged(UUID, Bool)
    case completed(UUID, UUID)
    case transportChanged(UUID, TransportKind?)
}

private struct Preference: Codable { let enabled: Bool }
private struct Acknowledgement: Codable { let complete: Bool }
private struct FailureMessage: Codable { let code: ProtocolFailure }
private struct SwitchMessage: Codable { let transport: TransportKind }
private struct PeerChannels {
    let ble: EncryptedChannel
    let generation: UUID
    var tcp: EncryptedChannel?
    var tcpGeneration: UUID?
    var route = TransportCoordinator()
    var offer: TCPOffer?
    var epoch = Wire.zeroID
    var switching = false
}

public actor SyncCoordinator {
    public let identity: UUID
    public let role: PeerRole
    private let store: TransferStore
    private let events: @Sendable (SyncEvent) async throws -> Void
    private var peers: [UUID: PeerChannels] = [:]
    private var scheduler = TransferScheduler()
    private var pumps: [UUID: Task<Void, Never>] = [:]
    private var collectionTask: Task<Void, Never>?
    private var localWifi = true
    private var currentClipboard: URL?
    private var activeSources: [UUID: URL] = [:]
    private var activeJobs: [UUID: UUID] = [:]
    private var activeCancelled: Set<UUID> = []
    private var lastProgress: [UUID: ContinuousClock.Instant] = [:]

    public init(identity: UUID, role: PeerRole, store: TransferStore,
                events: @escaping @Sendable (SyncEvent) async throws -> Void) {
        self.identity = identity; self.role = role; self.store = store; self.events = events
    }

    public func restore() async throws {
        for job in try await store.restoreOutgoing() { scheduler.enqueue(job) }
    }

    public func connectedPeers() -> Set<UUID> { Set(peers.keys) }
    public func outgoingFiles() -> [OutboundJob] { scheduler.jobs.filter { $0.manifest.kind == .file } }
    public func usingTCP(_ peer: UUID) -> Bool { peers[peer]?.tcp != nil }
    public func bleRoot(_ peer: UUID) -> Data? { peers[peer]?.ble.root }
    public func permitsWifi(_ peer: UUID) -> Bool {
        guard let entry = peers[peer] else { return false }
        return localWifi && entry.route.remoteWifi
    }

    public func installBLE(_ peer: UUID, channel: EncryptedChannel) async throws {
        if let previous = peers.removeValue(forKey: peer) { await previous.ble.close(); await previous.tcp?.close() }
        var entry = PeerChannels(ble: channel, generation: UUID())
        var epochReader = BinaryReader(Data(channel.root.prefix(16)))
        entry.epoch = try epochReader.uuid()
        entry.route.authenticated(true)
        entry.route.preference(local: localWifi)
        peers[peer] = entry
        await store.selectEpoch(peer: peer, epoch: entry.epoch)
        await channel.setDataEpoch(entry.epoch)
        scheduler.reconnect(peer)
        let generation = entry.generation
        Task { await self.readLoop(peer, channel: channel, generation: generation, tcp: false) }
        try await channel.send(Record(.wifiPreference, metadata: Wire.encodeJSON(Preference(enabled: localWifi))))
        try await events(.connected(peer))
        schedulePump()
    }

    public func offerTCP(_ peer: UUID, addresses: [TCPAddress]) async throws -> TCPOffer {
        guard role == .mac, permitsWifi(peer), var entry = peers[peer], addresses.count <= 8, !addresses.isEmpty else {
            throw ProtocolFailure.peerUnavailable
        }
        let offer = TCPOffer(addresses: addresses, secret: try Crypto.random(32))
        entry.offer = offer
        peers[peer] = entry
        try await entry.ble.send(Record(.tcpOffer, metadata: Wire.encodeJSON(offer)))
        return offer
    }

    public func bindingKey(peer: UUID, context: UUID) throws -> Data {
        guard permitsWifi(peer), let entry = peers[peer], let offer = entry.offer,
              offer.id == context, let secret = Data(hex: offer.secret), secret.count == 32 else {
            throw ProtocolFailure.authenticationFailed
        }
        return Crypto.derive(entry.ble.root, salt: secret, info: "Andcintosh/v2/tcp-binding")
    }

    public func installTCP(_ peer: UUID, channel: EncryptedChannel, context: UUID) async throws {
        guard var entry = peers[peer], permitsWifi(peer), entry.offer?.id == context else {
            await channel.close(); throw ProtocolFailure.authenticationFailed
        }
        let previous = entry.tcp
        entry.tcp = nil; entry.tcpGeneration = nil
        peers[peer] = entry
        await previous?.close()
        guard let current = peers[peer], current.generation == entry.generation, permitsWifi(peer), current.offer?.id == context else {
            await channel.close(); throw ProtocolFailure.peerUnavailable
        }
        entry = current
        entry.tcp = channel
        entry.tcpGeneration = UUID()
        entry.epoch = context
        entry.switching = true
        try entry.route.activateTCP()
        peers[peer] = entry
        await entry.ble.setDataEpoch(nil)
        await channel.setDataEpoch(entry.epoch)
        try await events(.transportChanged(peer, nil))
        await store.selectEpoch(peer: peer, epoch: entry.epoch)
        guard var current = peers[peer], current.epoch == context, current.tcp === channel else {
            await channel.close(); throw ProtocolFailure.peerUnavailable
        }
        current.switching = false
        peers[peer] = current
        if !permitsWifi(peer) { await fallback(peer); throw ProtocolFailure.peerUnavailable }
        try await events(.transportChanged(peer, .tcp))
        scheduler.channelChanged(peer)
        let generation = entry.tcpGeneration!
        Task { await self.readLoop(peer, channel: channel, generation: generation, tcp: true) }
        schedulePump()
    }

    public func wifi(_ enabled: Bool) async {
        localWifi = enabled
        for id in Array(peers.keys) {
            guard var entry = peers[id] else { continue }
            entry.route.preference(local: enabled)
            peers[id] = entry
            if !enabled { await fallback(id) }
            try? await entry.ble.send(Record(.wifiPreference, metadata: Wire.encodeJSON(Preference(enabled: enabled))))
        }
        schedulePump()
    }

    public func stop(_ peer: UUID? = nil) async {
        for id in peer.map({ [$0] }) ?? Array(peers.keys) {
            if let entry = peers[id] { try? await entry.ble.send(Record(.goodbye)) }
            await disconnect(id, intentional: true)
        }
    }

    public func disconnect(_ peer: UUID, intentional: Bool = false) async {
        guard let entry = peers.removeValue(forKey: peer) else { return }
        pumps[peer]?.cancel()
        try? await store.checkpoint(peer)
        await entry.ble.close(); await entry.tcp?.close()
        if peers.isEmpty { await store.closeHandles() }
        scheduler.reconnect(peer)
        try? await store.persistOutgoing(scheduler.jobs)
        try? await events(.disconnected(peer, intentional: intentional))
    }

    public func enqueue(_ snapshot: Snapshot, targets: [UUID], userInitiated: Bool) async throws {
        let previous = Set(scheduler.jobs.map(\.snapshot))
        for peer in targets {
            scheduler.enqueue(OutboundJob(peer: peer, manifest: snapshot.manifest, snapshot: snapshot.url, userInitiated: userInitiated))
        }
        try await store.persistOutgoing(scheduler.jobs)
        let retained = Set(scheduler.jobs.map(\.snapshot))
        for url in previous.subtracting(retained) where url.path.contains("/outgoing/") { await store.release(url) }
        schedulePump()
    }

    public func cancel(_ id: UUID, peer: UUID) async {
        let cancelsActive = activeJobs[peer] == id
        if cancelsActive { activeCancelled.insert(peer) }
        let previous = scheduler.jobs.first(where: { $0.peer == peer && $0.manifest.id == id })?.snapshot ?? (cancelsActive ? activeSources[peer] : nil)
        scheduler.remove(id, peer: peer)
        try? await store.persistOutgoing(scheduler.jobs)
        if let channel = dataChannel(peer), let epoch = peers[peer]?.epoch {
            await channel.discardBuffered(id)
            try? await channel.send(Record(.cancel, transferID: id, epoch: epoch))
        }
        await store.cancel(peer: peer, id: id)
        if let previous, !scheduler.jobs.contains(where: { $0.snapshot == previous }), previous.path.contains("/outgoing/") { await store.release(previous) }
        schedulePump()
    }

    public func retry(_ id: UUID, peer: UUID) async throws {
        scheduler.fail(id, peer: peer, error: nil)
        try await store.persistOutgoing(scheduler.jobs)
        schedulePump()
    }

    private func dataChannel(_ peer: UUID) -> EncryptedChannel? { peers[peer]?.tcp ?? peers[peer]?.ble }

    private func readLoop(_ peer: UUID, channel: EncryptedChannel, generation: UUID, tcp: Bool) async {
        do {
            while true {
                let record = try await channel.receive()
                guard let entry = peers[peer], (tcp ? entry.tcpGeneration : entry.generation) == generation else { return }
                try await receive(record, from: peer, channel: channel, tcp: tcp)
            }
        } catch {
            guard let entry = peers[peer], (tcp ? entry.tcpGeneration : entry.generation) == generation else { return }
            if tcp {
                await fallback(peer)
                try? await events(.wifiChanged(peer, false))
                schedulePump()
            } else { await disconnect(peer) }
        }
    }

    private func receive(_ record: Record, from peer: UUID, channel: EncryptedChannel, tcp: Bool) async throws {
        let isTransfer = [.begin, .data, .finish, .acknowledge, .resume, .cancel, .failure].contains(record.kind)
        if isTransfer && (peers[peer]?.switching != false || record.epoch != peers[peer]?.epoch || channel !== dataChannel(peer)) { return }
        do {
            switch record.kind {
            case .begin:
                let manifest = try Wire.decodeJSON(TransferManifest.self, record.metadata)
                guard manifest.id == record.transferID else { throw ProtocolFailure.invalidManifest }
                let offset = try await store.begin(manifest, peer: peer, epoch: record.epoch)
                try await channel.send(Record(.resume, transferID: manifest.id, offset: offset, epoch: record.epoch))
            case .data:
                if let durable = try await store.append(peer: peer, id: record.transferID, offset: record.offset, bytes: record.bytes, epoch: record.epoch) {
                    try await channel.send(Record(.acknowledge, transferID: record.transferID, offset: durable,
                                                  metadata: Wire.encodeJSON(Acknowledgement(complete: false)), epoch: record.epoch))
                }
            case .finish:
                let (manifest, url, new) = try await store.finish(peer: peer, id: record.transferID, epoch: record.epoch)
                if new {
                    try await events(.received(peer, manifest, url))
                    try await store.delivered(peer: peer, id: manifest.id)
                    if manifest.kind != .file { currentClipboard = url }
                    if role == .mac && manifest.kind != .file {
                        scheduler.jobs.filter { $0.manifest.kind != .file }.forEach { scheduler.remove($0.manifest.id, peer: $0.peer) }
                        let snapshot = Snapshot(manifest: manifest, url: url)
                        for target in peers.keys where target != peer {
                            scheduler.enqueue(OutboundJob(peer: target, manifest: manifest, snapshot: snapshot.url, userInitiated: true))
                        }
                    }
                }
                try await channel.send(Record(.acknowledge, transferID: manifest.id, offset: manifest.size,
                                              metadata: Wire.encodeJSON(Acknowledgement(complete: true)), epoch: record.epoch))
            case .resume:
                try scheduler.resume(record.transferID, peer: peer, offset: record.offset)
            case .acknowledge:
                let acknowledgement = try Wire.decodeJSON(Acknowledgement.self, record.metadata)
                if acknowledgement.complete {
                    if let job = scheduler.jobs.first(where: { $0.peer == peer && $0.manifest.id == record.transferID }) {
                        guard record.offset == job.manifest.size else { throw ProtocolFailure.invalidOffset }
                        scheduler.remove(record.transferID, peer: peer)
                        try await store.persistOutgoing(scheduler.jobs)
                        if !scheduler.jobs.contains(where: { $0.snapshot == job.snapshot }) && job.snapshot.path.contains("/outgoing/") {
                            await store.release(job.snapshot)
                        }
                        try await events(.completed(peer, record.transferID))
                        await collectClipboard()
                    }
                }
            case .cancel:
                if activeJobs[peer] == record.transferID { activeCancelled.insert(peer) }
                scheduler.remove(record.transferID, peer: peer)
                await store.cancel(peer: peer, id: record.transferID)
                try await store.persistOutgoing(scheduler.jobs)
            case .wifiPreference:
                guard !tcp, var entry = peers[peer] else { throw ProtocolFailure.invalidFrame }
                let preference = try Wire.decodeJSON(Preference.self, record.metadata)
                entry.route.preference(remote: preference.enabled)
                peers[peer] = entry
                if !preference.enabled { await fallback(peer) }
                try await events(.wifiChanged(peer, preference.enabled))
            case .tcpOffer:
                guard role == .android, !tcp, var entry = peers[peer], permitsWifi(peer) else { throw ProtocolFailure.invalidFrame }
                let offer = try Wire.decodeJSON(TCPOffer.self, record.metadata)
                guard offer.addresses.count <= 8, !offer.addresses.isEmpty,
                      let secret = Data(hex: offer.secret), secret.count == 32 else { throw ProtocolFailure.invalidFrame }
                entry.offer = offer
                peers[peer] = entry
                let binding = Crypto.derive(entry.ble.root, salt: secret, info: "Andcintosh/v2/tcp-binding")
                try await events(.tcpOffer(peer, offer, binding))
            case .goodbye:
                guard !tcp else { throw ProtocolFailure.invalidFrame }
                await disconnect(peer, intentional: true)
            case .transportSwitch:
                guard !tcp, try Wire.decodeJSON(SwitchMessage.self, record.metadata).transport == .ble else { throw ProtocolFailure.invalidFrame }
                if role == .mac {
                    guard record.epoch == Wire.zeroID else { throw ProtocolFailure.invalidFrame }
                    await fallback(peer)
                } else {
                    guard record.epoch != Wire.zeroID, var entry = peers[peer] else { throw ProtocolFailure.invalidFrame }
                    if record.epoch == entry.epoch && entry.tcp == nil && !entry.switching { return }
                    let old = entry.tcp
                    entry.tcp = nil; entry.tcpGeneration = nil; entry.offer = nil
                    entry.epoch = record.epoch; entry.route.tcpLost(); entry.switching = true
                    peers[peer] = entry
                    await store.selectEpoch(peer: peer, epoch: entry.epoch)
                    await entry.ble.setDataEpoch(entry.epoch)
                    try await store.checkpoint(peer)
                    scheduler.channelChanged(peer)
                    await old?.close()
                    if var current = peers[peer], current.epoch == record.epoch {
                        current.switching = false; peers[peer] = current
                    }
                }
            case .failure:
                let failure = try Wire.decodeJSON(FailureMessage.self, record.metadata)
                scheduler.fail(record.transferID, peer: peer, error: failure.code)
                try await store.persistOutgoing(scheduler.jobs)
                try await events(.failed(peer, record.transferID, failure.code))
            }
        } catch let failure as ProtocolFailure {
            if isTransfer && record.epoch != peers[peer]?.epoch { return }
            if [.begin, .data, .finish, .resume].contains(record.kind) {
                try await channel.send(Record(.failure, transferID: record.transferID, metadata: Wire.encodeJSON(FailureMessage(code: failure)), epoch: record.epoch))
                try await events(.failed(peer, record.transferID, failure))
            } else { throw failure }
        } catch {
            if [.begin, .data, .finish].contains(record.kind) {
                let native = error as NSError
                let failure: ProtocolFailure = native.code == ENOSPC || native.code == NSFileWriteOutOfSpaceError ? .insufficientSpace : .sourceUnavailable
                try await channel.send(Record(.failure, transferID: record.transferID, metadata: Wire.encodeJSON(FailureMessage(code: failure)), epoch: record.epoch))
                try await events(.failed(peer, record.transferID, failure))
            } else { throw error }
        }
        schedulePump()
    }

    private func schedulePump() {
        let available = Set(peers.filter { !$0.value.switching }.keys)
        let filePeer = scheduler.firstFilePeer(available: available)
        var seen: Set<UUID> = []
        for peer in scheduler.jobs.map(\.peer) where seen.insert(peer).inserted {
            guard available.contains(peer), pumps[peer] == nil,
                  scheduler.ready(available: [peer], includeFiles: filePeer == peer) else { continue }
            pumps[peer] = Task { await self.pump(peer) }
        }
    }

    private func collectClipboard() async {
        var retained = Set(scheduler.jobs.map(\.snapshot))
        if let currentClipboard { retained.insert(currentClipboard) }
        retained.formUnion(activeSources.values)
        await store.collectClipboard(keeping: retained)
    }

    private func fallback(_ peer: UUID) async {
        guard var entry = peers[peer] else { return }
        if entry.switching { return }
        let old = entry.tcp
        let changing = old != nil || entry.offer != nil
        if !changing {
            if role == .mac {
                try? await entry.ble.send(Record(.transportSwitch, metadata: Wire.encodeJSON(SwitchMessage(transport: .ble)), epoch: entry.epoch))
            }
            return
        }
        if role == .mac { entry.epoch = UUID() }
        entry.switching = true
        entry.tcp = nil; entry.tcpGeneration = nil; entry.offer = nil; entry.route.tcpLost()
        peers[peer] = entry
        try? await events(.transportChanged(peer, nil))
        try? await store.checkpoint(peer)
        await old?.close()
        if role == .mac {
            await store.selectEpoch(peer: peer, epoch: entry.epoch)
            await entry.ble.setDataEpoch(entry.epoch)
            scheduler.channelChanged(peer)
            try? await entry.ble.send(Record(.transportSwitch, metadata: Wire.encodeJSON(SwitchMessage(transport: .ble)), epoch: entry.epoch))
            if var current = peers[peer], current.epoch == entry.epoch {
                current.switching = false; peers[peer] = current
                try? await events(.transportChanged(peer, .ble))
            }
        } else {
            try? await entry.ble.send(Record(.transportSwitch, metadata: Wire.encodeJSON(SwitchMessage(transport: .ble))))
        }
    }

    private func dataRecord(_ job: OutboundJob, bytes: Data, channel: EncryptedChannel, epoch: UUID) throws -> Record {
        guard !activeCancelled.contains(job.peer) else { throw ProtocolFailure.cancelled }
        guard epoch == peers[job.peer]?.epoch, channel === dataChannel(job.peer), peers[job.peer]?.switching == false else { throw ProtocolFailure.peerUnavailable }
        guard !bytes.isEmpty else { throw ProtocolFailure.sourceUnavailable }
        return Record(.data, transferID: job.manifest.id, offset: job.offset, bytes: bytes, epoch: epoch)
    }

    private func pump(_ peer: UUID) async {
        defer {
            pumps.removeValue(forKey: peer)
            activeSources.removeValue(forKey: peer); activeJobs.removeValue(forKey: peer)
            activeCancelled.remove(peer)
            if collectionTask == nil {
                collectionTask = Task {
                    await self.collectClipboard()
                    self.collectionTask = nil
                    self.schedulePump()
                }
            }
        }
        while !Task.isCancelled, peers[peer]?.switching == false,
              var job = scheduler.next(available: [peer], includeFiles: scheduler.firstFilePeer(available: Set(peers.keys)) == peer) {
            activeJobs[peer] = job.manifest.id; activeCancelled.remove(peer)
            activeSources[peer] = job.snapshot
            guard let channel = dataChannel(job.peer) else { scheduler.requeue(job); return }
            guard let epoch = peers[job.peer]?.epoch else { scheduler.requeue(job); return }
            do {
                if !job.begun {
                    job.begun = true; job.waitingForResume = true
                    scheduler.requeue(job)
                    try await channel.send(Record(.begin, transferID: job.manifest.id, metadata: Wire.encodeJSON(job.manifest), epoch: epoch))
                } else if job.offset < job.manifest.size {
                    let count = channel.transport == .tcp ? Wire.tcpChunkSize : Wire.bleChunkSize
                    let pending = job
                    scheduler.requeue(job)
                    let sent = try await channel.sendBuffered { [self] in
                        let bytes: Data
                        do { bytes = try await store.read(pending.snapshot, offset: pending.offset, count: min(count, Int(pending.manifest.size - pending.offset))) }
                        catch { throw ProtocolFailure.sourceUnavailable }
                        return try await self.dataRecord(pending, bytes: bytes, channel: channel, epoch: epoch)
                    }
                    if activeCancelled.contains(peer) { continue }
                    if epoch != peers[peer]?.epoch || channel !== dataChannel(peer) { continue }
                    scheduler.remove(job.manifest.id, peer: peer)
                    job.offset += UInt64(sent)
                    scheduler.requeue(job)
                    let now = ContinuousClock.now
                    if job.offset == job.manifest.size || lastProgress[job.manifest.id].map({ $0.duration(to: now) >= .milliseconds(200) }) ?? true {
                        lastProgress[job.manifest.id] = now
                        try await events(.progress(job.peer, job.manifest.id, job.offset, job.manifest.size))
                    }
                } else {
                    job.finished = true
                    scheduler.requeue(job)
                    try await channel.send(Record(.finish, transferID: job.manifest.id, offset: job.offset, epoch: epoch))
                }
            } catch {
                if activeCancelled.contains(peer) { continue }
                if error is ProtocolFailure && (error as? ProtocolFailure) == .sourceUnavailable {
                    scheduler.remove(job.manifest.id, peer: job.peer)
                    if job.manifest.kind == .file {
                        job.failure = .sourceUnavailable; job.begun = false; job.waitingForResume = false; job.finished = false
                        scheduler.requeue(job)
                        try? await store.persistOutgoing(scheduler.jobs)
                    }
                    try? await events(.failed(job.peer, job.manifest.id, .sourceUnavailable))
                } else {
                    scheduler.channelChanged(job.peer)
                    if channel === dataChannel(job.peer) {
                        if channel.transport == .tcp { await fallback(job.peer) }
                        else { await disconnect(job.peer) }
                    }
                    return
                }
            }
        }
    }
}
