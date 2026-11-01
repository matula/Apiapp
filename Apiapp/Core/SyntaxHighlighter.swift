import Foundation

enum CodeLanguage: Sendable {
    case json, headers, plain
}

enum TokenKind: Equatable, Sendable {
    case key, string, number, literal, punctuation, variable
}

struct SyntaxToken: Equatable, Sendable {
    var range: NSRange
    var kind: TokenKind
}

/// Finds what to colour. Works on UTF-16 offsets because that's what `NSTextView` uses.
enum SyntaxHighlighter {
    static func tokens(in text: String, language: CodeLanguage) -> [SyntaxToken] {
        switch language {
        case .json: json(Array(text.utf16))
        case .headers: headers(Array(text.utf16))
        case .plain: variables(Array(text.utf16))
        }
    }

    private static func json(_ units: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var index = 0
        let count = units.count

        while index < count {
            let unit = units[index]
            switch unit {
            case quote:
                let start = index
                index += 1
                while index < count, units[index] != quote, units[index] != newline {
                    index += units[index] == backslash ? 2 : 1
                }
                index = min(index + 1, count)
                var next = index
                while next < count, isSpace(units[next]) { next += 1 }
                let isKey = next < count && units[next] == colon
                tokens.append(SyntaxToken(range: NSRange(location: start, length: index - start), kind: isKey ? .key : .string))
            case openBrace where index + 1 < count && units[index + 1] == openBrace:
                index = variable(units, at: index, into: &tokens)
            case openBrace, closeBrace, openBracket, closeBracket, comma, colon:
                tokens.append(SyntaxToken(range: NSRange(location: index, length: 1), kind: .punctuation))
                index += 1
            case minus, 0x30...0x39:
                let start = index
                index += 1
                while index < count, isNumberPart(units[index]) { index += 1 }
                tokens.append(SyntaxToken(range: NSRange(location: start, length: index - start), kind: .number))
            case 0x74, 0x66, 0x6E: // t, f, n
                let start = index
                while index < count, isLetter(units[index]) { index += 1 }
                let word = String(decoding: units[start..<index], as: UTF16.self)
                if word == "true" || word == "false" || word == "null" {
                    tokens.append(SyntaxToken(range: NSRange(location: start, length: index - start), kind: .literal))
                }
            default:
                index += 1
            }
        }
        return tokens
    }

    private static func variables(_ units: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var index = 0
        while index + 1 < units.count {
            if units[index] == openBrace, units[index + 1] == openBrace {
                index = variable(units, at: index, into: &tokens)
            } else {
                index += 1
            }
        }
        return tokens
    }

    private static func headers(_ units: [UInt16]) -> [SyntaxToken] {
        var tokens: [SyntaxToken] = []
        var lineStart = 0
        var foundColon = false
        for (index, unit) in units.enumerated() {
            if unit == newline {
                lineStart = index + 1
                foundColon = false
            } else if unit == colon, !foundColon {
                tokens.append(SyntaxToken(range: NSRange(location: lineStart, length: index - lineStart), kind: .key))
                foundColon = true
            }
        }
        return tokens
    }

    /// Records `{{name}}` if it closes, and returns where to carry on.
    private static func variable(_ units: [UInt16], at start: Int, into tokens: inout [SyntaxToken]) -> Int {
        var index = start + 2
        while index + 1 < units.count, units[index] != newline {
            if units[index] == closeBrace, units[index + 1] == closeBrace {
                tokens.append(SyntaxToken(range: NSRange(location: start, length: index + 2 - start), kind: .variable))
                return index + 2
            }
            index += 1
        }
        return start + 1
    }

    private static let quote: UInt16 = 0x22
    private static let backslash: UInt16 = 0x5C
    private static let newline: UInt16 = 0x0A
    private static let openBrace: UInt16 = 0x7B
    private static let closeBrace: UInt16 = 0x7D
    private static let openBracket: UInt16 = 0x5B
    private static let closeBracket: UInt16 = 0x5D
    private static let comma: UInt16 = 0x2C
    private static let colon: UInt16 = 0x3A
    private static let minus: UInt16 = 0x2D

    private static func isSpace(_ unit: UInt16) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    private static func isLetter(_ unit: UInt16) -> Bool {
        (0x61...0x7A).contains(unit) || (0x41...0x5A).contains(unit)
    }

    private static func isNumberPart(_ unit: UInt16) -> Bool {
        (0x30...0x39).contains(unit) || unit == 0x2E || unit == 0x2B || unit == minus || unit == 0x65 || unit == 0x45
    }
}
