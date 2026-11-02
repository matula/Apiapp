import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Apiapp

@Suite struct JSONFormatterTests {
    @Test func indentsWithTwoSpaces() throws {
        let output = try JSONFormatter.format(#"{"a":1,"b":[true,null],"c":{}}"#)
        #expect(output == """
        {
          "a": 1,
          "b": [
            true,
            null
          ],
          "c": {}
        }
        """)
    }

    @Test func keepsKeyOrderAndNumberText() throws {
        let output = try JSONFormatter.format(#"{"z":1.0,"a":12345678901234567890,"m":1e3}"#)
        #expect(output == """
        {
          "z": 1.0,
          "a": 12345678901234567890,
          "m": 1e3
        }
        """)
    }

    @Test func keepsEscapesAndUnicode() throws {
        let output = try JSONFormatter.format(#"{"text":"a \"quoted\" \\ é ☃"}"#)
        #expect(output == "{\n  \"text\": \"a \\\"quoted\\\" \\\\ é ☃\"\n}")
    }

    @Test func allowsBareVariables() throws {
        let output = try JSONFormatter.format(#"{"id":{{userId}},"name":"{{name}}"}"#)
        #expect(output == "{\n  \"id\": {{userId}},\n  \"name\": \"{{name}}\"\n}")
    }

    @Test func isStableWhenRunTwice() throws {
        let once = try JSONFormatter.format(#"[{"a":[1,2]},{"b":{}}]"#)
        #expect(try JSONFormatter.format(once) == once)
    }

    @Test func emptyTextStaysEmpty() throws {
        #expect(try JSONFormatter.format("  \n ") == "")
    }

    @Test(arguments: [
        (#"{"a":1"#, "Expected , or }"),
        (#"{"a" 1}"#, "Expected : after the key"),
        (#"{a:1}"#, "Expected a key in double quotes"),
        (#"[1,]"#, "Expected a value"),
        (#"{"a":1} extra"#, "Unexpected text after the end of the JSON"),
        (#""open"#, "This string is never closed"),
        (#"{"a":tru}"#, "Expected a value"),
        (#"-"#, "Expected a number"),
    ])
    func reportsSyntaxErrors(input: String, message: String) {
        #expect(throws: JSONFormatter.Failure.self) { try JSONFormatter.format(input) }
        do {
            _ = try JSONFormatter.format(input)
        } catch let failure as JSONFormatter.Failure {
            #expect(failure.message == message)
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test func reportsTheLineAndColumn() {
        do {
            _ = try JSONFormatter.format("{\n  \"a\": 1\n  \"b\": 2\n}")
            Issue.record("Should have failed")
        } catch let failure as JSONFormatter.Failure {
            #expect(failure.line == 3)
            #expect(failure.column == 3)
        } catch {
            Issue.record("Wrong error: \(error)")
        }
    }

    @Test func deepNestingFailsInsteadOfCrashing() {
        let text = String(repeating: "[", count: 100_000)
        #expect(throws: JSONFormatter.Failure.self) { try JSONFormatter.format(text) }
    }

    @Test func handlesNestingUpToTheLimit() throws {
        let depth = 199
        let text = String(repeating: "[", count: depth) + "1" + String(repeating: "]", count: depth)
        #expect(try JSONFormatter.format(text).contains("1"))
    }

    @Test func tooDeepResponseFallsBackToRawText() {
        let text = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        let snapshot = ResponseSnapshot(statusCode: 200, headers: [], body: Data(text.utf8), duration: 0, url: "")
        let display = ResponseDisplay(snapshot)
        #expect(display.bodyText == text)
        #expect(display.language == .plain)
    }
}

@Suite struct SyntaxHighlighterTests {
    private func kinds(_ text: String, _ language: CodeLanguage = .json) -> [(String, TokenKind)] {
        let string = text as NSString
        return SyntaxHighlighter.tokens(in: text, language: language).map { (string.substring(with: $0.range), $0.kind) }
    }

    @Test func tellsKeysFromStrings() {
        let tokens = kinds(#"{"name": "Ada"}"#).filter { $0.1 != .punctuation }
        #expect(tokens.map(\.0) == [#""name""#, #""Ada""#])
        #expect(tokens.map(\.1) == [.key, .string])
    }

    @Test func findsNumbersLiteralsAndVariables() {
        let tokens = kinds(#"[-1.5e3, true, {{id}}]"#).filter { $0.1 != .punctuation }
        #expect(tokens.map(\.0) == ["-1.5e3", "true", "{{id}}"])
        #expect(tokens.map(\.1) == [.number, .literal, .variable])
    }

    @Test func usesUTF16OffsetsAfterEmoji() {
        let tokens = kinds(#"{"😀": 1}"#).filter { $0.1 == .number }
        #expect(tokens.first?.0 == "1")
    }

    @Test func survivesUnterminatedString() {
        #expect(kinds(#"{"open"#).last?.0 == #""open"#)
    }

    @Test func colorsHeaderNames() {
        let tokens = kinds("Content-Type: text/plain\nX-Time: 10:30", .headers)
        #expect(tokens.map(\.0) == ["Content-Type", "X-Time"])
    }
}

@Suite struct QuerySyncTests {
    @Test func splitsURLWithVariables() {
        let parts = QuerySync.split("{{baseUrl}}/users?page=1#top")
        #expect(parts.base == "{{baseUrl}}/users")
        #expect(parts.query == "page=1")
        #expect(parts.fragment == "top")
    }

    @Test func urlEditsFillTheTable() {
        var draft = RequestDraft()
        draft.setURL("{{baseUrl}}/users?page=2&q=ada%20l&flag")
        #expect(draft.params.map(\.key) == ["page", "q", "flag"])
        #expect(draft.params.map(\.value) == ["2", "ada l", ""])
    }

    @Test func tableEditsRewriteTheURL() {
        var draft = RequestDraft()
        draft.setURL("https://x.dev/a?old=1#frag")
        draft.setParams([KeyValue(key: "new", value: "a&b"), KeyValue(key: "off", value: "1")])
        #expect(draft.url == "https://x.dev/a?new=a%26b&off=1#frag")
    }

    @Test func disabledRowsLeaveTheURLButStayInTheTable() {
        var draft = RequestDraft()
        draft.setURL("https://x.dev/a?keep=1&hide=2")
        var rows = draft.params
        rows[1].isEnabled = false
        draft.setParams(rows)
        #expect(draft.url == "https://x.dev/a?keep=1")
        #expect(draft.params.count == 2)

        draft.setURL("https://x.dev/a?keep=9")
        #expect(draft.params.map(\.key) == ["keep", "hide"])
        #expect(draft.params.map(\.value) == ["9", "2"])
        #expect(draft.params[1].isEnabled == false)
    }

    @Test func clearingEveryRowRemovesTheQuestionMark() {
        var draft = RequestDraft()
        draft.setURL("https://x.dev/a?one=1")
        draft.setParams([])
        #expect(draft.url == "https://x.dev/a")
    }

    @Test func typingKeepsRowIdentity() {
        var draft = RequestDraft()
        draft.setURL("https://x.dev/a?one=1")
        let id = draft.params[0].id
        draft.setURL("https://x.dev/a?one=12")
        #expect(draft.params[0].id == id)
    }

    @Test func plusSignsSurviveTheTable() {
        var draft = RequestDraft()
        draft.setURL("https://x.dev/a?literal=a%2Bb&spaced=c+d")
        #expect(draft.params.map(\.value) == ["a+b", "c d"])
        draft.setParams(draft.params)
        #expect(draft.url == "https://x.dev/a?literal=a%2Bb&spaced=c d")
        draft.setParams([KeyValue(key: "typed", value: "1+1")])
        #expect(draft.url == "https://x.dev/a?typed=1%2B1")
    }
}

@Suite struct ContentTypeTests {
    @Test func newRequestsStartWithJSON() {
        let draft = RequestDraft.blank()
        #expect(draft.bodyType == .json)
        #expect(draft.contentType?.value == "application/json")
        #expect(draft.isContentTypeAutomatic)
    }

    @Test func switchingBodyTypeUpdatesTheHeader() {
        var draft = RequestDraft.blank()
        draft.setBodyType(.form)
        #expect(draft.contentType?.value == "application/x-www-form-urlencoded")
        draft.setBodyType(.raw)
        #expect(draft.contentType?.value == "text/plain")
        #expect(draft.headers.count == 1)
    }

    @Test func noneRemovesTheHeader() {
        var draft = RequestDraft.blank()
        draft.setBodyType(.none)
        #expect(draft.contentType == nil)
    }

    @Test func removedHeaderCanBeAddedBack() {
        var draft = RequestDraft.blank()
        draft.removeContentType()
        #expect(draft.contentType == nil)
        draft.addAutomaticContentType()
        #expect(draft.contentType?.value == "application/json")
    }

    @Test func editedValueIsNoLongerAutomatic() {
        var draft = RequestDraft.blank()
        draft.headers[draft.contentTypeIndex!].value = "application/vnd.api+json"
        #expect(!draft.isContentTypeAutomatic)
    }

    @Test func matchesHeaderNameInAnyCase() {
        var draft = RequestDraft()
        draft.headers = [KeyValue(key: "content-type", value: "text/csv")]
        draft.setBodyType(.json)
        #expect(draft.headers.count == 1)
        #expect(draft.headers[0].value == "application/json")
    }

    @Test func keepsOtherHeaders() {
        var draft = RequestDraft.blank()
        draft.headers.append(KeyValue(key: "X-Thing", value: "1"))
        draft.setBodyType(.none)
        #expect(draft.headers.map(\.key) == ["X-Thing"])
    }
}

@Suite struct VariableResolverTests {
    @Test func fillsValues() {
        #expect(VariableResolver.resolve("{{a}}/{{ b }}", values: ["a": "1", "b": "2"]) == "1/2")
    }

    @Test func followsReferences() {
        #expect(VariableResolver.resolve("{{url}}", values: ["url": "{{host}}/v1", "host": "x.dev"]) == "x.dev/v1")
    }

    @Test func stopsOnCycles() {
        #expect(VariableResolver.resolve("{{a}}", values: ["a": "{{a}}"]) == "{{a}}")
    }

    @Test func listsWhatIsMissing() {
        #expect(VariableResolver.unresolved(in: "{{a}} and {{b}}") == ["a", "b"])
    }
}

@Suite struct RequestBuilderTests {
    private func draft(_ method: HTTPMethod = .post, url: String = "https://x.dev/users", body: String = #"{"a":1}"#) -> RequestDraft {
        var draft = RequestDraft.blank()
        draft.method = method
        draft.setURL(url)
        draft.bodyText = body
        return draft
    }

    @Test func fillsVariablesEverywhere() throws {
        var request = draft(url: "{{baseUrl}}/users")
        request.bodyText = #"{"id":{{id}}}"#
        request.headers.append(KeyValue(key: "X-Env", value: "{{env}}"))
        let built = try RequestBuilder.build(request, variables: ["baseUrl": "https://x.dev", "id": "7", "env": "qa"])
        #expect(built.url?.absoluteString == "https://x.dev/users")
        #expect(built.value(forHTTPHeaderField: "X-Env") == "qa")
        #expect(built.httpBody == Data(#"{"id":7}"#.utf8))
    }

    @Test func refusesUnknownVariablesInTheURL() {
        #expect(throws: RequestBuildError.unknownVariables(["baseUrl"])) {
            try RequestBuilder.build(draft(url: "{{baseUrl}}/users"), variables: [:])
        }
    }

    @Test func leavesUnknownVariablesInTheBody() throws {
        let built = try RequestBuilder.build(draft(body: "{{literally}}"), variables: [:])
        #expect(built.httpBody == Data("{{literally}}".utf8))
    }

    @Test func refusesAnEmptyURL() {
        #expect(throws: RequestBuildError.missingURL) {
            try RequestBuilder.build(draft(url: "  "), variables: [:])
        }
    }

    @Test(arguments: ["ftp://x.dev", "file:///etc/hosts", "http://"])
    func refusesBadURLs(url: String) {
        #expect(throws: RequestBuildError.self) {
            try RequestBuilder.build(draft(url: url), variables: [:])
        }
    }

    @Test func addsASchemeWhenMissing() throws {
        #expect(try RequestBuilder.build(draft(url: "localhost:3000/x"), variables: [:]).url?.absoluteString == "http://localhost:3000/x")
        #expect(try RequestBuilder.build(draft(url: "api.x.dev/x"), variables: [:]).url?.absoluteString == "https://api.x.dev/x")
    }

    @Test func encodesSpacesInTheURL() throws {
        let built = try RequestBuilder.build(draft(url: "https://x.dev/a?q=ada lovelace"), variables: [:])
        #expect(built.url?.absoluteString == "https://x.dev/a?q=ada%20lovelace")
    }

    @Test func skipsDisabledAndBlankHeaders() throws {
        var request = draft()
        request.headers.append(KeyValue(isEnabled: false, key: "X-Off", value: "1"))
        request.headers.append(KeyValue(key: "  ", value: "1"))
        let built = try RequestBuilder.build(request, variables: [:])
        #expect(built.value(forHTTPHeaderField: "X-Off") == nil)
        #expect(built.allHTTPHeaderFields?.count == 1)
    }

    @Test func dropsAutomaticContentTypeWithoutABody() throws {
        let built = try RequestBuilder.build(draft(.get, body: ""), variables: [:])
        #expect(built.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(built.httpBody == nil)
    }

    @Test func keepsAnEditedContentTypeWithoutABody() throws {
        var request = draft(.get, body: "")
        request.headers[request.contentTypeIndex!].value = "application/custom"
        let built = try RequestBuilder.build(request, variables: [:])
        #expect(built.value(forHTTPHeaderField: "Content-Type") == "application/custom")
    }

    @Test func removedContentTypeOnPOSTIsSentBlank() throws {
        var request = draft()
        request.removeContentType()
        let built = try RequestBuilder.build(request, variables: [:])
        #expect(built.value(forHTTPHeaderField: "Content-Type") == "")
    }

    @Test func removedContentTypeOnPUTIsLeftOut() throws {
        var request = draft(.put)
        request.removeContentType()
        let built = try RequestBuilder.build(request, variables: [:])
        #expect(built.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test func getWithABodyIsRefused() {
        #expect(throws: RequestBuildError.bodyNotAllowed(.get)) {
            try RequestBuilder.build(draft(.get), variables: [:])
        }
    }

    @Test func getIgnoresBodyTextWhenTypeIsNone() throws {
        var request = draft(.get)
        request.setBodyType(.none)
        #expect(try RequestBuilder.build(request, variables: [:]).httpBody == nil)
    }

    @Test func bearerAuth() throws {
        var request = draft()
        request.auth.kind = .bearer
        request.auth.token = "{{token}}"
        let built = try RequestBuilder.build(request, variables: ["token": "abc"])
        #expect(built.value(forHTTPHeaderField: "Authorization") == "Bearer abc")
    }

    @Test func basicAuth() throws {
        var request = draft()
        request.auth.kind = .basic
        request.auth.username = "ada"
        request.auth.password = "secret"
        let built = try RequestBuilder.build(request, variables: [:])
        #expect(built.value(forHTTPHeaderField: "Authorization") == "Basic YWRhOnNlY3JldA==")
    }

    @Test func authReplacesATypedHeader() throws {
        var request = draft()
        request.headers.append(KeyValue(key: "authorization", value: "old"))
        request.auth.kind = .bearer
        request.auth.token = "new"
        let built = try RequestBuilder.build(request, variables: [:])
        #expect(built.value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test func apiKeyInHeader() throws {
        var request = draft()
        request.auth.kind = .apiKey
        request.auth.apiKeyValue = "k1"
        let built = try RequestBuilder.build(request, variables: [:])
        #expect(built.value(forHTTPHeaderField: "X-API-Key") == "k1")
    }

    @Test func apiKeyInQuery() throws {
        var request = draft(url: "https://x.dev/a?x=1#f")
        request.auth.kind = .apiKey
        request.auth.apiKeyName = "key"
        request.auth.apiKeyValue = "a&b"
        request.auth.apiKeyPlacement = .query
        let built = try RequestBuilder.build(request, variables: [:])
        #expect(built.url?.absoluteString == "https://x.dev/a?x=1&key=a%26b#f")
        #expect(request.url == "https://x.dev/a?x=1#f")
    }

    @Test func missingAuthVariableIsRefused() {
        var request = draft()
        request.auth.kind = .bearer
        request.auth.token = "{{token}}"
        #expect(throws: RequestBuildError.unknownVariables(["token"])) {
            try RequestBuilder.build(request, variables: [:])
        }
    }

    @Test func formBody() throws {
        var request = draft()
        request.setBodyType(.form)
        request.formFields = [
            KeyValue(key: "name", value: "Ada L&"),
            KeyValue(isEnabled: false, key: "off", value: "1"),
            KeyValue(key: "id", value: "{{id}}"),
        ]
        let built = try RequestBuilder.build(request, variables: ["id": "7"])
        #expect(String(data: built.httpBody!, encoding: .utf8) == "name=Ada+L%26&id=7")
        #expect(built.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
    }

    @Test func multipartBody() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        try Data("file text".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var request = draft()
        request.setBodyType(.multipart)
        request.multipartFields = [
            MultipartField(key: "title", value: "hello"),
            MultipartField(key: "upload", value: file.path, kind: .file),
        ]
        let built = try RequestBuilder.build(request, variables: [:], boundary: "BOUND")
        #expect(built.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUND")
        #expect(String(data: built.httpBody!, encoding: .utf8) == """
        --BOUND\r
        Content-Disposition: form-data; name="title"\r
        \r
        hello\r
        --BOUND\r
        Content-Disposition: form-data; name="upload"; filename="\(file.lastPathComponent)"\r
        Content-Type: application/octet-stream\r
        \r
        file text\r
        --BOUND--\r

        """)
    }

    @Test func missingUploadFileIsReported() {
        var request = draft()
        request.setBodyType(.multipart)
        request.multipartFields = [MultipartField(key: "upload", value: "/no/such/file", kind: .file)]
        #expect(throws: RequestBuildError.unreadableFile("/no/such/file")) {
            try RequestBuilder.build(request, variables: [:])
        }
    }

    @Test func namesTheCredentialHeaders() {
        var request = draft()
        #expect(RequestBuilder.credentialHeaderNames(for: request, variables: [:]) == ["Authorization"])
        request.auth.kind = .apiKey
        request.auth.apiKeyName = "{{keyHeader}}"
        #expect(RequestBuilder.credentialHeaderNames(for: request, variables: ["keyHeader": "X-Key"]) == ["Authorization", "X-Key"])
        request.auth.apiKeyPlacement = .query
        #expect(RequestBuilder.credentialHeaderNames(for: request, variables: [:]) == ["Authorization"])
    }

    @Test func planningChecksUploadsAndAssemblingReadsThem() throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).txt")
        try Data("file text".utf8).write(to: file)
        var request = draft()
        request.setBodyType(.multipart)
        request.multipartFields = [MultipartField(key: "upload", value: file.path, kind: .file)]
        let plan = try RequestBuilder.plan(request, variables: [:], boundary: "BOUND")
        let assembled = try RequestBuilder.assemble(plan)
        #expect(assembled.httpBody.map { String(decoding: $0, as: UTF8.self) }?.contains("file text") == true)
        #expect(assembled.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUND")

        try FileManager.default.removeItem(at: file)
        #expect(throws: RequestBuildError.unreadableFile(file.path)) { try RequestBuilder.assemble(plan) }
        #expect(throws: RequestBuildError.unreadableFile(file.path)) { try RequestBuilder.plan(request, variables: [:]) }
    }
}

@Suite struct ResponseDisplayTests {
    private func snapshot(_ body: String, contentType: String) -> ResponseSnapshot {
        ResponseSnapshot(
            statusCode: 200,
            headers: [HeaderField(name: "Content-Type", value: contentType)],
            body: Data(body.utf8),
            duration: 0.1,
            url: "https://x.dev"
        )
    }

    @Test func prettyPrintsJSON() {
        let display = ResponseDisplay(snapshot(#"{"a":1}"#, contentType: "application/json; charset=utf-8"))
        #expect(display.bodyText == "{\n  \"a\": 1\n}")
        #expect(display.language == .json)
    }

    @Test func detectsJSONWithAWrongContentType() {
        #expect(ResponseDisplay(snapshot("[1]", contentType: "text/plain")).language == .json)
    }

    @Test func leavesInvalidJSONAlone() {
        let display = ResponseDisplay(snapshot("{oops", contentType: "application/json"))
        #expect(display.bodyText == "{oops")
        #expect(display.language == .plain)
    }

    @Test func leavesPlainTextAlone() {
        let display = ResponseDisplay(snapshot("hello", contentType: "text/plain"))
        #expect(display.bodyText == "hello")
    }

    @Test func recognizesBinaryData() {
        var value = snapshot("", contentType: "application/octet-stream")
        value.body = Data([0x00, 0x01, 0xFF])
        let display = ResponseDisplay(value)
        #expect(display.isBinary)
    }

    @Test func honorsCharset() {
        var value = snapshot("", contentType: "text/plain; charset=iso-8859-1")
        value.body = Data([0x63, 0x61, 0x66, 0xE9])
        #expect(ResponseDisplay(value).bodyText == "café")
    }

    @Test func listsHeaders() {
        #expect(ResponseDisplay(snapshot("", contentType: "a/b")).headersText == "Content-Type: a/b")
    }

    @Test func redirectsRoundTripAndOlderFilesHaveNone() throws {
        var value = snapshot("x", contentType: "text/plain")
        value.redirects = [RedirectHop(statusCode: 301, url: "https://x.dev/after")]
        value.url = "https://x.dev/after"
        let data = try JSONEncoder().encode(value)
        #expect(try JSONDecoder().decode(ResponseSnapshot.self, from: data) == value)
        #expect(value.redirectSummary == "Redirected (301) to https://x.dev/after")
        value.redirects.append(RedirectHop(statusCode: 302, url: "https://x.dev/after"))
        #expect(value.redirectSummary == "Redirected 2 times (301, 302) to https://x.dev/after")

        let older = #"{"statusCode":200,"headers":[],"bodyText":"x","duration":0.1,"url":"https://x.dev"}"#
        #expect(try JSONDecoder().decode(ResponseSnapshot.self, from: Data(older.utf8)).redirects.isEmpty)
    }
}

@Suite struct StatusTextTests {
    @Test(arguments: [(200, "OK"), (201, "Created"), (204, "No Content"), (404, "Not Found"), (500, "Internal Server Error")])
    func usesStandardPhrases(code: Int, phrase: String) {
        let snapshot = ResponseSnapshot(statusCode: code, headers: [], body: Data(), duration: 0, url: "")
        #expect(snapshot.reason == phrase)
    }
}

@Suite struct FormattingTests {
    @Test func durations() {
        #expect(Formatting.duration(0.184) == "184 ms")
        #expect(Formatting.duration(12.34) == "12.3 s")
    }

    @Test func sizes() {
        #expect(Formatting.size(312) == "312 B")
        #expect(Formatting.size(2048) == "2.0 KB")
        #expect(Formatting.size(3 * 1024 * 1024) == "3.0 MB")
    }

    @Test func ages() {
        let now = Date()
        #expect(Formatting.age(since: now.addingTimeInterval(-30), now: now) == "now")
        #expect(Formatting.age(since: now.addingTimeInterval(-120), now: now) == "2m")
        #expect(Formatting.age(since: now.addingTimeInterval(-7200), now: now) == "2h")
        #expect(Formatting.age(since: now.addingTimeInterval(-172800), now: now) == "2d")
    }
}

@MainActor
@Suite struct CodeEditorTests {
    private final class TextBox {
        var text = ""
    }

    @MainActor
    private struct Editor {
        var textView: NSTextView
        var coordinator: CodeEditor.Coordinator
        var ruler: LineNumberRuler

        var length: Int { (textView.string as NSString).length }

        func replace(_ range: NSRange, with text: String) {
            textView.insertText(text, replacementRange: range)
        }
    }

    /// The same TextKit stack `CodeEditor` builds, without a window.
    private func makeEditor(_ text: String, language: CodeLanguage = .json) -> Editor {
        let box = TextBox()
        let coordinator = CodeEditor.Coordinator(text: Binding(get: { box.text }, set: { box.text = $0 }), language: language)
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), textContainer: container)
        textView.isRichText = false
        textView.delegate = coordinator
        let scrollView = NSScrollView(frame: textView.frame)
        scrollView.documentView = textView
        let ruler = LineNumberRuler(textView: textView, scrollView: scrollView)
        coordinator.ruler = ruler
        coordinator.replaceAll(in: textView, with: text)
        return Editor(textView: textView, coordinator: coordinator, ruler: ruler)
    }

    private func colours(of editor: Editor) -> [ObjectIdentifier?] {
        guard let layoutManager = editor.textView.layoutManager else { return [] }
        return (0..<editor.length).map { index in
            (layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor).map(ObjectIdentifier.init)
        }
    }

    private func lineStarts(of text: String) -> [Int] {
        var starts = [0]
        for (index, unit) in text.utf16.enumerated() where unit == 0x0A { starts.append(index + 1) }
        return starts
    }

    @Test func editsRecolourOnlyNearbyLinesAndMatchAFullPass() {
        let editor = makeEditor("{\n  \"a\": 1,\n  \"b\": [true, null],\n  \"c\": \"{{name}}\"\n}")
        editor.replace(NSRange(location: 4, length: 0), with: "\"z\": -2.5e3, ")
        #expect(editor.coordinator.lastPassWasPartial)
        editor.replace(NSRange(location: 2, length: 1), with: "")
        editor.replace(NSRange(location: 1, length: 0), with: "\n  \"q\"\n  : false,")
        editor.replace(NSRange(location: editor.length, length: 0), with: "\n")
        let incremental = colours(of: editor)
        editor.coordinator.highlight(editor.textView)
        #expect(!editor.coordinator.lastPassWasPartial)
        #expect(colours(of: editor) == incremental)
        #expect(incremental.contains { $0 != nil })
        #expect(editor.coordinator.lastText == editor.textView.string)
    }

    @Test func lineNumbersKeepUpWithEdits() {
        let editor = makeEditor("one\ntwo\nthree")
        func check() {
            #expect(editor.ruler.lineStarts == lineStarts(of: editor.textView.string))
        }
        editor.replace(NSRange(location: 4, length: 0), with: "x\ny\n")
        check()
        editor.replace(NSRange(location: 2, length: 5), with: "")
        check()
        editor.replace(NSRange(location: editor.length, length: 0), with: "\n")
        check()
        editor.replace(NSRange(location: 0, length: 0), with: "ab\n")
        check()
        editor.replace(NSRange(location: 3, length: 2), with: "\n\n\n")
        check()
        editor.replace(NSRange(location: 0, length: editor.length), with: "")
        #expect(editor.ruler.lineStarts == [0])
    }
}
