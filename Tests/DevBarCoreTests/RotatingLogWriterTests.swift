import Foundation
import XCTest
@testable import DevBarCore

final class RotatingLogWriterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DevBar-Rotation-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func testRetainsCurrentAndTwoArchivesWithoutExceedingThresholdEvenForOversizedEntry() throws {
        let writer = try RotatingLogWriter(directory: root, maximumFileSizeBytes: 64, fileCount: 3)
        let date = Date(timeIntervalSince1970: 1_753_706_096.789)

        for index in 0 ..< 4 {
            try writer.append(LogEntry(timestamp: date, stream: .stdout, text: "row-\(index)-abcdefghijklmnop"))
        }
        try writer.append(LogEntry(timestamp: date, stream: .stderr, text: String(repeating: "界", count: 80)))

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertEqual(names, ["current.log", "current.log.1", "current.log.2"])
        for name in names {
            let size = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)[.size] as? NSNumber
            XCTAssertLessThanOrEqual(size?.intValue ?? .max, 64)
        }
        let joined = try names.map { try String(decoding: Data(contentsOf: root.appendingPathComponent($0)), as: UTF8.self) }.joined()
        XCTAssertTrue(joined.contains("界"))
    }

    func testEscapesEmbeddedSeparatorsAndReadsThemBack() throws {
        let writer = try RotatingLogWriter(directory: root, maximumFileSizeBytes: 1_024, fileCount: 3)
        let entry = LogEntry(timestamp: Date(timeIntervalSince1970: 1_753_706_096.789), stream: .stderr, text: "a\\b\tc\nd")

        try writer.append(entry)

        XCTAssertEqual(try writer.readAllRecords(), [entry])
    }
}
