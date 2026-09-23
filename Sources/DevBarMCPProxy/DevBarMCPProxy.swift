import Darwin
import Foundation

@main
enum DevBarMCPProxy {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)

        guard let urlText = ProcessInfo.processInfo.environment["DEVBAR_MCP_URL"],
              let url = URL(string: urlText),
              url.scheme == "http", url.host == "127.0.0.1", url.path == "/mcp",
              let token = ProcessInfo.processInfo.environment["DEVBAR_MCP_TOKEN"],
              !token.isEmpty else {
            writeError("Set DEVBAR_MCP_URL and DEVBAR_MCP_TOKEN from DevBar's MCP settings.")
            exit(64)
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 130
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var protocolVersion = "2025-11-25"
        var sessionID: String?
        var initializePayload: Data?

        while let line = readLine() {
            guard let payload = line.data(using: .utf8), !payload.isEmpty else { continue }
            let message = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            let requestID = message?["id"]
            let method = message?["method"] as? String

            do {
                if method == "initialize" {
                    await closeSession(sessionID, url: url, token: token, protocolVersion: protocolVersion, session: session)
                    sessionID = nil
                    initializePayload = payload
                }

                if method != "initialize", sessionID == nil, let initializePayload {
                    let established = try await establishSession(
                        from: initializePayload, url: url, token: token,
                        protocolVersion: protocolVersion, session: session
                    )
                    sessionID = established.id
                    protocolVersion = established.protocolVersion
                }

                let response: ProxyResponse
                do {
                    response = try await send(
                        payload, url: url, token: token,
                        protocolVersion: protocolVersion, sessionID: sessionID, session: session
                    )
                } catch let error as ProxyError {
                    guard case .httpStatus(404) = error,
                          method != "initialize",
                          let initializePayload else {
                        sessionID = nil
                        throw error
                    }
                    let established = try await establishSession(
                        from: initializePayload, url: url, token: token,
                        protocolVersion: protocolVersion, session: session
                    )
                    sessionID = established.id
                    protocolVersion = established.protocolVersion
                    response = try await send(
                        payload, url: url, token: token,
                        protocolVersion: protocolVersion, sessionID: sessionID, session: session
                    )
                } catch {
                    sessionID = nil
                    throw error
                }
                guard !response.body.isEmpty else { continue } // Accepted notifications have no response.
                if let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
                   let result = object["result"] as? [String: Any],
                   let negotiated = result["protocolVersion"] as? String {
                    protocolVersion = negotiated
                }
                FileHandle.standardOutput.write(response.body)
                FileHandle.standardOutput.write(Data("\n".utf8))
            } catch {
                guard let requestID else {
                    writeError(error.localizedDescription)
                    continue
                }
                let response: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": requestID,
                    "error": ["code": -32000, "message": error.localizedDescription]
                ]
                if let encoded = try? JSONSerialization.data(withJSONObject: response) {
                    FileHandle.standardOutput.write(encoded)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                }
            }
        }

        await closeSession(sessionID, url: url, token: token, protocolVersion: protocolVersion, session: session)
    }

    private static func establishSession(
        from initializePayload: Data,
        url: URL,
        token: String,
        protocolVersion: String,
        session: URLSession
    ) async throws -> (id: String, protocolVersion: String) {
        var message = try JSONSerialization.jsonObject(with: initializePayload) as? [String: Any]
            ?? [:]
        message["id"] = "devbar-reinit-\(UUID().uuidString)"
        let requestBody = try JSONSerialization.data(withJSONObject: message)
        let response = try await send(
            requestBody, url: url, token: token,
            protocolVersion: protocolVersion, sessionID: nil, session: session
        )
        guard response.statusCode == 200,
              let sessionID = response.http.value(forHTTPHeaderField: "Mcp-Session-Id") else {
            throw ProxyError.missingSession
        }
        let result = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let negotiated = (result?["result"] as? [String: Any])?["protocolVersion"] as? String
            ?? protocolVersion
        let initialized = Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8)
        let notificationResponse = try await send(
            initialized, url: url, token: token,
            protocolVersion: negotiated, sessionID: sessionID, session: session
        )
        guard notificationResponse.statusCode == 202 else {
            throw ProxyError.sessionInitializationFailed
        }
        return (sessionID, negotiated)
    }

    private static func send(
        _ body: Data,
        url: URL,
        token: String,
        protocolVersion: String,
        sessionID: String?,
        session: URLSession
    ) async throws -> ProxyResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let (responseBody, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProxyError.invalidResponse }
        guard (200...299).contains(http.statusCode) else { throw ProxyError.httpStatus(http.statusCode) }
        return ProxyResponse(body: responseBody, http: http)
    }

    private static func closeSession(
        _ sessionID: String?,
        url: URL,
        token: String,
        protocolVersion: String,
        session: URLSession
    ) async {
        guard let sessionID else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(protocolVersion, forHTTPHeaderField: "MCP-Protocol-Version")
        request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        _ = try? await session.data(for: request)
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("DevBar MCP: \(message)\n".utf8))
    }
}

private enum ProxyError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int)
    case missingSession
    case sessionInitializationFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "Invalid response from DevBar MCP."
        case let .httpStatus(status): "DevBar MCP returned HTTP \(status). Check that MCP is running and the token is current."
        case .missingSession: "DevBar MCP did not assign an HTTP session."
        case .sessionInitializationFailed: "DevBar MCP session initialization was not accepted."
        }
    }
}

private struct ProxyResponse {
    let body: Data
    let http: HTTPURLResponse

    var statusCode: Int { http.statusCode }
}
