import Foundation
import XCTest
@testable import DevBarCore

@MainActor
final class AppStateTests: XCTestCase {
    func testFirstLaunchLoadsEmptyConfigurationAndStartsShellWarmup() async throws {
        let configuration = FakeConfigurationStore(result: .success(.empty))
        let shell = FakeShellEnvironment(result: .success(["PATH": "/usr/bin"]))
        let appState = makeAppState(configuration: configuration, shell: shell)

        appState.start()
        try await waitUntil { appState.isConfigurationReady && appState.isShellEnvironmentReady }

        XCTAssertTrue(appState.isFirstLaunch)
        XCTAssertEqual(appState.aggregateStatus, .neutral)
        let shellCallCount = await shell.callCount()
        XCTAssertEqual(shellCallCount, 1)
    }

    func testConfigurationFailureAndLogWarningBothMakeAggregateStatusError() async throws {
        let configuration = FakeConfigurationStore(result: .failure(FakeError.configuration))
        let warning = LogStoreWarning(serviceID: UUID(), kind: .write, message: "Disk unavailable")
        let logs = FakeLogs(warnings: [warning])
        let appState = makeAppState(configuration: configuration, logs: logs)

        appState.start()
        try await waitUntil { appState.alert?.kind == .configurationRecovery && !appState.logWarnings.isEmpty }

        XCTAssertEqual(appState.aggregateStatus, .error)
        XCTAssertFalse(appState.isConfigurationReady)
        XCTAssertEqual(appState.alert?.kind, .configurationRecovery)
    }

    func testStartAndStopDelegateToConfiguredWorkspaceOnlyAfterShellIsReady() async throws {
        let workspace = workspace()
        let supervisor = FakeSupervisor()
        let appState = makeAppState(configuration: .init(result: .success(config(workspaces: [workspace]))), supervisor: supervisor)

        appState.start()
        try await waitUntil { appState.isConfigurationReady && appState.isShellEnvironmentReady }
        await appState.startAll(workspaceID: workspace.id)
        await appState.stopAll(workspaceID: workspace.id)

        let startedWorkspaces = await supervisor.startedWorkspaceIDs()
        let stoppedWorkspaces = await supervisor.stoppedWorkspaceIDs()
        XCTAssertEqual(startedWorkspaces, [workspace.id])
        XCTAssertEqual(stoppedWorkspaces, [workspace.id])
    }

    func testRunningServiceLocksWorkspaceEditsAndRequiresQuitConfirmation() async throws {
        let workspace = workspace()
        let supervisor = FakeSupervisor()
        let appState = makeAppState(configuration: .init(result: .success(config(workspaces: [workspace]))), supervisor: supervisor)

        appState.start()
        try await waitUntil { appState.isConfigurationReady }
        await supervisor.emit(.init(workspaceID: workspace.id, serviceID: workspace.services[0].id, state: .running(runID: UUID())))
        try await waitUntil { appState.isEditingLocked(workspaceID: workspace.id) }

        XCTAssertEqual(appState.aggregateStatus, .ready)
        guard case let .confirmationRequired(active) = await appState.prepareToQuit() else {
            return XCTFail("Expected running services to require quit confirmation")
        }
        XCTAssertEqual(active.map(\.serviceID), [workspace.services[0].id])

        await supervisor.emit(.init(workspaceID: workspace.id, serviceID: workspace.services[0].id, state: .stopped))
        try await waitUntil { !appState.isEditingLocked(workspaceID: workspace.id) }
        let quitResult = await appState.prepareToQuit()
        XCTAssertEqual(quitResult, .immediate)
    }

    func testSaveRecoversFromConfigurationWarningWithoutBlockingSettings() async throws {
        let store = FakeConfigurationStore(result: .failure(FakeError.configuration))
        let appState = makeAppState(configuration: store)
        let repaired = config(workspaces: [])

        appState.start()
        try await waitUntil { appState.alert?.kind == .configurationRecovery }
        await appState.save(repaired)

        XCTAssertTrue(appState.isConfigurationReady)
        XCTAssertEqual(appState.config, repaired)
        XCTAssertNil(appState.alert)
        let savedConfigurations = await store.savedConfigurations()
        XCTAssertEqual(savedConfigurations, [repaired])
    }

    func testConfigurationEventsAreSerializedAndAppliedToLatestSnapshot() async throws {
        let originalWorkspace = workspace()
        let store = FakeConfigurationStore(result: .success(config(workspaces: [originalWorkspace])))
        let appState = makeAppState(configuration: store)
        let gate = ConfigurationEventGate()
        appState.start()
        try await waitUntil { appState.isConfigurationReady && appState.isShellEnvironmentReady }

        var renamedWorkspace = originalWorkspace
        renamedWorkspace.name = "Renamed"
        let first = Task {
            try await appState.applyConfigurationEvent(.upsertWorkspace(renamedWorkspace)) { _, _ in
                await gate.wait()
            }
        }
        await gate.waitUntilEntered()

        var preferences = PreferencesConfig.default
        preferences.logFileCount = 7
        let second = Task {
            try await appState.applyConfigurationEvent(.updatePreferences(preferences))
        }
        await Task.yield()
        let savesWhileBlocked = await store.savedConfigurations()
        XCTAssertTrue(savesWhileBlocked.isEmpty)

        await gate.release()
        _ = try await first.value
        _ = try await second.value

        let saves = await store.savedConfigurations()
        XCTAssertEqual(saves.count, 2)
        XCTAssertEqual(saves[0].workspaces[0].name, "Renamed")
        XCTAssertEqual(saves[1].workspaces[0].name, "Renamed")
        XCTAssertEqual(saves[1].preferences.logFileCount, 7)
    }

    func testStartWaitingOnFailedConfigurationEventIsCancelled() async throws {
        let configuredWorkspace = workspace()
        let supervisor = FakeSupervisor()
        let appState = makeAppState(
            configuration: .init(result: .success(config(workspaces: [configuredWorkspace]))),
            supervisor: supervisor
        )
        let gate = ConfigurationEventGate()
        appState.start()
        try await waitUntil { appState.isConfigurationReady && appState.isShellEnvironmentReady }

        var renamedWorkspace = configuredWorkspace
        renamedWorkspace.name = "Will fail"
        let event = Task {
            try await appState.applyConfigurationEvent(.upsertWorkspace(renamedWorkspace)) { _, _ in
                await gate.wait()
                throw FakeError.configuration
            }
        }
        await gate.waitUntilEntered()
        let start = Task {
            await appState.startAll(workspaceID: configuredWorkspace.id)
        }
        await Task.yield()
        let startsWhileBlocked = await supervisor.startedWorkspaceIDs()
        XCTAssertTrue(startsWhileBlocked.isEmpty)

        await gate.release()
        _ = try? await event.value
        await start.value

        let startsAfterFailure = await supervisor.startedWorkspaceIDs()
        XCTAssertTrue(startsAfterFailure.isEmpty)
        XCTAssertEqual(appState.config.workspaces[0].name, configuredWorkspace.name)
    }

    func testSuccessfulBackupRecoveryIsVisibleWithoutBlockingServiceConfiguration() async throws {
        let recovered = config(workspaces: [])
        let diagnosticStore = DiagnosticConfigurationStore(
            result: .init(
                configuration: recovered,
                source: .backup(preservedCorruptURL: URL(fileURLWithPath: "/tmp/config.json.corrupt-test"))
            )
        )
        let appState = AppState(
            configurationStore: diagnosticStore,
            supervisor: FakeSupervisor(),
            shellEnvironment: FakeShellEnvironment(result: .success([:])),
            logs: FakeLogs(warnings: []),
            startsImmediately: false
        )

        appState.start()
        try await waitUntil { appState.alert?.kind == .configurationRecovery }

        XCTAssertTrue(appState.isConfigurationReady)
        XCTAssertEqual(appState.config, recovered)
        XCTAssertTrue(appState.alert?.message.contains("config.json.bak") == true)
    }

    func testStartupResolvesAndRefreshesConfiguredShellPath() async throws {
        let configuredPath = "/opt/homebrew/bin/zsh"
        let refresher = ControlledShellEnvironmentRefresher()
        await refresher.resolve(path: configuredPath, with: .success(resolution(path: configuredPath)))
        let appState = makeAppState(
            configuration: .init(result: .success(config(workspaces: [], shellPath: configuredPath))),
            shellRefresher: refresher
        )

        appState.start()
        try await waitUntil { appState.isShellEnvironmentReady }

        XCTAssertEqual(appState.resolvedShellPath, configuredPath)
        let requestedPaths = await refresher.requestedPaths()
        XCTAssertEqual(requestedPaths, [configuredPath])
    }

    func testChangedShellBlocksStartsUntilRefreshSucceeds() async throws {
        let oldPath = "/bin/zsh"
        let newPath = "/opt/devbar/zsh"
        let workspace = workspace()
        let refresher = ControlledShellEnvironmentRefresher()
        await refresher.resolve(path: oldPath, with: .success(resolution(path: oldPath)))
        let supervisor = FakeSupervisor()
        let appState = makeAppState(
            configuration: .init(result: .success(config(workspaces: [workspace], shellPath: oldPath))),
            supervisor: supervisor,
            shellRefresher: refresher
        )
        appState.start()
        try await waitUntil { appState.isShellEnvironmentReady }

        let saveTask = Task {
            await appState.save(config(workspaces: [workspace], shellPath: newPath))
        }
        try await waitUntilRequested(newPath, by: refresher)
        XCTAssertTrue(appState.isShellEnvironmentRefreshing)
        XCTAssertEqual(appState.config.preferences.shellPath, oldPath)
        await appState.startAll(workspaceID: workspace.id)
        let startsWhileRefreshing = await supervisor.startedWorkspaceIDs()
        XCTAssertEqual(startsWhileRefreshing, [])

        await refresher.resolve(path: newPath, with: .success(resolution(path: newPath)))
        await saveTask.value
        XCTAssertTrue(appState.isShellEnvironmentReady)
        XCTAssertEqual(appState.resolvedShellPath, newPath)

        await appState.startAll(workspaceID: workspace.id)
        let startsAfterRefresh = await supervisor.startedWorkspaceIDs()
        XCTAssertEqual(startsAfterRefresh, [workspace.id])
    }

    func testOlderFailedRefreshCannotOverwriteNewShellSuccess() async throws {
        let oldPath = "/bin/zsh"
        let firstPath = "/opt/first/zsh"
        let latestPath = "/opt/latest/zsh"
        let refresher = ControlledShellEnvironmentRefresher()
        await refresher.resolve(path: oldPath, with: .success(resolution(path: oldPath)))
        let appState = makeAppState(
            configuration: .init(result: .success(config(workspaces: [], shellPath: oldPath))),
            shellRefresher: refresher
        )
        appState.start()
        try await waitUntil { appState.isShellEnvironmentReady }

        let firstSave = Task {
            await appState.save(config(workspaces: [], shellPath: firstPath))
        }
        try await waitUntilRequested(firstPath, by: refresher)
        let latestSave = Task {
            await appState.save(config(workspaces: [], shellPath: latestPath))
        }
        try await waitUntilRequested(latestPath, by: refresher)

        await refresher.resolve(path: latestPath, with: .success(resolution(path: latestPath)))
        await latestSave.value
        await refresher.resolve(path: firstPath, with: .failure(FakeError.shell))
        await firstSave.value

        XCTAssertEqual(appState.config.preferences.shellPath, latestPath)
        XCTAssertEqual(appState.resolvedShellPath, latestPath)
        XCTAssertTrue(appState.isShellEnvironmentReady)
        XCTAssertNotEqual(appState.alert?.kind, .shellEnvironment)
    }

    func testFailedDraftShellRefreshIsNotPersisted() async throws {
        let oldPath = "/bin/zsh"
        let invalidPath = "/missing/zsh"
        let refresher = ControlledShellEnvironmentRefresher()
        await refresher.resolve(path: oldPath, with: .success(resolution(path: oldPath)))
        await refresher.resolve(path: invalidPath, with: .failure(FakeError.shell))
        let store = FakeConfigurationStore(result: .success(config(workspaces: [], shellPath: oldPath)))
        let appState = makeAppState(configuration: store, shellRefresher: refresher)
        appState.start()
        try await waitUntil { appState.isShellEnvironmentReady }

        await appState.save(config(workspaces: [], shellPath: invalidPath))

        XCTAssertEqual(appState.config.preferences.shellPath, oldPath)
        XCTAssertEqual(appState.resolvedShellPath, oldPath)
        XCTAssertTrue(appState.isShellEnvironmentReady)
        XCTAssertEqual(appState.alert?.kind, .shellEnvironment)
        let savedConfigurations = await store.savedConfigurations()
        XCTAssertTrue(savedConfigurations.isEmpty)
    }

    private func makeAppState(
        configuration: FakeConfigurationStore = .init(result: .success(.empty)),
        supervisor: FakeSupervisor = .init(),
        shell: FakeShellEnvironment = .init(result: .success([:])),
        shellRefresher: (any ShellEnvironmentRefreshing)? = nil,
        logs: FakeLogs = .init(warnings: [])
    ) -> AppState {
        AppState(
            configurationStore: configuration,
            supervisor: supervisor,
            shellEnvironment: shell,
            shellEnvironmentRefresher: shellRefresher,
            logs: logs,
            startsImmediately: false
        )
    }

    private func workspace() -> WorkspaceConfig {
        WorkspaceConfig(
            name: "Workspace",
            rootDirectory: "/tmp",
            iconSymbol: "terminal.fill",
            tintHex: "#FF7A59",
            environment: [],
            services: [
                ServiceConfig(name: "Web", workingDirectory: .absolute("/tmp"), command: "npm run dev")
            ]
        )
    }

    private func config(workspaces: [WorkspaceConfig], shellPath: String = "") -> AppConfig {
        var preferences = PreferencesConfig.default
        preferences.shellPath = shellPath
        return AppConfig(workspaces: workspaces, preferences: preferences)
    }

    private func resolution(path: String) -> ZshResolution {
        ZshResolution(path: path, source: .shellEnvironment, warning: nil)
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !predicate() {
            guard clock.now < deadline else { throw FakeError.timeout }
            await Task.yield()
        }
    }

    private func waitUntilRequested(
        _ path: String,
        by refresher: ControlledShellEnvironmentRefresher,
        timeout: Duration = .seconds(1)
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await refresher.requestedPaths()).contains(path) {
            guard clock.now < deadline else { throw FakeError.timeout }
            await Task.yield()
        }
    }
}

private enum FakeError: Error, LocalizedError {
    case configuration
    case shell
    case timeout

    var errorDescription: String? {
        switch self {
        case .configuration: "Configuration could not be recovered."
        case .shell: "Shell refresh failed."
        case .timeout: "Timed out waiting for app state."
        }
    }
}

private actor ConfigurationEventGate {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters.removeAll()
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            enteredWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}

private actor ControlledShellEnvironmentRefresher: ShellEnvironmentRefreshing {
    private var queuedResults: [String: Result<ZshResolution, Error>] = [:]
    private var continuations: [String: [CheckedContinuation<ZshResolution, Error>]] = [:]
    private var requests: [String] = []

    func refreshShellEnvironment(preferences: PreferencesConfig) async throws -> ZshResolution {
        let path = preferences.shellPath.trimmingCharacters(in: .whitespacesAndNewlines)
        requests.append(path)
        if let result = queuedResults.removeValue(forKey: path) {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[path, default: []].append(continuation)
        }
    }

    func resolve(path: String, with result: Result<ZshResolution, Error>) {
        guard var waiting = continuations.removeValue(forKey: path), !waiting.isEmpty else {
            queuedResults[path] = result
            return
        }
        let continuation = waiting.removeFirst()
        if !waiting.isEmpty { continuations[path] = waiting }
        continuation.resume(with: result)
    }

    func requestedPaths() -> [String] { requests }
}

private actor FakeConfigurationStore: ConfigurationStoring {
    private let result: Result<AppConfig, Error>
    private var saves: [AppConfig] = []

    init(result: Result<AppConfig, Error>) {
        self.result = result
    }

    func load() throws -> AppConfig {
        try result.get()
    }

    func save(_ config: AppConfig) {
        saves.append(config)
    }

    func savedConfigurations() -> [AppConfig] { saves }
}

private actor DiagnosticConfigurationStore: ConfigurationStoring, ConfigurationLoadDiagnosing {
    private let result: ConfigurationLoadResult

    init(result: ConfigurationLoadResult) {
        self.result = result
    }

    func load() -> AppConfig { result.configuration }
    func loadResult() -> ConfigurationLoadResult { result }
    func save(_: AppConfig) {}
}

private actor FakeShellEnvironment: ShellEnvironmentProviding {
    private let result: Result<[String: String], Error>
    private var calls = 0

    init(result: Result<[String: String], Error>) {
        self.result = result
    }

    func cachedOrRefresh() throws -> [String: String] {
        calls += 1
        return try result.get()
    }

    func callCount() -> Int { calls }
}

private actor FakeLogs: LogWarningProviding {
    private let suppliedWarnings: [LogStoreWarning]

    init(warnings: [LogStoreWarning]) {
        suppliedWarnings = warnings
    }

    func warnings() -> [LogStoreWarning] { suppliedWarnings }
}

private actor FakeSupervisor: ProcessSupervising {
    private var stateContinuations: [UUID: AsyncStream<ServiceRuntime>.Continuation] = [:]
    private var eventContinuations: [UUID: AsyncStream<SupervisedServiceRuntimeEvent>.Continuation] = [:]
    private var stateHistory: [ServiceRuntime] = []
    private var starts: [UUID] = []
    private var stops: [UUID] = []

    func start(service: ServiceConfig, workspace: WorkspaceConfig, preferences _: PreferencesConfig) {
        starts.append(workspace.id)
        emit(.init(workspaceID: workspace.id, serviceID: service.id, state: .running(runID: UUID())))
    }

    func stop(serviceID: UUID) {
        stops.append(serviceID)
    }

    func stateUpdates() -> AsyncStream<ServiceRuntime> {
        let id = UUID()
        let history = stateHistory
        return AsyncStream<ServiceRuntime>(bufferingPolicy: .unbounded) { continuation in
            stateContinuations[id] = continuation
            history.forEach { _ = continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(id) }
            }
        }
    }

    func runtimeEvents() -> AsyncStream<SupervisedServiceRuntimeEvent> {
        let id = UUID()
        return AsyncStream<SupervisedServiceRuntimeEvent>(bufferingPolicy: .unbounded) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(id) }
            }
        }
    }

    func startAll(workspace: WorkspaceConfig, preferences _: PreferencesConfig) {
        starts.append(workspace.id)
    }

    func stopAll(workspaceID: UUID) {
        stops.append(workspaceID)
    }

    func emit(_ runtime: ServiceRuntime) {
        stateHistory.removeAll { $0.serviceID == runtime.serviceID }
        stateHistory.append(runtime)
        for continuation in stateContinuations.values { continuation.yield(runtime) }
    }

    func startedWorkspaceIDs() -> [UUID] { starts }
    func stoppedWorkspaceIDs() -> [UUID] { stops }

    private func removeStateContinuation(_ id: UUID) { stateContinuations[id] = nil }
    private func removeEventContinuation(_ id: UUID) { eventContinuations[id] = nil }
}
