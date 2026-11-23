import Foundation
import Testing
@testable import Apiapp

/// Polls for up to five seconds.
@MainActor
private func eventually(_ what: String, _ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(what)")
}

/// Calls a tool and reads its reply as JSON. A tool error fails the test, with its message.
@discardableResult
private func call(_ tools: LibraryTools, _ name: String, _ arguments: JSONValue = [:]) throws -> JSONValue {
    let result = try #require(tools.call(name, arguments: arguments))
    #expect(!result.isError, "\(result.text)")
    return try JSONDecoder().decode(JSONValue.self, from: Data(result.text.utf8))
}

private func callExpectingError(_ tools: LibraryTools, _ name: String, _ arguments: JSONValue) throws -> String {
    let result = try #require(tools.call(name, arguments: arguments))
    #expect(result.isError)
    return result.text
}

private let loginRequest: JSONValue = [
    "name": "Login",
    "method": "POST",
    "url": "{{baseUrl}}/auth/login",
    "folder": "Auth",
    "body": #"{"email": "{{email}}", "password": "{{password}}"}"#,
]

@Suite struct MCPServerTests {
    private let server = MCPServer(tools: LibraryTools(store: Store(root: URL(filePath: "/nonexistent"))))

    private func send(_ message: JSONValue) throws -> JSONValue? {
        let line = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        return try server.reply(to: line).map { try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
    }

    @Test func initializeAgreesOnAProtocolVersion() throws {
        let known = try send(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-03-26"]])
        #expect(known?["result"]?["protocolVersion"] == "2025-03-26")
        #expect(known?["result"]?["capabilities"]?["tools"] != nil)

        let unknown = try send(["jsonrpc": "2.0", "id": "a", "method": "initialize", "params": ["protocolVersion": "1999-01-01"]])
        #expect(unknown?["id"] == "a")
        #expect(unknown?["result"]?["protocolVersion"] == .string(MCPServer.protocolVersions[0]))
    }

    @Test func listsEveryTool() throws {
        let reply = try send(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])
        guard case .array(let tools)? = reply?["result"]?["tools"] else {
            Issue.record("No tools in \(String(describing: reply))")
            return
        }
        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(names == ["list_library", "get_request", "save_request", "create_folder", "save_environment"])
        #expect(tools.allSatisfy { $0["inputSchema"]?["type"] == "object" })
    }

    @Test func notificationsGetNoReply() throws {
        #expect(try send(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        #expect(server.reply(to: "") == nil)
    }

    @Test func badMessagesGetJSONRPCErrors() throws {
        #expect(try send(["jsonrpc": "2.0", "id": 3, "method": "resources/list"])?["error"]?["code"] == -32601)
        #expect(try send(["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "nope"]])?["error"]?["code"] == -32602)
        let garbled = try #require(server.reply(to: "{not json"))
        #expect(garbled.contains("-32700"))
    }
}

@MainActor
@Suite struct LibraryToolTests {
    @Test func savesALoginRequestTheAppCanOpen() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let tools = LibraryTools(store: Store(root: harness.root))

        let reply = try call(tools, "save_request", loginRequest)
        #expect(reply["notes"] != nil)

        let model = try await harness.model()
        let folder = try #require(model.folders.first { $0.name == "Auth" })
        let saved = try #require(model.requests(in: folder.id).first)
        #expect(saved.id.uuidString == reply["request"]?["id"]?.stringValue)
        #expect(saved.request.method == .post)
        #expect(saved.request.url == "{{baseUrl}}/auth/login")
        #expect(saved.request.bodyType == .json)
        #expect(saved.request.contentType?.value == "application/json")
        #expect(saved.request.bodyText == "{\n  \"email\": \"{{email}}\",\n  \"password\": \"{{password}}\"\n}")
    }

    @Test func updatingChangesOnlyTheFieldsGiven() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let tools = LibraryTools(store: Store(root: harness.root))
        let created = try call(tools, "save_request", loginRequest)
        let id = try #require(created["request"]?["id"])

        let updated = try call(tools, "save_request", ["id": id, "url": "{{baseUrl}}/v2/login?remember=1", "folder": ""])
        let request = try #require(updated["request"])
        #expect(request["name"] == "Login")
        #expect(request["method"] == "POST")
        #expect(request["folder"] == nil)
        #expect(request["body"]?.stringValue?.contains("{{email}}") == true)

        let saved = try #require(try Store(root: harness.root).loadLibrary().requests.first)
        #expect(saved.request.params.map(\.key) == ["remember"])
    }

    @Test func getRequestFindsByNameAndRoundTrips() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let tools = LibraryTools(store: Store(root: harness.root))
        try call(tools, "save_request", loginRequest)

        let found = try call(tools, "get_request", ["name": "login"])
        #expect(found["url"] == "{{baseUrl}}/auth/login")

        guard case .object(var fields) = found else { return }
        fields["id"] = nil
        fields["updatedAt"] = nil
        fields["name"] = "Login copy"
        try call(tools, "save_request", .object(fields))
        let copy = try #require(try Store(root: harness.root).loadLibrary().requests.first { $0.request.name == "Login copy" })
        let original = try #require(try Store(root: harness.root).loadLibrary().requests.first { $0.request.name == "Login" })
        #expect(copy.request.bodyText == original.request.bodyText)
        #expect(copy.request.headers == original.request.headers)
    }

    @Test func realSecretsAreRefusedAndNothingIsWritten() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let tools = LibraryTools(store: Store(root: harness.root))

        let token = try callExpectingError(tools, "save_request", [
            "name": "Me", "url": "https://api.test/me", "auth": ["kind": "bearer", "token": "tok-SECRET"],
        ])
        #expect(token.contains("{{variable}}"))
        #expect(!token.contains("tok-SECRET"))
        _ = try callExpectingError(tools, "save_request", [
            "name": "Me", "url": "https://api.test/me", "headers": [["key": "Authorization", "value": "Bearer tok-SECRET"]],
        ])
        _ = try callExpectingError(tools, "save_environment", [
            "name": "Prod", "variables": [["key": "token", "value": "tok-SECRET", "secret": true]],
        ])
        #expect(harness.files(in: "requests").isEmpty)
        #expect(try !harness.allFileText().contains("tok-SECRET"))

        try call(tools, "save_request", [
            "name": "Me", "url": "https://api.test/me",
            "auth": ["kind": "bearer", "token": "{{token}}"],
            "headers": [["key": "Authorization", "value": "Bearer {{token}}"]],
        ])
    }

    @Test func notesNameVariablesNoEnvironmentDefines() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let tools = LibraryTools(store: Store(root: harness.root))
        try call(tools, "save_environment", ["name": "Local", "variables": [["key": "baseUrl", "value": "http://localhost:3000"]]])

        let reply = try call(tools, "save_request", loginRequest)
        let notes = reply["notes"].map { "\($0)" } ?? ""
        #expect(notes.contains("email, password"))
        #expect(!notes.contains("baseUrl"))
    }

    @Test func foldersAreMatchedByNameAndMadeWhenMissing() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let tools = LibraryTools(store: Store(root: harness.root))

        #expect(try call(tools, "create_folder", ["name": "Auth"])["created"] == true)
        #expect(try call(tools, "create_folder", ["name": " auth "])["created"] == false)
        try call(tools, "save_request", loginRequest)
        #expect(try Store(root: harness.root).loadLibrary().folders.count == 1)
    }

    @Test func environmentsMergeVariablesByKey() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let tools = LibraryTools(store: Store(root: harness.root))
        try call(tools, "save_environment", ["name": "Staging", "variables": [
            ["key": "baseUrl", "value": "https://staging.test"],
            ["key": "email", "value": "qa@example.com"],
        ]])
        let before = try #require(try Store(root: harness.root).loadLibrary().environments?.first)

        try call(tools, "save_environment", ["name": "staging", "variables": [
            ["key": "baseUrl", "value": "https://staging2.test"],
            ["key": "password", "secret": true],
        ]])
        let after = try #require(try Store(root: harness.root).loadLibrary().environments)
        #expect(after.count == 1)
        #expect(after[0].variables.map(\.key) == ["baseUrl", "email", "password"])
        #expect(after[0].variables[0].value == "https://staging2.test")
        #expect(after[0].variables[0].id == before.variables[0].id)
        #expect(after[0].variables[2].isSecret)
    }

    @Test func anUnreadableEnvironmentsFileIsLeftAlone() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        try Store(root: harness.root).prepare()
        let file = harness.root.appending(path: "environments.json")
        try Data("not json".utf8).write(to: file)
        let tools = LibraryTools(store: Store(root: harness.root))

        let message = try callExpectingError(tools, "save_environment", ["name": "Local", "variables": [["key": "a", "value": "b"]]])
        #expect(message.contains("environments.json"))
        #expect(try String(contentsOf: file, encoding: .utf8) == "not json")
    }
}

@MainActor
@Suite struct LibraryReloadTests {
    @Test func theAppReloadsWhenTheServerAnnouncesAChange() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try await harness.model()
        model.watchForLibraryChanges()
        let root = harness.root
        let tools = LibraryTools(store: Store(root: root)) { LibraryChangeNotice.post(root: root) }

        try call(tools, "save_request", loginRequest)
        try await eventually("the new request to appear") { model.savedRequests.contains { $0.request.name == "Login" } }
        #expect(model.folders.map(\.name) == ["Auth"])
    }

    @Test func aCleanTabShowsTheNewVersionAndAnEditedOneKeepsItsEdits() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try await harness.model()
        let tools = LibraryTools(store: Store(root: harness.root))
        let id = try #require(try call(tools, "save_request", loginRequest)["request"]?["id"])
        await model.reloadLibrary()
        let savedID = try #require(UUID(uuidString: id.stringValue ?? ""))
        model.openSaved(savedID)
        let tabID = try #require(model.activeTabID)

        try call(tools, "save_request", ["id": id, "url": "{{baseUrl}}/v2/login"])
        await model.reloadLibrary()
        var tab = try #require(model.activeTab)
        #expect(tab.draft.url == "{{baseUrl}}/v2/login")
        #expect(!tab.isDirty)

        model.update(tabID) { $0.draft.bodyText = "{}" }
        try call(tools, "save_request", ["id": id, "url": "{{baseUrl}}/v3/login"])
        await model.reloadLibrary()
        tab = try #require(model.activeTab)
        #expect(tab.draft.bodyText == "{}")
        #expect(tab.baseline.url == "{{baseUrl}}/v3/login")
        #expect(tab.isDirty)
    }

    @Test func secretVariablesKeepTheirValuesThroughAReload() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try await harness.model()
        var environments = model.environments
        environments[0].variables.append(Variable(key: "password", value: "pw-SECRET", isSecret: true))
        model.updateEnvironments(environments)
        let name = environments[0].name

        try call(LibraryTools(store: Store(root: harness.root)), "save_environment", [
            "name": .string(name), "variables": [["key": "email", "value": "dev@example.com"]],
        ])
        await model.reloadLibrary()
        let variables = try #require(model.environments.first { $0.name == name }?.variables)
        #expect(variables.first { $0.key == "password" }?.value == "pw-SECRET")
        #expect(variables.first { $0.key == "email" }?.value == "dev@example.com")
        #expect(try !harness.allFileText().contains("pw-SECRET"))
    }

    @Test func aVariableReferenceReplacesATokenKeptInTheKeychain() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try await harness.model()
        let tabID = try #require(model.activeTabID)
        model.update(tabID) {
            $0.draft.setURL("https://api.test/me")
            $0.draft.auth.kind = .bearer
            $0.draft.auth.token = "tok-SECRET"
        }
        model.save(tabID: tabID, name: "Me", folderID: nil)
        let savedID = try #require(model.savedRequests.first?.id)

        try call(LibraryTools(store: Store(root: harness.root)), "save_request", [
            "id": .string(savedID.uuidString), "auth": ["kind": "bearer", "token": "{{token}}"],
        ])
        await model.reloadLibrary()
        #expect(model.savedRequests.first?.request.auth.token == "{{token}}")
        let relaunched = try await harness.model()
        #expect(relaunched.savedRequests.first?.request.auth.token == "{{token}}")
    }
}
