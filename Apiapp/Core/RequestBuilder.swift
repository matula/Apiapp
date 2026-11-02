import Foundation

enum RequestBuildError: LocalizedError, Equatable {
    case missingURL
    case invalidURL(String)
    case unknownVariables([String])
    case bodyNotAllowed(HTTPMethod)
    case unreadableFile(String)

    var errorDescription: String? {
        switch self {
        case .missingURL:
            "Enter a URL to send this request."
        case .invalidURL(let url):
            "“\(url)” isn’t a valid URL."
        case .unknownVariables(let names):
            "Not set in this environment: \(names.map { "{{\($0)}}" }.joined(separator: ", "))"
        case .bodyNotAllowed(let method):
            "macOS can’t send a body with \(method.rawValue). Clear the body, set its type to None, or use another method."
        case .unreadableFile(let path):
            "Couldn’t read the file at \(path)."
        }
    }
}

/// Turns a request as edited in a tab into a `URLRequest`, ready to send.
enum RequestBuilder {
    /// A request that has been checked, with its body still to be put together. Checking
    /// happens as soon as Send is pressed, so mistakes show at once. Assembling may read
    /// upload files, so the app does it away from the main thread.
    struct Plan: Sendable {
        fileprivate var request: URLRequest
        fileprivate var body: Body

        fileprivate enum Body: Sendable {
            case none
            case bytes(Data)
            case multipart(parts: [Part], boundary: String)

            var isEmpty: Bool {
                switch self {
                case .none: true
                case .bytes(let data): data.isEmpty
                case .multipart: false
                }
            }
        }

        fileprivate struct Part: Sendable {
            var name: String
            var kind: MultipartField.Kind
            /// The text to send, or the path of the file to send.
            var value: String
        }
    }

    static func build(_ draft: RequestDraft, variables: [String: String], boundary: String = "Apiapp-\(UUID().uuidString)") throws -> URLRequest {
        try assemble(plan(draft, variables: variables, boundary: boundary))
    }

    static func plan(_ draft: RequestDraft, variables: [String: String], boundary: String = "Apiapp-\(UUID().uuidString)") throws -> Plan {
        var missing: [String] = []
        func fill(_ text: String) -> String {
            let result = VariableResolver.resolve(text, values: variables)
            missing.append(contentsOf: VariableResolver.unresolved(in: result))
            return result
        }

        var urlText = fill(draft.url).trimmingCharacters(in: .whitespacesAndNewlines)
        var headers: [(name: String, value: String)] = draft.headers
            .filter { $0.isEnabled && !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { (fill($0.key).trimmingCharacters(in: .whitespaces), fill($0.value)) }

        switch draft.auth.kind {
        case .none:
            break
        case .bearer:
            setHeader(&headers, "Authorization", "Bearer \(fill(draft.auth.token))")
        case .basic:
            let credentials = "\(fill(draft.auth.username)):\(fill(draft.auth.password))"
            setHeader(&headers, "Authorization", "Basic \(Data(credentials.utf8).base64EncodedString())")
        case .apiKey:
            let name = fill(draft.auth.apiKeyName)
            let value = fill(draft.auth.apiKeyValue)
            if draft.auth.apiKeyPlacement == .header {
                setHeader(&headers, name, value)
            } else {
                urlText = appendingQuery(name: name, value: value, to: urlText)
            }
        }

        if !missing.isEmpty {
            var seen = Set<String>()
            throw RequestBuildError.unknownVariables(missing.filter { seen.insert($0).inserted })
        }
        guard !urlText.isEmpty else { throw RequestBuildError.missingURL }
        guard let url = makeURL(urlText) else { throw RequestBuildError.invalidURL(urlText) }

        let body = try planBody(draft, variables: variables, boundary: boundary)
        let hasBody = !body.isEmpty
        if hasBody, !draft.method.allowsBody { throw RequestBuildError.bodyNotAllowed(draft.method) }

        var request = URLRequest(url: url)
        request.httpMethod = draft.method.rawValue

        // Without a body, a Content-Type that the body type picked has nothing to describe.
        if !hasBody, draft.isContentTypeAutomatic {
            headers.removeAll { RequestDraft.isContentType($0.name) }
        }
        for header in headers {
            request.addValue(header.value, forHTTPHeaderField: header.name)
        }
        if draft.bodyType == .multipart, hasBody,
           let contentType = headers.first(where: { RequestDraft.isContentType($0.name) })?.value,
           !contentType.contains("boundary=") {
            request.setValue("\(contentType); boundary=\(boundary)", forHTTPHeaderField: RequestDraft.contentTypeHeader)
        }
        // URLSession fills in a form Content-Type on any POST body that has none. A blank
        // value is the only way to stop it, so that's what a removed header becomes.
        if draft.method == .post, hasBody, request.value(forHTTPHeaderField: RequestDraft.contentTypeHeader) == nil {
            request.setValue("", forHTTPHeaderField: RequestDraft.contentTypeHeader)
        }
        return Plan(request: request, body: hasBody ? body : .none)
    }

    /// Adds the body to a planned request, reading any upload files.
    static func assemble(_ plan: Plan) throws -> URLRequest {
        var request = plan.request
        switch plan.body {
        case .none:
            break
        case .bytes(let data):
            request.httpBody = data
        case .multipart(let parts, let boundary):
            request.httpBody = try multipartBody(parts, boundary: boundary)
        }
        return request
    }

    /// The headers that carry credentials. The runner lets them follow a redirect to the
    /// same origin only, as curl does.
    static func credentialHeaderNames(for draft: RequestDraft, variables: [String: String]) -> Set<String> {
        var names: Set<String> = ["Authorization"]
        if draft.auth.kind == .apiKey, draft.auth.apiKeyPlacement == .header {
            names.insert(VariableResolver.resolve(draft.auth.apiKeyName, values: variables))
        }
        return names
    }

    private static func setHeader(_ headers: inout [(name: String, value: String)], _ name: String, _ value: String) {
        headers.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        headers.append((name, value))
    }

    private static func appendingQuery(name: String, value: String, to url: String) -> String {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        var parts = QuerySync.split(url)
        parts.query = [parts.query, "\(encodedName)=\(encodedValue)"].compactMap { $0 }.joined(separator: "&")
        return parts.base + "?\(parts.query!)" + (parts.fragment.map { "#\($0)" } ?? "")
    }

    /// Accepts `localhost:3000/x` and `api.example.com/x` as well as full URLs.
    private static func makeURL(_ text: String) -> URL? {
        var candidate = text
        if !candidate.contains("://") {
            let host = candidate.prefix { $0 != "/" && $0 != ":" && $0 != "?" }
            let isLocal = ["localhost", "127.0.0.1", "0.0.0.0", "[", ""].contains(String(host))
            candidate = (isLocal ? "http://" : "https://") + candidate
        }
        guard let url = URL(string: candidate, encodingInvalidCharacters: true),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host() != nil else { return nil }
        return url
    }

    private static func planBody(_ draft: RequestDraft, variables: [String: String], boundary: String) throws -> Plan.Body {
        func fill(_ text: String) -> String { VariableResolver.resolve(text, values: variables) }

        switch draft.bodyType {
        case .none:
            return .none
        case .json, .raw:
            // Double braces can be real content in a body, so unknown names are left as typed.
            return .bytes(Data(fill(draft.bodyText).utf8))
        case .form:
            let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._*"))
            let pieces = draft.formFields.filter { $0.isEnabled && !$0.key.isEmpty }.map { field -> String in
                func encode(_ text: String) -> String {
                    let encoded = text.addingPercentEncoding(withAllowedCharacters: allowed.union(.whitespaces)) ?? text
                    return encoded.replacingOccurrences(of: " ", with: "+")
                }
                return "\(encode(fill(field.key)))=\(encode(fill(field.value)))"
            }
            return .bytes(Data(pieces.joined(separator: "&").utf8))
        case .multipart:
            let fields = draft.multipartFields.filter { $0.isEnabled && !$0.key.isEmpty }
            guard !fields.isEmpty else { return .none }
            let parts = try fields.map { field -> Plan.Part in
                let value = fill(field.value)
                // Checked now, so a missing file is reported straight away like any other mistake.
                if field.kind == .file, !FileManager.default.isReadableFile(atPath: value) {
                    throw RequestBuildError.unreadableFile(value)
                }
                return Plan.Part(name: fill(field.key), kind: field.kind, value: value)
            }
            return .multipart(parts: parts, boundary: boundary)
        }
    }

    private static func multipartBody(_ parts: [Plan.Part], boundary: String) throws -> Data {
        var data = Data()
        for part in parts {
            let name = quoted(part.name)
            data.append(Data("--\(boundary)\r\n".utf8))
            switch part.kind {
            case .text:
                data.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
                data.append(Data(part.value.utf8))
            case .file:
                guard let contents = FileManager.default.contents(atPath: part.value) else {
                    throw RequestBuildError.unreadableFile(part.value)
                }
                let filename = quoted((part.value as NSString).lastPathComponent)
                data.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
                data.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
                data.append(contents)
            }
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    private static func quoted(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
