import DevBarCore
import Foundation

@MainActor
struct AppDependencies {
    let appState: AppState

    static func live() -> AppDependencies {
        let paths = AppPaths()
        let logs = LogStore(paths: paths)
        let supervisor = ProcessSupervisor(logStore: logs)
        let shell = ShellEnvironmentProvider(zshPath: "/bin/zsh")
        return AppDependencies(
            appState: AppState(
                configurationStore: ConfigurationStore(paths: paths),
                supervisor: supervisor,
                shellEnvironment: shell,
                logs: logs
            )
        )
    }

    /// UI tests are deliberately independent from real configuration, Runner helpers,
    /// and the user's shell files. The supplied root is retained as an explicit test
    /// boundary for future test-only filesystem fixtures.
    static func uiTesting(configuration: AppConfig, applicationSupportRoot: URL) -> AppDependencies {
        let configurationStore = InMemoryConfigurationStore(configuration: configuration)
        let supervisor = UITestProcessSupervisor(configuration: configuration)
        let shell = StaticShellEnvironment()
        let logs = UITestLogWarnings()
        _ = applicationSupportRoot.standardizedFileURL
        return AppDependencies(
            appState: AppState(
                configurationStore: configurationStore,
                supervisor: supervisor,
                shellEnvironment: shell,
                logs: logs
            )
        )
    }
}

private actor InMemoryConfigurationStore: ConfigurationStoring {
    private var configuration: AppConfig

    init(configuration: AppConfig) {
        self.configuration = configuration
    }

    func load() -> AppConfig { configuration }

    func save(_ config: AppConfig) {
        configuration = config
    }
}

private actor StaticShellEnvironment: ShellEnvironmentProviding {
    func cachedOrRefresh() -> [String: String] { [:] }
}

private actor UITestLogWarnings: LogWarningProviding {
    func warnings() -> [LogStoreWarning] { [] }
}

private actor UITestProcessSupervisor: ProcessSupervising {
    private let configuration: AppConfig
    private var stateContinuations: [UUID: AsyncStream<ServiceRuntime>.Continuation] = [:]
    private var eventContinuations: [UUID: AsyncStream<SupervisedServiceRuntimeEvent>.Continuation] = [:]

    init(configuration: AppConfig) {
        self.configuration = configuration
    }

    func stateUpdates() -> AsyncStream<ServiceRuntime> {
        let id = UUID()
        return AsyncStream { continuation in
            stateContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id) }
            }
        }
    }

    func runtimeEvents() -> AsyncStream<SupervisedServiceRuntimeEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }

    func start(service: ServiceConfig, workspace: WorkspaceConfig, preferences _: PreferencesConfig) {
        emit(.init(workspaceID: workspace.id, serviceID: service.id, state: .running(runID: UUID())))
    }

    func stop(serviceID: UUID) {
        guard let workspace = configuration.workspaces.first(where: { workspace in
            workspace.services.contains(where: { $0.id == serviceID })
        }) else { return }
        emit(.init(workspaceID: workspace.id, serviceID: serviceID, state: .stopped))
    }

    func startAll(workspace: WorkspaceConfig, preferences _: PreferencesConfig) {
        for service in workspace.services where service.includeInStartAll {
            emit(.init(workspaceID: workspace.id, serviceID: service.id, state: .running(runID: UUID())))
        }
    }

    func stopAll(workspaceID: UUID) {
        guard let workspace = configuration.workspaces.first(where: { $0.id == workspaceID }) else { return }
        for service in workspace.services {
            emit(.init(workspaceID: workspaceID, serviceID: service.id, state: .stopped))
        }
    }

    private func emit(_ runtime: ServiceRuntime) {
        for continuation in stateContinuations.values { continuation.yield(runtime) }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations[id] = nil
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations[id] = nil
    }
}
