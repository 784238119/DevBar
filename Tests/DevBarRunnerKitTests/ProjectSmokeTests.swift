import XCTest
@testable import DevBarRunnerKit

final class ProjectSmokeTests: XCTestCase {
    func testRunnerKitModuleIsWired() {
        XCTAssertEqual(DevBarRunnerKitModule.name, "DevBarRunnerKit")
    }
}
