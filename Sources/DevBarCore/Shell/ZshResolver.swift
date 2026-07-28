import Foundation

public enum ZshResolutionSource: Equatable, Sendable {
    case shellEnvironment
    case fallback
}

public struct ZshResolution: Equatable, Sendable {
    public let path: String
    public let source: ZshResolutionSource
    public let warning: String?

    public init(path: String, source: ZshResolutionSource, warning: String?) {
        self.path = path
        self.source = source
        self.warning = warning
    }
}

public enum ZshResolutionError: Error, Equatable, Sendable, LocalizedError {
    case noUsableZsh

    public var errorDescription: String? {
        "DevBar requires an executable zsh. Set SHELL to zsh or install zsh at /bin/zsh."
    }
}

public struct ZshResolver {
    private let fileManager: FileManager
    private let commandExecutor: any ShellCommandExecuting
    private let fallbackPath: String

    public init(
        fileManager: FileManager = .default,
        commandExecutor: any ShellCommandExecuting = ShellCommandExecutor(),
        fallbackPath: String = "/bin/zsh"
    ) {
        self.fileManager = fileManager
        self.commandExecutor = commandExecutor
        self.fallbackPath = fallbackPath
    }

    public func resolve(environment: [String: String]) throws -> ZshResolution {
        let shellPath = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if isVerifiedZsh(at: shellPath) {
            return ZshResolution(path: shellPath, source: .shellEnvironment, warning: nil)
        }
        if isVerifiedZsh(at: fallbackPath) {
            let warning: String?
            if shellPath.isEmpty {
                warning = nil
            } else {
                warning = "SHELL is not a verified zsh. DevBar is using \(fallbackPath) instead."
            }
            return ZshResolution(path: fallbackPath, source: .fallback, warning: warning)
        }
        throw ZshResolutionError.noUsableZsh
    }

    private func isVerifiedZsh(at path: String) -> Bool {
        guard isExecutableRegularFile(at: path) else { return false }
        guard let result = try? commandExecutor.run(
            executable: path,
            arguments: ["--version"],
            environment: nil,
            timeout: .seconds(2)
        ), result.terminationStatus == 0 else {
            return false
        }
        let output = String(decoding: result.stdout + result.stderr, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return output.hasPrefix("zsh ")
    }

    private func isExecutableRegularFile(at path: String) -> Bool {
        guard !path.isEmpty, fileManager.isExecutableFile(atPath: path) else { return false }
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey]) else {
            return false
        }
        return values.isRegularFile == true
    }
}
