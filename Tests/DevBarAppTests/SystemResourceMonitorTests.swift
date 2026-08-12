import Darwin
import XCTest
@testable import DevBar

@MainActor
final class SystemResourceMonitorTests: XCTestCase {
    func testReadsResidentMemoryForCurrentProcessGroup() {
        let residentBytes = SystemResourceMonitor.processGroupResidentMemory(getpgrp())

        XCTAssertGreaterThan(residentBytes, 0)
    }

    func testRejectsInvalidProcessGroup() {
        XCTAssertEqual(SystemResourceMonitor.processGroupResidentMemory(0), 0)
    }
}
