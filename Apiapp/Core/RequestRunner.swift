import Foundation
import Synchronization

enum ResponseError: LocalizedError, Equatable {
    case tooLarge(limit: Int)

    var errorDescription: String? {
        switch self {
        case .tooLarge(let limit):
            "The response is larger than \(Formatting.size(limit)), so it wasn’t kept. A response this size is better saved straight to a file, for instance with curl -o."
        }
    }
}

/// Sends requests. Nothing is cached and cookies aren't kept, so every send goes out
/// with exactly what the tab shows.
struct RequestRunner: Sendable {
    static let timeout: TimeInterval = 60
    /// A bigger body would be held in memory three times over and then handed to the text
    /// view, so it's refused instead.
    static let maximumBodySize = 50 * 1024 * 1024

    private let session: URLSession
    private let maximumBodySize: Int

    init(configuration: URLSessionConfiguration = Self.defaultConfiguration(), maximumBodySize: Int = Self.maximumBodySize) {
        session = URLSession(configuration: configuration)
        self.maximumBodySize = maximumBodySize
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
        let clock = ContinuousClock()
        let start = clock.now
        let collector = ResponseCollector(original: request, credentialHeaders: credentialHeaders, limit: maximumBodySize)
        let task = session.dataTask(with: request)
        task.delegate = collector
        let (data, http) = try await collector.response(from: task)
        let elapsed = start.duration(to: clock.now)

        let headers = http.allHeaderFields
            .map { HeaderField(name: String(describing: $0.key), value: String(describing: $0.value)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let snapshot = ResponseSnapshot(
            statusCode: http.statusCode,
            headers: headers,
            body: data,
            duration: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18,
            url: http.url?.absoluteString ?? request.url?.absoluteString ?? "",
            redirects: collector.hops
        )
        return await Task.detached(priority: .userInitiated) { ResponseDisplay(snapshot) }.value
    }
}

/// Receives one response for `RequestRunner`, and hands it to the task that's waiting.
///
/// It follows redirects the way curl does. Left alone, URLSession drops Authorization on
/// every redirect, even back to the same host, and keeps every other header, even to a
/// different one. This puts credentials back for the same origin and takes them off for
/// any other, and keeps a note of each hop for the response pane.
///
/// It also stops reading a body that turns out to be over the limit, whether the server
/// announced its size or not.
private final class ResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private struct State {
        var data = Data()
        var response: HTTPURLResponse?
        var hops: [RedirectHop] = []
        var isOverLimit = false
        var continuation: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
    }

    private let original: URLRequest
    private let credentialHeaders: Set<String>
    private let limit: Int
    private let state = Mutex(State())

    init(original: URLRequest, credentialHeaders: Set<String>, limit: Int) {
        self.original = original
        self.credentialHeaders = credentialHeaders
        self.limit = limit
    }

    var hops: [RedirectHop] {
        state.withLock { $0.hops }
    }

    /// Starts the task and waits for it to finish. Cancelling the waiting task cancels the request.
    func response(from task: URLSessionDataTask) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.withLock { $0.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
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
        state.withLock { $0.hops.append(RedirectHop(statusCode: response.statusCode, url: next.url?.absoluteString ?? "")) }
        return next
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        let announced = response.expectedContentLength
        return state.withLock { state in
            state.response = response as? HTTPURLResponse
            if announced > Int64(limit) {
                state.isOverLimit = true
                return .cancel
            }
            if announced > 0 { state.data.reserveCapacity(Int(announced)) }
            return .allow
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let tooMuch = state.withLock { state in
            state.data.append(data)
            guard state.data.count > limit else { return false }
            state.isOverLimit = true
            return true
        }
        if tooMuch { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let (continuation, outcome) = state.withLock { state -> (CheckedContinuation<(Data, HTTPURLResponse), any Error>?, Result<(Data, HTTPURLResponse), any Error>) in
            let continuation = state.continuation
            state.continuation = nil
            if state.isOverLimit { return (continuation, .failure(ResponseError.tooLarge(limit: limit))) }
            if let error { return (continuation, .failure(error)) }
            guard let response = state.response else { return (continuation, .failure(URLError(.badServerResponse))) }
            return (continuation, .success((state.data, response)))
        }
        continuation?.resume(with: outcome)
    }

    /// Scheme, host and port, which together decide whether credentials may go along.
    private static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}
