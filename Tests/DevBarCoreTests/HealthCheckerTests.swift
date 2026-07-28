import Darwin
import Foundation
import XCTest
@testable import DevBarCore

final class HealthCheckerTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testHTTPAcceptsOnlyStatusCodes200Through399() async {
        let session = makeSession()
        let probe = NetworkHealthProbe(session: session, timeout: .milliseconds(100))
        let url = URL(string: "https://health.test/status")!

        for status in [199, 200, 302, 399, 400] {
            MockURLProtocol.set(.response(status: status))
            let result = await probe.probe(.http(url))
            if (200...399).contains(status) {
                XCTAssertEqual(result, .ready, "status \(status)")
            } else {
                guard case .unready = result else {
                    return XCTFail("Expected status \(status) to be unready")
                }
            }
        }
    }

    func testHTTPTransportErrorIsUnready() async {
        MockURLProtocol.set(.failure(URLError(.timedOut)))
        let result = await NetworkHealthProbe(session: makeSession(), timeout: .milliseconds(100)).probe(
            .http(URL(string: "https://health.test/timeout")!)
        )
        guard case .unready = result else { return XCTFail("Expected transport failure") }
    }

    func testTCPSucceedsOnlyAfterConnectionReady() async throws {
        let listener = try SocketListener()

        let result = await NetworkHealthProbe(timeout: .milliseconds(250)).probe(
            .tcp(host: "127.0.0.1", port: listener.port)
        )
        XCTAssertEqual(result, .ready)
    }

    func testPollingDoesNotOverlapAndCancellationStopsLaterEmission() async {
        let probe = BlockingProbe()
        let checker = HealthChecker(probe: probe, pollInterval: .milliseconds(10))
        let serviceID = UUID()
        let stream = await checker.start(serviceID: serviceID, runID: UUID(), config: .none)
        let first = Task { () -> HealthProbeResult? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        await eventually { await probe.invocationCount == 1 }
        try? await Task.sleep(for: .milliseconds(80))
        let beforeCancellationCount = await probe.invocationCount
        XCTAssertEqual(beforeCancellationCount, 1, "A blocked probe must prevent overlapping polls")

        await checker.cancel(serviceID: serviceID)
        await probe.resumeAll(with: .ready)
        let firstResult = await first.value
        XCTAssertNil(firstResult)
        try? await Task.sleep(for: .milliseconds(40))
        let afterCancellationCount = await probe.invocationCount
        XCTAssertEqual(afterCancellationCount, 1)
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func eventually(condition: @escaping () async -> Bool) async {
        for _ in 0..<100 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let result = await condition()
        XCTAssertTrue(result)
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    enum Outcome {
        case response(status: Int)
        case failure(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var outcome: Outcome = .response(status: 200)

    static func set(_ outcome: Outcome) {
        lock.lock()
        self.outcome = outcome
        lock.unlock()
    }

    static func reset() { set(.response(status: 200)) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let outcome = Self.outcome
        Self.lock.unlock()
        switch outcome {
        case let .response(status):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private actor BlockingProbe: HealthProbing {
    private var continuations: [CheckedContinuation<HealthProbeResult, Never>] = []
    private(set) var invocationCount = 0

    func probe(_ configuration: HealthCheckConfig) async -> HealthProbeResult {
        invocationCount += 1
        return await withCheckedContinuation { continuations.append($0) }
    }

    func resumeAll(with result: HealthProbeResult) {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending { continuation.resume(returning: result) }
    }
}

private final class SocketListener {
    let descriptor: Int32
    let port: Int

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.descriptor = descriptor
        self.port = Int(UInt16(bigEndian: address.sin_port))
    }

    deinit {
        Darwin.close(descriptor)
    }
}
