import AppKit
import DevBarCore
import Foundation

@MainActor
struct AppDependencies {
    let appState: AppState
    let paths: AppPaths
    let logStore: LogStore
    let deletionCoordinator: DeletionCoordinator

    static func live() -> AppDependencies {
        let paths = AppPaths()
        let configurationStore = ConfigurationStore(paths: paths)
        let logs = LogStore(paths: paths)
        let supervisor = ProcessSupervisor(logStore: logs)
        let shell = ShellEnvironmentProvider(zshPath: "/bin/zsh")
        return AppDependencies(
            appState: AppState(
                configurationStore: configurationStore,
                supervisor: supervisor,
                shellEnvironment: shell,
                logs: logs
            ),
            paths: paths,
            logStore: logs,
            deletionCoordinator: DeletionCoordinator(
                paths: paths,
                configurationStore: configurationStore
            )
        )
    }

    /// UI tests are deliberately independent from real configuration, Runner helpers,
    /// and the user's shell files.
    static func uiTesting(configuration: AppConfig, applicationSupportRoot: URL) -> AppDependencies {
        let paths = AppPaths(applicationSupport: applicationSupportRoot)
        let configurationStore = InMemoryConfigurationStore(configuration: configuration)
        let logs = LogStore(paths: paths)
        let supervisor = UITestProcessSupervisor(configuration: configuration)
        let shell = StaticShellEnvironment()
        return AppDependencies(
            appState: AppState(
                configurationStore: configurationStore,
                supervisor: supervisor,
                shellEnvironment: shell,
                logs: logs
            ),
            paths: paths,
            logStore: logs,
            deletionCoordinator: DeletionCoordinator(
                paths: paths,
                configurationStore: configurationStore
            )
        )
    }

    func makeSettingsViewModel(
        directoryPicker: (any DirectoryPicking)? = nil
    ) -> SettingsViewModel {
        SettingsViewModel(
            configuration: appState.config,
            directoryPicker: directoryPicker,
            workspaceLocked: { [appState] workspaceID in
                appState.isEditingLocked(workspaceID: workspaceID)
            },
            commit: { [appState, deletionCoordinator] baseline, draft in
                let movedLogFolders = try await deletionCoordinator.prepareConfigurationChanges(
                    from: baseline,
                    to: draft
                )
                do {
                    try await appState.saveOrThrow(draft)
                } catch {
                    if movedLogFolders > 0 {
                        throw SettingsCommitError.configurationSaveFailedAfterTrash(
                            recoverableItemCount: movedLogFolders,
                            message: error.localizedDescription
                        )
                    }
                    throw error
                }
            },
            refreshShell: { [appState] shellPath in
                var preferences = appState.config.preferences
                preferences.shellPath = shellPath
                guard await appState.refreshShellEnvironment(preferences: preferences) else {
                    throw AppStateSaveError.shellEnvironmentUnavailable
                }
            }
        )
    }

    func makeLogViewModel(selectedServiceID: UUID? = nil) -> LogViewModel {
        LogViewModel(
            services: LogServiceDescriptor.all(in: appState.config),
            selectedServiceID: selectedServiceID,
            store: logStore,
            openDirectory: { [paths] service in
                let directory = paths.logsRootURL
                    .appendingPathComponent(service.workspaceID.uuidString.lowercased(), isDirectory: true)
                    .appendingPathComponent(service.serviceID.uuidString.lowercased(), isDirectory: true)
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            },
            deleteHistory: { [appState, deletionCoordinator, logStore] service in
                guard !Self.isActive(appState.serviceStates[service.serviceID] ?? .stopped) else {
                    throw LogHistoryActionError.serviceIsRunning
                }
                _ = try await deletionCoordinator.trashLogs(
                    for: .service(workspaceID: service.workspaceID, serviceID: service.serviceID)
                )
                await logStore.forgetHistory(serviceID: service.serviceID)
            }
        )
    }

    private static func isActive(_ state: ServiceState) -> Bool {
        switch state {
        case .starting, .running, .ready, .unready, .stopping: true
        case .stopped, .failed: false
        }
    }
}

private enum LogHistoryActionError: Error, LocalizedError {
    case serviceIsRunning

    var errorDescription: String? {
        "请先停止服务，再删除磁盘日志。"
    }
}

private enum SettingsCommitError: Error, LocalizedError {
    case configurationSaveFailedAfterTrash(recoverableItemCount: Int, message: String)

    var errorDescription: String? {
        switch self {
        case let .configurationSaveFailedAfterTrash(count, message):
            "配置未保存；\(count) 个日志目录已移入废纸篓，可恢复后重试。\(message)"
        }
    }
}

private actor InMemoryConfigurationStore: ConfigurationStoring, ConfigurationPersisting {
    private var configuration: AppConfig

    init(configuration: AppConfig) {
        self.configuration = configuration
    }

    func load() -> AppConfig { configuration }

    func save(_ config: AppConfig) {
        configuration = config
    }

    func persist(_ configuration: AppConfig) {
        self.configuration = configuration
    }
}

private actor StaticShellEnvironment: ShellEnvironmentProviding {
    func cachedOrRefresh() -> [String: String] { [:] }

    func refresh() -> [String: String] { [:] }
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
