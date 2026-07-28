import DevBarCore
import AppKit
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
    @State private var appState: AppState

    init() {
        let dependencies = AppDependencies.live()
        _appState = State(initialValue: dependencies.appState)
    }

    var body: some Scene {
        MenuBarExtra {
            ProductionMenuContent(appState: appState)
        } label: {
            ProductionStatusItem(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsPlaceholderView(appState: appState)
        }
    }
}

@MainActor
private struct ProductionMenuContent: View {
    @Bindable var appState: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        MenuBarPanel(
            appState: appState,
            openSettings: {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
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
private struct UITestDevBarApp: App {
    @State private var appState: AppState

    init() {
        // These values are read only after the explicit --ui-testing argument has
        // selected this process entry point. Production never observes them.
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
            let dependencies = AppDependencies.uiTesting(
                configuration: configuration,
                applicationSupportRoot: URL(fileURLWithPath: rootPath, isDirectory: true)
            )
            _appState = State(initialValue: dependencies.appState)
        } catch {
            fatalError("Could not load DEVBAR_TEST_CONFIG: \(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup("DevBar") {
            UITestHost(appState: appState)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
private struct UITestHost: View {
    @Bindable var appState: AppState
    @State private var showSettings = false
    @State private var didHandleFirstLaunch = false

    var body: some View {
        MenuBarPanel(
            appState: appState,
            openSettings: { showSettings = true },
            quit: {}
        )
        .task {
            while !appState.isConfigurationReady {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard appState.isFirstLaunch, !didHandleFirstLaunch else { return }
            didHandleFirstLaunch = true
            showSettings = true
        }
        .sheet(isPresented: $showSettings) {
            SettingsPlaceholderView(appState: appState)
        }
    }
}

@MainActor
private struct SettingsPlaceholderView: View {
    @Bindable var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            DevBarIcon(size: 64)
            Text("设置 DevBar")
                .font(.system(size: 24, weight: .bold))
            Text("添加工作区、服务目录与启动命令。")
                .foregroundStyle(DevBarTheme.textSecondary)
            Button("开始配置") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("settings.begin")
        }
        .frame(width: 520, height: 340)
        .background(DevBarTheme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.placeholder")
    }
}
