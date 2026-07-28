import XCTest
@testable import DevBarCore

final class LogSanitizerTests: XCTestCase {
    func testStripsSplitCSIAndOSCSequences() {
        var sanitizer = LogSanitizer()

        XCTAssertEqual(sanitizer.append("before \u{001B}[31"), "before ")
        XCTAssertEqual(sanitizer.append("mred\u{001B}[0m \u{001B}]0;DevBar"), "red ")
        XCTAssertEqual(sanitizer.append("\u{0007}after"), "after")
    }

    func testNormalizesCarriageReturnsAndKeepsTabsAndNewlines() {
        var sanitizer = LogSanitizer()

        XCTAssertEqual(sanitizer.append("one\r\ntwo\rthree\tok\u{0007}"), "one\ntwo\nthree\tok")
    }

    func testDoesNotGuessWhetherCommandOutputIsSensitive() {
        var sanitizer = LogSanitizer()

        XCTAssertEqual(sanitizer.append("TOKEN=secret API_KEY=visible"), "TOKEN=secret API_KEY=visible")
    }
}
