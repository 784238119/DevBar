import Foundation

@MainActor
protocol MCPRuntimeStateStoring: AnyObject {
    var wasRunning: Bool { get }
    func recordRunning(_ running: Bool)
}

@MainActor
final class MCPRuntimeStateStore: MCPRuntimeStateStoring {
    static let wasRunningKey = "mcpWasRunning"

    private let defaults: UserDefaults
    private let wasRunningKey: String

    init(
        defaults: UserDefaults = .standard,
        wasRunningKey: String = MCPRuntimeStateStore.wasRunningKey
    ) {
        self.defaults = defaults
        self.wasRunningKey = wasRunningKey
    }

    var wasRunning: Bool {
        defaults.bool(forKey: wasRunningKey)
    }

    func recordRunning(_ running: Bool) {
        defaults.set(running, forKey: wasRunningKey)
    }
}
