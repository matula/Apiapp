import Foundation
import Network

/// A real HTTP server on a loopback port, so tests can see the exact bytes URLSession
/// sends. It replies with the raw request it received as a JSON string.
final class LocalEchoServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LocalEchoServer")

    /// Set before sending. A request whose path starts with `/redirect` is answered with
    /// a 302 to this URL instead of an echo.
    var redirectLocation: String?

    /// Leaves out Content-Length, so the body's size is only known once the connection closes.
    var omitsContentLength = false

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if Self.isComplete(buffer) {
                self.reply(to: buffer, on: connection)
            } else if !isComplete {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private static func isComplete(_ data: Data) -> Bool {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self).lowercased()
        let length = head.split(separator: "\r\n")
            .first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        return data.distance(from: end.upperBound, to: data.endIndex) >= length
    }

    private func reply(to request: Data, on connection: NWConnection) {
        let text = String(decoding: request, as: UTF8.self)
        let path = text.prefix { $0 != "\r" }.split(separator: " ").dropFirst().first ?? ""
        var response: Data
        if let location = redirectLocation, path.hasPrefix("/redirect") {
            response = Data("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        } else {
            let body = (try? JSONEncoder().encode(text)) ?? Data()
            let length = omitsContentLength ? "" : "Content-Length: \(body.count)\r\n"
            response = Data("HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nX-Echo: yes\r\n\(length)Connection: close\r\n\r\n".utf8)
            response.append(body)
        }
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
