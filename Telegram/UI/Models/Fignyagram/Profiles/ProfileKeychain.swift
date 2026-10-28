import Foundation
import Security

/// Per-profile database encryption keys, kept in the Keychain.
///
/// TDLib requires the exact same key every time it opens a database, so a key
/// is generated only for a profile whose database does not exist yet. Existing,
/// unencrypted databases keep working (no key is passed for them).
nonisolated enum ProfileKeychain {
    private static let service = "com.Fignyagram.Fignyagram.profileKeys"

    static func databaseEncryptionKey(for slot: AccountSlot) -> Data? {
        if let existing = load(id: slot.id) { return existing }
        // Only new containers receive a key; encrypting an existing database
        // with a fresh key would make it unreadable.
        let dbPath = slot.databaseDirectory + "/db.sqlite"
        guard !FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { return nil }
        let key = Data(bytes)
        save(id: slot.id, key: key)
        CallDiag.log("profile key generated for \(slot.id)")
        return key
    }

    static func deleteKey(for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id
        ]
        SecItemDelete(query as CFDictionary)
    }

    private static func load(id: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func save(id: String, key: Data) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id
        ]
        SecItemDelete(base as CFDictionary)
        var attributes = base
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
