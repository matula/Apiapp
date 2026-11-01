import Foundation
import Testing
@testable import Apiapp

/// Sends through the real networking stack to a loopback server, to check what
/// actually leaves the machine.
@Suite(.serialized) struct WireTests {
    private func send(_ draft: RequestDraft) async throws -> (raw: String, display: ResponseDisplay) {
        let server = try LocalEchoServer()
        let port = try await server.start()
        defer { server.stop() }

        var draft = draft
        draft.setURL("http://127.0.0.1:\(port)/v1/users?page=1")
        let request = try RequestBuilder.build(draft, variables: [:])
        let display = try await RequestRunner().send(request)
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
}
