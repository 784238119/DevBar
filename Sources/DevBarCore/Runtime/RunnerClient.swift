import Darwin
import Foundation

public protocol RunnerControlling: Sendable {
    func launch(_ request: RunnerLaunchRequest) async throws -> AsyncStream<ServiceRuntimeEvent>
    func stop(runID: UUID) async throws
}

public enum RunnerClientError: Error, Equatable, Sendable, LocalizedError {
    case helperMissing(String)
    case helperNotExecutable(String)
    case duplicateRun(UUID)
    case pipeCreation(Int32)
    case spawn(Int32)
    case endOfFile
    case readFailure(String)
    case initialWrite(String)
    case stopWrite(String)

    public var errorDescription: String? {
        switch self {
        case let .helperMissing(path):
            "DevBarRunner is missing from the app bundle at \(path)."
        case let .helperNotExecutable(path):
            "DevBarRunner is not executable at \(path)."
        case let .duplicateRun(runID):
            "A Runner is already active for run \(runID.uuidString)."
        case let .pipeCreation(code):
            "Could not create Runner pipes (POSIX error \(code))."
        case let .spawn(code):
            "Could not launch DevBarRunner (POSIX error \(code))."
        case .endOfFile:
            "Runner channel closed."
        case let .readFailure(message):
            "Could not read the Runner channel. \(message)"
        case let .initialWrite(message):
            "Could not send the Runner launch request. \(message)"
        case let .stopWrite(message):
            "Could not send the Runner stop request. \(message)"
        }
    }
}

/// Launches the embedded Runner and owns only the GUI ends of its four pipes.
///
/// This actor intentionally does not interpret Runner exit status. The supervisor decides whether
/// an exit was requested and therefore whether it is a stopped or failed service.
public actor RunnerClient: RunnerControlling {
    private let helperURL: URL
    private var connections: [UUID: RunnerConnection] = [:]

    public init(helperURL: URL? = nil) {
        self.helperURL = helperURL ?? Self.embeddedHelperURL()
    }

    public static func embeddedHelperURL(bundle: Bundle = .main) -> URL {
        bundle.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("DevBarRunner", isDirectory: false)
    }

    public func launch(_ request: RunnerLaunchRequest) async throws -> AsyncStream<ServiceRuntimeEvent> {
        guard connections[request.runID] == nil else {
            throw RunnerClientError.duplicateRun(request.runID)
        }
        guard FileManager.default.fileExists(atPath: helperURL.path) else {
            throw RunnerClientError.helperMissing(helperURL.path)
        }
        guard FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            throw RunnerClientError.helperNotExecutable(helperURL.path)
        }

        let connection: RunnerConnection
        do {
            connection = try RunnerConnection(helperURL: helperURL, request: request)
        } catch let error as RunnerClientError {
            throw error
        } catch {
            throw RunnerClientError.initialWrite(error.localizedDescription)
        }

        connections[request.runID] = connection
        connection.onCompletion = { [weak self] in
            Task { await self?.removeConnection(runID: request.runID) }
        }
        let stream = connection.start()
        return stream
    }

    public func stop(runID: UUID) async throws {
        guard let connection = connections[runID] else { return }
        do {
            try connection.sendStop()
        } catch {
            throw RunnerClientError.stopWrite(error.localizedDescription)
        }
    }

    private func removeConnection(runID: UUID) {
        connections.removeValue(forKey: runID)
    }
}

private final class RunnerConnection: @unchecked Sendable {
    private let lock = NSLock()
    private let request: RunnerLaunchRequest
    private var commandWriteFD: Int32 = -1
    private var eventReadFD: Int32 = -1
    private var stdoutReadFD: Int32 = -1
    private var stderrReadFD: Int32 = -1
    private var runnerPID: pid_t = 0
    private var continuation: AsyncStream<ServiceRuntimeEvent>.Continuation?
    private var pendingReaders = 3
    private var didRequestStop = false
    private var completed = false

    var onCompletion: (@Sendable () -> Void)?

    init(helperURL: URL, request: RunnerLaunchRequest) throws {
        self.request = request
        var command = try Self.makePipe()
        var event = try Self.makePipe()
        var stdout = try Self.makePipe()
        var stderr = try Self.makePipe()
        var pid: pid_t = 0

        do {
            // Keep source descriptors away from 3...6 so the later close actions cannot close a
            // descriptor that has just been remapped for the Runner.
            var commandRunner = try Self.duplicateForRunner(command.read)
            var eventRunner = try Self.duplicateForRunner(event.write)
            var stdoutRunner = try Self.duplicateForRunner(stdout.write)
            var stderrRunner = try Self.duplicateForRunner(stderr.write)
            defer {
                Self.close(&commandRunner)
                Self.close(&eventRunner)
                Self.close(&stdoutRunner)
                Self.close(&stderrRunner)
            }
            Self.close(&command.read)
            Self.close(&event.write)
            Self.close(&stdout.write)
            Self.close(&stderr.write)

            try Self.setCloseOnExec(command.write)
            try Self.setCloseOnExec(event.read)
            try Self.setCloseOnExec(stdout.read)
            try Self.setCloseOnExec(stderr.read)

            var actions: posix_spawn_file_actions_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else {
                throw RunnerClientError.spawn(errno)
            }
            defer { posix_spawn_file_actions_destroy(&actions) }

            // Close the GUI ends first. Some of them can numerically overlap 3...6.
            try Self.addAction(posix_spawn_file_actions_addclose(&actions, command.write))
            try Self.addAction(posix_spawn_file_actions_addclose(&actions, event.read))
            try Self.addAction(posix_spawn_file_actions_addclose(&actions, stdout.read))
            try Self.addAction(posix_spawn_file_actions_addclose(&actions, stderr.read))
            try Self.addAction(posix_spawn_file_actions_adddup2(&actions, commandRunner, 3))
            try Self.addAction(posix_spawn_file_actions_adddup2(&actions, eventRunner, 4))
            try Self.addAction(posix_spawn_file_actions_adddup2(&actions, stdoutRunner, 5))
            try Self.addAction(posix_spawn_file_actions_adddup2(&actions, stderrRunner, 6))
            for descriptor in [commandRunner, eventRunner, stdoutRunner, stderrRunner] {
                try Self.addAction(posix_spawn_file_actions_addclose(&actions, descriptor))
            }

            let arguments = [
                helperURL.path,
                "--command-fd", "3",
                "--event-fd", "4",
                "--stdout-fd", "5",
                "--stderr-fd", "6"
            ]
            let result = Self.withCStringArray(arguments) { argv in
                helperURL.path.withCString { executable in
                    posix_spawn(&pid, executable, &actions, nil, argv, environ)
                }
            }
            guard result == 0 else { throw RunnerClientError.spawn(result) }

            self.commandWriteFD = command.write
            self.eventReadFD = event.read
            self.stdoutReadFD = stdout.read
            self.stderrReadFD = stderr.read
            self.runnerPID = pid
            command.write = -1
            event.read = -1
            stdout.read = -1
            stderr.read = -1

            do {
                try Self.writeLine(request, to: commandWriteFD)
            } catch {
                closeAllAndReap(pid: pid)
                throw RunnerClientError.initialWrite(error.localizedDescription)
            }
        } catch {
            Self.close(&command.read)
            Self.close(&command.write)
            Self.close(&event.read)
            Self.close(&event.write)
            Self.close(&stdout.read)
            Self.close(&stdout.write)
            Self.close(&stderr.read)
            Self.close(&stderr.write)
            throw error
        }
    }

    deinit {
        let gracefulWait = max(
            2,
            request.sigintGraceSeconds + request.sigtermGraceSeconds + 3
        )
        closeAllAndReap(pid: runnerPID, gracefulWaitSeconds: gracefulWait)
    }

    func start() -> AsyncStream<ServiceRuntimeEvent> {
        AsyncStream { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.closeCommandPipe() }
            readEvents()
            readRawOutput(descriptor: stdoutReadFD, isStandardError: false)
            readRawOutput(descriptor: stderrReadFD, isStandardError: true)
        }
    }

    func sendStop() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !didRequestStop else { return }
        guard commandWriteFD >= 0 else { return }
        do {
            try Self.writeLine(RunnerCommand.stop(runID: request.runID), to: commandWriteFD)
            didRequestStop = true
        } catch {
            throw error
        }
    }

    private func readEvents() {
        let descriptor = eventReadFD
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                self?.closeReader(descriptor)
                self?.readerFinished()
            }
            guard let self else { return }
            while true {
                do {
                    let line = try Self.readLine(from: descriptor)
                    let event = try RunnerCodec.decodeLine(line, as: RunnerEvent.self)
                    self.yield(.runner(event))
                } catch RunnerClientError.endOfFile {
                    return
                } catch {
                    self.yield(.channelFailure(runID: self.request.runID, message: error.localizedDescription))
                    return
                }
            }
        }
    }

    private func readRawOutput(descriptor: Int32, isStandardError: Bool) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer {
                self?.closeReader(descriptor)
                self?.readerFinished()
            }
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = buffer.withUnsafeMutableBytes { pointer in
                    Darwin.read(descriptor, pointer.baseAddress, pointer.count)
                }
                if count > 0 {
                    let data = Data(buffer.prefix(Int(count)))
                    self.yield(isStandardError
                        ? .stderr(runID: self.request.runID, data: data)
                        : .stdout(runID: self.request.runID, data: data)
                    )
                    continue
                }
                if count == -1, errno == EINTR { continue }
                if count == -1 {
                    self.yield(.channelFailure(
                        runID: self.request.runID,
                        message: "Could not read Runner output: \(String(cString: strerror(errno)))."
                    ))
                }
                return
            }
        }
    }

    private func yield(_ event: ServiceRuntimeEvent) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(event)
    }

    private func readerFinished() {
        lock.lock()
        pendingReaders -= 1
        let shouldFinish = pendingReaders == 0 && !completed
        if shouldFinish { completed = true }
        let continuation = self.continuation
        lock.unlock()
        guard shouldFinish else { return }
        closeCommandPipe()
        reapRunnerIfExited()
        continuation?.finish()
        onCompletion?()
    }

    private func closeReader(_ descriptor: Int32) {
        lock.lock()
        if eventReadFD == descriptor {
            Self.close(&eventReadFD)
        } else if stdoutReadFD == descriptor {
            Self.close(&stdoutReadFD)
        } else if stderrReadFD == descriptor {
            Self.close(&stderrReadFD)
        }
        lock.unlock()
    }

    private func reapRunnerIfExited() {
        lock.lock()
        let child = runnerPID
        runnerPID = 0
        lock.unlock()
        guard child > 0 else { return }
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1, errno == EINTR {}
    }

    private func closeCommandPipe() {
        lock.lock()
        Self.close(&commandWriteFD)
        lock.unlock()
    }

    private func closeAllAndReap(pid: pid_t, gracefulWaitSeconds: Int = 0) {
        lock.lock()
        Self.close(&commandWriteFD)
        Self.close(&eventReadFD)
        Self.close(&stdoutReadFD)
        Self.close(&stderrReadFD)
        let child = runnerPID
        runnerPID = 0
        lock.unlock()
        let target = pid == 0 ? child : pid
        guard target > 0 else { return }
        if gracefulWaitSeconds > 0, waitForExit(target, timeout: TimeInterval(gracefulWaitSeconds)) {
            return
        }
        _ = Darwin.kill(target, SIGTERM)
        if waitForExit(target, timeout: 1) { return }
        _ = Darwin.kill(target, SIGKILL)
        var status: Int32 = 0
        while waitpid(target, &status, 0) == -1, errno == EINTR {}
    }

    private func waitForExit(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) { return true }
            if result == -1, errno != EINTR { return false }
            if Date() >= deadline { return false }
            usleep(20_000)
        }
    }

    private static func makePipe() throws -> (read: Int32, write: Int32) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw RunnerClientError.pipeCreation(errno) }
        return (descriptors[0], descriptors[1])
    }

    private static func duplicateForRunner(_ descriptor: Int32) throws -> Int32 {
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 20)
        guard duplicate >= 0 else { throw RunnerClientError.pipeCreation(errno) }
        return duplicate
    }

    private static func setCloseOnExec(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0, fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0 else {
            throw RunnerClientError.pipeCreation(errno)
        }
    }

    private static func addAction(_ result: Int32) throws {
        guard result == 0 else { throw RunnerClientError.spawn(result) }
    }

    private static func writeLine<Value: Encodable>(_ value: Value, to descriptor: Int32) throws {
        let data = try RunnerCodec.encodeLine(value)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if count > 0 {
                    offset += count
                } else if count == -1, errno == EINTR {
                    continue
                } else {
                    throw RunnerClientError.initialWrite(String(cString: strerror(errno)))
                }
            }
        }
    }

    private static func readLine(from descriptor: Int32) throws -> Data {
        var line = Data()
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(descriptor, &byte, 1)
            if count == 0 { throw RunnerClientError.endOfFile }
            if count == -1, errno == EINTR { continue }
            if count < 0 { throw RunnerClientError.readFailure(String(cString: strerror(errno))) }
            line.append(byte)
            if byte == 0x0A { return line }
            if line.count > 1_048_576 { throw RunnerClientError.readFailure("Runner event line exceeds 1 MiB.") }
        }
    }

    private static func close(_ descriptor: inout Int32) {
        guard descriptor >= 0 else { return }
        _ = Darwin.close(descriptor)
        descriptor = -1
    }


    private static func withCStringArray<Result>(
        _ strings: [String],
        body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Result
    ) -> Result {
        var pointers = strings.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers { free(pointer) }
        }
        return pointers.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
