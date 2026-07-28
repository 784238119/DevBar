import Darwin
import XCTest
@testable import DevBarRunnerKit

final class ProcessGroupTerminatorTests: XCTestCase {
    func testStopTerminatesAnEntireForegroundProcessGroup() async throws {
        let stdout = try makePipe()
        defer {
            close(stdout.read)
            close(stdout.write)
        }

        let spawned = try PosixSpawner().spawn(
            SpawnRequest(
                zshPath: "/bin/zsh",
                command: "sleep 60 & first=$!; sleep 60 & second=$!; printf '%s %s %s\\n' $$ $first $second; wait",
                workingDirectory: "/private/tmp",
                environment: ProcessInfo.processInfo.environment,
                stdoutFD: stdout.write,
                stderrFD: stdout.write,
                fileDescriptorsToCloseInChild: []
            )
        )
        close(stdout.write)

        let pids = try readPIDLine(from: stdout.read)
        let result = await ProcessGroupTerminator().stop(
            pgid: spawned.pgid,
            grace: StopGrace(sigint: .milliseconds(100), sigterm: .milliseconds(100))
        )

        XCTAssertNotEqual(result, .alreadyExited)
        reap(pid: spawned.pid)
        for pid in pids {
            XCTAssertTrue(waitUntilGone(pid: pid), "process \(pid) survived group termination")
        }
    }

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&descriptors), 0)
        return (descriptors[0], descriptors[1])
    }

    private func readPIDLine(from descriptor: Int32) throws -> [pid_t] {
        var bytes = [UInt8]()
        var byte: UInt8 = 0
        while read(descriptor, &byte, 1) == 1 {
            if byte == 0x0A { break }
            bytes.append(byte)
        }
        let string = try XCTUnwrap(String(bytes: bytes, encoding: .utf8))
        return try string.split(separator: " ").map { token in
            try XCTUnwrap(pid_t(token))
        }
    }

    private func waitUntilGone(pid: pid_t) -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            usleep(20_000)
        }
        return false
    }

    private func reap(pid: pid_t) {
        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
    }
}
