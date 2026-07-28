import Foundation

public enum ShellEnvironmentParserError: Error, Equatable, Sendable, LocalizedError {
    case missingBeginSentinel
    case missingEndSentinel
    case invalidUTF8Entry

    public var errorDescription: String? {
        switch self {
        case .missingBeginSentinel:
            "zsh startup output did not contain DevBar's environment start marker."
        case .missingEndSentinel:
            "zsh startup output did not contain DevBar's environment end marker."
        case .invalidUTF8Entry:
            "zsh returned an environment entry that is not valid UTF-8."
        }
    }
}

public enum ShellEnvironmentParser {
    private static let beginSentinel = Data("DEVBAR_ENV_BEGIN\0".utf8)
    private static let endSentinel = Data("DEVBAR_ENV_END\0".utf8)

    public static func parse(_ bytes: Data) throws -> [String: String] {
        guard let beginRange = bytes.range(of: beginSentinel) else {
            throw ShellEnvironmentParserError.missingBeginSentinel
        }
        let afterBegin = beginRange.upperBound
        guard let endRange = bytes.range(of: endSentinel, in: afterBegin..<bytes.endIndex) else {
            throw ShellEnvironmentParserError.missingEndSentinel
        }
        let payload = bytes[afterBegin..<endRange.lowerBound]
        var environment: [String: String] = [:]
        for entryBytes in payload.split(separator: 0, omittingEmptySubsequences: true) {
            guard let entry = String(data: entryBytes, encoding: .utf8) else {
                throw ShellEnvironmentParserError.invalidUTF8Entry
            }
            guard let separator = entry.firstIndex(of: "=") else { continue }
            let key = String(entry[..<separator])
            guard !key.isEmpty else { continue }
            environment[key] = String(entry[entry.index(after: separator)...])
        }
        return environment
    }
}

public enum ShellEnvironmentProviderError: Error, Equatable, Sendable, LocalizedError {
    case captureFailed(stderr: String)
    case timedOut(stderr: String)
    case parser(ShellEnvironmentParserError)

    public var errorDescription: String? {
        switch self {
        case let .captureFailed(stderr):
            "Could not capture the zsh environment. \(stderr)"
        case let .timedOut(stderr):
            "zsh environment capture timed out after 5 seconds. Check ~/.zshrc for interactive or long-running commands. \(stderr)"
        case let .parser(error):
            error.localizedDescription
        }
    }
}

public actor ShellEnvironmentProvider {
    private let zshPath: String
    private let executor: any ShellCommandExecuting
    private let timeout: Duration
    private var cachedEnvironment: [String: String]?

    public init(
        zshPath: String,
        executor: any ShellCommandExecuting = ShellCommandExecutor(),
        timeout: Duration = .seconds(5)
    ) {
        self.zshPath = zshPath
        self.executor = executor
        self.timeout = timeout
    }

    public func refresh() async throws -> [String: String] {
        let result: ShellCommandResult
        do {
            result = try executor.run(
                executable: zshPath,
                arguments: [
                    "-l",
                    "-i",
                    "-c",
                    "printf 'DEVBAR_ENV_BEGIN\\0'; /usr/bin/env -0; printf 'DEVBAR_ENV_END\\0'"
                ],
                environment: nil,
                timeout: timeout
            )
        } catch let ShellCommandExecutionError.timedOut(_, stderr) {
            throw ShellEnvironmentProviderError.timedOut(stderr: String(decoding: stderr, as: UTF8.self))
        }

        guard result.terminationStatus == 0 else {
            throw ShellEnvironmentProviderError.captureFailed(
                stderr: String(decoding: result.stderr, as: UTF8.self)
            )
        }

        do {
            let environment = try ShellEnvironmentParser.parse(result.stdout)
            cachedEnvironment = environment
            return environment
        } catch let error as ShellEnvironmentParserError {
            throw ShellEnvironmentProviderError.parser(error)
        }
    }

    public func cachedOrRefresh() async throws -> [String: String] {
        if let cachedEnvironment {
            return cachedEnvironment
        }
        return try await refresh()
    }
}
