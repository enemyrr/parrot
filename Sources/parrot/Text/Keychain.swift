import Foundation
import Security

/// Generic-password Keychain item for the Anthropic API key. The key never
/// goes in config.toml — that file is meant to be readable and shareable.
enum Keychain {
    private static let service = "com.digimata.parrot"
    private static let account = "anthropic-api-key"

    enum KeychainError: Error, CustomStringConvertible {
        case failed(OSStatus)

        var description: String {
            switch self {
            case .failed(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "\(status)"
                return "keychain error: \(message)"
            }
        }
    }

    /// Look up the key, falling back to `$ANTHROPIC_API_KEY`.
    static func anthropicAPIKey() -> String? {
        if let stored = read(), !stored.isEmpty { return stored }
        let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        return (env?.isEmpty == false) ? env : nil
    }

    static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(value.utf8)

        // Update in place if it exists; SecItemAdd fails with errSecDuplicateItem.
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.failed(update) }

        var insert = base
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.failed(status) }
    }

    static func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.failed(status)
        }
    }
}
