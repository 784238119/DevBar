import AppKit
import XCTest
@testable import DevBar

@MainActor
final class MainWindowCoordinatorTests: XCTestCase {
    func testOpenReturnsFalseBeforePresentationActionIsRegistered() {
        var activations = 0
        let coordinator = MainWindowCoordinator { activations += 1 }

        XCTAssertFalse(coordinator.openMainWindow())
        XCTAssertEqual(activations, 0)
    }

    func testOpenActivatesApplicationBeforePresentingMainWindow() {
        var events: [String] = []
        let coordinator = MainWindowCoordinator(
            activateApplication: { events.append("activate") },
            setActivationPolicy: {
                events.append($0 == .regular ? "regular" : "other")
                return true
            }
        )
        coordinator.register { events.append("open") }

        XCTAssertTrue(coordinator.openMainWindow())
        XCTAssertEqual(events, ["regular", "activate", "open"])
    }

    func testReplacingRegistrationUsesOnlyLatestPresentationAction() {
        var events: [String] = []
        let coordinator = MainWindowCoordinator {}
        coordinator.register { events.append("old") }
        coordinator.register { events.append("new") }

        XCTAssertTrue(coordinator.openMainWindow())
        XCTAssertEqual(events, ["new"])
    }

    func testClosingLastVisibleWindowSwitchesToAccessoryMode() {
        var policies: [NSApplication.ActivationPolicy] = []
        let coordinator = MainWindowCoordinator(
            activateApplication: {},
            setActivationPolicy: {
                policies.append($0)
                return true
            }
        )

        coordinator.hideDockIconIfNoVisibleWindows(false)

        XCTAssertEqual(policies, [.accessory])
    }

    func testClosingOneWindowKeepsDockWhileAnotherWindowIsVisible() {
        var policies: [NSApplication.ActivationPolicy] = []
        let coordinator = MainWindowCoordinator(
            activateApplication: {},
            setActivationPolicy: {
                policies.append($0)
                return true
            }
        )

        coordinator.hideDockIconIfNoVisibleWindows(true)

        XCTAssertTrue(policies.isEmpty)
    }

    func testDockReopenRoutesToMainWindowCoordinator() {
        var opens = 0
        let coordinator = MainWindowCoordinator {}
        coordinator.register { opens += 1 }
        let delegate = DevBarApplicationDelegate(mainWindowCoordinator: coordinator)

        XCTAssertTrue(
            delegate.applicationShouldHandleReopen(
                NSApplication.shared,
                hasVisibleWindows: false
            )
        )
        XCTAssertEqual(opens, 1)
    }

    func testClosingLastWindowKeepsMenuBarApplicationRunning() {
        let delegate = DevBarApplicationDelegate()

        XCTAssertFalse(
            delegate.applicationShouldTerminateAfterLastWindowClosed(
                NSApplication.shared
            )
        )
    }

    func testProductionInfoPlistDoesNotHideApplicationFromDock() {
        let bundle = Bundle(for: DevBarApplicationDelegate.self)

        XCTAssertNotEqual(
            bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool,
            true
        )
    }
}
