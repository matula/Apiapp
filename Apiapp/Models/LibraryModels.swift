import Foundation

struct Folder: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
}

/// A request kept on purpose, in a folder or on the main list.
struct SavedRequest: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var folderID: UUID?
    var request: RequestDraft
    var updatedAt = Date()
}

/// Written automatically every time a request is sent.
struct HistoryEntry: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var request: RequestDraft
    var sentAt = Date()
    var statusCode: Int?
}

/// A response kept on purpose, along with the request that produced it.
struct SavedResponse: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var savedAt = Date()
    var request: RequestDraft
    var response: ResponseSnapshot
}

struct Variable: Identifiable, Sendable {
    var id = UUID()
    var isEnabled = true
    var key = ""
    var value = ""
    var isSecret = false
}

extension Variable: Equatable {
    static func == (a: Variable, b: Variable) -> Bool {
        a.isEnabled == b.isEnabled && a.key == b.key && a.value == b.value && a.isSecret == b.isSecret
    }
}

extension Variable: Codable {
    private enum CodingKeys: String, CodingKey { case id, enabled, key, value, secret }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        isSecret = try c.decodeIfPresent(Bool.self, forKey: .secret) ?? false
    }

    // A secret variable's value lives in the Keychain, so the file only names it.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(isEnabled, forKey: .enabled)
        try c.encode(key, forKey: .key)
        try c.encode(isSecret, forKey: .secret)
        try c.encodeIfPresent(isSecret ? nil : value, forKey: .value)
    }
}

struct RequestEnvironment: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var name: String
    var variables: [Variable] = []

    var resolvedValues: [String: String] {
        variables.reduce(into: [:]) { values, variable in
            if variable.isEnabled, !variable.key.isEmpty { values[variable.key] = variable.value }
        }
    }
}
