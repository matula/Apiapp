import Foundation

/// Swaps `{{name}}` placeholders for the active environment's values.
enum VariableResolver {
    /// A value may refer to another variable, so substitution runs a few times.
    private static let maxPasses = 5

    static func resolve(_ text: String, values: [String: String]) -> String {
        guard text.contains("{{") else { return text }
        var result = text
        for _ in 0..<maxPasses {
            let next = result.replacing(/\{\{\s*([^{}\s]+)\s*\}\}/) { match in
                values[String(match.1)] ?? String(match.0)
            }
            if next == result { break }
            result = next
        }
        return result
    }

    /// Names still unfilled in `text`, in the order they appear.
    static func unresolved(in text: String) -> [String] {
        text.matches(of: /\{\{\s*([^{}\s]+)\s*\}\}/).map { String($0.1) }
    }
}
