import CryptoKit
import Darwin
import Foundation

public struct Snapshot: Sendable {
    public let manifest: TransferManifest
    public let url: URL
}

private struct IncomingJournal: Codable {
    var manifest: TransferManifest
    var peer: UUID
    var durable: UInt64
    var complete: Bool
    var delivered: Bool
    var output: String?
}

private struct Incoming {
    var journal: IncomingJournal
    var handle: FileHandle?
    var written: UInt64
    var generation = UUID()
}

public actor TransferStore {
    public let root: URL
    private let downloads: URL
    private var incoming: [String: Incoming] = [:]
    private var readers: [URL: FileHandle] = [:]
    private var epochs: [UUID: UUID] = [:]
    private var verifications: [String: VerificationLease] = [:]
    private let checkpointBytes: UInt64 = 4 * 1_024 * 1_024

    public init(root: URL, downloads: URL) throws {
        self.root = root
        self.downloads = downloads
        for directory in [root, root.appendingPathComponent("outgoing"), root.appendingPathComponent("incoming"), root.appendingPathComponent("clipboard")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    public nonisolated func snapshot(_ source: URL, kind: PayloadKind, name: String, mime: String, origin: UUID) async throws -> Snapshot {
        let task = Task.detached(priority: .utility) { try self.copySnapshot(source, kind: kind, name: name, mime: mime, origin: origin) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }

    private nonisolated func copySnapshot(_ source: URL, kind: PayloadKind, name: String, mime: String, origin: UUID) throws -> Snapshot {
        let id = UUID()
        let destination = root.appendingPathComponent("outgoing/\(id.uuidString).blob")
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: destination)
        var success = false
        defer { try? output.close(); if !success { try? FileManager.default.removeItem(at: destination) } }
        var digest = SHA256()
        var count: UInt64 = 0
        while true {
            let read = try autoreleasepool {
                try Task.checkCancellation()
                guard let bytes = try input.read(upToCount: 65_536), !bytes.isEmpty else { return 0 }
                try output.write(contentsOf: bytes)
                digest.update(data: bytes)
                return bytes.count
            }
            if read == 0 { break }
            count += UInt64(read)
        }
        try output.synchronize()
        let manifest = try TransferManifest(id: id, kind: kind, name: name, mime: mime, size: count,
                                            sha256: Data(digest.finalize()).hex, origin: origin)
        success = true
        return Snapshot(manifest: manifest, url: destination)
    }

    public func snapshotText(_ text: String, origin: UUID) throws -> Snapshot {
        let id = UUID()
        let data = Data(text.utf8)
        let url = root.appendingPathComponent("outgoing/\(id.uuidString).blob")
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let manifest = try TransferManifest(id: id, kind: .text, name: id.uuidString, mime: "text/plain;charset=utf-8",
                                            size: UInt64(data.count), sha256: Crypto.digest(data), origin: origin)
        return Snapshot(manifest: manifest, url: url)
    }

    public func read(_ snapshot: URL, offset: UInt64, count: Int) throws -> Data {
        let handle: FileHandle
        if let existing = readers[snapshot] { handle = existing }
        else { handle = try FileHandle(forReadingFrom: snapshot); readers[snapshot] = handle }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    public func release(_ snapshot: URL) {
        try? readers.removeValue(forKey: snapshot)?.close()
        try? FileManager.default.removeItem(at: snapshot)
    }

    public func closeHandles() {
        for handle in readers.values { try? handle.close() }
        readers.removeAll()
        for key in Array(incoming.keys) {
            verifications[key]?.cancel()
            try? incoming[key]?.handle?.close(); incoming[key]?.handle = nil
        }
    }

    public func collectClipboard(keeping: Set<URL>) {
        let directory = root.appendingPathComponent("clipboard")
        for url in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where !keeping.contains(url) {
            try? readers.removeValue(forKey: url)?.close()
            try? FileManager.default.removeItem(at: url)
        }
    }

    public func persistOutgoing(_ jobs: [OutboundJob]) throws {
        try Wire.encodeJSON(jobs.filter { $0.manifest.kind == .file }).write(to: root.appendingPathComponent("outgoing.json"), options: .atomic)
    }

    public func restoreOutgoing() throws -> [OutboundJob] {
        let url = root.appendingPathComponent("outgoing.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try Wire.decodeJSON([OutboundJob].self, Data(contentsOf: url)).compactMap { job in
            guard job.manifest.kind == .file, job.snapshot.deletingLastPathComponent().standardizedFileURL == root.appendingPathComponent("outgoing").standardizedFileURL,
                  FileManager.default.fileExists(atPath: job.snapshot.path) else { return nil }
            var job = job
            job.begun = false; job.waitingForResume = false; job.finished = false
            return job
        }
    }

    public func selectEpoch(peer: UUID, epoch: UUID) {
        if epochs[peer] != epoch {
            for (key, item) in incoming where item.journal.peer == peer { verifications[key]?.cancel() }
        }
        epochs[peer] = epoch
    }

    public func begin(_ manifest: TransferManifest, peer: UUID, epoch: UUID? = nil) throws -> UInt64 {
        if let epoch, epochs[peer] != epoch { throw ProtocolFailure.invalidOffset }
        try manifest.validate()
        let key = identity(peer, manifest.id)
        verifications.removeValue(forKey: key)?.cancel()
        if var current = incoming[key] {
            guard current.journal.manifest == manifest else { throw ProtocolFailure.invalidManifest }
            if current.journal.complete { return manifest.size }
            current.generation = UUID()
            if current.handle == nil { current.handle = try FileHandle(forUpdating: root.appendingPathComponent("incoming/\(key)/data.part")) }
            try current.handle?.truncate(atOffset: current.journal.durable)
            try current.handle?.seek(toOffset: current.journal.durable)
            current.written = current.journal.durable
            incoming[key] = current
            return current.written
        }
        let directory = root.appendingPathComponent("incoming/\(key)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let journalURL = directory.appendingPathComponent("state.json")
        var journal = IncomingJournal(manifest: manifest, peer: peer, durable: 0, complete: false, delivered: false, output: nil)
        if FileManager.default.fileExists(atPath: journalURL.path) {
            journal = try Wire.decodeJSON(IncomingJournal.self, Data(contentsOf: journalURL))
            guard journal.manifest == manifest && journal.peer == peer else { throw ProtocolFailure.invalidManifest }
        }
        if journal.complete {
            incoming[key] = Incoming(journal: journal, handle: nil, written: manifest.size)
            return manifest.size
        }
        let file = directory.appendingPathComponent("data.part")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard journal.durable == 0 else { throw ProtocolFailure.invalidOffset }
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forUpdating: file)
        guard try handle.seekToEnd() >= journal.durable else { try? handle.close(); throw ProtocolFailure.invalidOffset }
        try handle.truncate(atOffset: journal.durable)
        try handle.seek(toOffset: journal.durable)
        incoming[key] = Incoming(journal: journal, handle: handle, written: journal.durable)
        try save(journal, at: journalURL)
        return journal.durable
    }

    public func append(peer: UUID, id: UUID, offset: UInt64, bytes: Data, epoch: UUID? = nil) throws -> UInt64? {
        if let epoch, epochs[peer] != epoch { throw ProtocolFailure.invalidOffset }
        let key = identity(peer, id)
        guard var item = incoming[key], !item.journal.complete, let handle = item.handle else { throw ProtocolFailure.invalidOffset }
        guard offset == item.written, UInt64(bytes.count) <= item.journal.manifest.size - item.written else { throw ProtocolFailure.invalidOffset }
        try handle.write(contentsOf: bytes)
        item.written += UInt64(bytes.count)
        let checkpoint = item.written - item.journal.durable >= checkpointBytes
        if checkpoint {
            try handle.synchronize()
            item.journal.durable = item.written
            try save(item.journal, at: journalURL(key))
        }
        incoming[key] = item
        return checkpoint ? item.journal.durable : nil
    }

    public func finish(peer: UUID, id: UUID, epoch: UUID? = nil) async throws -> (TransferManifest, URL, Bool) {
        if let epoch, epochs[peer] != epoch { throw ProtocolFailure.invalidOffset }
        let key = identity(peer, id)
        guard var item = incoming[key] else { throw ProtocolFailure.invalidOffset }
        if item.journal.complete, let output = item.journal.output {
            return (item.journal.manifest, URL(fileURLWithPath: output), !item.journal.delivered)
        }
        let manifest = item.journal.manifest
        guard item.written == manifest.size else { throw ProtocolFailure.invalidOffset }
        try item.handle?.synchronize()
        try item.handle?.close()
        item.handle = nil
        let source = root.appendingPathComponent("incoming/\(key)/data.part")
        incoming[key] = item
        let lease = VerificationLease()
        verifications.removeValue(forKey: key)?.cancel(); verifications[key] = lease
        defer { if verifications[key] === lease { verifications.removeValue(forKey: key) } }
        let staging = manifest.kind == .file ? downloads.appendingPathComponent(".\(id.uuidString).\(UUID().uuidString).part") : nil
        if staging != nil { try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true) }
        defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
        let verified: URL
        do { verified = try await VerificationWorker.prepare(source: source, staging: staging, sha256: manifest.sha256, lease: lease) }
        catch {
            if incoming[key]?.generation == item.generation, (error as? ProtocolFailure) == .digestMismatch { cancel(peer: peer, id: id) }
            throw error
        }
        try lease.check()
        guard incoming[key]?.generation == item.generation, epoch == nil || epochs[peer] == epoch else { throw ProtocolFailure.invalidOffset }
        let destination: URL
        if manifest.kind == .file { destination = try publish(verified, name: manifest.name, id: id) }
        else {
            destination = root.appendingPathComponent("clipboard/\(id.uuidString).blob")
            if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.moveItem(at: source, to: destination) }
        }
        item.journal.complete = true
        item.journal.durable = manifest.size
        item.journal.output = destination.path
        try save(item.journal, at: journalURL(key))
        incoming[key] = item
        if manifest.kind == .file { try? FileManager.default.removeItem(at: source) }
        return (manifest, destination, true)
    }

    public func cancel(peer: UUID, id: UUID) {
        let key = identity(peer, id)
        if let current = incoming[key], current.journal.complete { return }
        verifications.removeValue(forKey: key)?.cancel()
        try? incoming.removeValue(forKey: key)?.handle?.close()
        try? FileManager.default.removeItem(at: root.appendingPathComponent("incoming/\(key)"))
    }

    public func delivered(peer: UUID, id: UUID) throws {
        let key = identity(peer, id)
        guard var item = incoming[key], item.journal.complete else { throw ProtocolFailure.invalidOffset }
        item.journal.delivered = true
        try save(item.journal, at: journalURL(key))
        incoming[key] = item
    }

    public func checkpoint(_ peer: UUID) throws {
        for key in Array(incoming.keys) {
            guard var item = incoming[key], item.journal.peer == peer, !item.journal.complete else { continue }
            try item.handle?.synchronize()
            item.journal.durable = item.written
            try save(item.journal, at: journalURL(key))
            incoming[key] = item
        }
    }

    private func identity(_ peer: UUID, _ id: UUID) -> String { "\(peer.uuidString)/\(id.uuidString)" }
    private func journalURL(_ key: String) -> URL { root.appendingPathComponent("incoming/\(key)/state.json") }
    private func save(_ journal: IncomingJournal, at url: URL) throws { try Wire.encodeJSON(journal).write(to: url, options: .atomic) }

    private func publish(_ source: URL, name: String, id: UUID) throws -> URL {
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let hidden = source
        let ext = (name as NSString).pathExtension
        let stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        var index = 0
        while true {
            let candidate = index == 0 ? name : "\(stem) (\(index))\(ext.isEmpty ? "" : ".\(ext)")"
            let url = downloads.appendingPathComponent(candidate)
            if link(hidden.path, url.path) == 0 {
                try FileManager.default.removeItem(at: hidden)
                return url
            }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            index += 1
        }
    }
}
