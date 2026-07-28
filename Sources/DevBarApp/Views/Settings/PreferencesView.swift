import DevBarCore
import SwiftUI

struct PreferencesView: View {
    @Bindable var viewModel: SettingsViewModel
    let presentationPreferences: AppPresentationPreferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Button {
                            viewModel.leavePreferences()
                        } label: {
                            Label("返回工作区", systemImage: "chevron.left")
                        }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                        .accessibilityIdentifier("preferences.returnToWorkspace")

                        SettingsEventStatus(
                            isSaving: viewModel.isSaving,
                            notice: viewModel.notice
                        )
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        Text("偏好设置")
                            .font(.system(size: 23, weight: .bold))
                        Text("应用外观、Shell、日志轮转和安全停止策略")
                            .font(.system(size: 12))
                            .foregroundStyle(DevBarTheme.textSecondary)
                    }
                }

                SettingsSectionCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("应用外观", systemImage: "macwindow")
                            .font(.system(size: 15, weight: .bold))
                        Toggle("显示菜单栏图标", isOn: menuBarIconBinding)
                            .toggleStyle(.checkbox)
                            .accessibilityIdentifier("preferences.showMenuBarIcon")
                        Toggle("关闭最后一个窗口时隐藏 Dock 图标", isOn: hideDockIconBinding)
                            .toggleStyle(.checkbox)
                            .disabled(!presentationPreferences.showsMenuBarIcon)
                            .accessibilityIdentifier("preferences.hideDockIconWhenNoWindows")
                        HStack {
                            Text("主题")
                            Spacer()
                            Picker("主题", selection: appearanceBinding) {
                                ForEach(AppAppearance.allCases) { appearance in
                                    Text(appearance.title).tag(appearance)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .controlSize(.small)
                            .frame(width: 228)
                            .accessibilityIdentifier("preferences.appearance")
                        }
                        Text(dockVisibilityHelpText)
                            .font(.system(size: 11))
                            .foregroundStyle(DevBarTheme.textSecondary)
                    }
                }

                SettingsSectionCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("zsh 环境", systemImage: "terminal")
                            .font(.system(size: 15, weight: .bold))
                        HStack(spacing: 10) {
                            TextField("/bin/zsh", text: $viewModel.draft.preferences.shellPath)
                                .textFieldStyle(.roundedBorder)
                            Button {
                                Task { await viewModel.refreshShell() }
                            } label: {
                                Label("刷新 Shell 环境", systemImage: "arrow.clockwise")
                            }
                            .accessibilityIdentifier("preferences.refreshShell")
                        }
                        SettingsFieldError(issue: viewModel.issue(at: "preferences.shellPath"))
                        Text("路径改变后必须刷新成功才能保存。只支持可执行的 zsh。")
                            .font(.system(size: 11))
                            .foregroundStyle(DevBarTheme.textSecondary)
                    }
                }

                SettingsSectionCard {
                    VStack(alignment: .leading, spacing: 13) {
                        Label("日志", systemImage: "doc.text")
                            .font(.system(size: 15, weight: .bold))
                        HStack(spacing: 10) {
                            TextField(
                                PreferencesConfig.defaultLogDirectory,
                                text: $viewModel.draft.preferences.logDirectory
                            )
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isLogDirectoryLocked)
                            .accessibilityIdentifier("preferences.logDirectory")
                            Button("选择…") {
                                Task { await viewModel.chooseLogDirectory() }
                            }
                            .disabled(viewModel.isLogDirectoryLocked)
                            .accessibilityIdentifier("preferences.chooseLogDirectory")
                        }
                        .onSubmit {
                            Task { await viewModel.commitPreferences() }
                        }
                        SettingsFieldError(issue: viewModel.issue(at: "preferences.logDirectory"))
                        Text(logDirectoryHelpText)
                            .font(.system(size: 11))
                            .foregroundStyle(DevBarTheme.textSecondary)
                        preferenceStepper(
                            "单文件大小",
                            value: $viewModel.draft.preferences.logFileSizeMiB,
                            range: 1...100,
                            suffix: "MiB"
                        )
                        preferenceStepper(
                            "保留文件数",
                            value: $viewModel.draft.preferences.logFileCount,
                            range: 1...10,
                            suffix: "个"
                        )
                    }
                }

                SettingsSectionCard {
                    VStack(alignment: .leading, spacing: 13) {
                        Label("停止策略", systemImage: "stop.circle")
                            .font(.system(size: 15, weight: .bold))
                        preferenceStepper(
                            "SIGINT 等待",
                            value: $viewModel.draft.preferences.sigintGraceSeconds,
                            range: 1...60,
                            suffix: "秒"
                        )
                        preferenceStepper(
                            "SIGTERM 等待",
                            value: $viewModel.draft.preferences.sigtermGraceSeconds,
                            range: 1...30,
                            suffix: "秒"
                        )
                        Text("超时后 DevBar 会继续使用 SIGKILL，并等待 Runner 完成子进程回收。")
                            .font(.system(size: 11))
                            .foregroundStyle(DevBarTheme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var menuBarIconBinding: Binding<Bool> {
        Binding(
            get: { presentationPreferences.showsMenuBarIcon },
            set: { presentationPreferences.showsMenuBarIcon = $0 }
        )
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { presentationPreferences.appearance },
            set: { presentationPreferences.appearance = $0 }
        )
    }

    private var hideDockIconBinding: Binding<Bool> {
        Binding(
            get: { presentationPreferences.hidesDockIconWhenNoWindows },
            set: { presentationPreferences.hidesDockIconWhenNoWindows = $0 }
        )
    }

    private var dockVisibilityHelpText: String {
        if !presentationPreferences.showsMenuBarIcon {
            return "需要先显示菜单栏图标，确保关闭窗口后仍有入口可以重新打开 DevBar。"
        }
        if presentationPreferences.hidesDockIconWhenNoWindows {
            return "关闭全部窗口后 DevBar 继续在菜单栏运行；从菜单栏打开窗口时会恢复 Dock 图标。"
        }
        return "关闭窗口后仍可通过 Dock、菜单栏或 ⌘, 重新打开偏好设置。"
    }

    private var logDirectoryHelpText: String {
        if viewModel.isLogDirectoryLocked {
            return "仍有服务正在运行；请全部停止后再切换目录。已有日志不会自动迁移。"
        }
        return "默认保存在 /tmp/DevBar/Logs。切换目录不会迁移已有日志。"
    }

    private func preferenceStepper(
        _ label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        suffix: String
    ) -> some View {
        HStack {
            Text(label).font(.system(size: 13, weight: .medium))
            Spacer()
            Text("\(value.wrappedValue) \(suffix)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DevBarTheme.textSecondary)
                .frame(width: 78, alignment: .trailing)
            Stepper("", value: value, in: range)
                .labelsHidden()
                .onChange(of: value.wrappedValue) {
                    Task { await viewModel.commitPreferences() }
                }
        }
    }
}
