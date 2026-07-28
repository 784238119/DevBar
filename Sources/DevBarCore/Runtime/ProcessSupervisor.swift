import Foundation

public protocol ZshResolving {
    func resolve(environment: [String: String]) throws -> ZshResolution
}

extension ZshResolver: ZshResolving {}

public protocol ShellEnvironmentProviding: Sendable {
    func cachedOrRefresh() async throws -> [String: String]
}

extension ShellEnvironmentProvider: ShellEnvironmentProviding {}

public protocol ServiceLogStoring: Sendable {
    func prepare(workspaceID: UUID, serviceID: UUID) async throws
    func append(
        data: Data,
        stream: LogStream,
        workspaceID: UUID,
        serviceID: UUID,
        runID: UUID
    ) async
    func finishStream(
        stream: LogStream,
        workspaceID: UUID,
        serviceID: UUID,
        runID: UUID
    ) async
}

extension LogStore: ServiceLogStoring {}

public protocol ShellEnvironmentProvidingFactory: Sendable {
    func makeProvider(zshPath: String) -> any ShellEnvironmentProviding
}

public struct DefaultShellEnvironmentProviderFactory: ShellEnvironmentProvidingFactory {
    public init() {}

    public func makeProvider(zshPath: String) -> any ShellEnvironmentProviding {
        ShellEnvironmentProvider(zshPath: zshPath)
    }
}

/// Coordinates service state without owning presentation. Every state transition occurs on this
/// actor and is tagged with a fresh run ID, so delayed Runner output cannot affect a restart.
public actor ProcessSupervisor {
    private let runner: any RunnerControlling
    private let zshResolver: any ZshResolving
    private let environmentProviderFactory: any ShellEnvironmentProvidingFactory
    private let logStore: (any ServiceLogStoring)?
    private let healthChecker: HealthChecker
    private let noneRunningDelay: Duration
    private let fileManager: FileManager

    private var providersByZshPath: [String: any ShellEnvironmentProviding] = [:]
    private var runtimes: [UUID: ServiceRuntime] = [:]
    private var runIDs: [UUID: UUID] = [:]
    private var stateContinuations: [UUID: AsyncStream<ServiceRuntime>.Continuation] = [:]
    private var eventContinuations: [UUID: AsyncStream<SupervisedServiceRuntimeEvent>.Continuation] = [:]
    private var runnerStartedRuns: [UUID: UUID] = [:]
    private var noneHealthTasks: [UUID: Task<Void, Never>] = [:]
    private var healthConfigs: [UUID: (runID: UUID, config: HealthCheckConfig)] = [:]

    public init(
        runner: any RunnerControlling = RunnerClient(),
        zshResolver: any ZshResolving = ZshResolver(),
        environmentProviderFactory: any ShellEnvironmentProvidingFactory = DefaultShellEnvironmentProviderFactory(),
        logStore: (any ServiceLogStoring)? = nil,
        healthChecker: HealthChecker = HealthChecker(),
        noneRunningDelay: Duration = .seconds(1),
        fileManager: FileManager = .default
    ) {
        self.runner = runner
        self.zshResolver = zshResolver
        self.environmentProviderFactory = environmentProviderFactory
        self.logStore = logStore
        self.healthChecker = healthChecker
        self.noneRunningDelay = noneRunningDelay
        self.fileManager = fileManager
    }

    public func state(for serviceID: UUID) -> ServiceState {
        runtimes[serviceID]?.state ?? .stopped
    }

    public func runtime(for serviceID: UUID) -> ServiceRuntime? {
        runtimes[serviceID]
    }

    public func stateUpdates() -> AsyncStream<ServiceRuntime> {
        let subscriberID = UUID()
        return AsyncStream { continuation in
            stateContinuations[subscriberID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateContinuation(subscriberID) }
            }
        }
    }

    public func runtimeEvents() -> AsyncStream<SupervisedServiceRuntimeEvent> {
        let subscriberID = UUID()
        return AsyncStream { continuation in
            eventContinuations[subscriberID] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeEventContinuation(subscriberID) }
            }
        }
    }

    public func start(service: ServiceConfig, workspace: WorkspaceConfig, preferences: PreferencesConfig = .default) async {
        let serviceID = service.id
        switch state(for: serviceID) {
        case .stopped, .failed:
            break
        case .starting, .running, .ready, .unready, .stopping:
            return
        }

        let runID = UUID()
        runIDs[serviceID] = runID
        healthConfigs[serviceID] = (runID, service.healthCheck)
        setRuntime(.init(workspaceID: workspace.id, serviceID: serviceID, state: .starting(runID: runID)))

        let workingDirectory: String
        do {
            workingDirectory = try resolveWorkingDirectory(service: service, workspace: workspace)
        } catch {
            fail(serviceID: serviceID, runID: runID, failure: .invalidWorkingDirectory(error.localizedDescription))
            return
        }

        let zsh: ZshResolution
        do {
            var shellEnvironment = ProcessInfo.processInfo.environment
            if !preferences.shellPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                shellEnvironment["SHELL"] = preferences.shellPath
            }
            zsh = try zshResolver.resolve(environment: shellEnvironment)
        } catch {
            fail(serviceID: serviceID, runID: runID, failure: .zshResolution(error.localizedDescription))
            return
        }

        let capturedEnvironment: [String: String]
        do {
            let provider = provider(for: zsh.path)
            capturedEnvironment = try await provider.cachedOrRefresh()
        } catch {
            fail(serviceID: serviceID, runID: runID, failure: .environmentCapture(error.localizedDescription))
            return
        }

        guard isCurrentRun(runID, for: serviceID, expected: .starting) else { return }
        do {
            try await logStore?.prepare(workspaceID: workspace.id, serviceID: serviceID)
        } catch {
            fail(serviceID: serviceID, runID: runID, failure: .logInitialization(error.localizedDescription))
            return
        }
        guard isCurrentRun(runID, for: serviceID, expected: .starting) else { return }

        let request = RunnerLaunchRequest(
            runID: runID,
            zshPath: zsh.path,
            command: service.command,
            workingDirectory: workingDirectory,
            environment: EnvironmentMerger.merge(
                captured: capturedEnvironment,
                workspace: workspace.environment,
                service: service.environment
            ),
            sigintGraceSeconds: preferences.sigintGraceSeconds,
            sigtermGraceSeconds: preferences.sigtermGraceSeconds
        )

        do {
            let stream = try await runner.launch(request)
            guard isCurrentRun(runID, for: serviceID, expected: .starting) else {
                // Stop a Runner that finished launching while a user cancellation was processed.
                try? await runner.stop(runID: runID)
                return
            }
            consume(stream, workspaceID: workspace.id, serviceID: serviceID, runID: runID)
        } catch {
            fail(serviceID: serviceID, runID: runID, failure: .runnerLaunch(error.localizedDescription))
        }
    }

    public func stop(serviceID: UUID) async {
        guard let runtime = runtimes[serviceID], let runID = runIDs[serviceID] else { return }
        switch runtime.state {
        case .stopped, .failed, .stopping:
            return
        case .starting:
            guard runnerStartedRuns[serviceID] == runID else {
                // No confirmed Runner exists yet. Invalidate this run before publishing
                // stopped so queued Runner events cannot turn the cancellation into a failure.
                cancelHealth(serviceID: serviceID, runID: runID)
                runIDs.removeValue(forKey: serviceID)
                runnerStartedRuns.removeValue(forKey: serviceID)
                healthConfigs.removeValue(forKey: serviceID)
                setRuntime(.init(workspaceID: runtime.workspaceID, serviceID: serviceID, state: .stopped))
                return
            }
            setRuntime(.init(workspaceID: runtime.workspaceID, serviceID: serviceID, state: .stopping(runID: runID)))
        case .running, .ready, .unready:
            setRuntime(.init(workspaceID: runtime.workspaceID, serviceID: serviceID, state: .stopping(runID: runID)))
        }

        cancelHealth(serviceID: serviceID, runID: runID)
        do {
            try await runner.stop(runID: runID)
        } catch {
            fail(serviceID: serviceID, runID: runID, failure: .runnerLaunch(error.localizedDescription))
        }
    }

    public func startAll(workspace: WorkspaceConfig, preferences: PreferencesConfig = .default) async {
        for service in workspace.services where service.includeInStartAll && state(for: service.id) == .stopped {
            await start(service: service, workspace: workspace, preferences: preferences)
        }
    }

    public func stopAll(workspaceID: UUID) async {
        let serviceIDs = runtimes.values
            .filter { $0.workspaceID == workspaceID }
            .map(\.serviceID)
        for serviceID in serviceIDs {
            await stop(serviceID: serviceID)
        }
    }

    private func consume(
        _ stream: AsyncStream<ServiceRuntimeEvent>,
        workspaceID: UUID,
        serviceID: UUID,
        runID: UUID
    ) {
        Task { [weak self] in
            for await event in stream {
                await self?.handle(event, workspaceID: workspaceID, serviceID: serviceID, runID: runID)
            }
            await self?.streamEnded(workspaceID: workspaceID, serviceID: serviceID, runID: runID)
        }
    }

    private func handle(
        _ event: ServiceRuntimeEvent,
        workspaceID: UUID,
        serviceID: UUID,
        runID: UUID
    ) async {
        guard isCurrentRun(runID, for: serviceID), event.associatedRunID == runID else { return }
        switch event {
        case let .runner(runnerEvent):
            await handle(runnerEvent, serviceID: serviceID, runID: runID)
        case let .stdout(eventRunID, data) where eventRunID == runID:
            await logStore?.append(
                data: data,
                stream: .stdout,
                workspaceID: workspaceID,
                serviceID: serviceID,
                runID: runID
            )
        case let .stderr(eventRunID, data) where eventRunID == runID:
            await logStore?.append(
                data: data,
                stream: .stderr,
                workspaceID: workspaceID,
                serviceID: serviceID,
                runID: runID
            )
        case let .channelFailure(eventRunID, message) where eventRunID == runID:
            let requestedStop = isStopping(serviceID: serviceID, runID: runID)
            if requestedStop {
                setStopped(serviceID: serviceID)
            } else {
                fail(serviceID: serviceID, runID: runID, failure: .runnerChannel(message))
            }
        case .stdout, .stderr, .channelFailure:
            break
        }
        // Publish only after side effects such as log persistence complete. App-facing
        // observers can then read any warning emitted by the same event without racing it.
        publish(.init(workspaceID: workspaceID, serviceID: serviceID, event: event))
    }

    private func handle(_ event: RunnerEvent, serviceID: UUID, runID: UUID) async {
        guard event.associatedRunID == runID else { return }
        guard let runtime = runtimes[serviceID] else { return }
        switch event {
        case .started:
            if case .starting = runtime.state {
                runnerStartedRuns[serviceID] = runID
                guard healthConfigs[serviceID]?.runID == runID,
                      let healthConfig = healthConfigs[serviceID]?.config
                else { return }
                await startHealth(serviceID: serviceID, runID: runID, config: healthConfig)
            }
        case .stopPhase:
            break
        case .exited:
            if isStopping(serviceID: serviceID, runID: runID) {
                setStopped(serviceID: serviceID)
            } else {
                fail(serviceID: serviceID, runID: runID, failure: .unexpectedExit)
            }
        case let .error(_, message):
            fail(serviceID: serviceID, runID: runID, failure: .runnerLaunch(message))
        }
    }

    private func streamEnded(workspaceID: UUID, serviceID: UUID, runID: UUID) async {
        await logStore?.finishStream(
            stream: .stdout,
            workspaceID: workspaceID,
            serviceID: serviceID,
            runID: runID
        )
        await logStore?.finishStream(
            stream: .stderr,
            workspaceID: workspaceID,
            serviceID: serviceID,
            runID: runID
        )
        guard isCurrentRun(runID, for: serviceID), let runtime = runtimes[serviceID] else { return }
        switch runtime.state {
        case .stopped, .failed:
            return
        case .stopping:
            setStopped(serviceID: serviceID)
        case .starting, .running, .ready, .unready:
            fail(serviceID: serviceID, runID: runID, failure: .runnerChannel("Runner stream closed before it reported an exit."))
        }
    }

    private func startHealth(serviceID: UUID, runID: UUID, config: HealthCheckConfig) async {
        noneHealthTasks.removeValue(forKey: serviceID)?.cancel()
        await healthChecker.cancel(serviceID: serviceID)
        switch config {
        case .none:
            let delay = noneRunningDelay
            noneHealthTasks[serviceID] = Task { [weak self] in
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                await self?.markNoneHealthRunning(serviceID: serviceID, runID: runID)
            }
        case .http, .tcp:
            let stream = await healthChecker.start(serviceID: serviceID, runID: runID, config: config)
            Task { [weak self] in
                for await result in stream {
                    await self?.handleHealth(result, serviceID: serviceID, runID: runID)
                }
            }
        }
    }

    private func markNoneHealthRunning(serviceID: UUID, runID: UUID) {
        guard isCurrentRun(runID, for: serviceID), runnerStartedRuns[serviceID] == runID,
              let runtime = runtimes[serviceID], case .starting = runtime.state
        else { return }
        noneHealthTasks.removeValue(forKey: serviceID)
        setRuntime(.init(workspaceID: runtime.workspaceID, serviceID: serviceID, state: .running(runID: runID)))
    }

    private func handleHealth(_ result: HealthProbeResult, serviceID: UUID, runID: UUID) {
        guard isCurrentRun(runID, for: serviceID), runnerStartedRuns[serviceID] == runID,
              let runtime = runtimes[serviceID]
        else { return }
        switch runtime.state {
        case .stopping, .stopped, .failed:
            return
        case .starting, .running, .ready, .unready:
            let state: ServiceState
            switch result {
            case .ready:
                state = .ready(runID: runID)
            case let .unready(reason):
                state = .unready(runID: runID, reason: reason)
            }
            setRuntime(.init(workspaceID: runtime.workspaceID, serviceID: serviceID, state: state))
        }
    }

    private func cancelHealth(serviceID: UUID, runID: UUID? = nil) {
        noneHealthTasks.removeValue(forKey: serviceID)?.cancel()
        Task { [healthChecker] in
            await healthChecker.cancel(serviceID: serviceID, runID: runID)
        }
    }

    private func provider(for zshPath: String) -> any ShellEnvironmentProviding {
        if let provider = providersByZshPath[zshPath] { return provider }
        let provider = environmentProviderFactory.makeProvider(zshPath: zshPath)
        providersByZshPath[zshPath] = provider
        return provider
    }

    private enum ExpectedState {
        case starting
    }

    private func isCurrentRun(_ runID: UUID, for serviceID: UUID, expected: ExpectedState? = nil) -> Bool {
        guard runIDs[serviceID] == runID, let state = runtimes[serviceID]?.state else { return false }
        guard let expected else { return true }
        if case (.starting, .starting) = (expected, state) { return true }
        return false
    }

    private func isStopping(serviceID: UUID, runID: UUID) -> Bool {
        guard runIDs[serviceID] == runID, case .stopping = runtimes[serviceID]?.state else { return false }
        return true
    }

    private func fail(serviceID: UUID, runID: UUID, failure: ServiceFailure) {
        guard isCurrentRun(runID, for: serviceID), let runtime = runtimes[serviceID] else { return }
        cancelHealth(serviceID: serviceID, runID: runID)
        runnerStartedRuns.removeValue(forKey: serviceID)
        healthConfigs.removeValue(forKey: serviceID)
        setRuntime(.init(workspaceID: runtime.workspaceID, serviceID: serviceID, state: .failed(failure)))
    }

    private func setStopped(serviceID: UUID) {
        guard let runtime = runtimes[serviceID] else { return }
        cancelHealth(serviceID: serviceID, runID: runIDs[serviceID])
        runnerStartedRuns.removeValue(forKey: serviceID)
        healthConfigs.removeValue(forKey: serviceID)
        setRuntime(.init(workspaceID: runtime.workspaceID, serviceID: serviceID, state: .stopped))
    }

    private func setRuntime(_ runtime: ServiceRuntime) {
        runtimes[runtime.serviceID] = runtime
        for continuation in stateContinuations.values {
            continuation.yield(runtime)
        }
    }

    private func publish(_ event: SupervisedServiceRuntimeEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func resolveWorkingDirectory(service: ServiceConfig, workspace: WorkspaceConfig) throws -> String {
        let root = URL(fileURLWithPath: workspace.rootDirectory, isDirectory: true).standardizedFileURL
        guard workspace.rootDirectory.hasPrefix("/"), root.path == workspace.rootDirectory, isDirectory(root) else {
            throw WorkingDirectoryResolutionError.invalidWorkspaceRoot(workspace.rootDirectory)
        }
        switch service.workingDirectory {
        case let .relative(path):
            guard !path.isEmpty, !URL(fileURLWithPath: path).pathComponents.contains("..") else {
                throw WorkingDirectoryResolutionError.invalidRelativePath(path)
            }
            let resolved = root.appendingPathComponent(path, isDirectory: true).standardizedFileURL
            guard resolved.path == root.path || resolved.path.hasPrefix(root.path + "/"), isDirectory(resolved) else {
                throw WorkingDirectoryResolutionError.missingDirectory(resolved.path)
            }
            return resolved.path
        case let .absolute(path):
            let resolved = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            guard path.hasPrefix("/"), resolved.path == path, isDirectory(resolved) else {
                throw WorkingDirectoryResolutionError.missingDirectory(path)
            }
            return resolved.path
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

public enum WorkingDirectoryResolutionError: Error, Equatable, Sendable, LocalizedError {
    case invalidWorkspaceRoot(String)
    case invalidRelativePath(String)
    case missingDirectory(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidWorkspaceRoot(path):
            "Workspace root is not an existing standardized absolute directory: \(path)."
        case let .invalidRelativePath(path):
            "Service working directory must be a non-empty relative path without '..': \(path)."
        case let .missingDirectory(path):
            "Service working directory does not exist: \(path)."
        }
    }
}

private extension RunnerEvent {
    var associatedRunID: UUID {
        switch self {
        case let .started(runID, _, _), let .stopPhase(runID, _), let .exited(runID, _, _), let .error(runID, _):
            runID
        }
    }
}

private extension ServiceRuntimeEvent {
    var associatedRunID: UUID {
        switch self {
        case let .runner(event):
            event.associatedRunID
        case let .stdout(runID, _), let .stderr(runID, _), let .channelFailure(runID, _):
            runID
        }
    }
}
