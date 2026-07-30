import AppKit
import DevBarCore
import SwiftUI

@main
enum DevBarLauncher {
    static func main() {
        let processInfo = ProcessInfo.processInfo
        let hasUITestEnvironment = processInfo.environment["DEVBAR_TEST_ROOT"] != nil
            && processInfo.environment["DEVBAR_TEST_CONFIG"] != nil
        if processInfo.arguments.contains("--ui-testing") || hasUITestEnvironment {
            UITestDevBarApp.main()
        } else {
            ProductionDevBarApp.main()
        }
    }
}

@MainActor
private struct ProductionDevBarApp: App {
    @NSApplicationDelegateAdaptor(DevBarApplicationDelegate.self) private var applicationDelegate
    @State private var presentationPreferences: AppPresentationPreferences
    @State private var updateController: AppUpdateController
    @State private var statusItemController: StatusItemController?
    private let dependencies: AppDependencies
    private var mainWindowCoordinator: MainWindowCoordinator {
        applicationDelegate.mainWindowCoordinator
    }

    init() {
        let dependencies = AppDependencies.live()
        let presentationPreferences = AppPresentationPreferences(defaults: .standard)
        self.dependencies = dependencies
        _presentationPreferences = State(
            initialValue: presentationPreferences
        )
        _updateController = State(initialValue: AppUpdateController())
        applicationDelegate.configure(
            appState: dependencies.appState,
            presentationPreferences: presentationPreferences
        )
    }

    var body: some Scene {
        Window("DevBar", id: "main") {
            SettingsSceneContent(
                dependencies: dependencies,
                presentationPreferences: presentationPreferences,
                updateController: updateController,
                mainWindowCoordinator: mainWindowCoordinator,
                installStatusItem: installStatusItemIfNeeded
            )
        }
        .defaultSize(width: 980, height: 680)
        .windowStyle(.hiddenTitleBar)
        .commands {
            MainWindowCommands(
                coordinator: mainWindowCoordinator,
                updateController: updateController
            )
        }

        Window("服务日志", id: "logs") {
            LogSceneContent(
                dependencies: dependencies,
                presentationPreferences: presentationPreferences
            )
        }
        .defaultSize(width: 900, height: 600)
    }

    private func installStatusItemIfNeeded() {
        guard statusItemController == nil else { return }
        let dependencies = dependencies
        let presentationPreferences = presentationPreferences
        let mainWindowCoordinator = mainWindowCoordinator
        statusItemController = StatusItemController(
            appState: dependencies.appState,
            presentationPreferences: presentationPreferences,
            mainWindowCoordinator: mainWindowCoordinator,
            menuContent: {
                AnyView(
                    ProductionMenuContent(
                        dependencies: dependencies,
                        presentationPreferences: presentationPreferences,
                        mainWindowCoordinator: mainWindowCoordinator
                    )
                )
            }
        )
    }
}

@MainActor
private struct ProductionMenuContent: View {
    let dependencies: AppDependencies
    let presentationPreferences: AppPresentationPreferences
    let mainWindowCoordinator: MainWindowCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarPanel(
            appState: dependencies.appState,
            openSettings: {
                mainWindowCoordinator.openMainWindow()
            },
            openLogs: { serviceID in
                dependencies.logWindowSelection.serviceID = serviceID
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "logs")
            }
        )
        .devBarAppearance(presentationPreferences.appearance)
    }
}

@MainActor
private final class StatusItemController: NSObject {
    private let appState: AppState
    private let presentationPreferences: AppPresentationPreferences
    private let mainWindowCoordinator: MainWindowCoordinator
    private let menuContent: () -> AnyView
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()

    init(
        appState: AppState,
        presentationPreferences: AppPresentationPreferences,
        mainWindowCoordinator: MainWindowCoordinator,
        menuContent: @escaping () -> AnyView
    ) {
        self.appState = appState
        self.presentationPreferences = presentationPreferences
        self.mainWindowCoordinator = mainWindowCoordinator
        self.menuContent = menuContent
        super.init()
        configureStatusItem()
        observePresentation()
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleStatusItemClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.toolTip = "DevBar"
        popover.behavior = .transient
    }

    private func observePresentation() {
        withObservationTracking {
            statusItem.isVisible = presentationPreferences.showsMenuBarIcon
            setStatusImage(for: appState.aggregateStatus)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.observePresentation()
            }
        }
    }

    private func setStatusImage(for status: AppAggregateStatus) {
        statusItem.button?.image = NSImage(
            systemSymbolName: statusItemSymbol(for: status),
            accessibilityDescription: "DevBar"
        )
    }

    @objc private func handleStatusItemClick() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            contextMenu.popUp(positioning: nil, at: event.locationInWindow, in: statusItem.button)
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        popover.contentViewController = NSHostingController(rootView: menuContent())
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private lazy var contextMenu: NSMenu = {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "显示主页",
            action: #selector(showMainWindow),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "")
        menu.items.forEach { $0.target = self }
        return menu
    }()

    @objc private func showMainWindow() {
        mainWindowCoordinator.openMainWindow()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

func statusItemSymbol(for status: AppAggregateStatus) -> String {
    switch status {
    case .neutral: "hammer"
    case .working: "hammer.fill"
    case .ready: "checkmark.circle.fill"
    case .error: "exclamationmark.triangle.fill"
    }
}

@MainActor
private struct MainWindowCommands: Commands {
    let coordinator: MainWindowCoordinator
    let updateController: AppUpdateController

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                coordinator.openMainWindow()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .appInfo) {
            Button("检查更新…") {
                updateController.checkForUpdates()
            }
        }
    }
}

@MainActor
private struct SettingsSceneContent: View {
    let dependencies: AppDependencies
    let presentationPreferences: AppPresentationPreferences
    let updateController: AppUpdateController
    let mainWindowCoordinator: MainWindowCoordinator?
    let installStatusItem: (() -> Void)?
    @State private var viewModel: SettingsViewModel?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let viewModel {
                SettingsRootView(
                    viewModel: viewModel,
                    presentationPreferences: presentationPreferences,
                    updateController: updateController
                )
            } else {
                ProgressView("正在加载配置…")
                    .frame(width: 980, height: 680)
                    .background(DevBarTheme.background)
            }
        }
        .background(MainWindowChromeConfigurator())
        .devBarAppearance(presentationPreferences.appearance)
        .task { installStatusItem?() }
        .task {
            guard let mainWindowCoordinator else { return }
            mainWindowCoordinator.register {
                openWindow(id: "main")
            }
        }
        .task { await prepareViewModel() }
        .onChange(of: dependencies.appState.config) { _, configuration in
            viewModel?.synchronize(with: configuration)
        }
        .onAppear {
            guard dependencies.appState.isConfigurationReady else { return }
            viewModel = dependencies.makeSettingsViewModel()
        }
    }

    private func prepareViewModel() async {
        while !dependencies.appState.isConfigurationReady {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        if viewModel == nil {
            viewModel = dependencies.makeSettingsViewModel()
        }
    }
}

/// Configures the AppKit-owned titlebar after SwiftUI has attached the main
/// content view to its real window. The root view's safe-area background can
/// then paint behind the traffic lights instead of leaving AppKit's gray
/// titlebar material visible.
private struct MainWindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowAttachmentView {
        WindowAttachmentView()
    }

    func updateNSView(_ nsView: WindowAttachmentView, context: Context) {
        nsView.configureWindow()
    }

    final class WindowAttachmentView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard let window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}

@MainActor
private struct LogSceneContent: View {
    let dependencies: AppDependencies
    let presentationPreferences: AppPresentationPreferences
    @State private var viewModel: LogViewModel?

    var body: some View {
        Group {
            if let viewModel {
                LogWindowView(viewModel: viewModel)
            } else {
                ProgressView("正在加载服务…")
                    .frame(minWidth: 720, minHeight: 440)
                    .background(DevBarTheme.background)
            }
        }
        .devBarAppearance(presentationPreferences.appearance)
        .onChange(of: dependencies.logWindowSelection.serviceID) { _, serviceID in
            guard dependencies.appState.isConfigurationReady else { return }
            viewModel = dependencies.makeLogViewModel(selectedServiceID: serviceID)
        }
        .task {
            while !dependencies.appState.isConfigurationReady {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            if viewModel == nil {
                viewModel = dependencies.makeLogViewModel(
                    selectedServiceID: dependencies.logWindowSelection.serviceID
                )
            }
        }
        .onAppear {
            guard dependencies.appState.isConfigurationReady else { return }
            viewModel = dependencies.makeLogViewModel(
                selectedServiceID: dependencies.logWindowSelection.serviceID
            )
        }
    }
}

@MainActor
private struct UITestDevBarApp: App {
    private let dependencies: AppDependencies
    private let presentationPreferences: AppPresentationPreferences
    private let updateController: AppUpdateController

    init() {
        let environment = ProcessInfo.processInfo.environment
        guard let rootPath = environment["DEVBAR_TEST_ROOT"],
              rootPath.hasPrefix("/"),
              let configurationPath = environment["DEVBAR_TEST_CONFIG"],
              configurationPath.hasPrefix("/") else {
            fatalError("--ui-testing requires DEVBAR_TEST_ROOT and DEVBAR_TEST_CONFIG.")
        }
        do {
            let configuration = try JSONDecoder().decode(
                AppConfig.self,
                from: Data(contentsOf: URL(fileURLWithPath: configurationPath))
            )
            dependencies = AppDependencies.uiTesting(
                configuration: configuration,
                applicationSupportRoot: URL(fileURLWithPath: rootPath, isDirectory: true)
            )
            let suiteName = "com.calo.DevBar.UITesting.\(ProcessInfo.processInfo.processIdentifier)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            presentationPreferences = AppPresentationPreferences(defaults: defaults)
            updateController = AppUpdateController(backend: DisabledUpdateBackend())
        } catch {
            fatalError("Could not load DEVBAR_TEST_CONFIG: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup("DevBar") {
            UITestHost(
                dependencies: dependencies,
                presentationPreferences: presentationPreferences,
                updateController: updateController
            )
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
private struct UITestHost: View {
    let dependencies: AppDependencies
    let presentationPreferences: AppPresentationPreferences
    let updateController: AppUpdateController
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var didHandleFirstLaunch = false

    var body: some View {
        MenuBarPanel(
            appState: dependencies.appState,
            openSettings: { openSettings() },
            openLogs: { serviceID in
                dependencies.logWindowSelection.serviceID = serviceID
                showLogs = true
            }
        )
        .devBarAppearance(presentationPreferences.appearance)
        .task {
            while !dependencies.appState.isConfigurationReady {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard dependencies.appState.isFirstLaunch, !didHandleFirstLaunch else { return }
            didHandleFirstLaunch = true
            openSettings()
        }
        .sheet(isPresented: $showSettings) {
            SettingsSceneContent(
                dependencies: dependencies,
                presentationPreferences: presentationPreferences,
                updateController: updateController,
                mainWindowCoordinator: nil,
                installStatusItem: nil
            )
        }
        .sheet(isPresented: $showLogs) {
            LogSceneContent(
                dependencies: dependencies,
                presentationPreferences: presentationPreferences
            )
        }
    }

    private func openSettings() {
        showSettings = true
    }
}

private extension View {
    func devBarAppearance(_ appearance: AppAppearance) -> some View {
        preferredColorScheme(appearance.preferredColorScheme)
    }
}
