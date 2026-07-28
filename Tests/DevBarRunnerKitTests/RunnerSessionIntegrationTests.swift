import Darwin
import XCTest
@testable import DevBarCore
@testable import DevBarRunnerKit

final class RunnerSessionIntegrationTests: XCTestCase {
    func testCommandEOFTerminatesManagedShellAndReapsIt() async throws {
        let command = try makePipe()
        let event = try makePipe()
        let stdout = try makePipe()
        let stderr = try makePipe()
        // In production the command writer lives only in the GUI process. This
        // in-process integration fixture must prevent zsh from inheriting that
        // writer, otherwise closing it cannot produce EOF at the Runner.
        try setCloseOnExec(command.write)
        defer {
            [event.read, stdout.read, stderr.read].forEach { close($0) }
        }

        let session = RunnerSession(
            commandReadFD: command.read,
            eventWriteFD: event.write,
            stdoutWriteFD: stdout.write,
            stderrWriteFD: stderr.write
        )
        let resultTask = Task { await session.run() }
        let request = RunnerLaunchRequest(
            runID: UUID(),
            zshPath: "/bin/zsh",
            command: "sleep 60 & wait",
            workingDirectory: "/private/tmp",
            environment: ProcessInfo.processInfo.environment,
            sigintGraceSeconds: 0,
            sigtermGraceSeconds: 0
        )
        try writeAll(try RunnerCodec.encodeLine(request), to: command.write)
        let started = try await nextEvent(from: event.read)
        guard case let .started(_, pid, _) = started else {
            return XCTFail("expected a started event, got \(started)")
        }

        close(command.write)
        let exitCode = await resultTask.value

        XCTAssertNotEqual(exitCode, 0)
        XCTAssertTrue(waitUntilReaped(pid: pid))
    }

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        return (descriptors[0], descriptors[1])
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), rawBuffer.count - offset)
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }

    private func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func nextEvent(from descriptor: Int32) async throws -> RunnerEvent {
        try await Task.detached {
            try RunnerCodec.decodeLine(RunnerChannel.readLine(from: descriptor), as: RunnerEvent.self)
        }.value
    }

    private func waitUntilReaped(pid: pid_t) -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            usleep(20_000)
        }
        return false
    }
}
