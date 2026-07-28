import Foundation
import XCTest
@testable import DevBarCore

final class RunnerClientIntegrationTests: XCTestCase {
    func testLaunchMapsFourPipesAndStopClosesTheServiceLifecycle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("runner.zsh")
        try """
        #!/bin/zsh
        IFS= read -r launch <&3
        runid="$(print -r -- "$launch" | /usr/bin/sed -E 's/.*"runID":"([^"]+)".*/\\1/')"
        print -r -- "service stdout" >&5
        print -r -- "service stderr" >&6
        print -r -- '{"kind":"started","pid":1,"pgid":1,"runID":"'"$runid"'"}' >&4
        IFS= read -r stop <&3
        print -r -- '{"code":0,"kind":"exited","runID":"'"$runid"'"}' >&4
        """.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)

        let client = RunnerClient(helperURL: helper)
        let runID = UUID()
        let stream = try await client.launch(.init(
            runID: runID, zshPath: "/bin/zsh", command: "echo ignored", workingDirectory: directory.path,
            environment: [:], sigintGraceSeconds: 1, sigtermGraceSeconds: 1
        ))
        let collector = EventCollector()
        let consumer = Task {
            for await event in stream { await collector.append(event) }
        }

        try await client.stop(runID: runID)
        await consumer.value
        let events = await collector.events

        XCTAssertTrue(
            events.contains(.stdout(runID: runID, data: Data("service stdout\n".utf8))),
            "events: \(events)"
        )
        XCTAssertTrue(
            events.contains(.stderr(runID: runID, data: Data("service stderr\n".utf8))),
            "events: \(events)"
        )
        XCTAssertTrue(
            events.contains(.runner(.started(runID: runID, pid: 1, pgid: 1))),
            "events: \(events)"
        )
        XCTAssertTrue(
            events.contains(.runner(.exited(runID: runID, code: 0, signal: nil))),
            "events: \(events)"
        )
    }

    func testMissingEmbeddedHelperFailsBeforeCreatingRunner() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let client = RunnerClient(helperURL: missing)
        let request = RunnerLaunchRequest(
            runID: UUID(), zshPath: "/bin/zsh", command: "echo ignored", workingDirectory: "/tmp",
            environment: [:], sigintGraceSeconds: 1, sigtermGraceSeconds: 1
        )

        do {
            _ = try await client.launch(request)
            XCTFail("Expected missing helper error")
        } catch let error as RunnerClientError {
            XCTAssertEqual(error, .helperMissing(missing.path))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHelperLocationIsInsideTheMainBundleHelpersDirectory() {
        let helper = RunnerClient.embeddedHelperURL()
        XCTAssertEqual(helper.lastPathComponent, "DevBarRunner")
        XCTAssertEqual(helper.deletingLastPathComponent().lastPathComponent, "Helpers")
        XCTAssertEqual(helper.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Contents")
    }
}

private actor EventCollector {
    private var storedEvents: [ServiceRuntimeEvent] = []

    var events: [ServiceRuntimeEvent] { storedEvents }

    func append(_ event: ServiceRuntimeEvent) {
        storedEvents.append(event)
    }
}
