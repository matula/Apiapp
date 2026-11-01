import Foundation

/// Keeps the URL's query string and the params table in step. Works on plain text
/// because URLs here can hold `{{variables}}`, which `URLComponents` won't parse.
enum QuerySync {
    struct Parts: Equatable {
        var base: String
        var query: String?
        var fragment: String?
    }

    static func split(_ url: String) -> Parts {
        var rest = Substring(url)
        var fragment: String?
        if let hash = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hash)...])
            rest = rest[..<hash]
        }
        var query: String?
        if let mark = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: mark)...])
            rest = rest[..<mark]
        }
        return Parts(base: String(rest), query: query, fragment: fragment)
    }

    /// Rows for the URL's query. Rows that were switched off aren't in the URL, so they're kept.
    static func params(from url: String, keeping existing: [KeyValue]) -> [KeyValue] {
        let pieces = (split(url).query ?? "").split(separator: "&", omittingEmptySubsequences: true)
        let enabledRows = existing.filter(\.isEnabled)
        var rows: [KeyValue] = pieces.enumerated().map { index, piece in
            let pair = piece.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            var row = index < enabledRows.count ? enabledRows[index] : KeyValue()
            row.key = decode(String(pair[0]))
            row.value = pair.count > 1 ? decode(String(pair[1])) : ""
            return row
        }
        rows.append(contentsOf: existing.filter { !$0.isEnabled })
        return rows
    }

    /// The URL with its query rebuilt from the enabled rows.
    static func url(_ url: String, applying params: [KeyValue]) -> String {
        var parts = split(url)
        let pieces = params.filter { $0.isEnabled && !($0.key.isEmpty && $0.value.isEmpty) }.map { row in
            let key = encode(row.key, extra: "=")
            return row.value.isEmpty ? key : "\(key)=\(encode(row.value, extra: ""))"
        }
        parts.query = pieces.isEmpty ? nil : pieces.joined(separator: "&")
        var result = parts.base
        if let query = parts.query { result += "?\(query)" }
        if let fragment = parts.fragment { result += "#\(fragment)" }
        return result
    }

    private static func decode(_ text: String) -> String {
        text.removingPercentEncoding ?? text
    }

    // Only the characters that would change how the query parses. Spaces and the
    // like stay readable in the URL field and are encoded when the request is sent.
    private static func encode(_ text: String, extra: String) -> String {
        var result = text.replacingOccurrences(of: "%", with: "%25")
        result = result.replacingOccurrences(of: "&", with: "%26")
        result = result.replacingOccurrences(of: "#", with: "%23")
        if extra.contains("=") { result = result.replacingOccurrences(of: "=", with: "%3D") }
        return result
    }
}
