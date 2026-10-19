import Foundation
import Security

enum ModelCredentials {
    private static let service = "org.linux-arctis-manager.huggingface"
    static func read() -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "token", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ token: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "token"]
        if token.isEmpty {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw AudioFailure.message("Could not remove the saved token (\(result)).") }
            return
        }
        let value = [kSecValueData as String: Data(token.utf8)]
        var result = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if result == errSecItemNotFound {
            var entry = query; entry[kSecValueData as String] = Data(token.utf8)
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            result = SecItemAdd(entry as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw AudioFailure.message("Could not save the token to Keychain (\(result)).") }
    }
}
