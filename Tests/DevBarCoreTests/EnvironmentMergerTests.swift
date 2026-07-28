import XCTest
@testable import DevBarCore

final class EnvironmentMergerTests: XCTestCase {
    func testServiceOverridesWorkspaceAndCapturedEnvironment() {
        let merged = EnvironmentMerger.merge(
            captured: ["MODE": "shell", "PATH": "/bin"],
            workspace: [.init(key: "MODE", value: "workspace"), .init(key: "WORKSPACE_ONLY", value: "yes")],
            service: [.init(key: "MODE", value: "service"), .init(key: "SERVICE_ONLY", value: "yes")]
        )

        XCTAssertEqual(merged["MODE"], "service")
        XCTAssertEqual(merged["PATH"], "/bin")
        XCTAssertEqual(merged["WORKSPACE_ONLY"], "yes")
        XCTAssertEqual(merged["SERVICE_ONLY"], "yes")
    }

    func testLaterDuplicateEntryWithinScopeWinsDeterministically() {
        let merged = EnvironmentMerger.merge(
            captured: ["MODE": "shell"],
            workspace: [.init(key: "MODE", value: "first"), .init(key: "MODE", value: "second")],
            service: []
        )

        XCTAssertEqual(merged["MODE"], "second")
    }
}
