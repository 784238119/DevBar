import Darwin
import Foundation

public struct StopGrace: Equatable, Sendable {
    public let sigint: Duration
    public let sigterm: Duration

    public init(sigint: Duration, sigterm: Duration) {
        self.sigint = sigint
        self.sigterm = sigterm
    }

    public static let `default` = StopGrace(sigint: .seconds(8), sigterm: .seconds(3))
}

public enum StopResult: Equatable, Sendable {
    case exitedAfterInterrupt
    case exitedAfterTerminate
    case killed
    case alreadyExited
    case failed(ProcessGroupTerminatorError)
}

public enum ProcessGroupTerminatorError: Error, Equatable, Sendable, LocalizedError {
    case invalidProcessGroup(pid_t)
    case signalFailed(signal: Int32, errno: Int32)

    public var errorDescription: String? {
        switch self {
        case let .invalidProcessGroup(pgid):
            "Invalid process group \(pgid)."
        case let .signalFailed(signal, code):
            "Sending signal \(signal) failed: \(String(cString: strerror(code)))."
        }
    }
}

/// Sends signals only to a negative process-group identifier, never to the Runner itself.
public struct ProcessGroupTerminator: Sendable {
    public init() {}

    public func stop(
        pgid: pid_t,
        grace: StopGrace,
        onSignal: @Sendable (Int32) -> Void = { _ in },
        reapLeaderIfExited: @Sendable () -> Void = {}
    ) async -> StopResult {
        guard pgid > 0 else { return .alreadyExited }
        guard groupExists(pgid) else { return .alreadyExited }

        do {
            try send(SIGINT, to: pgid)
            onSignal(SIGINT)
            if await waitForGroupToExit(pgid, within: grace.sigint, reapLeaderIfExited: reapLeaderIfExited) {
                return .exitedAfterInterrupt
            }

            try send(SIGTERM, to: pgid)
            onSignal(SIGTERM)
            if await waitForGroupToExit(pgid, within: grace.sigterm, reapLeaderIfExited: reapLeaderIfExited) {
                return .exitedAfterTerminate
            }

            try send(SIGKILL, to: pgid)
            onSignal(SIGKILL)
            _ = await waitForGroupToExit(pgid, within: .seconds(2), reapLeaderIfExited: reapLeaderIfExited)
            return .killed
        } catch let error as ProcessGroupTerminatorError {
            return .failed(error)
        } catch {
            return .failed(.signalFailed(signal: 0, errno: EIO))
        }
    }

    private func send(_ signal: Int32, to pgid: pid_t) throws {
        guard kill(-pgid, signal) == 0 else {
            if errno == ESRCH { return }
            throw ProcessGroupTerminatorError.signalFailed(signal: signal, errno: errno)
        }
    }

    private func groupExists(_ pgid: pid_t) -> Bool {
        if kill(-pgid, 0) == 0 { return true }
        return errno == EPERM
    }

    private func waitForGroupToExit(
        _ pgid: pid_t,
        within duration: Duration,
        reapLeaderIfExited: @Sendable () -> Void
    ) async -> Bool {
        reapLeaderIfExited()
        if !groupExists(pgid) { return true }

        let clock = ContinuousClock()
        let deadline = clock.now + duration
        while clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            reapLeaderIfExited()
            if !groupExists(pgid) { return true }
        }
        return !groupExists(pgid)
    }
}
