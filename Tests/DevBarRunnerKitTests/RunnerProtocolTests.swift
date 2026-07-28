import XCTest
@testable import DevBarCore

final class RunnerProtocolTests: XCTestCase {
    func testRunnerEventsRoundTripAsOneJSONObjectPerLine() throws {
        let event = RunnerEvent.started(runID: UUID(), pid: 123, pgid: 456)

        let line = try RunnerCodec.encodeLine(event)

        XCTAssertEqual(line.last, 0x0A)
        XCTAssertEqual(line.dropLast().filter { $0 == 0x0A }.count, 0)
        XCTAssertEqual(try RunnerCodec.decodeLine(line, as: RunnerEvent.self), event)
    }

    func testLaunchRequestRoundTripsWithoutPuttingShellOutputOnControlChannel() throws {
        let request = RunnerLaunchRequest(
            runID: UUID(),
            zshPath: "/bin/zsh",
            command: "printf 'hello\\n'",
            workingDirectory: "/private/tmp",
            environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
            sigintGraceSeconds: 8,
            sigtermGraceSeconds: 3
        )

        let line = try RunnerCodec.encodeLine(request)

        XCTAssertEqual(try RunnerCodec.decodeLine(line, as: RunnerLaunchRequest.self), request)
    }

    func testCommandRoundTrips() throws {
        let command = RunnerCommand.stop(runID: UUID())

        XCTAssertEqual(
            try RunnerCodec.decodeLine(try RunnerCodec.encodeLine(command), as: RunnerCommand.self),
            command
        )
    }
}
