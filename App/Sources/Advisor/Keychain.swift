import Foundation
import Security

/// Minimal macOS Keychain wrapper for the provider API keys. Secrets live here,
/// never in config.json — the app reads them only to inject into the sidecar's
/// environment at spawn (see SidecarManager). Stored as generic-password items
/// under one service, keyed by account name.
enum Keychain {
    /// Account names for the two provider keys.
    enum Key: String {
        case anthropic = "anthropic-api-key"
        case openai = "openai-api-key"
    }

    private static let service = "Advisor"

    private static func baseQuery(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
        ]
    }

    /// The stored secret, or nil if absent. Empty/whitespace-only is treated as
    /// absent so a cleared field reads the same as no key.
    static func read(_ key: Key) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Store (or replace) the secret. An empty/whitespace value deletes it, so the
    /// UI can clear a key by blanking the field. Returns whether the value was
    /// actually persisted (or deleted) — a false result means the Keychain
    /// rejected the write and nothing was stored.
    @discardableResult static func save(_ key: Key, _ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return delete(key)
        }
        let data = Data(trimmed.utf8)
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery(key) as CFDictionary, attrs as CFDictionary)
        if status == errSecSuccess { return true }
        if status == errSecItemNotFound {
            var add = baseQuery(key)
            add[kSecValueData as String] = data
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return false
    }

    /// Remove the secret. Returns whether it's now absent — an already-missing
    /// item counts as success.
    @discardableResult static func delete(_ key: Key) -> Bool {
        let status = SecItemDelete(baseQuery(key) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
