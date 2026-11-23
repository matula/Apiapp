import Foundation

struct ToolResult: Equatable {
    var text: String
    var isError = false
}

/// A problem with a tool call. The client sees it as the tool's result, so it can correct
/// the call, rather than as a protocol error.
struct ToolError: LocalizedError {
    var errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

/// The MCP server's tools. Every call reads the files afresh, since the app may have
/// changed them since the last one.
struct LibraryTools {
    let store: Store
    /// Runs after anything is written, to tell a running Apiapp.
    let announceChange: () -> Void

    init(store: Store, announceChange: @escaping () -> Void = {}) {
        self.store = store
        self.announceChange = announceChange
    }

    /// Nil when there's no tool by that name.
    func call(_ name: String, arguments: JSONValue) -> ToolResult? {
        let tool: (JSONValue) throws -> String
        switch name {
        case "list_library": tool = listLibrary
        case "get_request": tool = getRequest
        case "save_request": tool = saveRequest
        case "create_folder": tool = createFolder
        case "save_environment": tool = saveEnvironment
        default: return nil
        }
        do {
            return ToolResult(text: try tool(arguments))
        } catch let error as DecodingError {
            return ToolResult(text: Self.describe(error), isError: true)
        } catch {
            return ToolResult(text: error.localizedDescription, isError: true)
        }
    }

    // MARK: list_library

    private func listLibrary(_ arguments: JSONValue) throws -> String {
        let library = try store.loadLibrary()
        let folderNames = Dictionary(library.folders.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let requests = library.requests
            .map { saved in
                RequestEntry(
                    id: saved.id,
                    name: saved.request.displayName,
                    method: saved.request.method,
                    url: saved.request.url,
                    folder: saved.folderID.flatMap { folderNames[$0] }
                )
            }
            .sorted { ($0.folder ?? "", $0.name) < ($1.folder ?? "", $1.name) }
        let listing = LibraryListing(
            folders: library.folders
                .map { FolderEntry(id: $0.id, name: $0.name) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            requests: requests,
            environments: (library.environments ?? []).map(EnvironmentEntry.init),
            unreadableFiles: library.unreadableFiles.isEmpty ? nil : library.unreadableFiles
        )
        return try Self.json(listing)
    }

    // MARK: get_request

    private func getRequest(_ arguments: JSONValue) throws -> String {
        let query = try arguments.decode(as: RequestQuery.self)
        let library = try store.loadLibrary()
        let saved: SavedRequest
        if let id = query.id {
            guard let match = library.requests.first(where: { $0.id == id }) else {
                throw ToolError("No saved request has the id \(id). list_library shows every id.")
            }
            saved = match
        } else if let name = query.name {
            let matches = library.requests.filter { Self.sameName($0.request.displayName, name) }
            guard let match = matches.first else {
                throw ToolError("No saved request is called “\(name)”. list_library shows every request.")
            }
            guard matches.count == 1 else {
                let ids = matches.map(\.id.uuidString).joined(separator: ", ")
                throw ToolError("\(matches.count) saved requests are called “\(name)”. Pass one of these ids instead: \(ids)")
            }
            saved = match
        } else {
            throw ToolError("Pass the request's id or its name.")
        }
        return try Self.json(RequestDetails(saved, folders: library.folders))
    }

    // MARK: save_request

    private func saveRequest(_ arguments: JSONValue) throws -> String {
        let input = try arguments.decode(as: SaveRequestInput.self)
        let library = try store.loadLibrary()
        var notes: [String] = []

        var saved: SavedRequest
        if let id = input.id {
            guard let existing = library.requests.first(where: { $0.id == id }) else {
                throw ToolError("No saved request has the id \(id). Leave id out to create a new request.")
            }
            saved = existing
        } else {
            guard input.name?.trimmingCharacters(in: .whitespaces).isEmpty == false, input.url?.isEmpty == false else {
                throw ToolError("A new request needs a name and a url.")
            }
            saved = SavedRequest(request: RequestDraft())
        }
        let isNew = input.id == nil
        var draft = saved.request

        if let name = input.name {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ToolError("name can't be empty.") }
            draft.name = trimmed
        }
        if let method = input.method {
            guard let parsed = HTTPMethod(rawValue: method.uppercased()) else {
                throw ToolError("method must be one of \(HTTPMethod.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            draft.method = parsed
        }
        if let url = input.url { draft.setURL(url.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let rows = input.headers {
            try Self.checkCredentialHeaders(rows)
            draft.headers = rows.map(\.keyValue)
        }

        let bodyType = try input.bodyType.map(Self.bodyType) ?? (isNew ? Self.defaultBodyType(for: input, method: draft.method) : nil)
        if let bodyType { draft.bodyType = bodyType }
        let headersNameContentType = input.headers?.contains { RequestDraft.isContentType($0.key) } ?? false
        if !headersNameContentType, isNew || input.headers != nil || bodyType != nil {
            draft.addAutomaticContentType()
        }
        if let body = input.body { draft.bodyText = try Self.bodyText(from: body, type: draft.bodyType, notes: &notes) }
        if let rows = input.formFields { draft.formFields = rows.map(\.keyValue) }
        if let rows = input.multipartFields { draft.multipartFields = rows.map(\.field) }
        if let auth = input.auth { draft.auth = try auth.applied(to: draft.auth) }

        if !draft.method.allowsBody, draft.bodyType != .none, !draft.bodyText.isEmpty {
            notes.append("\(draft.method.rawValue) can't carry a body, so Apiapp will warn when it's sent.")
        }

        var folders = library.folders
        if let reference = input.folder {
            try Self.requireReadable("folders.json", in: library)
            let (folder, created) = Self.folder(matching: reference, in: &folders)
            saved.folderID = folder?.id
            if let folder, created {
                try store.save(folders: folders)
                notes.append("Made a new folder, “\(folder.name)”.")
            }
        }

        saved.request = draft
        saved.updatedAt = Date()
        try store.save(saved)
        announceChange()

        let undefined = Self.undefinedVariables(in: draft, environments: library.environments ?? [])
        if !undefined.isEmpty {
            notes.append("Not defined in any environment yet: \(undefined.joined(separator: ", ")). Add them with save_environment.")
        }
        return try Self.json(SaveRequestReply(request: RequestDetails(saved, folders: folders), notes: notes.isEmpty ? nil : notes))
    }

    private static func defaultBodyType(for input: SaveRequestInput, method: HTTPMethod) -> BodyType {
        if input.body != nil { return .json }
        if input.formFields != nil { return .form }
        if input.multipartFields != nil { return .multipart }
        return method.allowsBody ? .json : .none
    }

    private static func bodyType(_ name: String) throws -> BodyType {
        guard let type = BodyType(rawValue: name.lowercased()) else {
            throw ToolError("bodyType must be one of \(BodyType.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        return type
    }

    /// Text is kept as written, though JSON is laid out the way the app's Format command does.
    private static func bodyText(from value: JSONValue, type: BodyType, notes: inout [String]) throws -> String {
        switch value {
        case .null:
            return ""
        case .string(let text):
            guard type == .json, !text.isEmpty else { return text }
            do {
                return try JSONFormatter.format(text)
            } catch {
                notes.append("The body isn't valid JSON (\(error.localizedDescription)), so it was saved as written.")
                return text
            }
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let text = String(decoding: try encoder.encode(value), as: UTF8.self)
            return (try? JSONFormatter.format(text)) ?? text
        }
    }

    private static func checkCredentialHeaders(_ rows: [Row]) throws {
        let credentialHeaders = ["authorization", "proxy-authorization"]
        for row in rows where credentialHeaders.contains(row.key.trimmingCharacters(in: .whitespaces).lowercased()) {
            guard VariableResolver.unresolved(in: row.value).isEmpty else { continue }
            throw ToolError("""
                The \(row.key) header has to use a {{variable}}, such as “Bearer {{token}}”, since headers are \
                saved as plain text. Better still, use auth with kind bearer and token {{token}}. Make the \
                variable secret with save_environment, and the user types its value in Apiapp.
                """)
        }
    }

    private static func undefinedVariables(in draft: RequestDraft, environments: [RequestEnvironment]) -> [String] {
        let defined = Set(environments.flatMap(\.variables).map(\.key))
        var texts = [draft.url, draft.bodyText, draft.auth.token, draft.auth.username, draft.auth.password, draft.auth.apiKeyValue]
        texts += (draft.headers + draft.formFields).flatMap { [$0.key, $0.value] }
        texts += draft.multipartFields.flatMap { [$0.key, $0.value] }
        var seen = Set<String>()
        return texts
            .flatMap(VariableResolver.unresolved(in:))
            .filter { !defined.contains($0) && seen.insert($0).inserted }
    }

    // MARK: create_folder

    private func createFolder(_ arguments: JSONValue) throws -> String {
        let input = try arguments.decode(as: CreateFolderInput.self)
        let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ToolError("name can't be empty.") }
        let library = try store.loadLibrary()
        try Self.requireReadable("folders.json", in: library)
        var folders = library.folders
        let (match, created) = Self.folder(matching: name, in: &folders)
        guard let folder = match else { throw ToolError("name can't be empty.") }
        if created {
            try store.save(folders: folders)
            announceChange()
        }
        return try Self.json(CreateFolderReply(folder: FolderEntry(id: folder.id, name: folder.name), created: created))
    }

    /// An id or name, matched without regard to case. A name nothing matches becomes a new
    /// folder. An empty reference is the main list, which is no folder.
    private static func folder(matching reference: String, in folders: inout [Folder]) -> (folder: Folder?, created: Bool) {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !reference.isEmpty else { return (nil, false) }
        if let id = UUID(uuidString: reference), let match = folders.first(where: { $0.id == id }) { return (match, false) }
        if let match = folders.first(where: { sameName($0.name, reference) }) { return (match, false) }
        let folder = Folder(name: reference)
        folders.append(folder)
        return (folder, true)
    }

    // MARK: save_environment

    private func saveEnvironment(_ arguments: JSONValue) throws -> String {
        let input = try arguments.decode(as: SaveEnvironmentInput.self)
        let library = try store.loadLibrary()
        try Self.requireReadable("environments.json", in: library)
        var environments = library.environments ?? []
        var notes: [String] = []

        let index: Int
        if let id = input.id {
            guard let match = environments.firstIndex(where: { $0.id == id }) else {
                throw ToolError("No environment has the id \(id). list_library shows every id.")
            }
            index = match
        } else if let name = input.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            if let match = environments.firstIndex(where: { Self.sameName($0.name, name) }) {
                index = match
            } else {
                environments.append(RequestEnvironment(name: name))
                index = environments.count - 1
                notes.append("Made a new environment, “\(name)”. Pick it in Apiapp's environment menu to use it.")
            }
        } else {
            throw ToolError("Pass the environment's id or its name.")
        }

        for row in input.variables ?? [] {
            let key = row.key.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { throw ToolError("Every variable needs a key.") }
            var variable = environments[index].variables.first { $0.key == key } ?? Variable(key: key)
            let wasSecret = variable.isSecret
            let hadValue = !variable.value.isEmpty
            if let secret = row.secret { variable.isSecret = secret }
            if let enabled = row.enabled { variable.isEnabled = enabled }
            if variable.isSecret {
                if let value = row.value, !value.isEmpty {
                    throw ToolError("\(key) is secret, so its value can't be set here. The user types it in Apiapp, which keeps it in the Keychain.")
                }
                if !wasSecret {
                    let lost = hadValue ? " Its old value was taken out of the file," : ""
                    notes.append("\(key) is secret.\(lost) The user types its value in Apiapp's environment editor.")
                }
            } else if let value = row.value {
                variable.value = value
            }
            if let existing = environments[index].variables.firstIndex(where: { $0.key == key }) {
                environments[index].variables[existing] = variable
            } else {
                environments[index].variables.append(variable)
            }
        }

        try store.save(environments: environments)
        announceChange()
        return try Self.json(SaveEnvironmentReply(environment: EnvironmentEntry(environments[index]), notes: notes.isEmpty ? nil : notes))
    }

    // MARK: Helpers

    private static func requireReadable(_ file: String, in library: LibraryFiles) throws {
        guard library.unreadableFiles.contains(file) else { return }
        throw ToolError("\(file) in Apiapp's data folder couldn't be read, so it's being left alone. A copy ending in .broken is beside it.")
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    private static func json(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ codingPath: [CodingKey]) -> String {
            codingPath.reduce("") { text, key in
                if let index = key.intValue { return text + "[\(index)]" }
                return text.isEmpty ? key.stringValue : text + "." + key.stringValue
            }
        }
        switch error {
        case .keyNotFound(let key, let context):
            return "Invalid arguments: \(path(context.codingPath + [key])) is missing."
        case .typeMismatch(let type, let context):
            return "Invalid arguments: \(path(context.codingPath)) should be a \(type)."
        case .valueNotFound(_, let context):
            return "Invalid arguments: \(path(context.codingPath)) can't be null."
        case .dataCorrupted(let context):
            return "Invalid arguments: \(path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return "Invalid arguments: \(error.localizedDescription)"
        }
    }
}

// MARK: - Arguments and replies

extension LibraryTools {
    struct Row: Codable {
        var key: String
        var value: String
        var enabled: Bool?

        var keyValue: KeyValue { KeyValue(isEnabled: enabled ?? true, key: key, value: value) }

        init(_ row: KeyValue) {
            key = row.key
            value = row.value
            enabled = row.isEnabled ? nil : false
        }
    }

    struct MultipartRow: Codable {
        var key: String
        var value: String
        var kind: MultipartField.Kind?
        var enabled: Bool?

        var field: MultipartField { MultipartField(isEnabled: enabled ?? true, key: key, value: value, kind: kind ?? .text) }

        init(_ field: MultipartField) {
            key = field.key
            value = field.value
            kind = field.kind
            enabled = field.isEnabled ? nil : false
        }
    }

    /// The auth fields that are set. Secret fields only ever hold a `{{variable}}`.
    struct Auth: Codable {
        var kind: AuthConfig.Kind
        var token: String?
        var username: String?
        var password: String?
        var apiKeyName: String?
        var apiKeyValue: String?
        var apiKeyPlacement: AuthConfig.Placement?

        init(_ auth: AuthConfig) {
            kind = auth.kind
            switch auth.kind {
            case .none: break
            case .bearer: token = auth.token.nonEmpty
            case .basic:
                username = auth.username.nonEmpty
                password = auth.password.nonEmpty
            case .apiKey:
                apiKeyName = auth.apiKeyName
                apiKeyValue = auth.apiKeyValue.nonEmpty
                apiKeyPlacement = auth.apiKeyPlacement
            }
        }

        func applied(to auth: AuthConfig) throws -> AuthConfig {
            for (field, value) in [("token", token), ("password", password), ("apiKeyValue", apiKeyValue)] {
                guard let value, !value.isEmpty, !AuthConfig.isVariableReference(value) else { continue }
                throw ToolError("""
                    auth.\(field) has to be a {{variable}} reference, such as {{\(field)}}, so the real value stays \
                    out of Apiapp's files. Make that variable secret with save_environment, and the user types its \
                    value in Apiapp.
                    """)
            }
            var auth = auth
            auth.kind = kind
            if let token { auth.token = token }
            if let username { auth.username = username }
            if let password { auth.password = password }
            if let apiKeyName { auth.apiKeyName = apiKeyName }
            if let apiKeyValue { auth.apiKeyValue = apiKeyValue }
            if let apiKeyPlacement { auth.apiKeyPlacement = apiKeyPlacement }
            return auth
        }
    }

    struct RequestQuery: Decodable {
        var id: UUID?
        var name: String?
    }

    struct SaveRequestInput: Decodable {
        var id: UUID?
        var name: String?
        var method: String?
        var url: String?
        var folder: String?
        var headers: [Row]?
        var bodyType: String?
        var body: JSONValue?
        var formFields: [Row]?
        var multipartFields: [MultipartRow]?
        var auth: Auth?
    }

    struct CreateFolderInput: Decodable {
        var name: String
    }

    struct SaveEnvironmentInput: Decodable {
        struct VariableRow: Decodable {
            var key: String
            var value: String?
            var secret: Bool?
            var enabled: Bool?
        }

        var id: UUID?
        var name: String?
        var variables: [VariableRow]?
    }

    struct FolderEntry: Encodable {
        var id: UUID
        var name: String
    }

    struct RequestEntry: Encodable {
        var id: UUID
        var name: String
        var method: HTTPMethod
        var url: String
        var folder: String?
    }

    struct EnvironmentEntry: Encodable {
        struct Entry: Encodable {
            var key: String
            var value: String?
            var secret: Bool?
            var enabled: Bool?
        }

        var id: UUID
        var name: String
        var variables: [Entry]

        init(_ environment: RequestEnvironment) {
            id = environment.id
            name = environment.name
            variables = environment.variables.map { variable in
                Entry(
                    key: variable.key,
                    value: variable.isSecret ? nil : variable.value,
                    secret: variable.isSecret ? true : nil,
                    enabled: variable.isEnabled ? nil : false
                )
            }
        }
    }

    struct LibraryListing: Encodable {
        var folders: [FolderEntry]
        var requests: [RequestEntry]
        var environments: [EnvironmentEntry]
        var unreadableFiles: [String]?
    }

    /// Uses save_request's names, so a reply can be edited and passed straight back.
    struct RequestDetails: Encodable {
        var id: UUID
        var name: String
        var folder: String?
        var method: HTTPMethod
        var url: String
        var headers: [Row]
        var bodyType: BodyType
        var body: String?
        var formFields: [Row]?
        var multipartFields: [MultipartRow]?
        var auth: Auth?
        var updatedAt: Date

        init(_ saved: SavedRequest, folders: [Folder]) {
            let draft = saved.request
            id = saved.id
            name = draft.displayName
            folder = folders.first { $0.id == saved.folderID }?.name
            method = draft.method
            url = draft.url
            headers = draft.headers.map(Row.init)
            bodyType = draft.bodyType
            body = draft.bodyText.nonEmpty
            formFields = draft.formFields.isEmpty ? nil : draft.formFields.map(Row.init)
            multipartFields = draft.multipartFields.isEmpty ? nil : draft.multipartFields.map(MultipartRow.init)
            auth = draft.auth.kind == .none ? nil : Auth(draft.auth)
            updatedAt = saved.updatedAt
        }
    }

    struct SaveRequestReply: Encodable {
        var request: RequestDetails
        var notes: [String]?
    }

    struct CreateFolderReply: Encodable {
        var folder: FolderEntry
        var created: Bool
    }

    struct SaveEnvironmentReply: Encodable {
        var environment: EnvironmentEntry
        var notes: [String]?
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
