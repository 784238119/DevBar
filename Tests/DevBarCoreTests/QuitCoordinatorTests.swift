import XCTest
@testable import DevBarCore

@MainActor
final class QuitCoordinatorTests: XCTestCase {
    func testNoActiveServicesTerminatesImmediately() async {
        let state = FakeQuitState(active: [])
        let coordinator = QuitCoordinator(state: state, pollInterval: .milliseconds(1))

        let decision = await coordinator.requestQuit()
        XCTAssertEqual(decision, .terminateNow)
        XCTAssertEqual(state.stoppedWorkspaceIDs, [])
    }

    func testActiveServicesRequireConfirmationList() async {
        let first = runtime(workspaceID: UUID(), serviceID: UUID())
        let second = runtime(workspaceID: UUID(), serviceID: UUID())
        let state = FakeQuitState(active: [first, second])
        let coordinator = QuitCoordinator(state: state, pollInterval: .milliseconds(1))

        let decision = await coordinator.requestQuit()
        XCTAssertEqual(decision, .confirmationRequired([first, second]))
    }

    func testConfirmedQuitStopsEachWorkspaceOnceAndWaitsForTerminalStates() async {
        let workspaceID = UUID()
        let first = runtime(workspaceID: workspaceID, serviceID: UUID())
        let second = runtime(workspaceID: workspaceID, serviceID: UUID())
        let state = FakeQuitState(active: [first, second], terminalAfterPolls: 3)
        let coordinator = QuitCoordinator(state: state, pollInterval: .milliseconds(1))

        let stopped = await coordinator.stopAllAndWait()

        XCTAssertTrue(stopped)
        XCTAssertEqual(state.stoppedWorkspaceIDs, [workspaceID])
        XCTAssertGreaterThanOrEqual(state.prepareCallCount, 4)
        XCTAssertTrue(state.active.isEmpty)
    }

    func testConfirmedQuitTimesOutInsteadOfWaitingForever() async {
        let workspaceID = UUID()
        let state = FakeQuitState(active: [runtime(workspaceID: workspaceID, serviceID: UUID())])
        let coordinator = QuitCoordinator(
            state: state,
            pollInterval: .milliseconds(1),
            maximumWait: .milliseconds(5)
        )

        let stopped = await coordinator.stopAllAndWait()

        XCTAssertFalse(stopped)
        XCTAssertEqual(state.stoppedWorkspaceIDs, [workspaceID])
    }

    private func runtime(workspaceID: UUID, serviceID: UUID) -> ServiceRuntime {
        ServiceRuntime(
            workspaceID: workspaceID,
            serviceID: serviceID,
            state: .running(runID: UUID())
        )
    }
}

@MainActor
private final class FakeQuitState: QuitStateProviding {
    var active: [ServiceRuntime]
    private let terminalAfterPolls: Int?
    private(set) var stoppedWorkspaceIDs: [UUID] = []
    private(set) var prepareCallCount = 0

    init(active: [ServiceRuntime], terminalAfterPolls: Int? = nil) {
        self.active = active
        self.terminalAfterPolls = terminalAfterPolls
    }

    func prepareToQuit() -> QuitResult {
        prepareCallCount += 1
        if let terminalAfterPolls,
           !stoppedWorkspaceIDs.isEmpty,
           prepareCallCount >= terminalAfterPolls + 1 {
            active = []
        }
        return active.isEmpty ? .immediate : .confirmationRequired(active)
    }

    func stopAll(workspaceID: UUID) {
        stoppedWorkspaceIDs.append(workspaceID)
    }
}
