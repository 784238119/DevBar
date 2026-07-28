import DevBarCore
import SwiftUI

struct PreferencesView: View {
    @Bindable var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("偏好设置")
                        .font(.system(size: 26, weight: .bold))
                    Text("Shell、日志轮转和安全停止策略")
                        .font(.system(size: 12))
                        .foregroundStyle(DevBarTheme.textSecondary)
                }

                SettingsSectionCard {
                    VStack(alignment: .leading, spacing: 14) {
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
                    VStack(alignment: .leading, spacing: 18) {
                        Label("日志轮转", systemImage: "doc.text")
                            .font(.system(size: 15, weight: .bold))
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
                    VStack(alignment: .leading, spacing: 18) {
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
            .padding(30)
        }
        .scrollIndicators(.hidden)
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
        }
    }
}
