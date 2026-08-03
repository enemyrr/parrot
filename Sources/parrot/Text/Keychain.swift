import Foundation
import Security

/// Generic-password Keychain items for cleanup API keys, one per provider.
/// Keys never go in the settings blob — that is ordinary preferences, readable
/// by anything running as the user.
enum Keychain {
    private static let service = "com.enemyrr.parrot"

    /// A provider that needs an API key. Raw value doubles as the CLI
    /// spelling in `parrot cleanup set-key <provider>`.
    enum Account: String, CaseIterable {
        case anthropic
        case openai

        /// Keychain item name. Predates `openai`, hence the suffix pattern.
        var item: String { "\(rawValue)-api-key" }

        var envVar: String {
            switch self {
            case .anthropic: return "ANTHROPIC_API_KEY"
            case .openai: return "OPENAI_API_KEY"
            }
        }

        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openai: return "OpenAI"
            }
        }
    }

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

    /// Look up the key, falling back to the provider's environment variable.
    static func apiKey(for account: Account) -> String? {
        if let stored = read(account), !stored.isEmpty { return stored }
        let env = ProcessInfo.processInfo.environment[account.envVar]
        return (env?.isEmpty == false) ? env : nil
    }

    static func read(_ account: Account) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.item,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, for account: Account) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.item,
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

    static func delete(_ account: Account) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.item,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.failed(status)
        }
    }
}
