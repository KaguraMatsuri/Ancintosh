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

    public static func proof(key: Data, transcript: Data, role: PeerRole) -> Data {
        var input = Data("Andcintosh/v1/proof/".utf8)
        input.append(role.rawValue)
        input.append(transcript)
        return Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: key)))
    }

    public static func verify(_ proof: Data, key: Data, transcript: Data, role: PeerRole) -> Bool {
        var input = Data("Andcintosh/v1/proof/".utf8)
        input.append(role.rawValue)
        input.append(transcript)
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: input, using: SymmetricKey(data: key))
    }
}

public struct CryptoSession: Sendable {
    public let root: Data
    private let txKey: SymmetricKey
    private let rxKey: SymmetricKey
    private let txPrefix: Data
    private let rxPrefix: Data
    private var txSequence: UInt64 = 0
    private var rxSequence: UInt64 = 0

    public init(key: Data, local: Hello, remote: Hello, transport: TransportKind) throws {
        guard key.count == 32, local.role != remote.role, local.contextID == remote.contextID,
              local.nonce != remote.nonce else { throw ProtocolFailure.invalidHandshake }
        let mac = local.role == .mac ? local : remote
        let android = local.role == .android ? local : remote
        var salt = mac.nonce
        salt.append(android.nonce)
        var transcript = mac.encoded()
        transcript.append(android.encoded())
        root = Crypto.derive(key, salt: salt, info: "Andcintosh/v1/\(transport.rawValue)/\(Crypto.digest(transcript))")
        let tx = local.role == .mac ? "mac" : "android"
        let rx = local.role == .mac ? "android" : "mac"
        txKey = SymmetricKey(data: Crypto.derive(root, salt: Data(), info: "key/\(tx)"))
        rxKey = SymmetricKey(data: Crypto.derive(root, salt: Data(), info: "key/\(rx)"))
        txPrefix = Crypto.derive(root, salt: Data(), info: "nonce/\(tx)", count: 4)
        rxPrefix = Crypto.derive(root, salt: Data(), info: "nonce/\(rx)", count: 4)
    }

    public mutating func seal(_ record: Record) throws -> Data {
        guard txSequence < UInt64.max else { throw ProtocolFailure.invalidFrame }
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
        guard sequence == rxSequence, rxSequence < UInt64.max else { throw ProtocolFailure.replay }
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
