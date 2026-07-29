import XCTest
@testable import DevBar

@MainActor
final class AppUpdateControllerTests: XCTestCase {
    func testInitialStateComesFromBackend() {
        let backend = UpdateBackendSpy(automaticallyChecksForUpdates: true)

        let controller = AppUpdateController(backend: backend)

        XCTAssertTrue(controller.automaticallyChecksForUpdates)
    }

    func testChangingAutomaticChecksUpdatesBackend() {
        let backend = UpdateBackendSpy(automaticallyChecksForUpdates: false)
        let controller = AppUpdateController(backend: backend)

        controller.automaticallyChecksForUpdates = true

        XCTAssertTrue(backend.automaticallyChecksForUpdates)
    }

    func testManualCheckDelegatesToBackend() {
        let backend = UpdateBackendSpy(automaticallyChecksForUpdates: false)
        let controller = AppUpdateController(backend: backend)

        controller.checkForUpdates()

        XCTAssertEqual(backend.checkCount, 1)
    }
}

@MainActor
private final class UpdateBackendSpy: AppUpdateBackend {
    var automaticallyChecksForUpdates: Bool
    var checkCount = 0

    init(automaticallyChecksForUpdates: Bool) {
        self.automaticallyChecksForUpdates = automaticallyChecksForUpdates
    }

    func checkForUpdates() {
        checkCount += 1
    }
}
