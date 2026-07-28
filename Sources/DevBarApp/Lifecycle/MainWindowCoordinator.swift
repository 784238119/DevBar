import AppKit

typealias MainWindowOpenAction = @MainActor () -> Void

@MainActor
final class MainWindowCoordinator {
    private let activateApplication: @MainActor () -> Void
    private var openAction: MainWindowOpenAction?

    init(
        activateApplication: @escaping @MainActor () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.activateApplication = activateApplication
    }

    func register(openAction: @escaping MainWindowOpenAction) {
        self.openAction = openAction
    }

    @discardableResult
    func openMainWindow() -> Bool {
        guard let openAction else { return false }
        activateApplication()
        openAction()
        return true
    }
}
