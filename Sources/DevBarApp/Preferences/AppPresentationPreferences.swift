import Foundation
import Observation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "跟随系统"
        case .light: "白天"
        case .dark: "黑夜"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

@MainActor
@Observable
final class AppPresentationPreferences {
    static let showsMenuBarIconKey = "showsMenuBarIcon"
    static let hidesDockIconWhenNoWindowsKey = "hidesDockIconWhenNoWindows"
    static let appearanceKey = "appearance"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let menuBarIconKey: String
    @ObservationIgnored private let hidesDockIconWhenNoWindowsKey: String
    @ObservationIgnored private let appearanceKey: String

    var showsMenuBarIcon: Bool {
        didSet {
            defaults.set(showsMenuBarIcon, forKey: menuBarIconKey)
            if !showsMenuBarIcon {
                hidesDockIconWhenNoWindows = false
            }
        }
    }

    var hidesDockIconWhenNoWindows: Bool {
        didSet {
            defaults.set(hidesDockIconWhenNoWindows, forKey: hidesDockIconWhenNoWindowsKey)
        }
    }

    var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: appearanceKey)
        }
    }

    init(
        defaults: UserDefaults,
        showsMenuBarIconKey: String = AppPresentationPreferences.showsMenuBarIconKey,
        hidesDockIconWhenNoWindowsKey: String = AppPresentationPreferences.hidesDockIconWhenNoWindowsKey,
        appearanceKey: String = AppPresentationPreferences.appearanceKey
    ) {
        self.defaults = defaults
        menuBarIconKey = showsMenuBarIconKey
        self.hidesDockIconWhenNoWindowsKey = hidesDockIconWhenNoWindowsKey
        self.appearanceKey = appearanceKey
        let storedShowsMenuBarIcon = defaults.object(forKey: showsMenuBarIconKey) == nil
            ? true
            : defaults.bool(forKey: showsMenuBarIconKey)
        showsMenuBarIcon = storedShowsMenuBarIcon
        hidesDockIconWhenNoWindows = storedShowsMenuBarIcon
            && defaults.bool(forKey: hidesDockIconWhenNoWindowsKey)
        appearance = defaults.string(forKey: appearanceKey)
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
    }
}
