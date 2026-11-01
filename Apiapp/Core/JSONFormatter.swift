import Foundation

/// Formats JSON with two-space indents. It rewrites only the whitespace, so key
/// order and number text survive exactly (`JSONSerialization` would change both).
/// Bare `{{variables}}` are allowed, as in `"id": {{userId}}`.
enum JSONFormatter {
    struct Failure: LocalizedError, Equatable {
        var message: String
        var line: Int
        var column: Int

        var errorDescription: String? { "Line \(line), column \(column): \(message)" }
    }

    static func format(_ text: String) throws -> String {
        var parser = Parser(text)
        parser.skipWhitespace()
        guard !parser.atEnd else { return "" }
        try parser.value(depth: 0)
        parser.skipWhitespace()
        guard parser.atEnd else { throw parser.failure("Unexpected text after the end of the JSON") }
        return String(decoding: parser.output, as: UTF8.self)
    }

    private struct Parser {
        /// Parsing recurses, and responses are formatted on a background thread with a small
        /// stack. Anything deeper fails cleanly, and the viewer shows it unformatted.
        static let maxDepth = 200

        let bytes: [UInt8]
        var index = 0
        var output: [UInt8] = []

        init(_ text: String) {
            bytes = Array(text.utf8)
            output.reserveCapacity(bytes.count + bytes.count / 4)
        }

        var atEnd: Bool { index >= bytes.count }
        var current: UInt8? { atEnd ? nil : bytes[index] }

        mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
                index += 1
            }
        }

        mutating func value(depth: Int) throws {
            guard depth < Self.maxDepth else { throw failure("JSON is nested too deeply") }
            skipWhitespace()
            guard let byte = current else { throw failure("Expected a value but the text ended") }
            switch byte {
            case UInt8(ascii: "{"):
                if peekIsVariable() { try variable() } else { try object(depth: depth) }
            case UInt8(ascii: "["): try array(depth: depth)
            case UInt8(ascii: "\""): try string()
            case UInt8(ascii: "t"): try literal("true")
            case UInt8(ascii: "f"): try literal("false")
            case UInt8(ascii: "n"): try literal("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): try number()
            default: throw failure("Expected a value")
            }
        }

        mutating func object(depth: Int) throws {
            index += 1
            skipWhitespace()
            if current == UInt8(ascii: "}") {
                index += 1
                write("{}")
                return
            }
            write("{")
            while true {
                newline(depth + 1)
                skipWhitespace()
                guard current == UInt8(ascii: "\"") else {
                    throw failure("Expected a key in double quotes")
                }
                try string()
                skipWhitespace()
                guard current == UInt8(ascii: ":") else { throw failure("Expected : after the key") }
                index += 1
                write(": ")
                try value(depth: depth + 1)
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    index += 1
                    write(",")
                    continue
                }
                guard current == UInt8(ascii: "}") else { throw failure("Expected , or }") }
                index += 1
                newline(depth)
                write("}")
                return
            }
        }

        mutating func array(depth: Int) throws {
            index += 1
            skipWhitespace()
            if current == UInt8(ascii: "]") {
                index += 1
                write("[]")
                return
            }
            write("[")
            while true {
                newline(depth + 1)
                try value(depth: depth + 1)
                skipWhitespace()
                if current == UInt8(ascii: ",") {
                    index += 1
                    write(",")
                    continue
                }
                guard current == UInt8(ascii: "]") else { throw failure("Expected , or ]") }
                index += 1
                newline(depth)
                write("]")
                return
            }
        }

        mutating func string() throws {
            let start = index
            index += 1
            while let byte = current {
                switch byte {
                case UInt8(ascii: "\\"):
                    index += 2
                case UInt8(ascii: "\""):
                    index += 1
                    output.append(contentsOf: bytes[start..<index])
                    return
                case 0x0A:
                    throw failure("Line break inside a string")
                default:
                    index += 1
                }
            }
            index = start
            throw failure("This string is never closed")
        }

        mutating func number() throws {
            let start = index
            if current == UInt8(ascii: "-") { index += 1 }
            guard digits() else { throw failure("Expected a number") }
            if current == UInt8(ascii: ".") {
                index += 1
                guard digits() else { throw failure("Expected digits after the decimal point") }
            }
            if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
                index += 1
                if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
                guard digits() else { throw failure("Expected digits in the exponent") }
            }
            output.append(contentsOf: bytes[start..<index])
        }

        mutating func digits() -> Bool {
            let start = index
            while let byte = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) { index += 1 }
            return index > start
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard index + expected.count <= bytes.count,
                  Array(bytes[index..<(index + expected.count)]) == expected else {
                throw failure("Expected a value")
            }
            index += expected.count
            output.append(contentsOf: expected)
        }

        func peekIsVariable() -> Bool {
            index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "{")
        }

        mutating func variable() throws {
            let start = index
            while index + 1 < bytes.count {
                if bytes[index] == UInt8(ascii: "}"), bytes[index + 1] == UInt8(ascii: "}") {
                    index += 2
                    output.append(contentsOf: bytes[start..<index])
                    return
                }
                index += 1
            }
            index = start
            throw failure("This {{variable}} is never closed")
        }

        mutating func write(_ text: String) {
            output.append(contentsOf: text.utf8)
        }

        mutating func newline(_ depth: Int) {
            output.append(0x0A)
            output.append(contentsOf: repeatElement(0x20, count: depth * 2))
        }

        func failure(_ message: String) -> Failure {
            var line = 1
            var column = 1
            for byte in bytes[..<min(index, bytes.count)] {
                if byte == 0x0A {
                    line += 1
                    column = 1
                } else if byte & 0xC0 != 0x80 {
                    column += 1
                }
            }
            return Failure(message: message, line: line, column: column)
        }
    }
}
