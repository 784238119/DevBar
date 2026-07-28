import DevBarCore
import SwiftUI

struct SettingsSectionCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(DevBarTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(DevBarTheme.separator.opacity(0.46), lineWidth: 0.75)
            )
            .shadow(color: DevBarTheme.surfaceShadow.opacity(0.45), radius: 16, y: 7)
    }
}

struct SettingsGradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(DevBarTheme.accent.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .shadow(color: DevBarTheme.accentMiddle.opacity(0.16), radius: 12, y: 5)
    }
}

struct SettingsSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(DevBarTheme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(
                DevBarTheme.surfaceStrong.opacity(configuration.isPressed ? 0.72 : 0.54),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
    }
}

struct SettingsEventStatus: View {
    let isSaving: Bool
    let notice: SettingsNotice?

    var body: some View {
        HStack(spacing: 12) {
            if let notice {
                noticeView(notice)
            }
            if isSaving {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在保存配置")
            }
        }
        .frame(minHeight: 30)
    }

    @ViewBuilder
    private func noticeView(_ notice: SettingsNotice) -> some View {
        switch notice {
        case .checking:
            Label("正在检查…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(DevBarTheme.textSecondary)
        case let .success(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failure(message):
            Label(message, systemImage: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}

struct PlainEnvironmentWarning: View {
    var body: some View {
        Label("明文保存，请勿填写密码、Token 或密钥", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.orange.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct EnvironmentEditor: View {
    @Binding var entries: [EnvironmentEntry]
    let disabled: Bool
    let issueForIndex: (Int) -> ValidationIssue?
    var showsAddButton = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlainEnvironmentWarning()

            ForEach(entries.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("变量名，如 PORT", text: $entries[index].key)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.regular)
                            .frame(width: 220)
                            .frame(height: 32)
                        TextField("变量值", text: $entries[index].value)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.regular)
                            .frame(maxWidth: .infinity)
                            .frame(height: 32)
                        Button {
                            entries.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 32, height: 32)
                        .buttonStyle(.plain)
                        .disabled(disabled)
                        .accessibilityLabel("删除变量")
                    }
                    if let issue = issueForIndex(index) {
                        Text(issue.message)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.red)
                    } else if let message = localIssue(for: index) {
                        Text(message)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.red)
                    }
                }
            }

            if showsAddButton {
                Button {
                    entries.append(EnvironmentEntry(key: "", value: ""))
                } label: {
                    Label("添加变量", systemImage: "plus")
                        .frame(minWidth: 96)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DevBarTheme.accentMiddle)
                .disabled(disabled)
                .accessibilityIdentifier("environment.add")
            }
        }
        .disabled(disabled)
    }

    private func localIssue(for index: Int) -> String? {
        let key = entries[index].key
        guard !key.isEmpty else {
            return nil
        }
        if key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil {
            return "变量名只能包含字母、数字和下划线，且不能以数字开头。"
        }
        if entries.indices.contains(where: { $0 != index && entries[$0].key == key }) {
            return "变量名不能重复。"
        }
        return nil
    }
}

struct EnvironmentEditorSheet: View {
    @State private var entries: [EnvironmentEntry]
    let disabled: Bool
    let issueForIndex: (Int) -> ValidationIssue?
    let save: ([EnvironmentEntry]) async -> Bool
    let close: () -> Void
    @State private var isSaving = false

    init(
        entries: [EnvironmentEntry],
        disabled: Bool,
        issueForIndex: @escaping (Int) -> ValidationIssue?,
        save: @escaping ([EnvironmentEntry]) async -> Bool,
        close: @escaping () -> Void
    ) {
        _entries = State(initialValue: entries)
        self.disabled = disabled
        self.issueForIndex = issueForIndex
        self.save = save
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("公共环境变量")
                        .font(.system(size: 18, weight: .bold))
                    Text("\(entries.count) 个普通变量")
                        .font(.system(size: 11))
                        .foregroundStyle(DevBarTheme.textSecondary)
                }

                Spacer()

                Button {
                    entries.append(EnvironmentEntry(key: "", value: ""))
                } label: {
                    Label("添加变量", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .disabled(disabled)
                .accessibilityIdentifier("environment.add")

                Button("取消", action: close)
                    .buttonStyle(.bordered)
                    .disabled(isSaving)

                Button("完成") {
                    isSaving = true
                    Task {
                        _ = await save(entries)
                        close()
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DevBarTheme.accentMiddle)
                .disabled(disabled || isSaving)
            }
            .padding(.horizontal, 22)
            .frame(height: 68)

            Divider().overlay(DevBarTheme.separator)

            ScrollView {
                EnvironmentEditor(
                    entries: $entries,
                    disabled: disabled,
                    issueForIndex: issueForIndex,
                    showsAddButton: false
                )
                .padding(22)
            }

            if disabled {
                Label("服务运行中，环境变量已锁定", systemImage: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .frame(height: 44)
                    .overlay(alignment: .top) {
                        Divider().overlay(DevBarTheme.separator)
                    }
            }
        }
        .frame(width: 600, height: 400)
        .background(DevBarTheme.background)
        .accessibilityIdentifier("workspace.environment.editor")
    }
}

struct SettingsFieldError: View {
    let issue: ValidationIssue?

    var body: some View {
        if let issue {
            Text(issue.message)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
