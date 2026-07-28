import Foundation
import XCTest
@testable import DevBarCore

final class LogStoreTests: XCTestCase {
    private var root: URL!
    private var paths: AppPaths!
    private let workspaceID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    private let serviceID = UUID(uuidString: "00000000-0000-0000-0000-000000000022")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DevBar-LogStore-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(applicationSupport: root.appendingPathComponent("Application Support/DevBar", isDirectory: true))
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testSanitizesTerminalControlsOnDiskAndInMemoryWithoutGuessingSecrets() async throws {
        let store = LogStore(paths: paths, maximumFileSizeBytes: 1_024, fileCount: 3)
        try await store.prepare(workspaceID: workspaceID, serviceID: serviceID)

        await store.append(
            LogEntry(stream: .stdout, text: "\u{001B}[31mTOKEN=secret\u{001B}[0m\n"),
            workspaceID: workspaceID,
            serviceID: serviceID
        )

        let displayEntries = await store.entries(serviceID: serviceID)
        XCTAssertEqual(displayEntries.map(\.text), ["TOKEN=secret\n"])
        let disk = try String(decoding: Data(contentsOf: logDirectory().appendingPathComponent("current.log")), as: UTF8.self)
        XCTAssertTrue(disk.contains("TOKEN=secret"))
        XCTAssertFalse(disk.contains("\u{001B}"))
        XCTAssertFalse(disk.contains("[REDACTED]"))
    }

    func testRawPipeBytesDoNotSplitChineseUTF8AcrossEvents() async throws {
        let store = LogStore(paths: paths, maximumFileSizeBytes: 1_024, fileCount: 3)
        try await store.prepare(workspaceID: workspaceID, serviceID: serviceID)

        let runID = UUID()
        await store.append(
            data: Data([0xE4, 0xB8]), stream: .stdout,
            workspaceID: workspaceID, serviceID: serviceID, runID: runID
        )
        await store.append(
            data: Data([0xAD]), stream: .stdout,
            workspaceID: workspaceID, serviceID: serviceID, runID: runID
        )

        let entries = await store.entries(serviceID: serviceID)
        XCTAssertEqual(entries.map(\.text), ["中"])
    }

    func testLoadRecentCapsMemoryAndWarnsOnceForMalformedHeaders() async throws {
        let writer = try RotatingLogWriter(directory: logDirectory(), maximumFileSizeBytes: 1_024 * 1_024, fileCount: 3)
        for index in 0 ..< 8 {
            try writer.append(LogEntry(timestamp: Date(timeIntervalSince1970: Double(index)), stream: .stdout, text: "line-\(index)"))
        }
        try Data("bad header\n".utf8).appendToFile(logDirectory().appendingPathComponent("current.log"))

        let store = LogStore(paths: paths, maximumEntries: 3, maximumFileSizeBytes: 1_024 * 1_024, fileCount: 3)
        let loaded = await store.loadRecent(workspaceID: workspaceID, serviceID: serviceID)

        XCTAssertEqual(loaded.map(\.text), ["line-5", "line-6", "line-7"])
        let warnings = await store.warnings()
        XCTAssertEqual(warnings.filter { $0.kind == .malformedRecord }.count, 1)
        XCTAssertTrue(logDirectory().path.hasPrefix(paths.logsRootURL.path))
        XCTAssertTrue(logDirectory().path.contains(workspaceID.uuidString.lowercased()))
        XCTAssertTrue(logDirectory().path.contains(serviceID.uuidString.lowercased()))
    }

    func testClearViewLeavesHistoryAndDeleteHistoryOnlyUsesMappedUUIDDirectory() async throws {
        let store = LogStore(paths: paths, maximumFileSizeBytes: 1_024, fileCount: 3)
        try await store.prepare(workspaceID: workspaceID, serviceID: serviceID)
        await store.append(LogEntry(stream: .stderr, text: "still on disk"), workspaceID: workspaceID, serviceID: serviceID)

        await store.clearView(serviceID: serviceID)
        let clearedEntries = await store.entries(serviceID: serviceID)
        XCTAssertEqual(clearedEntries, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: logDirectory().appendingPathComponent("current.log").path))

        await store.deleteHistory(serviceID: serviceID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logDirectory().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.logsRootURL.appendingPathComponent(workspaceID.uuidString.lowercased()).path))
    }

    func testConfigureWritesNewServiceLogsUnderCustomRoot() async throws {
        let customRoot = root.appendingPathComponent("Custom Logs", isDirectory: true)
        let store = LogStore(paths: paths, maximumFileSizeBytes: 1_024, fileCount: 3)

        try await store.configure(
            logDirectory: customRoot.path,
            logFileSizeMiB: 1,
            fileCount: 3
        )
        try await store.prepare(workspaceID: workspaceID, serviceID: serviceID)
        await store.append(
            LogEntry(stream: .stdout, text: "custom root"),
            workspaceID: workspaceID,
            serviceID: serviceID
        )

        let currentLog = customRoot
            .appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(serviceID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("current.log", isDirectory: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentLog.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logDirectory().path))
    }

    private func logDirectory() -> URL {
        paths.logsRootURL
            .appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(serviceID.uuidString.lowercased(), isDirectory: true)
    }
}

private extension Data {
    func appendToFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
