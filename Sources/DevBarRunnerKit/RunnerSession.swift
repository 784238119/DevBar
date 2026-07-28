import Darwin
import DevBarCore
import Foundation

/// Owns one managed shell until it exits, receives a stop command, or loses the GUI control pipe.
public final class RunnerSession: @unchecked Sendable {
    private var commandReadFD: Int32
    private var eventWriteFD: Int32
    private var stdoutWriteFD: Int32
    private var stderrWriteFD: Int32
    private let spawner: PosixSpawner
    private let terminator: ProcessGroupTerminator

    public init(
        commandReadFD: Int32,
        eventWriteFD: Int32,
        stdoutWriteFD: Int32,
        stderrWriteFD: Int32,
        spawner: PosixSpawner = PosixSpawner(),
        terminator: ProcessGroupTerminator = ProcessGroupTerminator()
    ) {
        self.commandReadFD = commandReadFD
        self.eventWriteFD = eventWriteFD
        self.stdoutWriteFD = stdoutWriteFD
        self.stderrWriteFD = stderrWriteFD
        self.spawner = spawner
        self.terminator = terminator
    }

    deinit {
        closeDescriptors()
    }

    /// Returns the managed shell's normalized exit status. Control EOF is treated as ownership loss.
    public func run() async -> Int32 {
        defer { closeDescriptors() }
        guard let request = readLaunchRequest() else { return 64 }

        let spawned: SpawnedProcess
        do {
            spawned = try spawner.spawn(
                SpawnRequest(
                    zshPath: request.zshPath,
                    command: request.command,
                    workingDirectory: request.workingDirectory,
                    environment: request.environment,
                    stdoutFD: stdoutWriteFD,
                    stderrFD: stderrWriteFD,
                    fileDescriptorsToCloseInChild: [commandReadFD, eventWriteFD]
                )
            )
        } catch {
            emit(.error(runID: request.runID, message: error.localizedDescription))
            return 70
        }

        // Only the managed shell retains these write ends after posix_spawn.
        close(&stdoutWriteFD)
        close(&stderrWriteFD)
        emit(.started(runID: request.runID, pid: spawned.pid, pgid: spawned.pgid))

        var commandBuffer = Data()
        while true {
            if let status = reapIfExited(pid: spawned.pid) {
                emitExit(request.runID, status: status)
                return normalizedExitStatus(status)
            }

            switch readControlState(buffer: &commandBuffer) {
            case .noMessage:
                continue
            case .endOfFile:
                return await stopAndReap(spawned: spawned, request: request)
            case let .message(line):
                do {
                    let command = try RunnerCodec.decodeLine(line, as: RunnerCommand.self)
                    switch command {
                    case let .stop(runID) where runID == request.runID:
                        return await stopAndReap(spawned: spawned, request: request)
                    case .stop:
                        emit(.error(runID: request.runID, message: "Ignoring stop command for a different run."))
                    }
                } catch {
                    emit(.error(runID: request.runID, message: "Invalid control message: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func readLaunchRequest() -> RunnerLaunchRequest? {
        do {
            return try RunnerCodec.decodeLine(RunnerChannel.readLine(from: commandReadFD), as: RunnerLaunchRequest.self)
        } catch {
            // A launch request has no trustworthy runID until it has decoded.
            return nil
        }
    }

    private func stopAndReap(spawned: SpawnedProcess, request: RunnerLaunchRequest) async -> Int32 {
        let grace = StopGrace(
            sigint: .seconds(max(0, request.sigintGraceSeconds)),
            sigterm: .seconds(max(0, request.sigtermGraceSeconds))
        )
        let reaper = ChildReaper(pid: spawned.pid)
        let stopResult = await terminator.stop(pgid: spawned.pgid, grace: grace) { [weak self] signal in
            self?.emit(.stopPhase(runID: request.runID, signal: signal))
        } reapLeaderIfExited: {
            reaper.reapIfExited()
        }
        if case let .failed(error) = stopResult {
            emit(.error(runID: request.runID, message: error.localizedDescription))
            return 71
        }
        let status = reaper.takeStatus() ?? blockingReap(pid: spawned.pid)
        emitExit(request.runID, status: status)
        return normalizedExitStatus(status)
    }

    private enum ControlState {
        case noMessage
        case message(Data)
        case endOfFile
    }

    private func readControlState(buffer: inout Data) -> ControlState {
        var descriptor = pollfd(fd: commandReadFD, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let pollResult = Darwin.poll(&descriptor, 1, 100)
        if pollResult < 0 {
            return errno == EINTR ? .noMessage : .endOfFile
        }
        if pollResult == 0 { return .noMessage }

        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(commandReadFD, &bytes, bytes.count)
        if count == 0 { return .endOfFile }
        if count < 0 {
            return errno == EINTR || errno == EAGAIN ? .noMessage : .endOfFile
        }
        buffer.append(contentsOf: bytes.prefix(Int(count)))
        guard buffer.count <= RunnerChannel.maximumLineLength else { return .endOfFile }
        guard let newline = buffer.firstIndex(of: 0x0A) else { return .noMessage }
        let line = Data(buffer[...newline])
        buffer.removeSubrange(...newline)
        return .message(line)
    }

    private func reapIfExited(pid: pid_t) -> Int32? {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return status }
            if result == 0 { return nil }
            if result == -1, errno == EINTR { continue }
            return status
        }
    }

    private func blockingReap(pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { return status }
            if result == -1, errno == EINTR { continue }
            return status
        }
    }

    private func emitExit(_ runID: UUID, status: Int32) {
        let signal = status & 0x7F
        if signal == 0 {
            emit(.exited(runID: runID, code: (status >> 8) & 0xFF, signal: nil))
        } else {
            emit(.exited(runID: runID, code: nil, signal: signal))
        }
    }

    private func normalizedExitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? ((status >> 8) & 0xFF) : 128 + signal
    }

    private func emit(_ event: RunnerEvent) {
        try? RunnerChannel.writeLine(event, to: eventWriteFD)
    }

    private func closeDescriptors() {
        close(&commandReadFD)
        close(&eventWriteFD)
        close(&stdoutWriteFD)
        close(&stderrWriteFD)
    }

    private func close(_ descriptor: inout Int32) {
        guard descriptor >= 0 else { return }
        _ = Darwin.close(descriptor)
        descriptor = -1
    }
}

private final class ChildReaper: @unchecked Sendable {
    private let pid: pid_t
    private let lock = NSLock()
    private var status: Int32?

    init(pid: pid_t) {
        self.pid = pid
    }

    func reapIfExited() {
        lock.lock()
        defer { lock.unlock() }
        guard status == nil else { return }
        var value: Int32 = 0
        while true {
            let result = waitpid(pid, &value, WNOHANG)
            if result == pid {
                status = value
                return
            }
            if result == 0 { return }
            if result == -1, errno == EINTR { continue }
            return
        }
    }

    func takeStatus() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        return status
    }
}
