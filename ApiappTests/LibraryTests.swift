import Foundation
import Testing
@testable import Apiapp

/// Answers every request with a canned response, without touching the network.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url ?? URL(string: "https://stub.test")!
        if url.path().hasPrefix("/down") {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        if url.path().hasPrefix("/hang") { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"ok":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
struct Harness {
    let root = FileManager.default.temporaryDirectory.appending(path: "ApiappTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    let storage = InMemorySecretStorage()

    func model() throws -> AppModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return AppModel(store: Store(root: root), vault: try SecretVault(storage: storage), runner: RequestRunner(configuration: configuration))
    }

    func files(in directory: String) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: root.appending(path: directory), includingPropertiesForKeys: nil)) ?? []
    }

    /// Everything on disk, joined up, for checking that secrets stayed out of it.
    func allFileText() throws -> String {
        var text = ""
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if let data = try? Data(contentsOf: url) { text += String(decoding: data, as: UTF8.self) }
        }
        return text
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private func waitUntilSent(_ model: AppModel, tabID: UUID) async throws {
    for _ in 0..<500 {
        if model.tabs.first(where: { $0.id == tabID })?.isSending == false { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for the request")
}

@MainActor
@Suite struct AppModelTests {
    @Test func startsWithOneBlankTabAndALocalEnvironment() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        #expect(model.tabs.count == 1)
        #expect(model.activeTab?.draft.bodyType == .json)
        #expect(model.activeEnvironment?.name == "Local")
        #expect(model.activeEnvironment?.resolvedValues["baseUrl"] == "http://localhost:3000")
    }

    @Test func sendingRecordsHistoryIncludingTheBody() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        model.update(tabID) {
            $0.draft.method = .post
            $0.draft.setURL("{{baseUrl}}/v1/users")
            $0.draft.bodyText = #"{"name":"Ada"}"#
        }
        model.send(tabID)
        try await waitUntilSent(model, tabID: tabID)

        #expect(model.activeTab?.response?.snapshot.statusCode == 200)
        #expect(model.history.count == 1)
        #expect(model.history[0].request.bodyText == #"{"name":"Ada"}"#)
        #expect(model.history[0].request.url == "{{baseUrl}}/v1/users")
        #expect(model.history[0].statusCode == 200)
        #expect(harness.files(in: "history").count == 1)

        let reloaded = try harness.model()
        #expect(reloaded.history.first?.request.bodyText == #"{"name":"Ada"}"#)
        #expect(reloaded.history.first?.statusCode == 200)
    }

    @Test func failedRequestsStillGoInHistory() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        model.update(tabID) { $0.draft.setURL("https://stub.test/down") }
        model.send(tabID)
        try await waitUntilSent(model, tabID: tabID)

        guard case .failed = model.activeTab?.phase else {
            Issue.record("Expected a failure")
            return
        }
        #expect(model.history.count == 1)
        #expect(model.history[0].statusCode == nil)
    }

    @Test func requestsThatNeverLeftAreNotInHistory() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        model.update(tabID) { $0.draft.setURL("{{nope}}/x") }
        model.send(tabID)
        guard case .failed(let message) = model.activeTab?.phase else {
            Issue.record("Expected a failure")
            return
        }
        #expect(message.contains("{{nope}}"))
        #expect(model.history.isEmpty)
    }

    @Test func sendingAgainCancels() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        model.update(tabID) { $0.draft.setURL("https://stub.test/hang") }
        model.send(tabID)
        #expect(model.activeTab?.isSending == true)
        model.send(tabID)
        try await waitUntilSent(model, tabID: tabID)
        #expect(model.activeTab?.phase == .cancelled)
    }

    @Test func historyIsCapped() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        model.update(tabID) { $0.draft.setURL("https://stub.test/ok") }
        for _ in 0..<(AppModel.historyLimit + 3) {
            model.send(tabID)
            try await waitUntilSent(model, tabID: tabID)
        }
        #expect(model.history.count == AppModel.historyLimit)
        #expect(harness.files(in: "history").count == AppModel.historyLimit)
    }

    @Test func clickingHistoryOpensATabWithEverythingAndItCanBeSaved() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        model.update(tabID) {
            $0.draft.method = .put
            $0.draft.setURL("https://stub.test/a?x=1")
            $0.draft.headers.append(KeyValue(key: "X-One", value: "1"))
            $0.draft.bodyText = "{}"
        }
        model.send(tabID)
        try await waitUntilSent(model, tabID: tabID)
        let entry = try #require(model.history.first)

        model.openHistory(entry.id)
        #expect(model.tabs.count == 2)
        #expect(model.activeTab?.draft == entry.request)
        #expect(model.activeTab?.isDirty == false)
        #expect(model.activeSidebarItem == .history(entry.id))

        model.openHistory(entry.id)
        #expect(model.tabs.count == 2)

        let opened = try #require(model.activeTabID)
        model.save(tabID: opened, name: "Update thing", folderID: nil)
        #expect(model.savedRequests.first?.request.name == "Update thing")
        #expect(model.savedRequests.first?.request.bodyText == "{}")
        #expect(model.activeTab?.savedRequestID == model.savedRequests.first?.id)
    }

    @Test func savesToAFolderOrTheMainList() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        let folder = model.addFolder(named: "Users")

        model.save(tabID: tabID, name: "In folder", folderID: folder.id)
        model.newTab()
        model.save(tabID: try #require(model.activeTabID), name: "On list", folderID: nil)

        #expect(model.requests(in: folder.id).map(\.request.name) == ["In folder"])
        #expect(model.requests(in: nil).map(\.request.name) == ["On list"])

        let reloaded = try harness.model()
        #expect(reloaded.folders.map(\.name) == ["Users"])
        #expect(reloaded.requests(in: folder.id).map(\.request.name) == ["In folder"])
    }

    @Test func saveUpdatesAnAlreadySavedRequest() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        model.save(tabID: tabID, name: "Thing", folderID: nil)

        model.update(tabID) { $0.draft.setURL("https://x.dev/new") }
        #expect(model.activeTab?.isDirty == true)
        model.saveActiveTab()

        #expect(model.saveTarget == nil)
        #expect(model.activeTab?.isDirty == false)
        #expect(model.savedRequests.count == 1)
        #expect(try harness.model().savedRequests.first?.request.url == "https://x.dev/new")
    }

    @Test func saveAsksWhereForANewRequest() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        model.saveActiveTab()
        #expect(model.saveTarget?.id == model.activeTabID)
    }

    @Test func openingASavedRequestTwiceReusesItsTab() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        model.save(tabID: try #require(model.activeTabID), name: "Thing", folderID: nil)
        let id = try #require(model.savedRequests.first?.id)
        model.newTab()
        model.openSaved(id)
        #expect(model.tabs.count == 2)
        #expect(model.activeSidebarItem == .saved(id))
    }

    @Test func movingARequestUpdatesItsFolder() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let folder = model.addFolder(named: "Users")
        model.save(tabID: try #require(model.activeTabID), name: "Thing", folderID: nil)
        let id = try #require(model.savedRequests.first?.id)

        model.move(savedRequest: id, to: folder.id)
        #expect(try harness.model().requests(in: folder.id).map(\.request.name) == ["Thing"])

        model.move(savedRequest: id, to: nil)
        #expect(try harness.model().requests(in: nil).map(\.request.name) == ["Thing"])
    }

    @Test func duplicatingAndRenamingARequest() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        model.save(tabID: try #require(model.activeTabID), name: "Thing", folderID: nil)
        let id = try #require(model.savedRequests.first?.id)

        model.duplicate(savedRequest: id)
        #expect(model.requests(in: nil).map(\.request.name) == ["Thing", "Thing copy"])

        model.rename(.request(id), to: "Renamed")
        #expect(model.activeTab?.draft.name == "Renamed")
        #expect(model.activeTab?.isDirty == false)
    }

    @Test func deletingAFolderKeepsItsRequests() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let folder = model.addFolder(named: "Users")
        model.save(tabID: try #require(model.activeTabID), name: "Thing", folderID: folder.id)
        model.delete(folder: folder.id)
        #expect(model.folders.isEmpty)
        #expect(model.requests(in: nil).map(\.request.name) == ["Thing"])
    }

    @Test func deletingASavedRequestLeavesItsTabOpenButUnsaved() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        model.save(tabID: try #require(model.activeTabID), name: "Thing", folderID: nil)
        let id = try #require(model.savedRequests.first?.id)
        model.delete(savedRequest: id)
        #expect(model.activeTab?.savedRequestID == nil)
        #expect(harness.files(in: "requests").isEmpty)
    }

    @Test func savedResponsesKeepTheRequestAndBody() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        model.update(tabID) { $0.draft.setURL("https://stub.test/ok") }
        model.send(tabID)
        try await waitUntilSent(model, tabID: tabID)
        model.saveActiveResponse()
        #expect(model.activeTab?.savedResponseID != nil)

        let reloaded = try harness.model()
        let saved = try #require(reloaded.savedResponses.first)
        #expect(saved.response.body == Data(#"{"ok":true}"#.utf8))
        reloaded.openSavedResponse(saved.id)
        #expect(reloaded.activeTab?.response?.bodyText == "{\n  \"ok\": true\n}")
        #expect(reloaded.activeTab?.draft.url == "https://stub.test/ok")
    }

    @Test func tabsComeBackAfterRelaunch() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        model.update(tabID) { $0.draft.setURL("https://x.dev/unsaved") }
        model.newTab()
        model.update(try #require(model.activeTabID)) { $0.draft.setURL("https://x.dev/second") }
        model.saveWorkspace()

        let reloaded = try harness.model()
        #expect(reloaded.tabs.map(\.draft.url) == ["https://x.dev/unsaved", "https://x.dev/second"])
        #expect(reloaded.activeTab?.draft.url == "https://x.dev/second")
    }

    @Test func closingTheLastTabLeavesABlankOne() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        model.close(try #require(model.activeTabID))
        #expect(model.tabs.count == 1)
        #expect(model.activeTab != nil)
    }

    @Test func closingAskOnlyWhenWorkWouldBeLost() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        model.update(tabID) { $0.draft.setURL("https://stub.test/ok") }

        model.requestClose(tabID)
        #expect(model.tabPendingClose == tabID)
        model.tabPendingClose = nil

        model.send(tabID)
        try await waitUntilSent(model, tabID: tabID)
        model.requestClose(tabID)
        #expect(model.tabPendingClose == nil)
    }

    @Test func formatReportsErrorsWithoutChangingTheBody() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        model.update(tabID) { $0.draft.bodyText = "{oops" }
        model.formatActiveBody()
        #expect(model.activeTab?.draft.bodyText == "{oops")
        #expect(model.activeTab?.bodyNotice?.contains("Line 1") == true)

        model.update(tabID) { $0.draft.bodyText = #"{"a":1}"# }
        model.formatActiveBody()
        #expect(model.activeTab?.draft.bodyText == "{\n  \"a\": 1\n}")
        #expect(model.activeTab?.bodyNotice == nil)
    }

    @Test func eachNewResponseCanBeSaved() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        model.update(tabID) { $0.draft.setURL("https://stub.test/ok") }
        model.send(tabID)
        try await waitUntilSent(model, tabID: tabID)
        model.saveActiveResponse()
        #expect(model.activeTab?.savedResponseID != nil)

        model.send(tabID)
        try await waitUntilSent(model, tabID: tabID)
        #expect(model.activeTab?.savedResponseID == nil)
        model.saveActiveResponse()
        #expect(model.savedResponses.count == 2)
    }

    @Test func requestsInAMissingFolderShowOnTheMainList() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let folder = model.addFolder(named: "Users")
        model.save(tabID: try #require(model.activeTabID), name: "Thing", folderID: folder.id)
        try FileManager.default.removeItem(at: harness.root.appending(path: "folders.json"))

        let reloaded = try harness.model()
        #expect(reloaded.folders.isEmpty)
        #expect(reloaded.requests(in: nil).map(\.request.name) == ["Thing"])
        #expect(reloaded.requests(in: nil).first?.folderID == folder.id)
    }

    @Test func anUnreadableEnvironmentsFileIsNotReplaced() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        _ = try harness.model()
        let file = harness.root.appending(path: "environments.json")
        try Data("not json".utf8).write(to: file)

        let model = try harness.model()
        #expect(model.alertMessage?.contains("environments.json") == true)
        #expect(model.environments.map(\.name) == ["Local"])
        #expect(String(decoding: try Data(contentsOf: file), as: UTF8.self) == "not json")
        #expect(FileManager.default.fileExists(atPath: harness.root.appending(path: "environments.json.broken").path))
    }

    @Test func unreadableFilesAreReportedNotDeleted() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        _ = try harness.model()
        let bad = harness.root.appending(path: "requests/broken.json")
        try Data("not json".utf8).write(to: bad)

        let model = try harness.model()
        #expect(model.alertMessage?.contains("broken.json") == true)
        #expect(FileManager.default.fileExists(atPath: bad.path))
    }
}

@MainActor
@Suite struct SecretTests {
    private func addSecrets(to model: AppModel, tabID: UUID) {
        model.update(tabID) {
            $0.draft.setURL("https://stub.test/ok")
            $0.draft.auth.kind = .bearer
            $0.draft.auth.token = "tok-SECRET-123"
        }
    }

    @Test func tokensStayOutOfEveryFile() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        addSecrets(to: model, tabID: tabID)

        model.save(tabID: tabID, name: "Secure", folderID: nil)
        model.send(tabID)
        try await waitUntilSent(model, tabID: tabID)
        model.saveActiveResponse()
        model.saveWorkspace()

        #expect(harness.files(in: "requests").count == 1)
        #expect(harness.files(in: "history").count == 1)
        #expect(harness.files(in: "responses").count == 1)
        #expect(try !harness.allFileText().contains("tok-SECRET-123"))
    }

    @Test func tokensComeBackFromTheVault() async throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        addSecrets(to: model, tabID: tabID)
        model.save(tabID: tabID, name: "Secure", folderID: nil)
        model.send(tabID)
        try await waitUntilSent(model, tabID: tabID)
        model.saveWorkspace()

        let reloaded = try harness.model()
        #expect(reloaded.savedRequests.first?.request.auth.token == "tok-SECRET-123")
        #expect(reloaded.history.first?.request.auth.token == "tok-SECRET-123")
        #expect(reloaded.activeTab?.draft.auth.token == "tok-SECRET-123")
        #expect(reloaded.activeTab?.isDirty == false)
    }

    @Test func variableReferencesStayInTheFile() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        model.update(tabID) {
            $0.draft.auth.kind = .bearer
            $0.draft.auth.token = "{{token}}"
        }
        model.save(tabID: tabID, name: "Ref", folderID: nil)
        #expect(try harness.allFileText().contains("{{token}}"))
        #expect(try harness.model().savedRequests.first?.request.auth.token == "{{token}}")
    }

    @Test func secretVariablesStayOutOfTheEnvironmentsFile() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        var environments = model.environments
        environments[0].variables.append(Variable(key: "token", value: "var-SECRET-456", isSecret: true))
        environments[0].variables.append(Variable(key: "plain", value: "visible-value"))
        model.updateEnvironments(environments)

        let text = try harness.allFileText()
        #expect(!text.contains("var-SECRET-456"))
        #expect(text.contains("visible-value"))

        let reloaded = try harness.model()
        #expect(reloaded.activeEnvironment?.resolvedValues["token"] == "var-SECRET-456")
    }

    @Test func deletingThingsRemovesTheirSecrets() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        addSecrets(to: model, tabID: tabID)
        model.save(tabID: tabID, name: "Secure", folderID: nil)
        let id = try #require(model.savedRequests.first?.id)
        model.delete(savedRequest: id)
        model.close(tabID)

        let vault = try SecretVault(storage: harness.storage)
        #expect(vault.values(for: id).isEmpty)
        #expect(vault.values(for: tabID).isEmpty)
    }

    @Test func aFailedLoadLeavesSecretsAlone() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        addSecrets(to: model, tabID: tabID)
        model.save(tabID: tabID, name: "Secure", folderID: nil)
        let id = try #require(model.savedRequests.first?.id)

        // A file where the requests directory should be makes the whole load fail.
        let requests = harness.root.appending(path: "requests")
        try FileManager.default.removeItem(at: requests)
        try Data().write(to: requests)
        let broken = try harness.model()
        #expect(broken.alertMessage != nil)
        #expect(broken.savedRequests.isEmpty)
        #expect(try SecretVault(storage: harness.storage).values(for: id)["token"] == "tok-SECRET-123")
    }

    @Test func anUnreadableRequestKeepsItsSecrets() throws {
        let harness = Harness()
        defer { harness.cleanUp() }
        let model = try harness.model()
        let tabID = try #require(model.activeTabID)
        addSecrets(to: model, tabID: tabID)
        model.save(tabID: tabID, name: "Secure", folderID: nil)
        let id = try #require(model.savedRequests.first?.id)
        try Data("not json".utf8).write(to: harness.root.appending(path: "requests/\(id.uuidString).json"))

        let reloaded = try harness.model()
        #expect(reloaded.savedRequests.isEmpty)
        #expect(reloaded.alertMessage?.contains(id.uuidString) == true)
        #expect(try SecretVault(storage: harness.storage).values(for: id)["token"] == "tok-SECRET-123")
    }

    @Test func keychainRoundTrip() throws {
        let storage = KeychainSecretStorage(service: "local.apiapp.mac.tests.\(UUID().uuidString)")
        defer { try? storage.delete() }
        #expect(try storage.load() == nil)

        let owner = UUID()
        let vault = try SecretVault(storage: storage)
        try vault.set(["token": "first"], for: owner)
        try vault.set(["token": "second"], for: owner)

        #expect(try SecretVault(storage: storage).values(for: owner) == ["token": "second"])
        try storage.delete()
        #expect(try storage.load() == nil)
    }

    @Test func aFailedVaultReadIsNotTreatedAsEmpty() {
        final class FailingStorage: SecretStorage {
            func load() throws -> Data? { throw KeychainError(status: errSecAuthFailed) }
            func save(_ data: Data) throws {}
        }
        #expect(throws: KeychainError.self) { try SecretVault(storage: FailingStorage()) }
    }
}
