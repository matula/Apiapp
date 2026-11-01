import Foundation

struct HeaderField: Codable, Equatable, Sendable {
    var name: String
    var value: String
}

/// One step of a redirect: the status that sent the request on, and where it went.
struct RedirectHop: Codable, Equatable, Sendable {
    var statusCode: Int
    var url: String
}

/// What came back from the server.
struct ResponseSnapshot: Equatable, Sendable {
    var statusCode: Int
    var headers: [HeaderField]
    var body: Data
    var duration: TimeInterval
    /// Where the response came from, which after a redirect isn't where the request went.
    var url: String
    var redirects: [RedirectHop] = []

    /// One line for the response pane, such as "Redirected (301) to https://…".
    var redirectSummary: String {
        let codes = redirects.map { String($0.statusCode) }.joined(separator: ", ")
        let lead = redirects.count == 1 ? "Redirected" : "Redirected \(redirects.count) times"
        return "\(lead) (\(codes)) to \(url)"
    }

    /// The standard phrase for the code. Foundation's own text calls 200 "no error".
    var reason: String {
        Self.reasons[statusCode] ?? HTTPURLResponse.localizedString(forStatusCode: statusCode).capitalized
    }

    private static let reasons: [Int: String] = [
        200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content",
        301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
        307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 409: "Conflict",
        410: "Gone", 412: "Precondition Failed", 413: "Content Too Large", 415: "Unsupported Media Type",
        418: "I'm a Teapot", 422: "Unprocessable Content", 429: "Too Many Requests",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
        503: "Service Unavailable", 504: "Gateway Timeout",
    ]

    var contentType: String? {
        headers.first { $0.name.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
    }
}

// Text bodies are stored as text so a saved response stays readable in its file.
extension ResponseSnapshot: Codable {
    private enum CodingKeys: String, CodingKey {
        case statusCode, headers, bodyText, bodyBase64, duration, url, redirects
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        statusCode = try c.decode(Int.self, forKey: .statusCode)
        headers = try c.decode([HeaderField].self, forKey: .headers)
        duration = try c.decode(TimeInterval.self, forKey: .duration)
        url = try c.decode(String.self, forKey: .url)
        redirects = try c.decodeIfPresent([RedirectHop].self, forKey: .redirects) ?? []
        if let text = try c.decodeIfPresent(String.self, forKey: .bodyText) {
            body = Data(text.utf8)
        } else {
            let encoded = try c.decodeIfPresent(String.self, forKey: .bodyBase64) ?? ""
            body = Data(base64Encoded: encoded) ?? Data()
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(statusCode, forKey: .statusCode)
        try c.encode(headers, forKey: .headers)
        try c.encode(duration, forKey: .duration)
        try c.encode(url, forKey: .url)
        if !redirects.isEmpty { try c.encode(redirects, forKey: .redirects) }
        if let text = String(data: body, encoding: .utf8) {
            try c.encode(text, forKey: .bodyText)
        } else {
            try c.encode(body.base64EncodedString(), forKey: .bodyBase64)
        }
    }
}

/// A response made ready for the viewer. Built off the main thread.
struct ResponseDisplay: Equatable, Sendable {
    var snapshot: ResponseSnapshot
    var bodyText: String
    var headersText: String
    var language: CodeLanguage
    var isBinary: Bool

    init(_ snapshot: ResponseSnapshot) {
        self.snapshot = snapshot
        headersText = snapshot.headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n")

        guard let text = ResponseText.decode(snapshot.body, contentType: snapshot.contentType) else {
            isBinary = true
            bodyText = ""
            language = .plain
            return
        }
        isBinary = false
        if ResponseText.looksLikeJSON(text, contentType: snapshot.contentType), let pretty = try? JSONFormatter.format(text) {
            bodyText = pretty
            language = .json
        } else {
            bodyText = text
            language = .plain
        }
    }
}

enum ResponseText {
    /// Returns nil for data that isn't text.
    static func decode(_ data: Data, contentType: String?) -> String? {
        if data.isEmpty { return "" }
        if data.prefix(8192).contains(0) { return nil }
        if let text = String(data: data, encoding: charset(in: contentType) ?? .utf8) { return text }
        if contentType?.lowercased().hasPrefix("text/") == true {
            return String(data: data, encoding: .isoLatin1)
        }
        return nil
    }

    static func looksLikeJSON(_ text: String, contentType: String?) -> Bool {
        if contentType?.lowercased().contains("json") == true { return true }
        guard let first = text.first(where: { !$0.isWhitespace }) else { return false }
        return first == "{" || first == "["
    }

    private static func charset(in contentType: String?) -> String.Encoding? {
        guard let match = contentType?.lowercased().firstMatch(of: /charset="?([a-z0-9._-]+)/) else { return nil }
        switch match.1 {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "latin1": return .isoLatin1
        case "windows-1252": return .windowsCP1252
        case "us-ascii", "ascii": return .ascii
        case "utf-16": return .utf16
        default: return nil
        }
    }
}
