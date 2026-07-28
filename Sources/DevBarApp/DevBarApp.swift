import AppKit
import DevBarCore
import SwiftUI

@main
enum DevBarLauncher {
    static func main() {
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            UITestDevBarApp.main()
        } else {
            ProductionDevBarApp.main()
        }
    }
}

@MainActor
private struct ProductionDevBarApp: App {
    @NSApplicationDelegateAdaptor(DevBarApplicationDelegate.self) private var applicationDelegate
    private let dependencies: AppDependencies

    init() {
        let dependencies = AppDependencies.live()
        self.dependencies = dependencies
        applicationDelegate.configure(appState: dependencies.appState)
    }

    var body: some Scene {
        MenuBarExtra {
            ProductionMenuContent(dependencies: dependencies)
        } label: {
            ProductionStatusItem(appState: dependencies.appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsSceneContent(dependencies: dependencies)
        }

        Window("服务日志", id: "logs") {
            LogSceneContent(dependencies: dependencies)
        }
        .defaultSize(width: 900, height: 600)
    }
}

@MainActor
private struct ProductionMenuContent: View {
    let dependencies: AppDependencies
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarPanel(
            appState: dependencies.appState,
            openSettings: {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            },
            openLogs: {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "logs")
            },
            quit: { NSApp.terminate(nil) }
        )
    }
}

@MainActor
private struct ProductionStatusItem: View {
    @Bindable var appState: AppState
    @Environment(\.openSettings) private var openSettings
    @State private var didHandleFirstLaunch = false

    var body: some View {
        Image(systemName: statusSymbol)
            .accessibilityLabel("DevBar")
            .task {
                while !appState.isConfigurationReady {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(for: .milliseconds(30))
                }
                guard appState.isFirstLaunch, !didHandleFirstLaunch else { return }
                didHandleFirstLaunch = true
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
    }

    private var statusSymbol: String {
        switch appState.aggregateStatus {
        case .neutral: "terminal"
        case .working: "terminal.fill"
        case .ready: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }
}

@MainActor
private struct SettingsSceneContent: View {
    let dependencies: AppDependencies
    @State private var viewModel: SettingsViewModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let viewModel {
                SettingsRootView(viewModel: viewModel, close: { dismiss() })
            } else {
                ProgressView("正在加载配置…")
                    .frame(width: 980, height: 680)
                    .background(DevBarTheme.background)
            }
        }
        .task { await prepareViewModel() }
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
        .task {
            while !dependencies.appState.isConfigurationReady {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            if viewModel == nil {
                viewModel = dependencies.makeLogViewModel()
            }
        }
        .onAppear {
            guard dependencies.appState.isConfigurationReady else { return }
            viewModel = dependencies.makeLogViewModel()
        }
    }
}

@MainActor
private struct UITestDevBarApp: App {
    private let dependencies: AppDependencies

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
        } catch {
            fatalError("Could not load DEVBAR_TEST_CONFIG: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup("DevBar") {
            UITestHost(dependencies: dependencies)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
private struct UITestHost: View {
    let dependencies: AppDependencies
    @State private var showSettings = false
    @State private var showLogs = false
    @State private var didHandleFirstLaunch = false

    var body: some View {
        MenuBarPanel(
            appState: dependencies.appState,
            openSettings: { openSettings() },
            openLogs: {
                showLogs = true
            },
            quit: {}
        )
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
            SettingsSceneContent(dependencies: dependencies)
        }
        .sheet(isPresented: $showLogs) {
            LogSceneContent(dependencies: dependencies)
        }
    }

    private func openSettings() {
        showSettings = true
    }
}
