import Foundation
import Darwin
import XCTest
@testable import DevBarCore

final class ProcessSupervisorTests: XCTestCase {
    func testDuplicateStartsCreateOneRunnerAndDuplicateStopsSendOneCommand() async {
        let fixture = try! Fixture()
        defer { fixture.cleanup() }
        let runner = FakeRunner()
        let supervisor = fixture.supervisor(runner: runner)

        await supervisor.start(service: fixture.service(), workspace: fixture.workspace)
        await supervisor.start(service: fixture.service(), workspace: fixture.workspace)
        let launchCount = await runner.launchCount
        XCTAssertEqual(launchCount, 1)

        let initialRequests = await runner.launchedRequests
        let runID = try! XCTUnwrap(initialRequests.first?.runID)
        await runner.emit(.runner(.started(runID: runID, pid: 1, pgid: 1)), for: runID)
        await eventually { await supervisor.state(for: fixture.serviceID) == .running(runID: runID) }

        await supervisor.stop(serviceID: fixture.serviceID)
        await supervisor.stop(serviceID: fixture.serviceID)
        let stopCalls = await runner.stopCalls
        XCTAssertEqual(stopCalls, [runID])
    }

    func testFailedServiceMayRestartWithNewRunIDAndStaleEventsAreIgnored() async {
        let fixture = try! Fixture()
        defer { fixture.cleanup() }
        let runner = FakeRunner()
        let supervisor = fixture.supervisor(runner: runner)

        await supervisor.start(service: fixture.service(), workspace: fixture.workspace)
        let firstRequests = await runner.launchedRequests
        let first = try! XCTUnwrap(firstRequests.first?.runID)
        await runner.emit(.runner(.exited(runID: first, code: 0, signal: nil)), for: first)
        await eventually { await supervisor.state(for: fixture.serviceID) == .failed(.unexpectedExit) }

        await supervisor.start(service: fixture.service(), workspace: fixture.workspace)
        let secondRequests = await runner.launchedRequests
        let second = try! XCTUnwrap(secondRequests.last?.runID)
        XCTAssertNotEqual(first, second)

        await runner.emit(.runner(.started(runID: first, pid: 9, pgid: 9)), for: first)
        try? await Task.sleep(for: .milliseconds(50))
        let state = await supervisor.state(for: fixture.serviceID)
        XCTAssertEqual(state, .starting(runID: second))
    }

    func testStartAllIncludesOnlyStoppedOptedInServicesAndOneFailureDoesNotStopSibling() async {
        let fixture = try! Fixture()
        defer { fixture.cleanup() }
        let runner = FakeRunner(failingCommands: ["bad"])
        let supervisor = fixture.supervisor(runner: runner)
        let bad = fixture.service(id: UUID(), command: "bad", includeInStartAll: true)
        let good = fixture.service(id: UUID(), command: "good", includeInStartAll: true)
        let excluded = fixture.service(id: UUID(), command: "excluded", includeInStartAll: false)
        var workspace = fixture.workspace
        workspace.services = [bad, good, excluded]

        await supervisor.startAll(workspace: workspace)

        let requests = await runner.launchedRequests
        XCTAssertEqual(requests.map(\.command), ["good"])
        let badState = await supervisor.state(for: bad.id)
        let excludedState = await supervisor.state(for: excluded.id)
        XCTAssertEqual(badState, .failed(.runnerLaunch("intentional launch failure")))
        XCTAssertEqual(excludedState, .stopped)
    }

    func testUnsolicitedZeroExitFailsButExitAfterRequestedStopBecomesStopped() async {
        let fixture = try! Fixture()
        defer { fixture.cleanup() }
        let runner = FakeRunner()
        let supervisor = fixture.supervisor(runner: runner)

        await supervisor.start(service: fixture.service(), workspace: fixture.workspace)
        let firstRequests = await runner.launchedRequests
        let first = try! XCTUnwrap(firstRequests.first?.runID)
        await runner.emit(.runner(.exited(runID: first, code: 0, signal: nil)), for: first)
        await eventually { await supervisor.state(for: fixture.serviceID) == .failed(.unexpectedExit) }

        await supervisor.start(service: fixture.service(), workspace: fixture.workspace)
        let secondRequests = await runner.launchedRequests
        let second = try! XCTUnwrap(secondRequests.last?.runID)
        await runner.emit(.runner(.started(runID: second, pid: 1, pgid: 1)), for: second)
        await eventually { await supervisor.state(for: fixture.serviceID) == .running(runID: second) }
        await supervisor.stop(serviceID: fixture.serviceID)
        await runner.emit(.runner(.exited(runID: second, code: nil, signal: SIGINT)), for: second)
        await eventually { await supervisor.state(for: fixture.serviceID) == .stopped }
    }

    func testHealthTogglesReadyAndUnreadyWithoutRestart() async {
        let fixture = try! Fixture()
        defer { fixture.cleanup() }
        let runner = FakeRunner()
        let probe = ManualHealthProbe()
        let supervisor = fixture.supervisor(
            runner: runner,
            healthChecker: HealthChecker(probe: probe, pollInterval: .milliseconds(10))
        )
        let service = fixture.service(healthCheck: .http(URL(string: "http://127.0.0.1/health")!))

        await supervisor.start(service: service, workspace: fixture.workspace)
        let requests = await runner.launchedRequests
        let request = try! XCTUnwrap(requests.first)
        await runner.emit(.runner(.started(runID: request.runID, pid: 1, pgid: 1)), for: request.runID)
        await eventually { await probe.invocationCount == 1 }
        await probe.resume(at: 0, with: .ready)
        await eventually { await supervisor.state(for: fixture.serviceID) == .ready(runID: request.runID) }

        await eventually { await probe.invocationCount == 2 }
        await probe.resume(at: 1, with: .unready("port closed"))
        await eventually {
            await supervisor.state(for: fixture.serviceID) == .unready(runID: request.runID, reason: "port closed")
        }
        let requestCount = await runner.launchCount
        XCTAssertEqual(requestCount, 1)
    }

    func testStaleHealthResultAfterRestartCannotChangeNewRun() async {
        let fixture = try! Fixture()
        defer { fixture.cleanup() }
        let runner = FakeRunner()
        let probe = ManualHealthProbe()
        let supervisor = fixture.supervisor(
            runner: runner,
            healthChecker: HealthChecker(probe: probe, pollInterval: .seconds(30))
        )
        let service = fixture.service(healthCheck: .http(URL(string: "http://127.0.0.1/health")!))

        await supervisor.start(service: service, workspace: fixture.workspace)
        let firstRequests = await runner.launchedRequests
        let first = try! XCTUnwrap(firstRequests.first)
        await runner.emit(.runner(.started(runID: first.runID, pid: 1, pgid: 1)), for: first.runID)
        await eventually { await probe.invocationCount == 1 }
        await runner.emit(.runner(.exited(runID: first.runID, code: 1, signal: nil)), for: first.runID)
        await eventually { await supervisor.state(for: fixture.serviceID) == .failed(.unexpectedExit) }

        await supervisor.start(service: service, workspace: fixture.workspace)
        let secondRequests = await runner.launchedRequests
        let second = try! XCTUnwrap(secondRequests.last)
        XCTAssertNotEqual(first.runID, second.runID)
        await runner.emit(.runner(.started(runID: second.runID, pid: 2, pgid: 2)), for: second.runID)
        await eventually { await probe.invocationCount == 2 }

        await probe.resume(at: 0, with: .ready)
        try? await Task.sleep(for: .milliseconds(40))
        let staleResultState = await supervisor.state(for: fixture.serviceID)
        XCTAssertEqual(staleResultState, .starting(runID: second.runID))
        await probe.resume(at: 1, with: .ready)
        await eventually { await supervisor.state(for: fixture.serviceID) == .ready(runID: second.runID) }
    }

    func testNoneHealthDelayCannotReviveStoppedService() async {
        let fixture = try! Fixture()
        defer { fixture.cleanup() }
        let runner = FakeRunner()
        let supervisor = fixture.supervisor(runner: runner, noneRunningDelay: .milliseconds(100))

        await supervisor.start(service: fixture.service(), workspace: fixture.workspace)
        let requests = await runner.launchedRequests
        let request = try! XCTUnwrap(requests.first)
        await runner.emit(.runner(.started(runID: request.runID, pid: 1, pgid: 1)), for: request.runID)
        await supervisor.stop(serviceID: fixture.serviceID)
        await runner.emit(.runner(.exited(runID: request.runID, code: 0, signal: nil)), for: request.runID)
        await eventually { await supervisor.state(for: fixture.serviceID) == .stopped }
        try? await Task.sleep(for: .milliseconds(150))
        let laterState = await supervisor.state(for: fixture.serviceID)
        XCTAssertEqual(laterState, .stopped)
    }

    func testLogInitializationFailurePreventsRunnerLaunch() async {
        let fixture = try! Fixture()
        defer { fixture.cleanup() }
        let runner = FakeRunner()
        let logger = FakeLogStore(prepareError: "disk unavailable")
        let supervisor = fixture.supervisor(runner: runner, logStore: logger)

        await supervisor.start(service: fixture.service(), workspace: fixture.workspace)

        let launchCount = await runner.launchCount
        XCTAssertEqual(launchCount, 0)
        let state = await supervisor.state(for: fixture.serviceID)
        guard case let .failed(.logInitialization(message)) = state else {
            return XCTFail("Expected log initialization failure, got \(state)")
        }
        XCTAssertTrue(message.contains("disk unavailable"))
    }

    func testRuntimeOutputCarriesStableOwnershipAndRoutesToLogStore() async {
        let fixture = try! Fixture()
        defer { fixture.cleanup() }
        let runner = FakeRunner()
        let logger = FakeLogStore()
        let supervisor = fixture.supervisor(runner: runner, logStore: logger)
        let events = await supervisor.runtimeEvents()
        let firstEvent = Task {
            var iterator = events.makeAsyncIterator()
            return await iterator.next()
        }

        await supervisor.start(service: fixture.service(), workspace: fixture.workspace)
        let requests = await runner.launchedRequests
        let runID = try! XCTUnwrap(requests.first?.runID)
        let data = Data("hello".utf8)
        await runner.emit(.stdout(runID: runID, data: data), for: runID)

        await eventually { await logger.appended.count == 1 }
        let appended = await logger.appended
        XCTAssertEqual(appended.first, .init(
            data: data,
            stream: .stdout,
            workspaceID: fixture.workspaceID,
            serviceID: fixture.serviceID,
            runID: runID
        ))
        let published = await firstEvent.value
        XCTAssertEqual(
            published,
            .init(
                workspaceID: fixture.workspaceID,
                serviceID: fixture.serviceID,
                event: .stdout(runID: runID, data: data)
            )
        )
    }

    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !(await condition()) && clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let satisfied = await condition()
        XCTAssertTrue(satisfied)
    }
}

private final class Fixture {
    let root: URL
    let workspaceID = UUID()
    let serviceID = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var workspace: WorkspaceConfig {
        WorkspaceConfig(
            id: workspaceID,
            name: "Test",
            rootDirectory: root.path,
            iconSymbol: "terminal.fill",
            tintHex: "#FF7A59",
            environment: [.init(key: "WORKSPACE", value: "yes")],
            services: []
        )
    }

    func service(
        id: UUID? = nil,
        command: String = "echo test",
        includeInStartAll: Bool = true,
        healthCheck: HealthCheckConfig = .none
    ) -> ServiceConfig {
        ServiceConfig(
            id: id ?? serviceID,
            name: "Service",
            workingDirectory: .relative("."),
            command: command,
            includeInStartAll: includeInStartAll,
            environment: [.init(key: "SERVICE", value: "yes")],
            healthCheck: healthCheck
        )
    }

    func supervisor(
        runner: FakeRunner,
        logStore: (any ServiceLogStoring)? = nil,
        healthChecker: HealthChecker = HealthChecker(probe: TestReadyProbe()),
        noneRunningDelay: Duration = .milliseconds(10)
    ) -> ProcessSupervisor {
        ProcessSupervisor(
            runner: runner,
            zshResolver: TestZshResolver(),
            environmentProviderFactory: TestEnvironmentProviderFactory(),
            logStore: logStore,
            healthChecker: healthChecker,
            noneRunningDelay: noneRunningDelay
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private actor TestReadyProbe: HealthProbing {
    func probe(_ configuration: HealthCheckConfig) async -> HealthProbeResult { .ready }
}

private actor ManualHealthProbe: HealthProbing {
    private var continuations: [CheckedContinuation<HealthProbeResult, Never>?] = []
    private(set) var invocationCount = 0

    func probe(_ configuration: HealthCheckConfig) async -> HealthProbeResult {
        invocationCount += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func resume(at index: Int, with result: HealthProbeResult) {
        guard continuations.indices.contains(index), let continuation = continuations[index] else { return }
        continuations[index] = nil
        continuation.resume(returning: result)
    }
}

private struct TestZshResolver: ZshResolving {
    func resolve(environment: [String: String]) throws -> ZshResolution {
        .init(path: "/verified/zsh", source: .shellEnvironment, warning: nil)
    }
}

private struct TestEnvironmentProviderFactory: ShellEnvironmentProvidingFactory {
    func makeProvider(zshPath: String) -> any ShellEnvironmentProviding {
        TestEnvironmentProvider()
    }
}

private actor TestEnvironmentProvider: ShellEnvironmentProviding {
    func cachedOrRefresh() async throws -> [String: String] { ["PATH": "/test/bin"] }
}

private actor FakeRunner: RunnerControlling {
    private let failingCommands: Set<String>
    private var requests: [RunnerLaunchRequest] = []
    private var streams: [UUID: AsyncStream<ServiceRuntimeEvent>.Continuation] = [:]
    private var recordedStops: [UUID] = []

    init(failingCommands: Set<String> = []) {
        self.failingCommands = failingCommands
    }

    var launchCount: Int { requests.count }
    var launchedRequests: [RunnerLaunchRequest] { requests }
    var stopCalls: [UUID] { recordedStops }

    func launch(_ request: RunnerLaunchRequest) async throws -> AsyncStream<ServiceRuntimeEvent> {
        if failingCommands.contains(request.command) {
            throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "intentional launch failure"])
        }
        requests.append(request)
        return AsyncStream { continuation in
            streams[request.runID] = continuation
        }
    }

    func stop(runID: UUID) async throws {
        if !recordedStops.contains(runID) { recordedStops.append(runID) }
    }

    func emit(_ event: ServiceRuntimeEvent, for runID: UUID) {
        streams[runID]?.yield(event)
    }
}

private actor FakeLogStore: ServiceLogStoring {
    struct Appended: Equatable, Sendable {
        let data: Data
        let stream: LogStream
        let workspaceID: UUID
        let serviceID: UUID
        let runID: UUID
    }

    private let prepareError: String?
    private(set) var appended: [Appended] = []

    init(prepareError: String? = nil) {
        self.prepareError = prepareError
    }

    func prepare(workspaceID: UUID, serviceID: UUID) async throws {
        if let prepareError {
            throw NSError(domain: "FakeLogStore", code: 1, userInfo: [NSLocalizedDescriptionKey: prepareError])
        }
    }

    func append(
        data: Data,
        stream: LogStream,
        workspaceID: UUID,
        serviceID: UUID,
        runID: UUID
    ) async {
        appended.append(.init(
            data: data,
            stream: stream,
            workspaceID: workspaceID,
            serviceID: serviceID,
            runID: runID
        ))
    }

    func finishStream(
        stream: LogStream,
        workspaceID: UUID,
        serviceID: UUID,
        runID: UUID
    ) async {}
}
