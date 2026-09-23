import Darwin
import DevBarCore
import Foundation
import XCTest
@testable import DevBar

@MainActor
final class MCPIntegrationTests: XCTestCase {
    func testHTTPAndStdioAuthenticationQueriesAndServiceControl() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DevBar-MCP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let port = try unusedLoopbackPort()
        var preferences = PreferencesConfig.default
        preferences.mcpPort = port
        let service = ServiceConfig(
            name: "Fixture Service",
            workingDirectory: .relative("."),
            command: "echo fixture"
        )
        let workspace = WorkspaceConfig(
            name: "MCP Fixture",
            rootDirectory: root.path,
            iconSymbol: "terminal.fill",
            tintHex: "#FF7A59",
            environment: [],
            services: [service]
        )
        let config = AppConfig(workspaces: [workspace], preferences: preferences)
        let paths = AppPaths(applicationSupport: root)
        let logs = LogStore(paths: paths)
        let runner = FixtureRunner()
        let supervisor = ProcessSupervisor(
            runner: runner,
            zshResolver: FixtureZshResolver(),
            environmentProviderFactory: FixtureEnvironmentFactory(),
            logStore: logs,
            noneRunningDelay: .milliseconds(10)
        )
        let appState = AppState(
            configurationStore: FixtureConfigStore(config: config),
            supervisor: supervisor,
            shellEnvironment: FixtureShellEnvironment(),
            shellEnvironmentRefresher: FixtureShellRefresher(),
            logs: logs
        )
        for _ in 0..<100 where !(appState.isConfigurationReady && appState.isShellEnvironmentReady) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(appState.isConfigurationReady)
        XCTAssertTrue(appState.isShellEnvironmentReady)

        let controller = MCPServiceController(
            appState: appState,
            supervisor: supervisor,
            logStore: logs,
            tokenStore: FixtureTokenStore()
        )
        await controller.start()
        XCTAssertTrue(controller.isRunning, controller.errorMessage ?? "No startup details")
        guard controller.isRunning else { return }

        do {
            let initialize = """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"DevBarTests","version":"1.0.0"}}}
            """
            let unauthorized = try await post(initialize, to: controller.endpoint)
            XCTAssertEqual(unauthorized.status, 401)
            let wrongToken = try await post(initialize, to: controller.endpoint, token: "wrong")
            XCTAssertEqual(wrongToken.status, 401)
            let wrongOrigin = try await post(
                initialize, to: controller.endpoint, token: "test-secret-token", origin: "https://example.com"
            )
            XCTAssertEqual(wrongOrigin.status, 403)
            var getRequest = URLRequest(url: URL(string: controller.endpoint)!)
            getRequest.httpMethod = "GET"
            getRequest.setValue("Bearer test-secret-token", forHTTPHeaderField: "Authorization")
            getRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let (_, getResponse) = try await URLSession.shared.data(for: getRequest)
            XCTAssertEqual((getResponse as? HTTPURLResponse)?.statusCode, 405)
            let missingSession = try await post(
                "{\"jsonrpc\":\"2.0\",\"id\":88,\"method\":\"tools/list\"}",
                to: controller.endpoint, token: "test-secret-token"
            )
            XCTAssertEqual(missingSession.status, 400)

            let handshake = try await post(initialize, to: controller.endpoint, token: "test-secret-token")
            XCTAssertEqual(handshake.status, 200)
            let handshakeResult = handshake.json?["result"] as? [String: Any]
            XCTAssertEqual(handshakeResult?["protocolVersion"] as? String, "2025-11-25")
            let firstSessionID = try XCTUnwrap(handshake.sessionID)

            let notification = try await post(
                "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
                to: controller.endpoint, token: "test-secret-token", sessionID: firstSessionID
            )
            XCTAssertEqual(notification.status, 202)

            let listed = try await post(
                "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
                to: controller.endpoint, token: "test-secret-token", sessionID: firstSessionID
            )
            XCTAssertEqual(listed.status, 200)
            let tools = (listed.json?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            XCTAssertTrue(tools?.contains(where: { $0["name"] as? String == "restart_service" }) == true)

            let workspaces = try await post(
                "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"list_workspaces\",\"arguments\":{}}}",
                to: controller.endpoint, token: "test-secret-token", sessionID: firstSessionID
            )
            XCTAssertEqual(workspaces.status, 200)
            let toolResult = workspaces.json?["result"] as? [String: Any]
            let content = toolResult?["content"] as? [[String: Any]]
            XCTAssertTrue((content?.first?["text"] as? String)?.contains("MCP Fixture") == true)

            await logs.append(
                LogEntry(stream: .stdout, text: "hello from fixture\n"),
                workspaceID: workspace.id,
                serviceID: service.id
            )
            let target = "\"workspace_id\":\"\(workspace.id.uuidString)\",\"service_id\":\"\(service.id.uuidString)\""
            let logsResponse = try await post(
                "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"get_service_logs\",\"arguments\":{\(target)}}}",
                to: controller.endpoint, token: "test-secret-token", sessionID: firstSessionID
            )
            let logsContent = (logsResponse.json?["result"] as? [String: Any])?["content"] as? [[String: Any]]
            XCTAssertTrue((logsContent?.first?["text"] as? String)?.contains("hello from fixture") == true)

            let started = try await post(
                "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"start_service\",\"arguments\":{\(target)}}}",
                to: controller.endpoint, token: "test-secret-token", sessionID: firstSessionID
            )
            XCTAssertEqual(started.status, 200)
            XCTAssertEqual((started.json?["result"] as? [String: Any])?["isError"] as? Bool, false)
            for _ in 0..<100 {
                if case .running = await supervisor.state(for: service.id) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard case .running = await supervisor.state(for: service.id) else {
                return XCTFail("Fixture service did not reach running state")
            }

            let restarted = try await post(
                "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"restart_service\",\"arguments\":{\(target)}}}",
                to: controller.endpoint, token: "test-secret-token", sessionID: firstSessionID
            )
            XCTAssertEqual(restarted.status, 200)
            XCTAssertEqual((restarted.json?["result"] as? [String: Any])?["isError"] as? Bool, false)
            let launchCount = await runner.launchCount
            let stopCount = await runner.stopCount
            XCTAssertEqual(launchCount, 2)
            XCTAssertEqual(stopCount, 1)

            let stopped = try await post(
                "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"stop_service\",\"arguments\":{\(target)}}}",
                to: controller.endpoint, token: "test-secret-token", sessionID: firstSessionID
            )
            XCTAssertEqual(stopped.status, 200)

            let secondHandshake = try await post(initialize, to: controller.endpoint, token: "test-secret-token")
            XCTAssertEqual(secondHandshake.status, 200)
            XCTAssertNotEqual(secondHandshake.sessionID, firstSessionID)

            controller.regenerateToken()
            let revoked = try await post(initialize, to: controller.endpoint, token: "test-secret-token")
            XCTAssertEqual(revoked.status, 401)
            let rotated = try await post(initialize, to: controller.endpoint, token: "replacement-token")
            XCTAssertEqual(rotated.status, 200)

            let activeSessionsBeforeStdio = controller.activeSessionCount
            let stdioResponses = try await callStdioProxy(
                endpoint: controller.endpoint, helperPath: controller.helperPath
            )
            XCTAssertEqual(
                controller.activeSessionCount, activeSessionsBeforeStdio,
                "The stdio proxy must reuse and close the session returned by initialize."
            )
            XCTAssertEqual(stdioResponses.count, 3)
            XCTAssertEqual(
                (stdioResponses.first?["result"] as? [String: Any])?["protocolVersion"] as? String,
                "2025-11-25",
                "stdio responses: \(stdioResponses)"
            )
            let proxiedTools = (stdioResponses[1]["result"] as? [String: Any])?["tools"] as? [[String: Any]]
            XCTAssertTrue(proxiedTools?.contains(where: { $0["name"] as? String == "get_service_logs" }) == true)
            XCTAssertNotNil(stdioResponses[2]["result"])
        } catch {
            await controller.stop()
            throw error
        }
        await controller.stop()
        XCTAssertFalse(controller.isRunning)
    }

    func testCodexOneClickConfigurationPreservesOtherServersAndMigratesAuthorization() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevBar-Codex-MCP-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configURL = root.appendingPathComponent("config.toml")
        let existing = """
        model = "gpt-6-sol"

        [mcp_servers.tabby-mcp]
        url = "http://localhost:6001/mcp"
        enabled = true

        [mcp_servers.devbar]
        url = "http://127.0.0.1:43171/mcp"
        http_headers = {
            "X-Client" = "preserve-me",
            "Authorization" = "Bearer old-token"
        }
        http_headers_helper = "old-helper --mcp-http-headers"
        tool_timeout_sec = 120

        [mcp_servers.tablepro]
        url = "http://127.0.0.1:23508/mcp"
        """
        try Data(existing.utf8).write(to: configURL)

        var didDeleteLegacyCredential = false
        let tokenStore = MCPTokenStore(
            configurationFileURL: configURL,
            legacyKeychainCleanup: { didDeleteLegacyCredential = true }
        )
        try tokenStore.saveToCodexConfiguration(
            token: "new-static-token",
            endpoint: "http://127.0.0.1:43171/mcp"
        )

        XCTAssertEqual(try tokenStore.load(), "new-static-token")
        try tokenStore.deleteLegacyKeychainToken()
        XCTAssertTrue(didDeleteLegacyCredential)

        let saved = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(saved.contains("[mcp_servers.tabby-mcp]"))
        XCTAssertTrue(saved.contains("[mcp_servers.tablepro]"))
        XCTAssertTrue(saved.contains("\"X-Client\" = \"preserve-me\""))
        XCTAssertTrue(saved.contains("\"Authorization\" = \"Bearer new-static-token\""))
        XCTAssertFalse(saved.contains("Bearer old-token"))
        XCTAssertEqual(saved.components(separatedBy: "http_headers =").count - 1, 1)
        XCTAssertFalse(saved.contains("http_headers_helper"))
        XCTAssertFalse(saved.contains("bearer_token_env_var"))
        XCTAssertTrue(saved.contains("tool_timeout_sec = 120"))
        XCTAssertTrue(saved.contains("enabled = true"))
        XCTAssertEqual(saved.components(separatedBy: "[mcp_servers.devbar]").count - 1, 1)

        let attributes = try FileManager.default.attributesOfItem(atPath: configURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    private func callStdioProxy(endpoint: String, helperPath: String) async throws -> [[String: Any]] {
        let helper = URL(fileURLWithPath: helperPath)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helper.path))
        let commands = [
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{},\"clientInfo\":{\"name\":\"StdioTest\",\"version\":\"1.0.0\"}}}",
            "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
            "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\"}",
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"get_current_time\",\"arguments\":{}}}"
        ].joined(separator: "\n") + "\n"
        let data = try await Task.detached(priority: .utility) { () throws -> Data in
            let process = Process()
            process.executableURL = helper
            var environment = ProcessInfo.processInfo.environment
            environment["DEVBAR_MCP_URL"] = endpoint
            environment["DEVBAR_MCP_TOKEN"] = "replacement-token"
            process.environment = environment
            let input = Pipe()
            let output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = Pipe()
            try process.run()
            input.fileHandleForWriting.write(Data(commands.utf8))
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ProxyTestError.exit(process.terminationStatus) }
            return output.fileHandleForReading.readDataToEndOfFile()
        }.value
        return try String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map { line in
                try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    private func post(
        _ json: String,
        to endpoint: String,
        token: String? = nil,
        origin: String? = nil,
        sessionID: String? = nil
    ) async throws -> (status: Int, json: [String: Any]?, sessionID: String?) {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.httpBody = Data(json.utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("2025-11-25", forHTTPHeaderField: "MCP-Protocol-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return (http.statusCode, decoded, http.value(forHTTPHeaderField: "Mcp-Session-Id"))
    }

    private func unusedLoopbackPort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw PortError.socketFailed }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw PortError.bindFailed }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let found = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard found == 0 else { throw PortError.lookupFailed }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

private actor FixtureConfigStore: ConfigurationStoring {
    let config: AppConfig
    init(config: AppConfig) { self.config = config }
    func load() -> AppConfig { config }
    func save(_ config: AppConfig) {}
}

private actor FixtureShellEnvironment: ShellEnvironmentProviding {
    func cachedOrRefresh() -> [String: String] { [:] }
    func refresh() -> [String: String] { [:] }
}

private actor FixtureShellRefresher: ShellEnvironmentRefreshing {
    func refreshShellEnvironment(preferences: PreferencesConfig) -> ZshResolution {
        ZshResolution(path: "/bin/zsh", source: .fallback, warning: nil)
    }
}

private struct FixtureZshResolver: ZshResolving {
    func resolve(environment: [String: String]) throws -> ZshResolution {
        ZshResolution(path: "/bin/zsh", source: .fallback, warning: nil)
    }
}

private struct FixtureEnvironmentFactory: ShellEnvironmentProvidingFactory {
    func makeProvider(zshPath: String) -> any ShellEnvironmentProviding {
        FixtureShellEnvironment()
    }
}

private actor FixtureRunner: RunnerControlling {
    private var launched: [UUID] = []
    private var stopped: [UUID] = []
    private var streams: [UUID: AsyncStream<ServiceRuntimeEvent>.Continuation] = [:]

    var launchCount: Int { launched.count }
    var stopCount: Int { stopped.count }

    func launch(_ request: RunnerLaunchRequest) -> AsyncStream<ServiceRuntimeEvent> {
        launched.append(request.runID)
        return AsyncStream { continuation in
            streams[request.runID] = continuation
            continuation.yield(.runner(.started(runID: request.runID, pid: 123, pgid: 123)))
        }
    }

    func stop(runID: UUID) {
        stopped.append(runID)
        streams[runID]?.yield(.runner(.exited(runID: runID, code: 0, signal: nil)))
        streams[runID]?.finish()
    }
}

private struct FixtureTokenStore: MCPTokenProviding {
    var configurationPath: String { "/tmp/DevBar-MCP-tests/config.toml" }
    func load() throws -> String? { "test-secret-token" }
    func generate() throws -> String { "replacement-token" }
    func saveToCodexConfiguration(token: String, endpoint: String) throws {}
    func deleteLegacyKeychainToken() throws {}
}

private enum PortError: Error {
    case socketFailed
    case bindFailed
    case lookupFailed
}

private enum ProxyTestError: Error {
    case exit(Int32)
}
