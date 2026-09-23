import DevBarCore
import Foundation
import MCP
import Observation

@MainActor
@Observable
final class MCPServiceController {
    private let appState: AppState
    private let logStore: LogStore
    private let tokenStore: any MCPTokenProviding
    private let toolHandler: MCPToolHandler
    private var listener: LoopbackMCPHTTPServer?
    @ObservationIgnored private var sessions: [String: Session] = [:]
    @ObservationIgnored private var pendingSessionCount = 0
    private static let maximumSessions = 32
    private static let sessionIdleSeconds: TimeInterval = 24 * 60 * 60

    private struct Session {
        let server: Server
        let transport: StatelessHTTPServerTransport
        var lastAccess: Date
    }

    private(set) var isRunning = false
    private(set) var isStarting = false
    private(set) var errorMessage: String?
    private(set) var token: String?
    private(set) var isCodexConfigured = false

    var activeSessionCount: Int { sessions.count }

    init(
        appState: AppState,
        supervisor: ProcessSupervisor,
        logStore: LogStore,
        tokenStore: any MCPTokenProviding = MCPTokenStore()
    ) {
        self.appState = appState
        self.logStore = logStore
        self.tokenStore = tokenStore
        toolHandler = MCPToolHandler(appState: appState, supervisor: supervisor, logStore: logStore)
    }

    func loadSavedToken() {
        guard token == nil else { return }
        do {
            token = try tokenStore.load()
            isCodexConfigured = token != nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    var endpoint: String {
        "http://127.0.0.1:\(appState.config.preferences.mcpPort)/mcp"
    }

    var helperPath: String {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/DevBarMCPProxy", isDirectory: false)
            .path
    }

    var codexConfigPath: String { tokenStore.configurationPath }

    var codexHTTPConfiguration: String? {
        guard let token else { return nil }
        return """
        [mcp_servers.devbar]
        url = \(tomlString(endpoint))
        http_headers = { "Authorization" = \(tomlString("Bearer \(token)")) }
        tool_timeout_sec = 120
        enabled = true
        """
    }

    var stdioJSONConfiguration: String? {
        guard let token else { return nil }
        let configuration = StdioConfiguration(mcpServers: [
            "devbar": .init(
                command: helperPath,
                environment: ["DEVBAR_MCP_URL": endpoint, "DEVBAR_MCP_TOKEN": token]
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(configuration) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func start() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        errorMessage = nil
        defer { isStarting = false }
        guard appState.isConfigurationReady else {
            errorMessage = "DevBar 配置尚未就绪。"
            return
        }

        let preferences = appState.config.preferences
        do {
            try await logStore.configure(
                logDirectory: preferences.logDirectory,
                logFileSizeMiB: preferences.logFileSizeMiB,
                fileCount: preferences.logFileCount,
                retentionDays: preferences.logRetentionDays
            )
            if let savedToken = try tokenStore.load() {
                token = savedToken
                isCodexConfigured = true
            } else {
                if token == nil { token = try tokenStore.generate() }
                isCodexConfigured = false
            }

            let listener = try LoopbackMCPHTTPServer(
                port: preferences.mcpPort,
                handler: { [weak self] request in
                    guard let self else {
                        return .error(statusCode: 503, .internalError("DevBar MCP is shutting down"))
                    }
                    return await self.handle(request, port: preferences.mcpPort)
                },
                onFailure: { [weak self] error in
                    Task { @MainActor [weak self] in
                        guard let self, self.isRunning else { return }
                        await self.stop()
                        self.errorMessage = "MCP 监听已中断：\(error.localizedDescription)"
                    }
                }
            )
            try await listener.start()

            self.listener = listener
            isRunning = true
        } catch {
            errorMessage = "MCP 启动失败：\(error.localizedDescription)"
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        listener?.stop()
        listener = nil
        let oldSessions = Array(sessions.values)
        sessions.removeAll()
        for session in oldSessions { await session.server.stop() }
        errorMessage = nil
    }

    func regenerateToken() {
        do {
            let newToken = try tokenStore.generate()
            try tokenStore.saveToCodexConfiguration(token: newToken, endpoint: endpoint)
            token = newToken
            isCodexConfigured = true
            errorMessage = nil
            removeLegacyKeychainCredentialIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func configureCodex() {
        do {
            let codexToken = try tokenStore.load() ?? token ?? tokenStore.generate()
            try tokenStore.saveToCodexConfiguration(token: codexToken, endpoint: endpoint)
            token = codexToken
            isCodexConfigured = true
            errorMessage = nil
            removeLegacyKeychainCredentialIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeLegacyKeychainCredentialIfNeeded() {
        do {
            try tokenStore.deleteLegacyKeychainToken()
        } catch {
            errorMessage = "Codex 配置已写入，但旧的 Keychain 令牌未能删除：\(error.localizedDescription)"
        }
    }

    private func handle(
        _ request: HTTPRequest,
        port: Int
    ) async -> HTTPResponse {
        guard isRunning else {
            return .error(statusCode: 503, .internalError("DevBar MCP is stopped"))
        }
        guard request.path == "/mcp" else {
            return .error(statusCode: 404, .invalidRequest("Not Found"))
        }
        guard request.header("Host") == "127.0.0.1:\(port)" else {
            return .error(statusCode: 421, .invalidRequest("Host not allowed"))
        }
        if let origin = request.header("Origin"), origin != "http://127.0.0.1:\(port)" {
            return .error(statusCode: 403, .invalidRequest("Origin not allowed"))
        }
        guard let token,
              let authorization = request.header("Authorization"),
              authorization.hasPrefix("Bearer "),
              secureEquals(String(authorization.dropFirst("Bearer ".count)), token) else {
            return .error(
                statusCode: 401,
                .invalidRequest("Unauthorized"),
                extraHeaders: ["WWW-Authenticate": "Bearer realm=\"DevBar MCP\""]
            )
        }
        await expireIdleSessions()
        if request.method.uppercased() == "GET" {
            return .error(
                statusCode: 405,
                .invalidRequest("Method Not Allowed"),
                extraHeaders: ["Allow": "POST, DELETE"]
            )
        }
        if let sessionID = request.header("Mcp-Session-Id") {
            guard var session = sessions[sessionID] else {
                return .error(statusCode: 404, .invalidRequest("MCP session not found"))
            }
            if request.method.uppercased() == "DELETE" {
                sessions.removeValue(forKey: sessionID)
                await session.server.stop()
                return .ok()
            }
            session.lastAccess = Date()
            sessions[sessionID] = session
            return await session.transport.handleRequest(request)
        }

        guard request.method.uppercased() == "POST",
              let body = request.body,
              let message = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              message["method"] as? String == "initialize" else {
            return .error(statusCode: 400, .invalidRequest("Initialize before calling MCP tools"))
        }
        guard sessions.count + pendingSessionCount < Self.maximumSessions else {
            return .error(statusCode: 503, .internalError("Too many MCP sessions"))
        }
        pendingSessionCount += 1
        defer { pendingSessionCount -= 1 }
        do {
            let session = try await makeSession()
            let response = await session.transport.handleRequest(request)
            guard isRunning else {
                await session.server.stop()
                return .error(statusCode: 503, .internalError("DevBar MCP is stopped"))
            }
            guard response.statusCode == 200 else {
                await session.server.stop()
                return response
            }
            let sessionID = UUID().uuidString
            sessions[sessionID] = session
            var headers = response.headers
            headers["Mcp-Session-Id"] = sessionID
            return .data(response.bodyData ?? Data(), headers: headers)
        } catch {
            return .error(statusCode: 500, .internalError("Could not initialize MCP session"))
        }
    }

    private func makeSession() async throws -> Session {
        let transport = StatelessHTTPServerTransport()
        let server = Server(
            name: "devbar",
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            title: "DevBar",
            instructions: "Manage configured local development services. Use workspace and service IDs from list tools. Logs may contain sensitive application output.",
            capabilities: .init(tools: .init())
        )
        let tools = MCPToolHandler.tools
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        let toolHandler = toolHandler
        await server.withMethodHandler(CallTool.self) { params in
            await toolHandler.call(params)
        }
        try await server.start(transport: transport)
        return Session(server: server, transport: transport, lastAccess: Date())
    }

    private func expireIdleSessions() async {
        let now = Date()
        let expired = sessions.filter { now.timeIntervalSince($0.value.lastAccess) > Self.sessionIdleSeconds }
        for (sessionID, session) in expired {
            sessions.removeValue(forKey: sessionID)
            await session.server.stop()
        }
    }

    private func secureEquals(_ supplied: String, _ expected: String) -> Bool {
        let left = Array(supplied.utf8)
        let right = Array(expected.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices { difference |= left[index] ^ right[index] }
        return difference == 0
    }

    private func tomlString(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }

}

private struct StdioConfiguration: Encodable {
    let mcpServers: [String: ServerConfiguration]

    struct ServerConfiguration: Encodable {
        let command: String
        let environment: [String: String]

        enum CodingKeys: String, CodingKey {
            case command
            case environment = "env"
        }
    }
}
