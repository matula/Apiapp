import Foundation

/// `Apiapp --mcp`: a Model Context Protocol server over stdin and stdout, one JSON-RPC
/// message per line, so Claude and other MCP clients can work with the library.
struct MCPServer {
    /// Newest first. A client asking for another version gets the newest, and decides for itself.
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    static let instructions = """
        Apiapp is the user's Mac API client. These tools read and change its saved requests, folders \
        and environments, which show up in the app straight away. Prefer {{baseUrl}}-style variables \
        to hard-coded hosts. Never put a real password, token or API key in a request or environment: \
        reference a secret variable instead, and the user types its value in Apiapp.
        """

    let tools: LibraryTools

    static func runOverStandardIO() {
        let root = Store.defaultRoot
        let server = MCPServer(tools: LibraryTools(store: Store(root: root)) {
            LibraryChangeNotice.post(root: root)
        })
        while let line = readLine(strippingNewline: true) {
            guard let reply = server.reply(to: line) else { continue }
            FileHandle.standardOutput.write(Data((reply + "\n").utf8))
        }
    }

    /// The line to write back, or nil when the message was a notification.
    func reply(to line: String) -> String? {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let response: JSONValue?
        do {
            response = handle(try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)))
        } catch {
            response = Self.error(id: .null, code: -32700, message: "Parse error: the line isn't JSON")
        }
        guard let response, let data = try? Self.encoder.encode(response) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return encoder
    }()

    func handle(_ message: JSONValue) -> JSONValue? {
        let id = message["id"]
        guard let method = message["method"]?.stringValue else {
            // A reply to a request of ours, which this server never sends.
            if message["result"] != nil || message["error"] != nil { return nil }
            return Self.error(id: id ?? .null, code: -32600, message: "Invalid request: no method")
        }
        guard let id else { return nil }
        let params = message["params"] ?? [:]

        switch method {
        case "initialize":
            return Self.result(id: id, initializeResult(requestedVersion: params["protocolVersion"]?.stringValue))
        case "ping":
            return Self.result(id: id, [:])
        case "tools/list":
            return Self.result(id: id, ["tools": .array(LibraryTools.definitions)])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.error(id: id, code: -32602, message: "Invalid params: tools/call needs a name")
            }
            guard let result = tools.call(name, arguments: params["arguments"] ?? [:]) else {
                return Self.error(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            return Self.result(id: id, [
                "content": [["type": "text", "text": .string(result.text)]],
                "isError": .bool(result.isError),
            ])
        default:
            return Self.error(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initializeResult(requestedVersion: String?) -> JSONValue {
        let version = requestedVersion.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "apiapp", "title": "Apiapp", "version": .string(appVersion)],
            "instructions": .string(Self.instructions),
        ]
    }

    private static func result(id: JSONValue, _ result: JSONValue) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .int(code), "message": .string(message)]]
    }
}

/// Tells a running Apiapp that the library files changed under it. The data folder's path
/// goes along, so an app using a different folder ignores it.
enum LibraryChangeNotice {
    static let name = Notification.Name("local.apiapp.mac.libraryChanged")

    static func post(root: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: root.standardizedFileURL.path, userInfo: nil, deliverImmediately: true
        )
    }

    static func observe(root: URL, _ handler: @escaping @Sendable () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(
            forName: name, object: root.standardizedFileURL.path, queue: .main
        ) { _ in handler() }
    }
}
