import Foundation

public enum ShellSyntaxResult: Equatable, Sendable {
    case valid
    case invalid(String)
}

public struct ShellSyntaxChecker: Sendable {
    private let zshPath: String
    private let executor: any ShellCommandExecuting

    public init(zshPath: String, executor: any ShellCommandExecuting = ShellCommandExecutor()) {
        self.zshPath = zshPath
        self.executor = executor
    }

    public func check(command: String) async -> ShellSyntaxResult {
        await Task.detached(priority: .userInitiated) {
            do {
                let result = try executor.run(
                    executable: zshPath,
                    arguments: ["-n", "-c", command],
                    environment: nil,
                    timeout: .seconds(5)
                )
                guard result.terminationStatus == 0 else {
                    let stderr = String(decoding: result.stderr, as: UTF8.self)
                    return .invalid(stderr.isEmpty ? "zsh rejected the command." : stderr)
                }
                return .valid
            } catch {
                return .invalid(error.localizedDescription)
            }
        }.value
    }
}
