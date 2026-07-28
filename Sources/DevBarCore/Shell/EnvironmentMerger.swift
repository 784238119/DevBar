import Foundation

public enum EnvironmentMerger {
    public static func merge(
        captured: [String: String],
        workspace: [EnvironmentEntry],
        service: [EnvironmentEntry]
    ) -> [String: String] {
        var result = captured
        apply(workspace, to: &result)
        apply(service, to: &result)
        return result
    }

    private static func apply(_ entries: [EnvironmentEntry], to environment: inout [String: String]) {
        for entry in entries {
            environment[entry.key] = entry.value
        }
    }
}
