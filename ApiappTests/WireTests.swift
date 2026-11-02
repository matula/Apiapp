import Foundation
import Testing
@testable import Apiapp

/// Sends through the real networking stack to a loopback server, to check what
/// actually leaves the machine.
@Suite(.serialized) struct WireTests {
    /// Sends to the echo server. With `redirectingTo`, the request goes to a path the
    /// server answers with a 302 to that URL, so the echo comes from wherever it points.
    private func send(
        _ draft: RequestDraft,
        redirectingTo location: ((UInt16) -> String)? = nil,
        runner: RequestRunner = RequestRunner(),
        omittingContentLength: Bool = false
    ) async throws -> (raw: String, display: ResponseDisplay) {
        let server = try LocalEchoServer()
        let port = try await server.start()
        defer { server.stop() }
        server.redirectLocation = location?(port)
        server.omitsContentLength = omittingContentLength

        var draft = draft
        draft.setURL("http://127.0.0.1:\(port)\(location == nil ? "/v1/users?page=1" : "/redirect")")
        let request = try RequestBuilder.build(draft, variables: [:])
        let credentialHeaders = RequestBuilder.credentialHeaderNames(for: draft, variables: [:])
        let display = try await runner.send(request, credentialHeaders: credentialHeaders)
        let raw = try JSONDecoder().decode(String.self, from: display.snapshot.body)
        return (raw, display)
    }

    private func headerLines(_ raw: String) -> [String] {
        let head = raw.components(separatedBy: "\r\n\r\n")[0]
        return head.components(separatedBy: "\r\n").map { $0.lowercased() }
    }

    private func contentTypeLine(_ raw: String) -> String? {
        headerLines(raw).first { $0.hasPrefix("content-type:") }
    }

    private func jsonPost() -> RequestDraft {
        var draft = RequestDraft.blank()
        draft.method = .post
        draft.bodyText = #"{"name":"Ada"}"#
        return draft
    }

    @Test func sendsMethodPathAndBody() async throws {
        let (raw, display) = try await send(jsonPost())
        #expect(raw.hasPrefix("POST /v1/users?page=1 HTTP/1.1\r\n"))
        #expect(raw.hasSuffix(#"{"name":"Ada"}"#))
        #expect(contentTypeLine(raw) == "content-type: application/json")
        #expect(display.snapshot.statusCode == 201)
        #expect(display.snapshot.reason == "Created")
        #expect(display.snapshot.headers.contains(HeaderField(name: "X-Echo", value: "yes")))
        #expect(display.snapshot.duration > 0)
        #expect(display.snapshot.redirects.isEmpty)
    }

    @Test func removingContentTypeOnPOSTStopsTheFormDefault() async throws {
        var draft = jsonPost()
        draft.removeContentType()
        let (raw, _) = try await send(draft)
        #expect(contentTypeLine(raw) == "content-type:" || contentTypeLine(raw) == "content-type: ")
    }

    @Test(arguments: [HTTPMethod.put, .patch, .delete])
    func removingContentTypeLeavesItOut(method: HTTPMethod) async throws {
        var draft = jsonPost()
        draft.method = method
        draft.removeContentType()
        let (raw, _) = try await send(draft)
        #expect(contentTypeLine(raw) == nil)
        #expect(raw.hasSuffix(#"{"name":"Ada"}"#))
    }

    @Test func bearerTokenReachesTheServer() async throws {
        var draft = jsonPost()
        draft.auth.kind = .bearer
        draft.auth.token = "abc123"
        let (raw, _) = try await send(draft)
        #expect(raw.contains("Bearer abc123"))
    }

    @Test func getWithoutABodyHasNoContentType() async throws {
        var draft = RequestDraft.blank()
        draft.method = .get
        let (raw, _) = try await send(draft)
        #expect(raw.hasPrefix("GET "))
        #expect(contentTypeLine(raw) == nil)
    }

    @Test func multipartSendsItsBoundary() async throws {
        var draft = jsonPost()
        draft.setBodyType(.multipart)
        draft.multipartFields = [MultipartField(key: "title", value: "hello")]
        let (raw, _) = try await send(draft)
        #expect(contentTypeLine(raw)?.hasPrefix("content-type: multipart/form-data; boundary=") == true)
        #expect(raw.contains(#"name="title""#))
    }

    @Test func sameOriginRedirectKeepsCredentials() async throws {
        var draft = jsonPost()
        draft.auth.kind = .bearer
        draft.auth.token = "abc123"
        let (raw, display) = try await send(draft, redirectingTo: { "http://127.0.0.1:\($0)/v1/after" })
        #expect(raw.hasPrefix("GET /v1/after HTTP/1.1\r\n"))
        #expect(raw.contains("Bearer abc123"))
        #expect(display.snapshot.redirects.map(\.statusCode) == [302])
        #expect(display.snapshot.url.hasSuffix("/v1/after"))
        #expect(display.snapshot.redirectSummary.hasPrefix("Redirected (302) to http://127.0.0.1:"))
    }

    /// `localhost` and `127.0.0.1` are the same machine but different origins.
    @Test func crossOriginRedirectDropsOnlyTheCredentials() async throws {
        var draft = jsonPost()
        draft.auth.kind = .apiKey
        draft.auth.apiKeyValue = "k-SECRET"
        draft.headers.append(KeyValue(key: "Authorization", value: "Bearer typed-SECRET"))
        draft.headers.append(KeyValue(key: "X-Plain", value: "stays"))
        let (raw, display) = try await send(draft, redirectingTo: { "http://localhost:\($0)/v1/after" })
        #expect(raw.hasPrefix("GET /v1/after HTTP/1.1\r\n"))
        #expect(!raw.contains("SECRET"))
        #expect(headerLines(raw).contains("x-plain: stays"))
        #expect(display.snapshot.url.hasPrefix("http://localhost:"))
        #expect(display.snapshot.redirects.count == 1)
    }

    @Test func refusesABodyAnnouncedAsOverTheLimit() async throws {
        var draft = jsonPost()
        draft.bodyText = String(repeating: "x", count: 4096)
        await #expect(throws: ResponseError.tooLarge(limit: 1024)) {
            try await send(draft, runner: RequestRunner(maximumBodySize: 1024))
        }
    }

    @Test func refusesABodyThatGrowsPastTheLimit() async throws {
        var draft = jsonPost()
        draft.bodyText = String(repeating: "x", count: 4096)
        await #expect(throws: ResponseError.tooLarge(limit: 1024)) {
            try await send(draft, runner: RequestRunner(maximumBodySize: 1024), omittingContentLength: true)
        }
    }

    @Test func theLimitLeavesSmallerBodiesAlone() async throws {
        let (raw, display) = try await send(jsonPost(), runner: RequestRunner(maximumBodySize: 1024 * 1024), omittingContentLength: true)
        #expect(raw.hasSuffix(#"{"name":"Ada"}"#))
        #expect(display.snapshot.statusCode == 201)
    }
}
