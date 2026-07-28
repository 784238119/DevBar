import Darwin
import Foundation

public enum PosixSpawnerError: Error, Equatable, Sendable, LocalizedError {
    case invalidFileDescriptor(Int32)
    case systemCall(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .invalidFileDescriptor(descriptor):
            "Invalid file descriptor \(descriptor)."
        case let .systemCall(operation, code):
            "\(operation) failed: \(String(cString: strerror(code)))."
        }
    }
}

public struct SpawnRequest: Sendable {
    public let zshPath: String
    public let command: String
    public let workingDirectory: String
    public let environment: [String: String]
    public let stdoutFD: Int32
    public let stderrFD: Int32
    /// Runner-owned descriptors which must never reach zsh or any descendant.
    public let fileDescriptorsToCloseInChild: [Int32]

    public init(
        zshPath: String,
        command: String,
        workingDirectory: String,
        environment: [String: String],
        stdoutFD: Int32,
        stderrFD: Int32,
        fileDescriptorsToCloseInChild: [Int32]
    ) {
        self.zshPath = zshPath
        self.command = command
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
        self.fileDescriptorsToCloseInChild = fileDescriptorsToCloseInChild
    }
}

public struct SpawnedProcess: Equatable, Sendable {
    public let pid: pid_t
    public let pgid: pid_t

    public init(pid: pid_t, pgid: pid_t) {
        self.pid = pid
        self.pgid = pgid
    }
}

/// Starts one non-interactive zsh process in a process group owned by the Runner.
public struct PosixSpawner: Sendable {
    public init() {}

    public func spawn(_ request: SpawnRequest) throws -> SpawnedProcess {
        guard request.stdoutFD >= 0 else { throw PosixSpawnerError.invalidFileDescriptor(request.stdoutFD) }
        guard request.stderrFD >= 0 else { throw PosixSpawnerError.invalidFileDescriptor(request.stderrFD) }

        let devNull = Darwin.open("/dev/null", O_RDONLY)
        guard devNull >= 0 else {
            throw PosixSpawnerError.systemCall(operation: "open(/dev/null)", code: errno)
        }
        defer { _ = Darwin.close(devNull) }

        try setCloseOnExec(devNull)
        try setCloseOnExec(request.stdoutFD)
        try setCloseOnExec(request.stderrFD)
        for descriptor in Set(request.fileDescriptorsToCloseInChild) where descriptor >= 0 {
            try setCloseOnExec(descriptor)
        }

        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions), operation: "posix_spawn_file_actions_init")
        defer { posix_spawn_file_actions_destroy(&actions) }

        try request.workingDirectory.withCString { path in
            let result: Int32
            if #available(macOS 26.0, *) {
                result = posix_spawn_file_actions_addchdir(&actions, path)
            } else {
                result = posix_spawn_file_actions_addchdir_np(&actions, path)
            }
            try check(result, operation: "posix_spawn_file_actions_addchdir")
        }
        try check(
            posix_spawn_file_actions_adddup2(&actions, devNull, STDIN_FILENO),
            operation: "posix_spawn_file_actions_adddup2(stdin)"
        )
        try check(
            posix_spawn_file_actions_adddup2(&actions, request.stdoutFD, STDOUT_FILENO),
            operation: "posix_spawn_file_actions_adddup2(stdout)"
        )
        try check(
            posix_spawn_file_actions_adddup2(&actions, request.stderrFD, STDERR_FILENO),
            operation: "posix_spawn_file_actions_adddup2(stderr)"
        )

        let descriptorsToClose = Set(request.fileDescriptorsToCloseInChild + [devNull, request.stdoutFD, request.stderrFD])
            .subtracting(Set([STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO]))
        for descriptor in descriptorsToClose where descriptor >= 0 {
            try check(
                posix_spawn_file_actions_addclose(&actions, descriptor),
                operation: "posix_spawn_file_actions_addclose"
            )
        }

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes), operation: "posix_spawnattr_init")
        defer { posix_spawnattr_destroy(&attributes) }
        try check(
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)),
            operation: "posix_spawnattr_setflags"
        )
        try check(posix_spawnattr_setpgroup(&attributes, 0), operation: "posix_spawnattr_setpgroup")

        let arguments = try CStringArray([request.zshPath, "-c", request.command])
        let environment = try CStringArray(
            request.environment.keys.sorted().map { "\($0)=\(request.environment[$0] ?? "")" }
        )
        var pid: pid_t = 0
        let spawnResult = request.zshPath.withCString { executablePath in
            posix_spawn(&pid, executablePath, &actions, &attributes, arguments.pointer, environment.pointer)
        }
        try check(spawnResult, operation: "posix_spawn")

        // POSIX_SPAWN_SETPGROUP with pgroup 0 makes the child its own group leader.
        return SpawnedProcess(pid: pid, pgid: pid)
    }

    private func setCloseOnExec(_ descriptor: Int32) throws {
        let currentFlags = fcntl(descriptor, F_GETFD)
        guard currentFlags >= 0 else {
            throw PosixSpawnerError.systemCall(operation: "fcntl(F_GETFD)", code: errno)
        }
        guard fcntl(descriptor, F_SETFD, currentFlags | FD_CLOEXEC) == 0 else {
            throw PosixSpawnerError.systemCall(operation: "fcntl(F_SETFD)", code: errno)
        }
    }

    private func check(_ result: Int32, operation: String) throws {
        guard result == 0 else { throw PosixSpawnerError.systemCall(operation: operation, code: result) }
    }
}

private final class CStringArray {
    let pointer: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let strings: [UnsafeMutablePointer<CChar>]

    init(_ values: [String]) throws {
        var allocated: [UnsafeMutablePointer<CChar>] = []
        allocated.reserveCapacity(values.count)
        for value in values {
            guard let string = strdup(value) else {
                allocated.forEach { Darwin.free($0) }
                throw PosixSpawnerError.systemCall(operation: "strdup", code: ENOMEM)
            }
            allocated.append(string)
        }
        strings = allocated
        pointer = .allocate(capacity: allocated.count + 1)
        for (index, string) in allocated.enumerated() { pointer[index] = string }
        pointer[allocated.count] = nil
    }

    deinit {
        strings.forEach { Darwin.free($0) }
        pointer.deallocate()
    }
}
