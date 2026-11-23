import Foundation

/// Any JSON value, for MCP messages, whose shape depends on the method.
enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    /// Re-reads this value as a `Decodable` type, so tool arguments get Swift types.
    func decode<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }

    /// Any `Encodable` value as JSON, for building replies.
    init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue: ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }

    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
