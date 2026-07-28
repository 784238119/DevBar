import Darwin
import Foundation
import XCTest
@testable import DevBarCore

final class ShellEnvironmentProviderTests: XCTestCase {
    func testParserIgnoresZshrcOutputOutsideSentinels() throws {
        let bytes = Data("banner\nDEVBAR_ENV_BEGIN\0PATH=/opt/bin\0A=x=y\0DEVBAR_ENV_END\0trailing".utf8)

        XCTAssertEqual(
            try ShellEnvironmentParser.parse(bytes),
            ["PATH": "/opt/bin", "A": "x=y"]
        )
    }

    func testRefreshCachesOnlySuccessfulEnvironment() async throws {
        let executor = ScriptedShellExecutor(results: [
            .success(.init(stdout: Self.environmentData(["PATH": "/first"]), stderr: Data(), terminationStatus: 0)),
            .success(.init(stdout: Data(), stderr: Data("bad zshrc".utf8), terminationStatus: 1))
        ])
        let provider = ShellEnvironmentProvider(zshPath: "/bin/zsh", executor: executor)

        let initial = try await provider.refresh()
        await XCTAssertThrowsErrorAsync(try await provider.refresh())
        let cached = try await provider.cachedOrRefresh()

        XCTAssertEqual(initial, ["PATH": "/first"])
        XCTAssertEqual(cached, ["PATH": "/first"])
        XCTAssertEqual(executor.invocationCount, 2)
    }

    func testCachedOrRefreshCapturesOnlyOnceAfterSuccess() async throws {
        let executor = ScriptedShellExecutor(results: [
            .success(.init(stdout: Self.environmentData(["PATH": "/captured"]), stderr: Data(), terminationStatus: 0))
        ])
        let provider = ShellEnvironmentProvider(zshPath: "/bin/zsh", executor: executor)

        let first = try await provider.cachedOrRefresh()
        let second = try await provider.cachedOrRefresh()

        XCTAssertEqual(first, ["PATH": "/captured"])
        XCTAssertEqual(second, ["PATH": "/captured"])
        XCTAssertEqual(executor.invocationCount, 1)
    }

    func testRefreshUsesInteractiveLoginZshEnvironmentCommand() async throws {
        let executor = ScriptedShellExecutor(results: [
            .success(.init(stdout: Self.environmentData(["PATH": "/captured"]), stderr: Data(), terminationStatus: 0))
        ])
        let provider = ShellEnvironmentProvider(zshPath: "/custom/zsh", executor: executor)

        _ = try await provider.refresh()

        XCTAssertEqual(executor.invocations, [
            .init(
                executable: "/custom/zsh",
                arguments: ["-l", "-i", "-c", "printf 'DEVBAR_ENV_BEGIN\\0'; /usr/bin/env -0; printf 'DEVBAR_ENV_END\\0'"],
                environment: nil,
                timeout: .seconds(5)
            )
        ])
    }

    func testExecutorTimeoutTerminatesTheWholeProcessGroup() throws {
        let directory = try Self.makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fork-child.zsh")
        try "#!/bin/zsh\nsleep 30 &\nchild=$!\nprintf '%s %s\n' $$ $child\nwait $child\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let executor = ShellCommandExecutor()
        var capturedPIDs: [Int32] = []

        do {
            _ = try executor.run(executable: "/bin/zsh", arguments: [script.path], environment: nil, timeout: .milliseconds(250))
            XCTFail("Expected timeout")
        } catch let ShellCommandExecutionError.timedOut(stdout, _) {
            capturedPIDs = String(decoding: stdout, as: UTF8.self)
                .split(whereSeparator: \.isWhitespace)
                .compactMap { Int32($0) }
        }

        XCTAssertEqual(capturedPIDs.count, 2)
        for pid in capturedPIDs {
            XCTAssertTrue(Self.waitUntilGone(pid), "Process \(pid) survived executor timeout")
        }
    }

    func testSyntaxCheckerNeverRunsTheCommand() async {
        let executor = ScriptedShellExecutor(results: [
            .success(.init(stdout: Data(), stderr: Data(), terminationStatus: 0)),
            .success(.init(stdout: Data(), stderr: Data("parse error".utf8), terminationStatus: 1))
        ])
        let checker = ShellSyntaxChecker(zshPath: "/bin/zsh", executor: executor)

        let validResult = await checker.check(command: "echo $((1 + 1))")
        let invalidResult = await checker.check(command: "if then")

        XCTAssertEqual(validResult, .valid)
        XCTAssertEqual(invalidResult, .invalid("parse error"))
        XCTAssertEqual(executor.invocations.map(\.arguments), [
            ["-n", "-c", "echo $((1 + 1))"],
            ["-n", "-c", "if then"]
        ])
    }

    private static func environmentData(_ values: [String: String]) -> Data {
        let entries = values.map { "\($0.key)=\($0.value)" }.joined(separator: "\0")
        return Data("DEVBAR_ENV_BEGIN\0\(entries)\0DEVBAR_ENV_END\0".utf8)
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func waitUntilGone(_ pid: Int32) -> Bool {
        for _ in 0..<200 {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            usleep(10_000)
        }
        return false
    }
}

private final class ScriptedShellExecutor: ShellCommandExecuting, @unchecked Sendable {
    struct Invocation: Equatable {
        let executable: String
        let arguments: [String]
        let environment: [String: String]?
        let timeout: Duration
    }

    private let lock = NSLock()
    private var results: [Result<ShellCommandResult, Error>]
    private(set) var invocations: [Invocation] = []

    init(results: [Result<ShellCommandResult, Error>]) {
        self.results = results
    }

    var invocationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return invocations.count
    }

    func run(executable: String, arguments: [String], environment: [String: String]?, timeout: Duration) throws -> ShellCommandResult {
        lock.lock()
        invocations.append(.init(executable: executable, arguments: arguments, environment: environment, timeout: timeout))
        let result = results.removeFirst()
        lock.unlock()
        return try result.get()
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T) async {
        do {
            _ = try await expression()
            XCTFail("Expected an error")
        } catch {
            // Expected.
        }
    }
}
