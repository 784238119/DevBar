import Foundation

@MainActor
public protocol QuitStateProviding: AnyObject {
    func prepareToQuit() async -> QuitResult
    func stopAll(workspaceID: UUID) async
}

extension AppState: QuitStateProviding {}

public enum QuitDecision: Equatable, Sendable {
    case terminateNow
    case confirmationRequired([ServiceRuntime])
}

/// Keeps AppKit termination policy out of `AppState`. A confirmed quit does not
/// complete until every active service reaches a terminal state, so the Runner
/// retains enough time to finish its SIGINT → SIGTERM → SIGKILL sequence.
@MainActor
public final class QuitCoordinator {
    private let state: any QuitStateProviding
    private let pollInterval: Duration
    private let maximumWait: Duration

    public init(
        state: any QuitStateProviding,
        pollInterval: Duration = .milliseconds(50),
        maximumWait: Duration = .seconds(120)
    ) {
        self.state = state
        self.pollInterval = pollInterval
        self.maximumWait = maximumWait
    }

    public func requestQuit() async -> QuitDecision {
        switch await state.prepareToQuit() {
        case .immediate:
            return .terminateNow
        case let .confirmationRequired(runtimes):
            return .confirmationRequired(runtimes)
        }
    }

    @discardableResult
    public func stopAllAndWait() async -> Bool {
        guard case let .confirmationRequired(active) = await state.prepareToQuit() else { return true }
        let workspaceIDs = Set(active.map(\.workspaceID))
        for workspaceID in workspaceIDs {
            await state.stopAll(workspaceID: workspaceID)
        }

        let clock = ContinuousClock()
        let deadline = clock.now + maximumWait
        while !Task.isCancelled, clock.now < deadline {
            if case .immediate = await state.prepareToQuit() { return true }
            try? await Task.sleep(for: pollInterval)
        }
        return false
    }
}
