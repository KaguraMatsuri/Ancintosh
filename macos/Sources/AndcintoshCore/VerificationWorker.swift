import CryptoKit
import Foundation

final class VerificationLease: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.withLock { stopped = true } }
    func check() throws { if lock.withLock({ stopped }) { throw ProtocolFailure.cancelled } }
}

enum VerificationWorker {
    private static let queue = DispatchQueue(label: "Andcintosh.file.verification", qos: .utility)
    static func prepare(source: URL, staging: URL?, sha256: String, lease: VerificationLease) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        try lease.check()
                        let verified = staging ?? source
                        if let staging { try FileManager.default.copyItem(at: source, to: staging) }
                        try lease.check()
                        let input = try FileHandle(forReadingFrom: verified)
                        defer { try? input.close() }
                        var digest = SHA256()
                        while true {
                            let finished = try autoreleasepool {
                                try lease.check()
                                guard let bytes = try input.read(upToCount: 65_536), !bytes.isEmpty else { return true }
                                digest.update(data: bytes)
                                return false
                            }
                            if finished { break }
                        }
                        guard Data(digest.finalize()).hex == sha256 else { throw ProtocolFailure.digestMismatch }
                        try lease.check()
                        continuation.resume(returning: verified)
                    } catch {
                        if let staging { try? FileManager.default.removeItem(at: staging) }
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: { lease.cancel() }
    }
}
