import Foundation
import Security

// Separate from invitation identity. Removing renewal credentials must never
// revoke access or remove the developer pairing needed for Restore.
enum RenewalVault {
    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.diwasupadhyay.catter.renewal",
            kSecAttrAccount as String: account, kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw AppError.message("Unlock the iPhone to access renewal credentials.")
        }
        return data
    }

    static func save(_ data: Data, account: String) throws {
        guard data.count <= 1_048_576 else { throw AppError.message("Renewal credentials are too large.") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.diwasupadhyay.catter.renewal", kSecAttrAccount as String: account]
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            insert[kSecAttrSynchronizable as String] = false
            status = SecItemAdd(insert as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AppError.message("Could not save renewal credentials securely.") }
    }

    static func remove(_ account: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.diwasupadhyay.catter.renewal",
            kSecAttrAccount as String: account] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AppError.message("Could not remove renewal credentials. Unlock the iPhone and retry.")
        }
    }
}
