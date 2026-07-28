import AppKit

typealias MainWindowOpenAction = @MainActor () -> Void

@MainActor
final class MainWindowCoordinator {
    private let activateApplication: @MainActor () -> Void
    private let setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Bool
    private var openAction: MainWindowOpenAction?

    init(
        activateApplication: @escaping @MainActor () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        },
        setActivationPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Bool = {
            NSApp.setActivationPolicy($0)
        }
    ) {
        self.activateApplication = activateApplication
        self.setActivationPolicy = setActivationPolicy
    }

    func register(openAction: @escaping MainWindowOpenAction) {
        self.openAction = openAction
    }

    @discardableResult
    func openMainWindow() -> Bool {
        guard let openAction else { return false }
        _ = setActivationPolicy(.regular)
        activateApplication()
        openAction()
        return true
    }

    func hideDockIconIfNoVisibleWindows(_ hasVisibleWindows: Bool) {
        guard !hasVisibleWindows else { return }
        _ = setActivationPolicy(.accessory)
    }
}
