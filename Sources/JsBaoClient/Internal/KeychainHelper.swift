import Foundation
import Security

/// Thin wrapper around the iOS/macOS Keychain for storing offline access grants.
final class KeychainHelper: @unchecked Sendable {
    private let service: String

    init(service: String) {
        self.service = service
    }

    /// Save data to the Keychain.
    ///
    /// - Parameters:
    ///   - key: The account/key name.
    ///   - data: The data to store.
    ///   - requireBiometric: If true, reading the item will require Face ID / Touch ID.
    func save(key: String, data: Data, requireBiometric: Bool = false) throws {
        // Delete any existing item first
        try? delete(key: key)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        if requireBiometric {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .biometryCurrentSet,
                &error
            ) else {
                throw KeychainError.accessControlCreationFailed(error?.takeRetainedValue())
            }
            query[kSecAttrAccessControl as String] = access
            query.removeValue(forKey: kSecAttrAccessible as String)
        }

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    /// Load data from the Keychain. If the item requires biometric authentication,
    /// the system will prompt the user automatically.
    func load(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        case errSecUserCanceled, errSecAuthFailed:
            throw KeychainError.biometricCancelled
        default:
            throw KeychainError.loadFailed(status)
        }
    }

    /// Delete an item from the Keychain.
    func delete(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Check if an item exists in the Keychain (without reading it).
    func exists(key: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: false,
        ]

        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
}

// MARK: - Errors

enum KeychainError: Error {
    case accessControlCreationFailed(CFError?)
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    case biometricCancelled
}
