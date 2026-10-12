import AndcintoshCore
import Foundation
import Security

public enum KeychainStore {
    private static let service = "Andcintosh.peer"
    public static func save(_ key: Data, peer: UUID) throws {
        guard key.count == 32 else { throw ProtocolFailure.invalidKey }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: peer.uuidString]
        let attributes: [String: Any] = [kSecValueData as String: key]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = key
            insert[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw ProtocolFailure.permissionDenied }
    }
    public static func load(peer: UUID) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                  kSecAttrAccount as String: peer.uuidString, kSecReturnData as String: true,
                                  kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let key = result as? Data, key.count == 32 else { throw ProtocolFailure.invalidKey }
        return key
    }
    public static func remove(peer: UUID) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: peer.uuidString] as CFDictionary)
    }
}
