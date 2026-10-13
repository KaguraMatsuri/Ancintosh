import Foundation

public enum DeviceKind: String, Codable, Sendable { case mac, phone, pad }

public struct DeviceInformation: Codable, Sendable {
    public let name: String
    public let kind: DeviceKind
    public let wifi: Bool
    public let renameRequest: UUID?
    public init(name: String, kind: DeviceKind, wifi: Bool, renameRequest: UUID? = nil) {
        self.name = name; self.kind = kind; self.wifi = wifi; self.renameRequest = renameRequest
    }
}

public struct ManagedDevice: Codable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: DeviceKind
    public let wifi: Bool
    public let priority: Int
    public let renameRequest: UUID?
    public init(id: UUID, name: String, kind: DeviceKind, wifi: Bool, priority: Int, renameRequest: UUID? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.wifi = wifi
        self.priority = priority; self.renameRequest = renameRequest
    }
}

// One device per message keeps configuration bounded by the existing metadata limit.
public struct ManagedConfiguration: Codable, Sendable {
    public let revision: Int64
    public let mac: ManagedDevice
    public let device: ManagedDevice?
    public let primary: UUID?
    public let lockEnabled: Bool
    public let lockDelaySeconds: Int
    public init(revision: Int64, mac: ManagedDevice, device: ManagedDevice?, primary: UUID?, lockEnabled: Bool, lockDelaySeconds: Int) {
        self.revision = revision; self.mac = mac; self.device = device; self.primary = primary
        self.lockEnabled = lockEnabled; self.lockDelaySeconds = lockDelaySeconds
    }
}
