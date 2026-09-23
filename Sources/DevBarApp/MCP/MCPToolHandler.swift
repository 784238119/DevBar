import DevBarCore
import Foundation
import MCP

/// MCP exposes the same live configuration, supervisor and log store used by the UI.
@MainActor
final class MCPToolHandler {
    private let appState: AppState
    private let supervisor: ProcessSupervisor
    private let logStore: LogStore
    private let launchedAt = Date()
    private var restarting = Set<UUID>()

    init(appState: AppState, supervisor: ProcessSupervisor, logStore: LogStore) {
        self.appState = appState
        self.supervisor = supervisor
        self.logStore = logStore
    }

    static var tools: [Tool] {
        let workspaceID: Value = ["type": "string", "format": "uuid", "description": "DevBar workspace UUID"]
        let serviceID: Value = ["type": "string", "format": "uuid", "description": "DevBar service UUID"]
        let readOnly = Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        let control = Tool.Annotations(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
        return [
            Tool(name: "get_app_info", description: "Get the running DevBar application's version, build, and launch time.", inputSchema: schema(), annotations: readOnly),
            Tool(name: "get_current_time", description: "Get the current time on the Mac running DevBar.", inputSchema: schema(), annotations: readOnly),
            Tool(name: "list_workspaces", description: "List configured DevBar workspaces and their IDs.", inputSchema: schema(), annotations: readOnly),
            Tool(name: "list_services", description: "List configured services and their current states, optionally within one workspace.", inputSchema: schema(properties: ["workspace_id": workspaceID]), annotations: readOnly),
            Tool(name: "get_service_status", description: "Get one service's current state, run ID, and last start time.", inputSchema: schema(properties: ["workspace_id": workspaceID, "service_id": serviceID], required: ["workspace_id", "service_id"]), annotations: readOnly),
            Tool(name: "get_service_logs", description: "Read up to 200 recent sanitized log records for one service. Logs may contain application secrets.", inputSchema: schema(properties: ["workspace_id": workspaceID, "service_id": serviceID, "limit": ["type": "integer", "minimum": 1, "maximum": 200]], required: ["workspace_id", "service_id"]), annotations: readOnly),
            Tool(name: "start_service", description: "Start one configured service using DevBar's saved command.", inputSchema: schema(properties: ["workspace_id": workspaceID, "service_id": serviceID], required: ["workspace_id", "service_id"]), annotations: control),
            Tool(name: "stop_service", description: "Stop one configured service using DevBar's graceful process-group policy.", inputSchema: schema(properties: ["workspace_id": workspaceID, "service_id": serviceID], required: ["workspace_id", "service_id"]), annotations: control),
            Tool(name: "restart_service", description: "Wait for one service to stop, then start it again using the latest saved configuration.", inputSchema: schema(properties: ["workspace_id": workspaceID, "service_id": serviceID], required: ["workspace_id", "service_id"]), annotations: control)
        ]
    }

    func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            switch params.name {
            case "get_app_info":
                return try result(AppInfo(
                    name: "DevBar",
                    version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
                    build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                    launchedAt: timestamp(launchedAt)
                ))
            case "get_current_time":
                let now = Date()
                let zone = TimeZone.current
                return try result(TimeInfo(
                    utc: timestamp(now),
                    local: timestamp(now, zone: zone),
                    timeZone: zone.identifier,
                    utcOffsetSeconds: zone.secondsFromGMT(for: now)
                ))
            case "list_workspaces":
                try requireConfiguration()
                return try result(appState.config.workspaces.map {
                    WorkspaceInfo(id: $0.id.uuidString.lowercased(), name: $0.name,
                                  rootDirectory: $0.rootDirectory, serviceCount: $0.services.count)
                })
            case "list_services":
                try requireConfiguration()
                let requestedID = try optionalUUID("workspace_id", in: params.arguments)
                let workspaces = appState.config.workspaces.filter { requestedID == nil || $0.id == requestedID }
                if requestedID != nil, workspaces.isEmpty { throw ToolError.workspaceNotFound }
                var services: [ServiceInfo] = []
                for workspace in workspaces {
                    for service in workspace.services {
                        services.append(await describe(service, in: workspace))
                    }
                }
                return try result(services)
            case "get_service_status":
                let (workspace, service) = try target(from: params.arguments)
                return try result(await describe(service, in: workspace))
            case "get_service_logs":
                let (workspace, service) = try target(from: params.arguments)
                let requestedLimit: Int
                if let provided = params.arguments?["limit"] {
                    guard let value = provided.intValue else { throw ToolError.invalidLimit }
                    requestedLimit = value
                } else {
                    requestedLimit = 100
                }
                guard (1...200).contains(requestedLimit) else { throw ToolError.invalidLimit }
                let entries = await logStore.readRecent(
                    workspaceID: workspace.id, serviceID: service.id, limit: requestedLimit
                )
                var remainingBytes = 128 * 1_024
                var selected: [LogInfo] = []
                var truncatedEntry = false
                for entry in entries.reversed() {
                    guard remainingBytes > 0 else { break }
                    let utf8 = entry.text.utf8
                    let text: String
                    if utf8.count > remainingBytes {
                        var start = utf8.index(utf8.endIndex, offsetBy: -remainingBytes)
                        while start > utf8.startIndex, (utf8[start] & 0xC0) == 0x80 {
                            utf8.formIndex(before: &start)
                        }
                        text = String(decoding: utf8[start...], as: UTF8.self)
                        truncatedEntry = true
                    } else {
                        text = entry.text
                    }
                    selected.append(LogInfo(timestamp: timestamp(entry.timestamp), stream: entry.stream.rawValue, text: text))
                    remainingBytes -= min(text.utf8.count, remainingBytes)
                    if truncatedEntry { break }
                }
                return try result(LogResult(
                    workspaceID: workspace.id.uuidString.lowercased(),
                    serviceID: service.id.uuidString.lowercased(),
                    entries: Array(selected.reversed()),
                    truncated: truncatedEntry || selected.count < entries.count
                ))
            case "start_service":
                let (workspace, service) = try target(from: params.arguments)
                try requireStartReady()
                await appState.start(serviceID: service.id, workspaceID: workspace.id)
                return try await startResult(service, in: workspace)
            case "stop_service":
                let (workspace, service) = try target(from: params.arguments)
                await appState.stop(serviceID: service.id)
                let info = await describe(service, in: workspace)
                if info.state == "failed" { throw ToolError.stopFailed }
                return try result(info)
            case "restart_service":
                let (workspace, service) = try target(from: params.arguments)
                try requireStartReady()
                guard restarting.insert(service.id).inserted else { throw ToolError.restartInProgress }
                defer { restarting.remove(service.id) }
                let state = await supervisor.state(for: service.id)
                switch state {
                case .starting, .running, .ready, .unready, .stopping:
                    await appState.stop(serviceID: service.id)
                    let waitSeconds = appState.config.preferences.sigintGraceSeconds
                        + appState.config.preferences.sigtermGraceSeconds + 10
                    let deadline = ContinuousClock.now.advanced(by: .seconds(waitSeconds))
                    while ContinuousClock.now < deadline {
                        let latest = await supervisor.state(for: service.id)
                        if case .stopped = latest { break }
                        if case .failed = latest { throw ToolError.stopFailed }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard case .stopped = await supervisor.state(for: service.id) else {
                        throw ToolError.stopTimedOut
                    }
                case .stopped, .failed:
                    break
                }
                guard appState.config.workspaces.contains(where: {
                    $0.id == workspace.id && $0.services.contains(where: { $0.id == service.id })
                }) else { throw ToolError.serviceNotFound }
                await appState.start(serviceID: service.id, workspaceID: workspace.id)
                return try await startResult(service, in: workspace)
            default:
                throw ToolError.unknownTool
            }
        } catch {
            return .init(content: [.text(text: error.localizedDescription, annotations: nil, _meta: nil)], isError: true)
        }
    }

    private static func schema(properties: [String: Value] = [:], required: [String] = []) -> Value {
        ["type": "object", "properties": .object(properties),
         "required": .array(required.map(Value.string)), "additionalProperties": false]
    }

    private func result<T: Codable>(_ payload: T) throws -> CallTool.Result {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let text = String(decoding: try encoder.encode(payload), as: UTF8.self)
        let structured = try Value(payload)
        return CallTool.Result(
            content: [.text(text: text, annotations: nil, _meta: nil)],
            structuredContent: Optional.some(structured),
            isError: false
        )
    }

    private func requireConfiguration() throws {
        guard appState.isConfigurationReady else { throw ToolError.configurationUnavailable }
    }

    private func requireStartReady() throws {
        try requireConfiguration()
        guard appState.isShellEnvironmentReady else { throw ToolError.shellUnavailable }
    }

    private func optionalUUID(_ key: String, in arguments: [String: Value]?) throws -> UUID? {
        guard let value = arguments?[key] else { return nil }
        guard let text = value.stringValue, let id = UUID(uuidString: text) else { throw ToolError.invalidIdentifier }
        return id
    }

    private func target(from arguments: [String: Value]?) throws -> (WorkspaceConfig, ServiceConfig) {
        try requireConfiguration()
        guard let workspaceID = try optionalUUID("workspace_id", in: arguments),
              let serviceID = try optionalUUID("service_id", in: arguments) else {
            throw ToolError.invalidIdentifier
        }
        guard let workspace = appState.config.workspaces.first(where: { $0.id == workspaceID }) else {
            throw ToolError.workspaceNotFound
        }
        guard let service = workspace.services.first(where: { $0.id == serviceID }) else {
            throw ToolError.serviceNotFound
        }
        return (workspace, service)
    }

    private func describe(_ service: ServiceConfig, in workspace: WorkspaceConfig) async -> ServiceInfo {
        let runtime = await supervisor.runtime(for: service.id)
        let state = runtime?.state ?? .stopped
        let stateName: String
        let runID: UUID?
        let detail: String?
        switch state {
        case .stopped:
            (stateName, runID, detail) = ("stopped", nil, nil)
        case let .starting(id):
            (stateName, runID, detail) = ("starting", id, nil)
        case let .running(id):
            (stateName, runID, detail) = ("running", id, nil)
        case let .ready(id):
            (stateName, runID, detail) = ("ready", id, nil)
        case let .unready(id, reason):
            (stateName, runID, detail) = ("unready", id, reason)
        case let .stopping(id):
            (stateName, runID, detail) = ("stopping", id, nil)
        case let .failed(failure):
            (stateName, runID, detail) = ("failed", nil, String(describing: failure))
        }
        return ServiceInfo(
            workspaceID: workspace.id.uuidString.lowercased(),
            serviceID: service.id.uuidString.lowercased(),
            workspaceName: workspace.name,
            name: service.name,
            state: stateName,
            runID: runID?.uuidString.lowercased(),
            lastStartedAt: runtime?.startedAt.map { timestamp($0) },
            detail: detail
        )
    }

    private func startResult(_ service: ServiceConfig, in workspace: WorkspaceConfig) async throws -> CallTool.Result {
        let info = await describe(service, in: workspace)
        if info.state == "stopped" || info.state == "failed" || info.state == "stopping" {
            throw ToolError.startFailed(info.detail)
        }
        return try result(info)
    }

    private func timestamp(_ date: Date, zone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = zone
        return formatter.string(from: date)
    }
}

private struct AppInfo: Codable {
    let name: String
    let version: String
    let build: String
    let launchedAt: String
}

private struct TimeInfo: Codable {
    let utc: String
    let local: String
    let timeZone: String
    let utcOffsetSeconds: Int
}

private struct WorkspaceInfo: Codable {
    let id: String
    let name: String
    let rootDirectory: String
    let serviceCount: Int
}

private struct ServiceInfo: Codable {
    let workspaceID: String
    let serviceID: String
    let workspaceName: String
    let name: String
    let state: String
    let runID: String?
    let lastStartedAt: String?
    let detail: String?
}

private struct LogInfo: Codable {
    let timestamp: String
    let stream: String
    let text: String
}

private struct LogResult: Codable {
    let workspaceID: String
    let serviceID: String
    let entries: [LogInfo]
    let truncated: Bool
}

private enum ToolError: Error, LocalizedError {
    case configurationUnavailable
    case shellUnavailable
    case workspaceNotFound
    case serviceNotFound
    case invalidIdentifier
    case invalidLimit
    case restartInProgress
    case stopFailed
    case stopTimedOut
    case startFailed(String?)
    case unknownTool

    var errorDescription: String? {
        switch self {
        case .configurationUnavailable: "DevBar configuration is not ready."
        case .shellUnavailable: "DevBar's shell environment is not ready."
        case .workspaceNotFound: "Workspace not found. List workspaces to get a current ID."
        case .serviceNotFound: "Service not found in that workspace. List services to get a current ID."
        case .invalidIdentifier: "workspace_id and service_id must be valid UUID strings."
        case .invalidLimit: "limit must be an integer from 1 through 200."
        case .restartInProgress: "A restart is already in progress for this service."
        case .stopFailed: "The service failed while stopping; it was not restarted."
        case .stopTimedOut: "The service did not stop before the restart timeout."
        case let .startFailed(detail): "The service did not start. \(detail ?? "Check DevBar service logs and shell readiness.")"
        case .unknownTool: "Unknown DevBar MCP tool."
        }
    }
}
