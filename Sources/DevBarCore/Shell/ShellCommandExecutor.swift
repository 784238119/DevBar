import Darwin
import Dispatch
import Foundation

public struct ShellCommandResult: Equatable, Sendable {
    public let stdout: Data
    public let stderr: Data
    public let terminationStatus: Int32

    public init(stdout: Data, stderr: Data, terminationStatus: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.terminationStatus = terminationStatus
    }
}

public enum ShellCommandExecutionError: Error, Equatable, Sendable, LocalizedError {
    case spawnFailed(Int32)
    case waitFailed(Int32)
    case timedOut(stdout: Data, stderr: Data)

    public var errorDescription: String? {
        switch self {
        case let .spawnFailed(code):
            "Could not launch zsh (POSIX error \(code))."
        case let .waitFailed(code):
            "Could not wait for zsh (POSIX error \(code))."
        case .timedOut:
            "zsh did not finish before the timeout. Check shell startup files for a command that waits for input or starts a long-running task."
        }
    }
}

public protocol ShellCommandExecuting: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String]?,
        timeout: Duration
    ) throws -> ShellCommandResult
}

/// Executes only short-lived shell commands used for environment capture and syntax validation.
///
/// Each command is a process-group leader so a timeout can terminate descendants that inherited
/// the shell's stdout or stderr pipes. Both pipes are drained concurrently to avoid a full-pipe
/// deadlock.
public struct ShellCommandExecutor: ShellCommandExecuting, Sendable {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: Duration
    ) throws -> ShellCommandResult {
        var stdoutPipe = try makePipe()
        var stderrPipe = try makePipe()
        defer {
            closeIfOpen(&stdoutPipe.read)
            closeIfOpen(&stdoutPipe.write)
            closeIfOpen(&stderrPipe.read)
            closeIfOpen(&stderrPipe.write)
        }

        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw ShellCommandExecutionError.spawnFailed(errno)
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        try addFileAction(posix_spawn_file_actions_adddup2(&fileActions, stdoutPipe.write, STDOUT_FILENO))
        try addFileAction(posix_spawn_file_actions_adddup2(&fileActions, stderrPipe.write, STDERR_FILENO))
        try addFileAction(posix_spawn_file_actions_addclose(&fileActions, stdoutPipe.read))
        try addFileAction(posix_spawn_file_actions_addclose(&fileActions, stderrPipe.read))
        try addFileAction(posix_spawn_file_actions_addclose(&fileActions, stdoutPipe.write))
        try addFileAction(posix_spawn_file_actions_addclose(&fileActions, stderrPipe.write))

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw ShellCommandExecutionError.spawnFailed(errno)
        }
        defer { posix_spawnattr_destroy(&attributes) }

        let flags = Int16(POSIX_SPAWN_SETPGROUP)
        try addSpawnAttribute(posix_spawnattr_setflags(&attributes, flags))
        try addSpawnAttribute(posix_spawnattr_setpgroup(&attributes, 0))

        let commandEnvironment = environment ?? ProcessInfo.processInfo.environment
        let environmentEntries = commandEnvironment
            .map { "\($0.key)=\($0.value)" }
            .sorted()
        var pid: pid_t = 0
        let spawnResult = withCStringArray([executable] + arguments) { argv in
            withCStringArray(environmentEntries) { envp in
                executable.withCString { executablePointer in
                    posix_spawn(&pid, executablePointer, &fileActions, &attributes, argv, envp)
                }
            }
        }
        guard spawnResult == 0 else {
            throw ShellCommandExecutionError.spawnFailed(spawnResult)
        }

        closeIfOpen(&stdoutPipe.write)
        closeIfOpen(&stderrPipe.write)

        let stdoutReader = DataReader(descriptor: stdoutPipe.read)
        stdoutPipe.read = -1
        let stderrReader = DataReader(descriptor: stderrPipe.read)
        stderrPipe.read = -1
        let readers = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: readers) {
            stdoutReader.readToEnd()
        }
        DispatchQueue.global(qos: .userInitiated).async(group: readers) {
            stderrReader.readToEnd()
        }

        let deadline = Date().addingTimeInterval(timeInterval(for: timeout))
        var status: Int32?
        while true {
            if status == nil {
                var waitStatus: Int32 = 0
                let waitResult = waitpid(pid, &waitStatus, WNOHANG)
                if waitResult == pid {
                    status = waitStatus
                } else if waitResult == -1, errno != EINTR {
                    terminateProcessGroup(pid)
                    readers.wait()
                    throw ShellCommandExecutionError.waitFailed(errno)
                }
            }

            if let status, readers.wait(timeout: .now()) == .success {
                return ShellCommandResult(
                    stdout: stdoutReader.data,
                    stderr: stderrReader.data,
                    terminationStatus: terminationStatus(from: status)
                )
            }

            if Date() >= deadline {
                terminateProcessGroup(pid)
                reap(pid)
                readers.wait()
                throw ShellCommandExecutionError.timedOut(stdout: stdoutReader.data, stderr: stderrReader.data)
            }
            usleep(10_000)
        }
    }

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else {
            throw ShellCommandExecutionError.spawnFailed(errno)
        }
        return (descriptors[0], descriptors[1])
    }

    private func addFileAction(_ result: Int32) throws {
        guard result == 0 else { throw ShellCommandExecutionError.spawnFailed(result) }
    }

    private func addSpawnAttribute(_ result: Int32) throws {
        guard result == 0 else { throw ShellCommandExecutionError.spawnFailed(result) }
    }

    private func closeIfOpen(_ descriptor: inout Int32) {
        guard descriptor >= 0 else { return }
        _ = Darwin.close(descriptor)
        descriptor = -1
    }

    private func terminateProcessGroup(_ pgid: pid_t) {
        _ = Darwin.kill(-pgid, SIGTERM)
        usleep(200_000)
        if Darwin.kill(-pgid, 0) == 0 || errno == EPERM {
            _ = Darwin.kill(-pgid, SIGKILL)
        }
    }

    private func reap(_ pid: pid_t) {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid || (result == -1 && errno == ECHILD) { return }
            if result == -1 && errno != EINTR { return }
        }
    }

    private func terminationStatus(from waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7F
        if signal == 0 {
            return (waitStatus >> 8) & 0xFF
        }
        return 128 + signal
    }

    private func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        let seconds = max(components.seconds, 0)
        let attoseconds = max(components.attoseconds, 0)
        return TimeInterval(seconds) + (TimeInterval(attoseconds) / 1_000_000_000_000_000_000)
    }
}

private final class DataReader: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var storedData = Data()

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storedData
    }

    func readToEnd() {
        defer { _ = Darwin.close(descriptor) }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(descriptor, pointer.baseAddress, pointer.count)
            }
            if count > 0 {
                result.append(buffer, count: Int(count))
                continue
            }
            if count == -1, errno == EINTR {
                continue
            }
            break
        }
        lock.lock()
        storedData = result
        lock.unlock()
    }
}

private func withCStringArray<Result>(
    _ strings: [String],
    body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Result
) rethrows -> Result {
    var pointers = strings.map { strdup($0) }
    pointers.append(nil)
    defer {
        for pointer in pointers {
            free(pointer)
        }
    }
    return try pointers.withUnsafeMutableBufferPointer { buffer in
        try body(buffer.baseAddress!)
    }
}
