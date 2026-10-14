import Foundation

public enum ProtocolFailure: String, Error, Codable, Sendable {
    case invalidKey, unsupportedVersion, invalidHandshake, authenticationFailed, invalidFrame, replay
    case oversizedRecord, invalidManifest, invalidOffset, digestMismatch
    case sourceUnavailable, originalUnavailable, insufficientSpace, cancelled
    case peerUnavailable, timeout, permissionDenied, invalidName, unsupported
}

public enum PeerRole: UInt8, Sendable { case mac = 1, android = 2 }
public enum TransportKind: String, Codable, Sendable { case ble, tcp }
public enum PayloadKind: Int, Codable, Sendable { case text = 1, image = 2, file = 3 }
public enum RecordKind: UInt8, Sendable {
    case begin = 1, data = 2, finish = 3, acknowledge = 4, resume = 5
    case cancel = 6, wifiPreference = 7, tcpOffer = 8, goodbye = 9, failure = 10, transportSwitch = 11
    case deviceInformation = 12, configuration = 13, notification = 14
}

public enum Wire {
    public static let magic = Data("Ciallo~".utf8)
    public static let version: UInt8 = 2
    public static let helloSize = 105
    public static let maxPlaintext = 65_536
    public static let recordHeaderSize = 45
    public static let maxMetadata = 8_192
    public static let tcpChunkSize = maxPlaintext - recordHeaderSize
    public static let bleChunkSize = 4_096
    public static let zeroID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public static func encodeJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decodeJSON<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

public struct Hello: Sendable, Equatable {
    public let role: PeerRole
    public let peerID: UUID
    public let contextID: UUID
    public let nonce: Data
    public let publicKey: Data

    public init(role: PeerRole, peerID: UUID, contextID: UUID = Wire.zeroID, nonce: Data, publicKey: Data) throws {
        guard nonce.count == 32, publicKey.count == 32 else { throw ProtocolFailure.invalidHandshake }
        self.role = role
        self.peerID = peerID
        self.contextID = contextID
        self.nonce = nonce
        self.publicKey = publicKey
    }

    public func encoded() -> Data {
        var data = Wire.magic
        data.append(Wire.version)
        data.append(role.rawValue)
        data.appendUUID(peerID)
        data.appendUUID(contextID)
        data.append(nonce)
        data.append(publicKey)
        return data
    }

    public static func decode(_ data: Data) throws -> Hello {
        guard data.count == Wire.helloSize else { throw ProtocolFailure.invalidHandshake }
        var reader = BinaryReader(data)
        guard try reader.bytes(7) == Wire.magic, try reader.byte() == Wire.version,
              let role = PeerRole(rawValue: try reader.byte()) else {
            throw ProtocolFailure.invalidHandshake
        }
        return try Hello(role: role, peerID: reader.uuid(), contextID: reader.uuid(), nonce: reader.bytes(32), publicKey: reader.bytes(32))
    }
}

public struct Record: Sendable, Equatable {
    public let kind: RecordKind
    public let transferID: UUID
    public let offset: UInt64
    public let metadata: Data
    public let bytes: Data
    public let epoch: UUID

    public init(_ kind: RecordKind, transferID: UUID = Wire.zeroID, offset: UInt64 = 0,
                metadata: Data = Data(), bytes: Data = Data(), epoch: UUID = Wire.zeroID) {
        self.kind = kind
        self.transferID = transferID
        self.offset = offset
        self.metadata = metadata
        self.bytes = bytes
        self.epoch = epoch
    }

    public func inEpoch(_ epoch: UUID) -> Record { Record(kind, transferID: transferID, offset: offset, metadata: metadata, bytes: bytes, epoch: epoch) }

    public func encoded() throws -> Data {
        guard metadata.count <= Wire.maxMetadata,
              Wire.recordHeaderSize + metadata.count + bytes.count <= Wire.maxPlaintext else {
            throw ProtocolFailure.oversizedRecord
        }
        var data = Data([kind.rawValue])
        data.appendUUID(epoch)
        data.appendUUID(transferID)
        data.appendBE(offset)
        data.appendBE(UInt32(metadata.count))
        data.append(metadata)
        data.append(bytes)
        return data
    }

    public static func decode(_ data: Data) throws -> Record {
        guard data.count <= Wire.maxPlaintext, data.count >= Wire.recordHeaderSize else {
            throw ProtocolFailure.invalidFrame
        }
        var reader = BinaryReader(data)
        guard let kind = RecordKind(rawValue: try reader.byte()) else { throw ProtocolFailure.invalidFrame }
        let epoch = try reader.uuid()
        let id = try reader.uuid()
        let offset = try reader.uint64()
        let size = try reader.uint32()
        guard size <= Wire.maxMetadata else { throw ProtocolFailure.oversizedRecord }
        let metadata = try reader.bytes(Int(size))
        return Record(kind, transferID: id, offset: offset, metadata: metadata, bytes: try reader.bytes(reader.remaining), epoch: epoch)
    }
}

public struct TransferManifest: Codable, Sendable, Equatable {
    public let id: UUID
    public let kind: PayloadKind
    public let name: String
    public let mime: String
    public let size: UInt64
    public let sha256: String
    public let origin: UUID

    public init(id: UUID = UUID(), kind: PayloadKind, name: String, mime: String,
                size: UInt64, sha256: String, origin: UUID) throws {
        self.id = id
        self.kind = kind
        self.name = name
        self.mime = mime
        self.size = size
        self.sha256 = sha256.lowercased()
        self.origin = origin
        try validate()
    }

    public func validate() throws {
        guard size <= UInt64(Int64.max), !mime.isEmpty, mime.utf8.count <= 255,
              sha256.count == 64, Data(hex: sha256)?.count == 32 else {
            throw ProtocolFailure.invalidManifest
        }
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 240,
              !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw ProtocolFailure.invalidName
        }
    }
}

public struct TCPAddress: Codable, Sendable, Equatable {
    public let host: String
    public let port: UInt16
    public init(host: String, port: UInt16) { self.host = host; self.port = port }
}

public struct TCPOffer: Codable, Sendable {
    public let id: UUID
    public let addresses: [TCPAddress]
    public let secret: String
    public init(id: UUID = UUID(), addresses: [TCPAddress], secret: Data) {
        self.id = id
        self.addresses = addresses
        self.secret = secret.hex
    }
}

public struct BinaryReader {
    private let data: Data
    private var offset = 0
    public init(_ data: Data) { self.data = data }
    public var remaining: Int { data.count - offset }
    public mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw ProtocolFailure.invalidFrame }
        let start = data.index(data.startIndex, offsetBy: offset)
        offset += count
        return Data(data[start..<data.index(start, offsetBy: count)])
    }
    public mutating func byte() throws -> UInt8 { try bytes(1).first! }
    public mutating func uint32() throws -> UInt32 { try bytes(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
    public mutating func uint64() throws -> UInt64 { try bytes(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) } }
    public mutating func uuid() throws -> UUID {
        let b = Array(try bytes(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

extension Data {
    public init?(hex: String) {
        guard hex.utf8.count % 2 == 0, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return nil }
        var bytes = [UInt8]()
        let characters = Array(hex.utf8)
        for i in stride(from: 0, to: characters.count, by: 2) {
            guard let value = UInt8(String(decoding: characters[i...i + 1], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(value)
        }
        self.init(bytes)
    }
    public var hex: String { map { String(format: "%02x", $0) }.joined() }
    public mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
    public mutating func appendUUID(_ value: UUID) {
        var uuid = value.uuid
        Swift.withUnsafeBytes(of: &uuid) { append(contentsOf: $0) }
    }
}
