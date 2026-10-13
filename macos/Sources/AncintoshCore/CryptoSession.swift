import CryptoKit
import Foundation
import Security

public enum Crypto {
    public static func random(_ count: Int) throws -> Data {
        var bytes = Data(count: count)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ProtocolFailure.authenticationFailed }
        return bytes
    }

    public static func key(_ hex: String) throws -> Data {
        guard hex.utf8.count == 64, let bytes = Data(hex: hex), bytes.count == 32 else {
            throw ProtocolFailure.invalidKey
        }
        return bytes
    }

    public static func digest(_ data: Data) -> String { Data(SHA256.hash(data: data)).hex }

    public static func derive(_ key: Data, salt: Data, info: String, count: Int = 32) -> Data {
        let result = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: key), salt: salt,
                                          info: Data(info.utf8), outputByteCount: count)
        return result.withUnsafeBytes { Data($0) }
    }

    public static func transcript(local: Hello, remote: Hello, transport: TransportKind) -> Data {
        let mac = local.role == .mac ? local : remote
        let android = local.role == .android ? local : remote
        return Data("Andcintosh/v2/\(transport.rawValue)/".utf8) + mac.encoded() + android.encoded()
    }

    public static func proof(key: Data, transcript: Data, role: PeerRole) -> Data {
        var input = Data("Andcintosh/v2/proof/".utf8)
        input.append(role.rawValue)
        input.append(transcript)
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: key)))
    }

    public static func verify(_ proof: Data, key: Data, transcript: Data, role: PeerRole) -> Bool {
        var input = Data("Andcintosh/v2/proof/".utf8)
        input.append(role.rawValue)
        input.append(transcript)
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: input, using: SymmetricKey(data: key))
    }
}

public struct CryptoSession: Sendable {
    public let root: Data
    private var txKey: SymmetricKey
    private var rxKey: SymmetricKey
    private let txDirection: String
    private let rxDirection: String
    private var txEpoch: UInt64 = 0
    private var rxEpoch: UInt64 = 0
    private let txPrefix: Data
    private let rxPrefix: Data
    var txSequence: UInt64 = 0
    var rxSequence: UInt64 = 0

    public init(key: Data, local: Hello, remote: Hello, transport: TransportKind, sharedSecret: Data) throws {
        guard key.count == 32, sharedSecret.count == 32, sharedSecret.contains(where: { $0 != 0 }), local.role != remote.role, local.contextID == remote.contextID,
              local.nonce != remote.nonce else { throw ProtocolFailure.invalidHandshake }
        let mac = local.role == .mac ? local : remote
        let android = local.role == .android ? local : remote
        let salt = Data(HMAC<SHA256>.authenticationCode(for: mac.nonce + android.nonce, using: SymmetricKey(data: key)))
        let transcript = Crypto.transcript(local: local, remote: remote, transport: transport)
        root = Crypto.derive(sharedSecret, salt: salt, info: "Andcintosh/v2/session/\(Crypto.digest(transcript))")
        let tx = local.role == .mac ? "mac" : "android"
        let rx = local.role == .mac ? "android" : "mac"
        txDirection = tx; rxDirection = rx
        txKey = SymmetricKey(data: Crypto.derive(root, salt: Data(), info: "key/\(tx)/0"))
        rxKey = SymmetricKey(data: Crypto.derive(root, salt: Data(), info: "key/\(rx)/0"))
        txPrefix = Crypto.derive(root, salt: Data(), info: "nonce/\(tx)", count: 4)
        rxPrefix = Crypto.derive(root, salt: Data(), info: "nonce/\(rx)", count: 4)
    }

    public mutating func seal(_ record: Record) throws -> Data {
        guard txSequence < UInt64(Int64.max) else { throw ProtocolFailure.invalidFrame }
        let epoch = txSequence >> 20
        if epoch != txEpoch {
            txKey = SymmetricKey(data: Crypto.derive(root, salt: Data(), info: "key/\(txDirection)/\(epoch)"))
            txEpoch = epoch
        }
        let plaintext = try record.encoded()
        var header = Data()
        header.appendBE(UInt32(plaintext.count + 16))
        header.appendBE(txSequence)
        var nonce = txPrefix
        nonce.appendBE(txSequence)
        let box = try AES.GCM.seal(plaintext, using: txKey, nonce: AES.GCM.Nonce(data: nonce), authenticating: header)
        var output = header
        output.append(box.ciphertext)
        output.append(box.tag)
        txSequence += 1
        return output
    }

    public mutating func open(_ wire: Data) throws -> Record {
        guard wire.count >= 12 + 16 else { throw ProtocolFailure.invalidFrame }
        var reader = BinaryReader(wire)
        let length = try reader.uint32()
        let sequence = try reader.uint64()
        guard length <= Wire.maxPlaintext + 16, Int(length) == reader.remaining else {
            throw ProtocolFailure.invalidFrame
        }
        guard sequence == rxSequence, rxSequence < UInt64(Int64.max) else { throw ProtocolFailure.replay }
        let epoch = sequence >> 20
        if epoch != rxEpoch {
            rxKey = SymmetricKey(data: Crypto.derive(root, salt: Data(), info: "key/\(rxDirection)/\(epoch)"))
            rxEpoch = epoch
        }
        var nonce = rxPrefix
        nonce.appendBE(sequence)
        let ciphertext = try reader.bytes(Int(length) - 16)
        let tag = try reader.bytes(16)
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
        let plaintext: Data
        do { plaintext = try AES.GCM.open(box, using: rxKey, authenticating: Data(wire.prefix(12))) }
        catch { throw ProtocolFailure.authenticationFailed }
        let record = try Record.decode(plaintext)
        rxSequence += 1
        return record
    }
}
