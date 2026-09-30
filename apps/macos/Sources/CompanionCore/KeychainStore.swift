import Foundation
import Security

public enum KeychainStore {
    public static let service = "Kio"
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    public static func read(account: String = "gemini") throws -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { throw StoreError.unavailable }
        return value
    }
    public static func save(_ value: String, account: String = "gemini") throws {
        guard !value.isEmpty, value.utf8.count <= 4096 else { throw StoreError.invalid }
        let attributes = [kSecValueData as String: Data(value.utf8)]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(account)
            request[kSecValueData as String] = Data(value.utf8)
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw StoreError.unavailable }
        } else if status != errSecSuccess { throw StoreError.unavailable }
    }
    public static func delete(account: String = "gemini") throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StoreError.unavailable }
    }
    public enum StoreError: Error { case unavailable, invalid }
}
