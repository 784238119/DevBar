import AppKit
import DevBarCore

@MainActor
final class DevBarApplicationDelegate: NSObject, NSApplicationDelegate {
    let mainWindowCoordinator: MainWindowCoordinator
    private weak var appState: AppState?
    private var presentationPreferences: AppPresentationPreferences?
    private var terminationTask: Task<Void, Never>?
    private var hasApprovedTermination = false

    override init() {
        mainWindowCoordinator = MainWindowCoordinator()
        super.init()
    }

    init(mainWindowCoordinator: MainWindowCoordinator) {
        self.mainWindowCoordinator = mainWindowCoordinator
        super.init()
    }

    func configure(
        appState: AppState,
        presentationPreferences: AppPresentationPreferences
    ) {
        self.appState = appState
        self.presentationPreferences = presentationPreferences
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        mainWindowCoordinator.openMainWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if hasApprovedTermination { return .terminateNow }
        guard terminationTask == nil else { return .terminateLater }
        guard let appState else { return .terminateNow }

        let coordinator = QuitCoordinator(state: appState)
        terminationTask = Task { [weak self, weak sender] in
            guard let self, let sender else { return }
            switch await coordinator.requestQuit() {
            case .terminateNow:
                approveTermination(sender)
            case let .confirmationRequired(runtimes):
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "仍有 \(runtimes.count) 个服务正在运行"
                alert.informativeText = "DevBar 会先按 SIGINT → SIGTERM → SIGKILL 的策略停止服务，完成子进程回收后再退出。"
                alert.addButton(withTitle: "停止服务并退出")
                alert.addButton(withTitle: "取消")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn {
                    if await coordinator.stopAllAndWait() {
                        approveTermination(sender)
                    } else {
                        let failure = NSAlert()
                        failure.alertStyle = .critical
                        failure.messageText = "无法安全停止全部服务"
                        failure.informativeText = "DevBar 已取消退出，避免遗留失控子进程。请检查日志后重试；必要时可使用系统“强制退出”。"
                        failure.runModal()
                        terminationTask = nil
                        sender.reply(toApplicationShouldTerminate: false)
                    }
                } else {
                    terminationTask = nil
                    sender.reply(toApplicationShouldTerminate: false)
                }
            }
        }
        return .terminateLater
    }

    private func approveTermination(_ sender: NSApplication) {
        hasApprovedTermination = true
        terminationTask = nil
        sender.reply(toApplicationShouldTerminate: true)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        guard presentationPreferences?.showsMenuBarIcon == true,
              presentationPreferences?.hidesDockIconWhenNoWindows == true else {
            return
        }
        let closingWindow = notification.object as? NSWindow
        let hasVisibleWindows = NSApp.windows.contains {
            $0 !== closingWindow && $0.isVisible && $0.canBecomeMain
        }
        mainWindowCoordinator.hideDockIconIfNoVisibleWindows(hasVisibleWindows)
    }
}
