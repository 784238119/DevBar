import Foundation
import Observation

public protocol ConfigurationStoring: Sendable {
    func load() async throws -> AppConfig
    func save(_ config: AppConfig) async throws
}

extension ConfigurationStore: ConfigurationStoring {}

public protocol ConfigurationLoadDiagnosing: Sendable {
    func loadResult() async throws -> ConfigurationLoadResult
}

extension ConfigurationStore: ConfigurationLoadDiagnosing {}

public protocol ProcessSupervising: Sendable {
    func stateUpdates() async -> AsyncStream<ServiceRuntime>
    func runtimeEvents() async -> AsyncStream<SupervisedServiceRuntimeEvent>
    func start(service: ServiceConfig, workspace: WorkspaceConfig, preferences: PreferencesConfig) async
    func stop(serviceID: UUID) async
    func startAll(workspace: WorkspaceConfig, preferences: PreferencesConfig) async
    func stopAll(workspaceID: UUID) async
}

extension ProcessSupervisor: ProcessSupervising {}

public protocol LogWarningProviding: Sendable {
    func warnings() async -> [LogStoreWarning]
}

extension LogStore: LogWarningProviding {}

public enum AppAlertKind: Equatable, Sendable {
    case configurationRecovery
    case shellEnvironment
    case save
}

public struct AppAlert: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: AppAlertKind
    public let message: String

    public init(id: UUID = UUID(), kind: AppAlertKind, message: String) {
        self.id = id
        self.kind = kind
        self.message = message
    }
}

public enum AppAggregateStatus: Equatable, Sendable {
    case neutral
    case working
    case ready
    case error
}

public enum QuitResult: Equatable, Sendable {
    case immediate
    case confirmationRequired([ServiceRuntime])
}

/// Main-actor composition root for app-facing state. Process and storage work remain in
/// their actors; this object only receives snapshots and translates them into UI decisions.
@MainActor
@Observable
public final class AppState {
    public private(set) var config: AppConfig = .empty
    public private(set) var serviceStates: [UUID: ServiceState] = [:]
    public private(set) var alert: AppAlert?
    public private(set) var logWarnings: [LogStoreWarning] = []
    public private(set) var isConfigurationReady = false
    public private(set) var isShellEnvironmentReady = false

    public var isFirstLaunch: Bool { config.workspaces.isEmpty }

    public var aggregateStatus: AppAggregateStatus {
        if configurationWarning != nil || !logWarnings.isEmpty || serviceStates.values.contains(where: isFailed) {
            return .error
        }
        if serviceStates.values.contains(where: isWorking) {
            return .working
        }
        if serviceStates.values.contains(where: isReady) {
            return .ready
        }
        return .neutral
    }

    private let configurationStore: any ConfigurationStoring
    private let supervisor: any ProcessSupervising
    private let shellEnvironment: any ShellEnvironmentProviding
    private let logs: any LogWarningProviding
    private var configurationWarning: AppAlert?
    // These references are created and replaced only on the main actor. They are kept
    // outside Observation so `deinit` can synchronously cancel their streams in Swift 6.
    @ObservationIgnored nonisolated(unsafe) private var startupTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var stateSubscriptionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var eventSubscriptionTask: Task<Void, Never>?
    private var didStart = false

    public init(
        configurationStore: any ConfigurationStoring,
        supervisor: any ProcessSupervising,
        shellEnvironment: any ShellEnvironmentProviding,
        logs: any LogWarningProviding,
        startsImmediately: Bool = true
    ) {
        self.configurationStore = configurationStore
        self.supervisor = supervisor
        self.shellEnvironment = shellEnvironment
        self.logs = logs
        if startsImmediately {
            start()
        }
    }

    deinit {
        startupTask?.cancel()
        stateSubscriptionTask?.cancel()
        eventSubscriptionTask?.cancel()
    }

    /// Starts the one-time configuration load, shell-cache warmup, and actor streams.
    /// Calling it more than once is deliberately idempotent.
    public func start() {
        guard !didStart else { return }
        didStart = true
        subscribeToSupervisor()
        startupTask = Task { [weak self] in
            await self?.loadInitialConfiguration()
            await self?.refreshShellEnvironment()
            await self?.refreshLogWarnings()
        }
    }

    public func startAll(workspaceID: UUID) async {
        guard canStartServices(),
              let workspace = config.workspaces.first(where: { $0.id == workspaceID })
        else { return }
        await supervisor.startAll(workspace: workspace, preferences: config.preferences)
        await refreshLogWarnings()
    }

    public func start(serviceID: UUID, workspaceID: UUID) async {
        guard canStartServices(),
              let workspace = config.workspaces.first(where: { $0.id == workspaceID }),
              let service = workspace.services.first(where: { $0.id == serviceID })
        else { return }
        await supervisor.start(service: service, workspace: workspace, preferences: config.preferences)
        await refreshLogWarnings()
    }

    public func stop(serviceID: UUID) async {
        await supervisor.stop(serviceID: serviceID)
        await refreshLogWarnings()
    }

    public func stopAll(workspaceID: UUID) async {
        await supervisor.stopAll(workspaceID: workspaceID)
        await refreshLogWarnings()
    }

    public func save(_ newConfig: AppConfig) async {
        do {
            try await configurationStore.save(newConfig)
            config = newConfig
            isConfigurationReady = true
            configurationWarning = nil
            if alert?.kind == .configurationRecovery || alert?.kind == .save {
                alert = nil
            }
        } catch {
            showAlert(.save, error.localizedDescription)
        }
    }

    public func refreshShellEnvironment() async {
        do {
            _ = try await shellEnvironment.cachedOrRefresh()
            isShellEnvironmentReady = true
            if alert?.kind == .shellEnvironment { alert = nil }
        } catch {
            isShellEnvironmentReady = false
            showAlert(.shellEnvironment, error.localizedDescription)
        }
    }

    public func isEditingLocked(workspaceID: UUID) -> Bool {
        guard let workspace = config.workspaces.first(where: { $0.id == workspaceID }) else { return false }
        return workspace.services.contains { isActive(serviceStates[$0.id] ?? .stopped) }
    }

    public func prepareToQuit() async -> QuitResult {
        let active = serviceStates.compactMap { serviceID, state -> ServiceRuntime? in
            guard isActive(state), let workspace = workspaceContaining(serviceID: serviceID) else { return nil }
            return ServiceRuntime(workspaceID: workspace.id, serviceID: serviceID, state: state)
        }
        return active.isEmpty ? .immediate : .confirmationRequired(active.sorted { $0.serviceID.uuidString < $1.serviceID.uuidString })
    }

    private func loadInitialConfiguration() async {
        do {
            if let diagnostics = configurationStore as? any ConfigurationLoadDiagnosing {
                let result = try await diagnostics.loadResult()
                config = result.configuration
                if case let .backup(preservedCorruptURL) = result.source {
                    let warning = AppAlert(
                        kind: .configurationRecovery,
                        message: "DevBar recovered configuration from config.json.bak and preserved the corrupt original at \(preservedCorruptURL.lastPathComponent)."
                    )
                    configurationWarning = warning
                    alert = warning
                }
            } else {
                config = try await configurationStore.load()
            }
            isConfigurationReady = true
        } catch {
            config = .empty
            isConfigurationReady = false
            let warning = AppAlert(kind: .configurationRecovery, message: error.localizedDescription)
            configurationWarning = warning
            alert = warning
        }
    }

    private func subscribeToSupervisor() {
        stateSubscriptionTask = Task { [weak self, supervisor] in
            let stream = await supervisor.stateUpdates()
            for await runtime in stream {
                guard !Task.isCancelled else { return }
                self?.serviceStates[runtime.serviceID] = runtime.state
            }
        }
        eventSubscriptionTask = Task { [weak self, supervisor] in
            let stream = await supervisor.runtimeEvents()
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await self?.refreshLogWarnings()
            }
        }
    }

    private func refreshLogWarnings() async {
        logWarnings = await logs.warnings()
    }

    private func showAlert(_ kind: AppAlertKind, _ message: String) {
        alert = AppAlert(kind: kind, message: message)
    }

    private func canStartServices() -> Bool {
        guard isConfigurationReady else {
            showAlert(.configurationRecovery, "DevBar configuration is not available yet. Open Settings to repair it before starting services.")
            return false
        }
        guard isShellEnvironmentReady else {
            showAlert(.shellEnvironment, "Shell environment is unavailable. Refresh it in Settings before starting services.")
            return false
        }
        return true
    }

    private func workspaceContaining(serviceID: UUID) -> WorkspaceConfig? {
        config.workspaces.first { workspace in workspace.services.contains(where: { $0.id == serviceID }) }
    }

    private func isActive(_ state: ServiceState) -> Bool {
        switch state {
        case .starting, .running, .ready, .unready, .stopping: return true
        case .stopped, .failed: return false
        }
    }

    private func isWorking(_ state: ServiceState) -> Bool {
        switch state {
        case .starting, .unready, .stopping: return true
        case .stopped, .running, .ready, .failed: return false
        }
    }

    private func isReady(_ state: ServiceState) -> Bool {
        if case .running = state { return true }
        if case .ready = state { return true }
        return false
    }

    private func isFailed(_ state: ServiceState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
