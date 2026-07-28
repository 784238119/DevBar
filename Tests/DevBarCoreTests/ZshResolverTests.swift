import Foundation
import XCTest
@testable import DevBarCore

final class ZshResolverTests: XCTestCase {
    func testShellEnvironmentCandidateMustBeExecutableRegularFileAndReportZsh() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidate = try makeExecutableFile(in: directory, named: "zsh")
        let executor = VersionExecutor(versions: [candidate.path: "zsh 5.9 (test)"])
        let resolver = ZshResolver(commandExecutor: executor, fallbackPath: directory.appendingPathComponent("missing-zsh").path)

        let result = try resolver.resolve(environment: ["SHELL": candidate.path])

        XCTAssertEqual(result.path, candidate.path)
        XCTAssertEqual(result.source, .shellEnvironment)
        XCTAssertNil(result.warning)
    }

    func testNonZshShellFallsBackWithWarning() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = try makeExecutableFile(in: directory, named: "bash")
        let fallback = try makeExecutableFile(in: directory, named: "zsh")
        let executor = VersionExecutor(versions: [
            shell.path: "GNU bash, version 5.2",
            fallback.path: "zsh 5.9 (test)"
        ])
        let resolver = ZshResolver(commandExecutor: executor, fallbackPath: fallback.path)

        let result = try resolver.resolve(environment: ["SHELL": shell.path])

        XCTAssertEqual(result.path, fallback.path)
        XCTAssertEqual(result.source, .fallback)
        XCTAssertNotNil(result.warning)
    }

    func testDirectoryCandidateIsRejectedWithoutVersionProbe() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fallback = try makeExecutableFile(in: directory, named: "zsh")
        let executor = VersionExecutor(versions: [fallback.path: "zsh 5.9 (test)"])
        let resolver = ZshResolver(commandExecutor: executor, fallbackPath: fallback.path)

        _ = try resolver.resolve(environment: ["SHELL": directory.path])

        XCTAssertEqual(executor.invocations, [fallback.path])
    }

    func testTwoInvalidCandidatesProduceResolutionError() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let shell = try makeExecutableFile(in: directory, named: "bash")
        let fallback = try makeExecutableFile(in: directory, named: "also-bash")
        let executor = VersionExecutor(versions: [
            shell.path: "GNU bash, version 5.2",
            fallback.path: "GNU bash, version 5.2"
        ])
        let resolver = ZshResolver(commandExecutor: executor, fallbackPath: fallback.path)

        XCTAssertThrowsError(try resolver.resolve(environment: ["SHELL": shell.path])) { error in
            XCTAssertEqual(error as? ZshResolutionError, .noUsableZsh)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeExecutableFile(in directory: URL, named name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

private final class VersionExecutor: ShellCommandExecuting, @unchecked Sendable {
    private let versions: [String: String]
    private(set) var invocations: [String] = []

    init(versions: [String: String]) {
        self.versions = versions
    }

    func run(executable: String, arguments: [String], environment: [String: String]?, timeout: Duration) throws -> ShellCommandResult {
        invocations.append(executable)
        return .init(
            stdout: Data((versions[executable] ?? "unknown").utf8),
            stderr: Data(),
            terminationStatus: 0
        )
    }
}
