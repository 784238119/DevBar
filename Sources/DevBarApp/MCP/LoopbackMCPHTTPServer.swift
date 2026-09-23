import Foundation
import MCP
import Network

/// A small HTTP/1.1 adapter for the SDK's framework-independent HTTP transport.
/// Each connection carries one bounded request and is then closed.
final class LoopbackMCPHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.calo.DevBar.mcp.http")
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private let onFailure: @Sendable (Error) -> Void
    private let lock = NSLock()
    private var startup: CheckedContinuation<Void, Error>?
    private var activeConnections = 0
    private static let maximumConnections = 32
    private static let maximumHeaders = 16 * 1_024
    private static let maximumBody = 1 * 1_024 * 1_024

    init(
        port: Int,
        handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse,
        onFailure: @escaping @Sendable (Error) -> Void
    ) throws {
        guard let rawPort = UInt16(exactly: port), rawPort >= 1_024,
              let networkPort = NWEndpoint.Port(rawValue: rawPort) else {
            throw HTTPServerError.invalidPort
        }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: networkPort)
        listener = try NWListener(using: parameters)
        self.handler = handler
        self.onFailure = onFailure
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            startup = continuation
            lock.unlock()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.completeStartup(.success(()))
                case let .failed(error):
                    guard let self else { return }
                    if !self.completeStartup(.failure(error)) {
                        self.onFailure(error)
                    }
                case .cancelled:
                    self?.completeStartup(.failure(HTTPServerError.cancelled))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    @discardableResult
    private func completeStartup(_ result: Result<Void, Error>) -> Bool {
        lock.lock()
        let continuation = startup
        startup = nil
        lock.unlock()
        continuation?.resume(with: result)
        return continuation != nil
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        let accepted = activeConnections < Self.maximumConnections
        if accepted { activeConnections += 1 }
        lock.unlock()
        connection.start(queue: queue)
        Task { [self] in
            defer {
                connection.cancel()
                if accepted {
                    lock.withLock { activeConnections -= 1 }
                }
            }
            guard accepted else {
                try? await send(status: 503, body: Data(), headers: [:], over: connection)
                return
            }
            let readTimeout = DispatchWorkItem { connection.cancel() }
            queue.asyncAfter(deadline: .now() + 10, execute: readTimeout)
            do {
                let request = try await readRequest(from: connection)
                readTimeout.cancel()
                let response = await handler(request)
                try await send(
                    status: response.statusCode,
                    body: response.bodyData ?? Data(),
                    headers: response.headers,
                    over: connection
                )
            } catch let error as HTTPServerError {
                readTimeout.cancel()
                try? await send(status: error.statusCode, body: Data(), headers: [:], over: connection)
            } catch {
                readTimeout.cancel()
                try? await send(status: 500, body: Data(), headers: [:], over: connection)
            }
        }
    }

    private func readRequest(from connection: NWConnection) async throws -> HTTPRequest {
        var bytes = Data()
        let separator = Data("\r\n\r\n".utf8)
        while true {
            if let headerRange = bytes.range(of: separator) {
                guard headerRange.lowerBound <= Self.maximumHeaders,
                      let headerText = String(data: bytes[..<headerRange.lowerBound], encoding: .utf8)
                else { throw HTTPServerError.badRequest }
                let lines = headerText.components(separatedBy: "\r\n")
                let requestLine = lines[0].split(separator: " ", omittingEmptySubsequences: false)
                guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" else {
                    throw HTTPServerError.badRequest
                }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    guard let colon = line.firstIndex(of: ":") else { throw HTTPServerError.badRequest }
                    let name = line[..<colon].lowercased()
                    let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, headers[name] == nil else { throw HTTPServerError.badRequest }
                    headers[name] = value
                }
                guard headers["transfer-encoding"] == nil else { throw HTTPServerError.badRequest }
                let method = String(requestLine[0])
                let length: Int
                if method == "POST" {
                    guard let text = headers["content-length"], let parsed = Int(text), parsed >= 0 else {
                        throw HTTPServerError.badRequest
                    }
                    length = parsed
                } else {
                    length = 0
                }
                guard length <= Self.maximumBody else { throw HTTPServerError.payloadTooLarge }
                let bodyStart = headerRange.upperBound
                while bytes.count - bodyStart < length {
                    try await appendReceivedBytes(to: &bytes, from: connection)
                }
                guard bytes.count - bodyStart == length else { throw HTTPServerError.badRequest }
                return HTTPRequest(
                    method: method,
                    headers: headers,
                    body: length == 0 ? nil : Data(bytes[bodyStart...]),
                    path: String(requestLine[1])
                )
            }
            guard bytes.count <= Self.maximumHeaders else { throw HTTPServerError.payloadTooLarge }
            try await appendReceivedBytes(to: &bytes, from: connection)
        }
    }

    private func appendReceivedBytes(to bytes: inout Data, from connection: NWConnection) async throws {
        let chunk = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(throwing: HTTPServerError.disconnected) }
                else { continuation.resume(throwing: HTTPServerError.badRequest) }
            }
        }
        bytes.append(chunk)
        guard bytes.count <= Self.maximumHeaders + Self.maximumBody else {
            throw HTTPServerError.payloadTooLarge
        }
    }

    private func send(status: Int, body: Data, headers: [String: String], over connection: NWConnection) async throws {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        case 421: reason = "Misdirected Request"
        case 503: reason = "Service Unavailable"
        default: reason = "Error"
        }
        var lines = [
            "HTTP/1.1 \(status) \(reason)",
            "Content-Length: \(body.count)",
            "Connection: close",
            "Cache-Control: no-store"
        ]
        lines.append(contentsOf: headers.map { "\($0.key): \($0.value)" })
        var payload = Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        payload.append(body)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: payload, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }
}

private enum HTTPServerError: Error {
    case invalidPort
    case cancelled
    case disconnected
    case badRequest
    case payloadTooLarge

    var statusCode: Int {
        switch self {
        case .payloadTooLarge: 413
        default: 400
        }
    }
}
