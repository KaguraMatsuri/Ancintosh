import Foundation

public struct NotificationAccess: Codable, Sendable, Equatable {
    public let capture: Bool
    public let display: Bool
    public let enabled: Bool?
    public init(capture: Bool = false, display: Bool = false, enabled: Bool? = nil) { self.capture = capture; self.display = display; self.enabled = enabled }
}

public struct NotificationMessage: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable { case upsert, remove }
    public let id: UUID
    public let action: Action
    public let application: String
    public let title: String
    public let body: String

    public init(id: UUID, action: Action, application: String = "", title: String = "", body: String = "") {
        self.id = id; self.action = action; self.application = application; self.title = title; self.body = body
    }
    public func validated() throws -> Self {
        guard id != Wire.zeroID, action != .upsert || !application.isEmpty,
              try Wire.encodeJSON(self).count <= Wire.maxMetadata else { throw ProtocolFailure.invalidFrame }
        return self
    }
    public static func bounded(id: UUID, application: String, title: String, body: String) throws -> Self {
        let app = String(application.prefix(128)), heading = String(title.prefix(256))
        let characters = Array(body.prefix(Wire.maxMetadata))
        var low = 0, high = characters.count
        while low < high {
            let middle = (low + high + 1) / 2
            let value = Self(id: id, action: .upsert, application: app, title: heading, body: String(characters.prefix(middle)))
            if try Wire.encodeJSON(value).count <= Wire.maxMetadata { low = middle } else { high = middle - 1 }
        }
        return try Self(id: id, action: .upsert, application: app, title: heading, body: String(characters.prefix(low))).validated()
    }
}

// Latest event per source ID. Identical text from distinct notifications stays distinct.
public struct NotificationQueue: Sendable {
    public static let capacity = 128
    private var values: [NotificationMessage] = []
    public init() {}
    public var count: Int { values.count }
    public func contains(_ id: UUID) -> Bool { values.contains { $0.id == id } }
    public mutating func remove(_ id: UUID) { values.removeAll { $0.id == id } }
    public mutating func append(_ value: NotificationMessage) {
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value }
        else {
            if values.count == Self.capacity { values.removeFirst() }
            values.append(value)
        }
    }
    public mutating func pop() -> NotificationMessage? { values.isEmpty ? nil : values.removeFirst() }
}
