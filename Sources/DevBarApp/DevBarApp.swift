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
    @State private var selectedLogServiceID: UUID?
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
        applicationDelegate.configure(
            appState: dependencies.appState,
            presentationPreferences: presentationPreferences
        )
    }

    var body: some Scene {
        Window("DevBar", id: "main") {
            SettingsSceneContent(
                dependencies: dependencies,
                presentationPreferences: presentationPreferences
            )
        }
        .defaultSize(width: 980, height: 680)
        .windowStyle(.hiddenTitleBar)
        .commands {
            MainWindowCommands(coordinator: mainWindowCoordinator)
        }

        MenuBarExtra(isInserted: menuBarIconBinding) {
            ProductionMenuContent(
                dependencies: dependencies,
                presentationPreferences: presentationPreferences,
                mainWindowCoordinator: mainWindowCoordinator,
                selectedLogServiceID: $selectedLogServiceID
            )
        } label: {
            ProductionStatusItem(
                appState: dependencies.appState,
                mainWindowCoordinator: mainWindowCoordinator
            )
        }
        .menuBarExtraStyle(.window)

        Window("服务日志", id: "logs") {
            LogSceneContent(
                dependencies: dependencies,
                presentationPreferences: presentationPreferences,
                selectedServiceID: selectedLogServiceID
            )
        }
        .defaultSize(width: 900, height: 600)
    }

    private var menuBarIconBinding: Binding<Bool> {
        Binding(
            get: { presentationPreferences.showsMenuBarIcon },
            set: { presentationPreferences.showsMenuBarIcon = $0 }
        )
    }
}

@MainActor
private struct ProductionMenuContent: View {
    let dependencies: AppDependencies
    let presentationPreferences: AppPresentationPreferences
    let mainWindowCoordinator: MainWindowCoordinator
    @Binding var selectedLogServiceID: UUID?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarPanel(
            appState: dependencies.appState,
            openSettings: {
                mainWindowCoordinator.openMainWindow()
            },
            openLogs: { serviceID in
                selectedLogServiceID = serviceID
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "logs")
            }
        )
        .devBarAppearance(presentationPreferences.appearance)
    }
}

@MainActor
private struct ProductionStatusItem: View {
    @Bindable var appState: AppState
    let mainWindowCoordinator: MainWindowCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: statusItemSymbol(for: appState.aggregateStatus))
            .accessibilityLabel("DevBar")
            .task {
                mainWindowCoordinator.register {
                    openWindow(id: "main")
                }
            }
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

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                coordinator.openMainWindow()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

@MainActor
private struct SettingsSceneContent: View {
    let dependencies: AppDependencies
    let presentationPreferences: AppPresentationPreferences
    @State private var viewModel: SettingsViewModel?

    var body: some View {
        Group {
            if let viewModel {
                SettingsRootView(
                    viewModel: viewModel,
                    presentationPreferences: presentationPreferences
                )
            } else {
                ProgressView("正在加载配置…")
                    .frame(width: 980, height: 680)
                    .background(DevBarTheme.background)
            }
        }
        .devBarAppearance(presentationPreferences.appearance)
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

@MainActor
private struct LogSceneContent: View {
    let dependencies: AppDependencies
    let presentationPreferences: AppPresentationPreferences
    let selectedServiceID: UUID?
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
        .task {
            while !dependencies.appState.isConfigurationReady {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            if viewModel == nil {
                viewModel = dependencies.makeLogViewModel(selectedServiceID: selectedServiceID)
            }
        }
        .onAppear {
            guard dependencies.appState.isConfigurationReady else { return }
            viewModel = dependencies.makeLogViewModel(selectedServiceID: selectedServiceID)
        }
        .onChange(of: selectedServiceID) { _, serviceID in
            guard dependencies.appState.isConfigurationReady else { return }
            viewModel = dependencies.makeLogViewModel(selectedServiceID: serviceID)
        }
    }
}

@MainActor
private struct UITestDevBarApp: App {
    private let dependencies: AppDependencies
    private let presentationPreferences: AppPresentationPreferences

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
        } catch {
            fatalError("Could not load DEVBAR_TEST_CONFIG: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup("DevBar") {
            UITestHost(
                dependencies: dependencies,
                presentationPreferences: presentationPreferences
            )
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
private struct UITestHost: View {
    let dependencies: AppDependencies
    let presentationPreferences: AppPresentationPreferences
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var selectedLogServiceID: UUID?
    @State private var didHandleFirstLaunch = false

    var body: some View {
        MenuBarPanel(
            appState: dependencies.appState,
            openSettings: { openSettings() },
            openLogs: { serviceID in
                selectedLogServiceID = serviceID
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
                presentationPreferences: presentationPreferences
            )
        }
        .sheet(isPresented: $showLogs) {
            LogSceneContent(
                dependencies: dependencies,
                presentationPreferences: presentationPreferences,
                selectedServiceID: selectedLogServiceID
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
