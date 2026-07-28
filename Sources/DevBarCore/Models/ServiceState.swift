import Foundation

/// The user-visible lifecycle of one configured service.
public enum ServiceState: Equatable, Sendable {
    case stopped
    case starting(runID: UUID)
    case running(runID: UUID)
    case ready(runID: UUID)
    case unready(runID: UUID, reason: String)
    case stopping(runID: UUID)
    case failed(ServiceFailure)
}

/// A failure is deliberately scoped to one service. A workspace is never failed as a whole.
public enum ServiceFailure: Equatable, Sendable {
    case invalidWorkingDirectory(String)
    case zshResolution(String)
    case environmentCapture(String)
    case logInitialization(String)
    case runnerLaunch(String)
    case runnerChannel(String)
    case unexpectedExit
}

/// Snapshot published by `ProcessSupervisor` whenever a service state changes.
public struct ServiceRuntime: Equatable, Sendable, Identifiable {
    public let workspaceID: UUID
    public let serviceID: UUID
    public var state: ServiceState

    public var id: UUID { serviceID }

    public init(workspaceID: UUID, serviceID: UUID, state: ServiceState) {
        self.workspaceID = workspaceID
        self.serviceID = serviceID
        self.state = state
    }
}

/// Raw output and control-plane activity from a Runner. Consumers must match `runID` before
/// associating output with the current process, because an old Runner can finish after a restart.
public enum ServiceRuntimeEvent: Equatable, Sendable {
    case runner(RunnerEvent)
    case stdout(runID: UUID, data: Data)
    case stderr(runID: UUID, data: Data)
    case channelFailure(runID: UUID, message: String)
}

/// A runtime event with stable ownership. Consumers never need to reconstruct
/// workspace/service identity from a mutable runID lookup table.
public struct SupervisedServiceRuntimeEvent: Equatable, Sendable {
    public let workspaceID: UUID
    public let serviceID: UUID
    public let event: ServiceRuntimeEvent

    public init(workspaceID: UUID, serviceID: UUID, event: ServiceRuntimeEvent) {
        self.workspaceID = workspaceID
        self.serviceID = serviceID
        self.event = event
    }
}
