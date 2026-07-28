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

public protocol ShellEnvironmentRefreshing: Sendable {
    func refreshShellEnvironment(preferences: PreferencesConfig) async throws -> ZshResolution
}

extension ProcessSupervisor: ShellEnvironmentRefreshing {}

private actor LegacyShellEnvironmentRefresher: ShellEnvironmentRefreshing {
    private let provider: any ShellEnvironmentProviding

    init(provider: any ShellEnvironmentProviding) {
        self.provider = provider
    }

    func refreshShellEnvironment(preferences: PreferencesConfig) async throws -> ZshResolution {
        _ = try await provider.refresh()
        let requestedPath = preferences.shellPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return ZshResolution(
            path: requestedPath.isEmpty ? "/bin/zsh" : requestedPath,
            source: requestedPath.isEmpty ? .fallback : .shellEnvironment,
            warning: nil
        )
    }
}

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
    public private(set) var isShellEnvironmentRefreshing = false
    public private(set) var resolvedShellPath: String?

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
    private let shellEnvironmentRefresher: any ShellEnvironmentRefreshing
    private let logs: any LogWarningProviding
    private var configurationWarning: AppAlert?
    // These references are created and replaced only on the main actor. They are kept
    // outside Observation so `deinit` can synchronously cancel their streams in Swift 6.
    @ObservationIgnored nonisolated(unsafe) private var startupTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var stateSubscriptionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var eventSubscriptionTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var shellRefreshTask: Task<ShellRefreshOutcome, Never>?
    private var shellRefreshPreferenceKey: String?
    private var shellRefreshGeneration: UInt64 = 0
    private var preparedShellPreferenceKey: String?
    private var preparedShellResolution: ZshResolution?
    private var didStart = false

    public init(
        configurationStore: any ConfigurationStoring,
        supervisor: any ProcessSupervising,
        shellEnvironment: any ShellEnvironmentProviding,
        shellEnvironmentRefresher: (any ShellEnvironmentRefreshing)? = nil,
        logs: any LogWarningProviding,
        startsImmediately: Bool = true
    ) {
        self.configurationStore = configurationStore
        self.supervisor = supervisor
        self.shellEnvironmentRefresher =
            shellEnvironmentRefresher
            ?? (supervisor as? any ShellEnvironmentRefreshing)
            ?? LegacyShellEnvironmentRefresher(provider: shellEnvironment)
        self.logs = logs
        if startsImmediately {
            start()
        }
    }

    deinit {
        startupTask?.cancel()
        stateSubscriptionTask?.cancel()
        eventSubscriptionTask?.cancel()
        shellRefreshTask?.cancel()
    }

    /// Starts the one-time configuration load, shell-cache warmup, and actor streams.
    /// Calling it more than once is deliberately idempotent.
    public func start() {
        guard !didStart else { return }
        didStart = true
        subscribeToSupervisor()
        startupTask = Task { [weak self] in
            await self?.loadInitialConfiguration()
            if self?.isConfigurationReady == true {
                await self?.refreshShellEnvironment()
            }
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
            try await saveOrThrow(newConfig)
        } catch {
            // saveOrThrow has already published the user-facing AppAlert.
        }
    }

    /// Persists and adopts a configuration as one main-actor operation. Settings uses
    /// the throwing form so a failed disk write can never be presented as a success.
    public func saveOrThrow(_ newConfig: AppConfig) async throws {
        let originalShellKey = normalizedShellPath(config.preferences.shellPath)
        let newShellKey = normalizedShellPath(newConfig.preferences.shellPath)
        let shellPathChanged = originalShellKey != newShellKey
        let shellPreparationRequired = shellPathChanged || !isShellEnvironmentReady
        if shellPreparationRequired, preparedShellPreferenceKey != newShellKey {
            guard await refreshShellEnvironment(preferences: newConfig.preferences) else {
                throw AppStateSaveError.shellEnvironmentUnavailable
            }
        }
        guard normalizedShellPath(config.preferences.shellPath) == originalShellKey else {
            let message = "Configuration changed while the shell environment was refreshing. Review the latest settings and save again."
            showAlert(.save, message)
            throw AppStateSaveError.configurationChanged
        }

        do {
            try await configurationStore.save(newConfig)
            config = newConfig
            isConfigurationReady = true
            configurationWarning = nil
            if alert?.kind == .configurationRecovery || alert?.kind == .save {
                alert = nil
            }
            if shellPathChanged {
                resolvedShellPath = preparedShellResolution?.path
                isShellEnvironmentReady = preparedShellPreferenceKey == newShellKey
                preparedShellPreferenceKey = nil
                preparedShellResolution = nil
                if !isShellEnvironmentReady {
                    showAlert(.shellEnvironment, "The saved shell environment is not ready. Refresh it before starting services.")
                }
            }
        } catch {
            showAlert(.save, error.localizedDescription)
            throw error
        }
    }

    /// UI-callable retry. Calls for the same preference share one refresh task; a result
    /// from an older shell preference can never overwrite a newer refresh.
    @discardableResult
    public func refreshShellEnvironment() async -> Bool {
        await refreshShellEnvironment(preferences: config.preferences)
    }

    /// Preferences uses this overload to validate and warm a draft zsh path before save.
    /// The current configuration is left unchanged; starts remain blocked while it runs.
    @discardableResult
    public func refreshShellEnvironment(preferences: PreferencesConfig) async -> Bool {
        let preferenceKey = normalizedShellPath(preferences.shellPath)
        let livePreferenceKey = normalizedShellPath(config.preferences.shellPath)
        let previousReady = isShellEnvironmentReady
        let previousResolvedPath = resolvedShellPath
        isShellEnvironmentReady = false
        isShellEnvironmentRefreshing = true

        let generation: UInt64
        let task: Task<ShellRefreshOutcome, Never>
        if let activeTask = shellRefreshTask, shellRefreshPreferenceKey == preferenceKey {
            generation = shellRefreshGeneration
            task = activeTask
        } else {
            shellRefreshTask?.cancel()
            shellRefreshGeneration &+= 1
            generation = shellRefreshGeneration
            shellRefreshPreferenceKey = preferenceKey
            let refresher = shellEnvironmentRefresher
            task = Task {
                do {
                    return .success(try await refresher.refreshShellEnvironment(preferences: preferences))
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
            shellRefreshTask = task
        }

        let outcome = await task.value
        guard generation == shellRefreshGeneration else {
            return false
        }
        shellRefreshTask = nil
        shellRefreshPreferenceKey = nil
        isShellEnvironmentRefreshing = false

        switch outcome {
        case let .success(resolution):
            if preferenceKey == normalizedShellPath(config.preferences.shellPath) {
                resolvedShellPath = resolution.path
                isShellEnvironmentReady = true
            } else {
                preparedShellPreferenceKey = preferenceKey
                preparedShellResolution = resolution
                if livePreferenceKey == normalizedShellPath(config.preferences.shellPath) {
                    resolvedShellPath = previousResolvedPath
                    isShellEnvironmentReady = previousReady
                }
            }
            if alert?.kind == .shellEnvironment { alert = nil }
            return true
        case let .failure(message):
            preparedShellPreferenceKey = nil
            preparedShellResolution = nil
            if preferenceKey == normalizedShellPath(config.preferences.shellPath) {
                resolvedShellPath = nil
                isShellEnvironmentReady = false
            } else if livePreferenceKey == normalizedShellPath(config.preferences.shellPath) {
                resolvedShellPath = previousResolvedPath
                isShellEnvironmentReady = previousReady
            }
            showAlert(.shellEnvironment, message)
            return false
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

    private func normalizedShellPath(_ path: String) -> String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
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

private enum ShellRefreshOutcome: Sendable {
    case success(ZshResolution)
    case failure(String)
}

public enum AppStateSaveError: Error, Equatable, Sendable, LocalizedError {
    case shellEnvironmentUnavailable
    case configurationChanged

    public var errorDescription: String? {
        switch self {
        case .shellEnvironmentUnavailable:
            "The selected shell environment is unavailable. Refresh it and try again."
        case .configurationChanged:
            "The configuration changed while saving. Review the latest settings and try again."
        }
    }
}
