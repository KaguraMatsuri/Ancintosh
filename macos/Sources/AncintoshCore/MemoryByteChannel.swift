#if DEBUG
import Foundation

private actor MemoryPipe {
    static let capacity = 128 * 1024
    private var buffer = Data()
    private var closed = false
    private struct Read { let id: UUID; let count: Int; let continuation: CheckedContinuation<Data, any Error> }
    private struct Write { let id: UUID; let bytes: Data; let continuation: CheckedContinuation<Void, any Error> }
    private var reader: Read?
    private var writers: [Write] = []

    func read(_ count: Int) async throws -> Data {
        guard !closed, count > 0, count <= Self.capacity, reader == nil else { throw ProtocolFailure.peerUnavailable }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                reader = Read(id: id, count: count, continuation: continuation); service()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func write(_ bytes: Data) async throws {
        guard !closed, !bytes.isEmpty, bytes.count <= Wire.maxPlaintext + 28 else { throw ProtocolFailure.peerUnavailable }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                writers.append(Write(id: id, bytes: bytes, continuation: continuation)); service()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func service() {
        while !closed {
            if let read = reader, buffer.count >= read.count {
                let bytes = Data(buffer.prefix(read.count)); buffer.removeFirst(read.count)
                reader = nil; read.continuation.resume(returning: bytes)
            } else if let write = writers.first, buffer.count + write.bytes.count <= Self.capacity {
                writers.removeFirst(); buffer.append(write.bytes); write.continuation.resume()
            } else { return }
        }
    }
    private func cancel(_ id: UUID) {
        if reader?.id == id { let read = reader; reader = nil; read?.continuation.resume(throwing: CancellationError()) }
        if let index = writers.firstIndex(where: { $0.id == id }) { writers.remove(at: index).continuation.resume(throwing: CancellationError()) }
    }
    func close() {
        closed = true; buffer.removeAll()
        reader?.continuation.resume(throwing: ProtocolFailure.peerUnavailable); reader = nil
        let pending = writers; writers.removeAll()
        for write in pending { write.continuation.resume(throwing: ProtocolFailure.peerUnavailable) }
    }
}

public actor MemoryByteChannel: ByteChannel {
    private let input: MemoryPipe
    private let output: MemoryPipe
    private let handshakeDelay: Duration
    private var writes = 0
    private init(input: MemoryPipe, output: MemoryPipe, handshakeDelay: Duration) {
        self.input = input; self.output = output; self.handshakeDelay = handshakeDelay
    }
    public static func pair(handshakeDelay: Duration = .zero) -> (MemoryByteChannel, MemoryByteChannel) {
        let a = MemoryPipe(), b = MemoryPipe()
        return (Self(input: a, output: b, handshakeDelay: handshakeDelay), Self(input: b, output: a, handshakeDelay: handshakeDelay))
    }
    public func readExactly(_ count: Int) async throws -> Data { try await input.read(count) }
    public func write(_ bytes: Data) async throws {
        let handshake = writes < 3; writes += 1
        if handshake && handshakeDelay != .zero { try await Task.sleep(for: handshakeDelay) }
        try await output.write(bytes)
    }
    public func close() async { await input.close(); await output.close() }
}
#endif
