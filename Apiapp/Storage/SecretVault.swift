import Foundation
import Security

/// Where the vault's contents actually live.
protocol SecretStorage: AnyObject {
    func load() throws -> Data?
    func save(_ data: Data) throws
}

/// One Keychain item holds every secret, which keeps the Keychain tidy however many
/// requests and history entries there are.
final class KeychainSecretStorage: SecretStorage {
    private let service: String
    private let account = "secrets"

    init(service: String = "local.apiapp.mac") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func load() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return result as? Data
    }

    func save(_ data: Data) throws {
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecAttrLabel as String] = "Apiapp secrets"
            item[kSecValueData as String] = data
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

struct KeychainError: LocalizedError {
    var status: OSStatus

    var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
        return "Keychain error: \(detail)"
    }
}

/// Keeps secrets in memory only. Used whenever the app runs on isolated data.
final class InMemorySecretStorage: SecretStorage {
    var data: Data?

    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
}

/// Secrets, grouped by what owns them: a request, a history entry, a tab or a variable.
final class SecretVault {
    private let storage: SecretStorage
    private var secrets: [String: [String: String]] = [:]

    init(storage: SecretStorage) throws {
        self.storage = storage
        if let data = try storage.load() {
            secrets = (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
        }
    }

    func values(for owner: UUID) -> [String: String] {
        secrets[owner.uuidString] ?? [:]
    }

    func set(_ values: [String: String], for owner: UUID) throws {
        let key = owner.uuidString
        guard (secrets[key] ?? [:]) != values else { return }
        secrets[key] = values.isEmpty ? nil : values
        try persist()
    }

    /// Removes several owners with a single Keychain write.
    func remove(_ owners: [UUID]) throws {
        var changed = false
        for owner in owners where secrets.removeValue(forKey: owner.uuidString) != nil {
            changed = true
        }
        if changed { try persist() }
    }

    /// Drops every owner not in `kept`, which clears out anything left behind.
    func prune(keeping kept: Set<UUID>) throws {
        let keys = Set(kept.map(\.uuidString))
        let before = secrets.count
        secrets = secrets.filter { keys.contains($0.key) }
        if secrets.count != before { try persist() }
    }

    private func persist() throws {
        try storage.save(JSONEncoder().encode(secrets))
    }
}
