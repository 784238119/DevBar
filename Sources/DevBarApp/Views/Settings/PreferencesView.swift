import DevBarCore
import SwiftUI

struct PreferencesView: View {
    @Bindable var viewModel: SettingsViewModel
    let presentationPreferences: AppPresentationPreferences
    @Bindable var updateController: AppUpdateController

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
                        Text("应用外观、版本更新、Shell、日志轮转和安全停止策略")
                            .font(.system(size: 12))
                            .foregroundStyle(DevBarTheme.textSecondary)
                    }
                }

                SettingsSectionCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("版本更新", systemImage: "arrow.triangle.2.circlepath")
                            .font(.system(size: 15, weight: .bold))
                        HStack {
                            Text("当前版本")
                            Spacer()
                            Text(currentVersion)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(DevBarTheme.textSecondary)
                        }
                        Toggle(
                            "自动检查更新",
                            isOn: $updateController.automaticallyChecksForUpdates
                        )
                        .toggleStyle(.checkbox)
                        .accessibilityIdentifier("preferences.automaticallyChecksForUpdates")
                        HStack(spacing: 10) {
                            Button {
                                updateController.checkForUpdates()
                            } label: {
                                Label("立即检查更新", systemImage: "arrow.clockwise")
                            }
                            .accessibilityIdentifier("preferences.checkForUpdates")
                            Link("查看 GitHub Releases", destination: AppUpdateController.releasesURL)
                                .accessibilityIdentifier("preferences.openReleases")
                        }
                        Text("更新清单来自公开 GitHub 仓库。发现新版本后由 Sparkle 验证更新签名，并提示下载安装。")
                            .font(.system(size: 11))
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
                        preferenceStepper(
                            "日志保留天数",
                            value: $viewModel.draft.preferences.logRetentionDays,
                            range: PreferencesConfig.logRetentionDaysRange,
                            suffix: "天"
                        )
                        preferenceStepper(
                            "日志加载条数",
                            value: $viewModel.draft.preferences.logViewerEntryLimit,
                            range: PreferencesConfig.logViewerEntryLimitRange,
                            step: 100,
                            suffix: "条"
                        )
                        Text("日志按年/月/日分目录保存，并自动清理超过保留天数的目录。日志窗口最多加载 10,000 条。")
                            .font(.system(size: 11))
                            .foregroundStyle(DevBarTheme.textSecondary)
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
        .padding(.top, 44)
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

    private var currentVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "未知"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build.map { "\(version) (\($0))" } ?? version
    }

    private func preferenceStepper(
        _ label: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int = 1,
        suffix: String
    ) -> some View {
        HStack {
            Text(label).font(.system(size: 13, weight: .medium))
            Spacer()
            Text("\(value.wrappedValue) \(suffix)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(DevBarTheme.textSecondary)
                .frame(width: 78, alignment: .trailing)
            Stepper("", value: value, in: range, step: step)
                .labelsHidden()
                .onChange(of: value.wrappedValue) {
                    Task { await viewModel.commitPreferences() }
                }
        }
    }
}
