import Foundation
import Network

public enum HealthProbeResult: Equatable, Sendable {
    case ready
    case unready(String)
}

public protocol HealthProbing: Sendable {
    func probe(_ configuration: HealthCheckConfig) async -> HealthProbeResult
}

/// Performs one bounded health probe. The default URL session has independent request and resource
/// limits of one second; TCP uses the same deadline and always cancels its connection afterwards.
public struct NetworkHealthProbe: HealthProbing, Sendable {
    private let session: URLSession
    private let timeout: Duration

    public init(session: URLSession? = nil, timeout: Duration = .seconds(1)) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 1
            configuration.timeoutIntervalForResource = 1
            self.session = URLSession(configuration: configuration)
        }
        self.timeout = timeout
    }

    public func probe(_ configuration: HealthCheckConfig) async -> HealthProbeResult {
        switch configuration {
        case .none:
            return .ready
        case let .http(url):
            return await probeHTTP(url)
        case let .tcp(host, port):
            return await probeTCP(host: host, port: port)
        }
    }

    private func probeHTTP(_ url: URL) async -> HealthProbeResult {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout.timeInterval
        do {
            let (_, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                return .unready("Health endpoint did not return an HTTP response.")
            }
            guard (200...399).contains(httpResponse.statusCode) else {
                return .unready("HTTP health check returned status \(httpResponse.statusCode).")
            }
            return .ready
        } catch {
            return .unready("HTTP health check failed: \(error.localizedDescription)")
        }
    }

    private func probeTCP(host: String, port: Int) async -> HealthProbeResult {
        guard let networkPort = UInt16(exactly: port).flatMap(NWEndpoint.Port.init(rawValue:)) else {
            return .unready("TCP health check has an invalid port.")
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: networkPort, using: .tcp)
        let completion = TCPProbeCompletion(connection: connection)
        return await withCheckedContinuation { continuation in
            completion.install(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    completion.finish(.ready)
                case let .failed(error):
                    completion.finish(.unready("TCP health check failed: \(error.localizedDescription)"))
                case .cancelled:
                    completion.finish(.unready("TCP health check was cancelled."))
                case .setup, .preparing, .waiting:
                    break
                @unknown default:
                    completion.finish(.unready("TCP health check entered an unsupported state."))
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout.timeInterval) {
                completion.finish(.unready("TCP health check timed out."))
            }
        }
    }
}

private final class TCPProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NWConnection
    private var continuation: CheckedContinuation<HealthProbeResult, Never>?

    init(connection: NWConnection) {
        self.connection = connection
    }

    func install(_ continuation: CheckedContinuation<HealthProbeResult, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: HealthProbeResult) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        guard let continuation else { return }
        connection.cancel()
        continuation.resume(returning: result)
    }
}

/// One polling session per service. Each loop awaits its probe before sleeping, which guarantees
/// that a slow probe cannot overlap the next two-second interval.
public actor HealthChecker {
    private final class Session: @unchecked Sendable {
        let runID: UUID
        let continuation: AsyncStream<HealthProbeResult>.Continuation
        let task: Task<Void, Never>

        init(
            runID: UUID,
            continuation: AsyncStream<HealthProbeResult>.Continuation,
            task: Task<Void, Never>
        ) {
            self.runID = runID
            self.continuation = continuation
            self.task = task
        }
    }

    private let probe: any HealthProbing
    private let pollInterval: Duration
    private var sessions: [UUID: Session] = [:]

    public init(probe: any HealthProbing = NetworkHealthProbe(), pollInterval: Duration = .seconds(2)) {
        self.probe = probe
        self.pollInterval = pollInterval
    }

    public func start(
        serviceID: UUID,
        runID: UUID,
        config: HealthCheckConfig
    ) -> AsyncStream<HealthProbeResult> {
        cancel(serviceID: serviceID)

        let (stream, continuation) = AsyncStream<HealthProbeResult>.makeStream()
        let probe = self.probe
        let interval = self.pollInterval
        let task = Task { [probe, config, continuation, interval] in
            while !Task.isCancelled {
                let result = await probe.probe(config)
                guard !Task.isCancelled else { break }
                continuation.yield(result)
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    break
                }
            }
            continuation.finish()
        }
        sessions[serviceID] = Session(runID: runID, continuation: continuation, task: task)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.cancelIfCurrent(serviceID: serviceID, runID: runID) }
        }
        return stream
    }

    public func cancel(serviceID: UUID, runID: UUID? = nil) {
        if let runID, sessions[serviceID]?.runID != runID { return }
        guard let session = sessions.removeValue(forKey: serviceID) else { return }
        session.task.cancel()
        session.continuation.finish()
    }

    private func cancelIfCurrent(serviceID: UUID, runID: UUID) {
        guard sessions[serviceID]?.runID == runID else { return }
        cancel(serviceID: serviceID, runID: runID)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let values = self.components
        return TimeInterval(values.seconds) + TimeInterval(values.attoseconds) / 1_000_000_000_000_000_000
    }
}
