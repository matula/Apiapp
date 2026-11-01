import Foundation

enum HTTPMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    case head = "HEAD"
    case options = "OPTIONS"

    var id: String { rawValue }

    /// URLSession refuses to send a body with these methods.
    var allowsBody: Bool { self != .get && self != .head }
}

/// One row in a params, headers or form table.
struct KeyValue: Identifiable, Sendable {
    var id = UUID()
    var isEnabled = true
    var key = ""
    var value = ""
}

extension KeyValue: Equatable {
    // Row ids only exist so SwiftUI can track rows, so they don't count as a change.
    static func == (a: KeyValue, b: KeyValue) -> Bool {
        a.isEnabled == b.isEnabled && a.key == b.key && a.value == b.value
    }
}

extension KeyValue: Codable {
    private enum CodingKeys: String, CodingKey { case enabled, key, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .enabled)
        try c.encode(key, forKey: .key)
        try c.encode(value, forKey: .value)
    }
}

/// A multipart row: either a text value or a path to a file on disk.
struct MultipartField: Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case text, file }

    var id = UUID()
    var isEnabled = true
    var key = ""
    var value = ""
    var kind = Kind.text
}

extension MultipartField: Equatable {
    static func == (a: MultipartField, b: MultipartField) -> Bool {
        a.isEnabled == b.isEnabled && a.key == b.key && a.value == b.value && a.kind == b.kind
    }
}

extension MultipartField: Codable {
    private enum CodingKeys: String, CodingKey { case enabled, key, value, kind }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        key = try c.decodeIfPresent(String.self, forKey: .key) ?? ""
        value = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(isEnabled, forKey: .enabled)
        try c.encode(key, forKey: .key)
        try c.encode(value, forKey: .value)
        try c.encode(kind, forKey: .kind)
    }
}

enum BodyType: String, Codable, CaseIterable, Identifiable, Sendable {
    case json, form, multipart, raw, none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .json: "JSON"
        case .form: "Form URL-Encoded"
        case .multipart: "Multipart Form"
        case .raw: "Raw Text"
        case .none: "None"
        }
    }

    var contentType: String? {
        switch self {
        case .json: "application/json"
        case .form: "application/x-www-form-urlencoded"
        case .multipart: "multipart/form-data"
        case .raw: "text/plain"
        case .none: nil
        }
    }
}

/// The Auth tab. Tokens, passwords and API keys are never written to JSON unless
/// they are a plain `{{variable}}` reference. `SecretVault` keeps the real values.
struct AuthConfig: Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case none, bearer, basic, apiKey

        var id: String { rawValue }

        var label: String {
            switch self {
            case .none: "None"
            case .bearer: "Bearer Token"
            case .basic: "Basic"
            case .apiKey: "API Key"
            }
        }
    }

    enum Placement: String, Codable, CaseIterable, Identifiable, Sendable {
        case header, query

        var id: String { rawValue }
        var label: String { self == .header ? "Header" : "Query Param" }
    }

    var kind = Kind.none
    var token = ""
    var username = ""
    var password = ""
    var apiKeyName = "X-API-Key"
    var apiKeyValue = ""
    var apiKeyPlacement = Placement.header

    static func isVariableReference(_ value: String) -> Bool {
        value.wholeMatch(of: /\{\{[^{}]+\}\}/) != nil
    }

    /// The values that belong in the Keychain.
    var secrets: [String: String] {
        let candidates = ["token": token, "password": password, "apiKeyValue": apiKeyValue]
        return candidates.filter { !$0.value.isEmpty && !Self.isVariableReference($0.value) }
    }

    mutating func apply(secrets: [String: String]) {
        if let value = secrets["token"] { token = value }
        if let value = secrets["password"] { password = value }
        if let value = secrets["apiKeyValue"] { apiKeyValue = value }
    }
}

extension AuthConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, token, username, password, apiKeyName, apiKeyValue, apiKeyPlacement
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .none
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? ""
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
        apiKeyName = try c.decodeIfPresent(String.self, forKey: .apiKeyName) ?? "X-API-Key"
        apiKeyValue = try c.decodeIfPresent(String.self, forKey: .apiKeyValue) ?? ""
        apiKeyPlacement = try c.decodeIfPresent(Placement.self, forKey: .apiKeyPlacement) ?? .header
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(username, forKey: .username)
        try c.encode(apiKeyName, forKey: .apiKeyName)
        try c.encode(apiKeyPlacement, forKey: .apiKeyPlacement)
        try c.encodeIfPresent(Self.isVariableReference(token) ? token : nil, forKey: .token)
        try c.encodeIfPresent(Self.isVariableReference(password) ? password : nil, forKey: .password)
        try c.encodeIfPresent(Self.isVariableReference(apiKeyValue) ? apiKeyValue : nil, forKey: .apiKeyValue)
    }
}

/// Everything about a request: what a tab edits and what a saved file holds.
struct RequestDraft: Codable, Equatable, Sendable {
    static let contentTypeHeader = "Content-Type"

    var name = ""
    var method = HTTPMethod.get
    var url = ""
    var params: [KeyValue] = []
    var headers: [KeyValue] = []
    var auth = AuthConfig()
    var bodyType = BodyType.json
    var bodyText = ""
    var formFields: [KeyValue] = []
    var multipartFields: [MultipartField] = []

    /// A new request, with the header that JSON (the default body type) needs.
    static func blank() -> RequestDraft {
        var draft = RequestDraft()
        draft.setBodyType(.json)
        return draft
    }

    var contentTypeIndex: Int? {
        headers.firstIndex { Self.isContentType($0.key) }
    }

    var contentType: KeyValue? {
        contentTypeIndex.map { headers[$0] }
    }

    /// True while the Content-Type is the value the body type picked.
    var isContentTypeAutomatic: Bool {
        contentType?.value == bodyType.contentType
    }

    static func isContentType(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(contentTypeHeader) == .orderedSame
    }

    /// Switching body type updates the Content-Type header. It stays an ordinary row,
    /// so it can still be edited or removed afterwards.
    mutating func setBodyType(_ type: BodyType) {
        bodyType = type
        addAutomaticContentType()
    }

    mutating func addAutomaticContentType() {
        guard let value = bodyType.contentType else {
            headers.removeAll { Self.isContentType($0.key) }
            return
        }
        if let index = contentTypeIndex {
            headers[index].value = value
            headers[index].isEnabled = true
        } else {
            headers.append(KeyValue(key: Self.contentTypeHeader, value: value))
        }
    }

    mutating func removeContentType() {
        headers.removeAll { Self.isContentType($0.key) }
    }

    /// Editing the URL refreshes the params table.
    mutating func setURL(_ newValue: String) {
        url = newValue
        params = QuerySync.params(from: newValue, keeping: params)
    }

    /// Editing the params table rewrites the URL's query string.
    mutating func setParams(_ newValue: [KeyValue]) {
        params = newValue
        url = QuerySync.url(url, applying: newValue)
    }

    /// What a tab, list row or history row shows.
    var displayName: String {
        if !name.isEmpty { return name }
        let path = shortPath
        return path.isEmpty ? "New Request" : path
    }

    /// The URL without its host or query, such as `/v1/users`.
    var shortPath: String {
        var text = QuerySync.split(url).base
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
            text = text.firstIndex(of: "/").map { String(text[$0...]) } ?? text
        } else if text.hasPrefix("{{"), let end = text.range(of: "}}") {
            let rest = String(text[end.upperBound...])
            if !rest.isEmpty { text = rest }
        }
        return text
    }
}
