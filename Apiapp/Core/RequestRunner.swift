import Foundation

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

    func send(_ request: URLRequest) async throws -> ResponseDisplay {
        let clock = ContinuousClock()
        let start = clock.now
        let (data, response) = try await session.data(for: request)
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
            url: http.url?.absoluteString ?? request.url?.absoluteString ?? ""
        )
        return await Task.detached(priority: .userInitiated) { ResponseDisplay(snapshot) }.value
    }
}
