import XCTest
@testable import DevBarCore

final class ProjectSmokeTests: XCTestCase {
    func testCoreModuleIsWired() {
        XCTAssertEqual(DevBarCoreModule.name, "DevBarCore")
    }
}
