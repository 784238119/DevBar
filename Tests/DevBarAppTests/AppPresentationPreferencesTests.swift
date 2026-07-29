import Foundation
import XCTest
@testable import DevBar

@MainActor
final class AppPresentationPreferencesTests: XCTestCase {
    nonisolated(unsafe) private var suiteName: String!
    nonisolated(unsafe) private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppPresentationPreferencesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMenuBarIconDefaultsToVisible() {
        let preferences = AppPresentationPreferences(defaults: defaults)

        XCTAssertTrue(preferences.showsMenuBarIcon)
    }

    func testMenuBarIconVisibilityPersistsImmediately() {
        let preferences = AppPresentationPreferences(defaults: defaults)

        preferences.showsMenuBarIcon = false

        XCTAssertFalse(AppPresentationPreferences(defaults: defaults).showsMenuBarIcon)
    }

    func testHidingDockIconWhenNoWindowsDefaultsToDisabled() {
        XCTAssertFalse(
            AppPresentationPreferences(defaults: defaults).hidesDockIconWhenNoWindows
        )
    }

    func testHidingDockIconWhenNoWindowsPersistsImmediately() {
        let preferences = AppPresentationPreferences(defaults: defaults)

        preferences.hidesDockIconWhenNoWindows = true

        XCTAssertTrue(
            AppPresentationPreferences(defaults: defaults).hidesDockIconWhenNoWindows
        )
    }

    func testRemovingMenuBarIconAlsoDisablesDockHiding() {
        let preferences = AppPresentationPreferences(defaults: defaults)
        preferences.hidesDockIconWhenNoWindows = true

        preferences.showsMenuBarIcon = false

        XCTAssertFalse(preferences.hidesDockIconWhenNoWindows)
        XCTAssertFalse(
            AppPresentationPreferences(defaults: defaults).hidesDockIconWhenNoWindows
        )
    }

    func testStoredDockHidingIsIgnoredWithoutMenuBarEntry() {
        defaults.set(true, forKey: AppPresentationPreferences.hidesDockIconWhenNoWindowsKey)
        defaults.set(false, forKey: AppPresentationPreferences.showsMenuBarIconKey)

        XCTAssertFalse(
            AppPresentationPreferences(defaults: defaults).hidesDockIconWhenNoWindows
        )
    }

    func testAppearanceDefaultsToSystem() {
        XCTAssertEqual(AppPresentationPreferences(defaults: defaults).appearance, .system)
    }

    func testAppearancePersistsImmediately() {
        let preferences = AppPresentationPreferences(defaults: defaults)

        preferences.appearance = .dark

        XCTAssertEqual(AppPresentationPreferences(defaults: defaults).appearance, .dark)
    }

    func testAppearanceCanReturnToSystemAfterAnOverride() {
        let preferences = AppPresentationPreferences(defaults: defaults)
        preferences.appearance = .dark

        preferences.appearance = .system

        XCTAssertNil(preferences.appearance.preferredColorScheme)
        XCTAssertEqual(AppPresentationPreferences(defaults: defaults).appearance, .system)
    }

    func testExplicitAppearancesMapToSwiftUIColorSchemes() {
        XCTAssertEqual(AppAppearance.light.preferredColorScheme, .light)
        XCTAssertEqual(AppAppearance.dark.preferredColorScheme, .dark)
    }

    func testInvalidStoredAppearanceFallsBackToSystem() {
        defaults.set("unknown", forKey: AppPresentationPreferences.appearanceKey)

        XCTAssertEqual(AppPresentationPreferences(defaults: defaults).appearance, .system)
    }
}
