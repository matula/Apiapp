import Foundation
import Synchronization

/// Sends requests. Nothing is cached and cookies aren't kept, so every send goes out
/// with exactly what the tab shows.
struct RequestRunner: Sendable {
    static let timeout: TimeInterval = 60

    private let session: URLSession

    init(configuration: URLSessionConfiguration = Self.defaultConfiguration()) {
        session = URLSession(configuration: configuration)
    }

    static func defaultConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = timeout
        return configuration
    }

    /// `credentialHeaders` names the headers that carry credentials. They follow a
    /// redirect to the same origin and nowhere else.
    func send(_ request: URLRequest, credentialHeaders: Set<String> = ["Authorization"]) async throws -> ResponseDisplay {
        let policy = RedirectPolicy(original: request, credentialHeaders: credentialHeaders)
        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await session.data(for: request, delegate: policy)
        let elapsed = start.duration(to: clock.now)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

        let headers = http.allHeaderFields
            .map { HeaderField(name: String(describing: $0.key), value: String(describing: $0.value)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let snapshot = ResponseSnapshot(
            statusCode: http.statusCode,
            headers: headers,
            body: data,
            duration: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            url: http.url?.absoluteString ?? request.url?.absoluteString ?? "",
            redirects: policy.hops
        )
        return await Task.detached(priority: .userInitiated) { ResponseDisplay(snapshot) }.value
    }
}

/// Follows redirects the way curl does. Left alone, URLSession drops Authorization on
/// every redirect, even back to the same host, and keeps every other header, even to a
/// different one. This puts credentials back for the same origin and takes them off for
/// any other, and keeps a note of each hop for the response pane.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let original: URLRequest
    private let credentialHeaders: Set<String>
    private let recorded = Mutex<[RedirectHop]>([])

    init(original: URLRequest, credentialHeaders: Set<String>) {
        self.original = original
        self.credentialHeaders = credentialHeaders
    }

    var hops: [RedirectHop] {
        recorded.withLock { $0 }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        var next = request
        let destination = Self.origin(of: next.url)
        let staysOnOrigin = destination != nil && destination == Self.origin(of: original.url)
        for name in credentialHeaders {
            if !staysOnOrigin {
                next.setValue(nil, forHTTPHeaderField: name)
            } else if next.value(forHTTPHeaderField: name) == nil, let value = original.value(forHTTPHeaderField: name) {
                next.setValue(value, forHTTPHeaderField: name)
            }
        }
        recorded.withLock { $0.append(RedirectHop(statusCode: response.statusCode, url: next.url?.absoluteString ?? "")) }
        return next
    }

    /// Scheme, host and port, which together decide whether credentials may go along.
    private static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}
