import DevBarCore
import SwiftUI

struct SettingsSectionCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .background(Color.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(DevBarTheme.separator.opacity(0.72), lineWidth: 1)
            )
            .shadow(color: DevBarTheme.surfaceShadow.opacity(0.55), radius: 16, y: 8)
    }
}

struct SettingsGradientButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(DevBarTheme.accent.opacity(configuration.isPressed ? 0.78 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .shadow(color: DevBarTheme.accentMiddle.opacity(0.18), radius: 10, y: 4)
    }
}

struct PlainEnvironmentWarning: View {
    var body: some View {
        Label("变量会以明文保存在本机配置中，请勿填写密码、Token 或密钥。", systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.orange.opacity(0.92))
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct EnvironmentEditor: View {
    @Binding var entries: [EnvironmentEntry]
    let disabled: Bool
    let issueForIndex: (Int) -> ValidationIssue?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PlainEnvironmentWarning()

            ForEach(entries.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        TextField("变量名", text: $entries[index].key)
                            .textFieldStyle(.roundedBorder)
                        TextField("值", text: $entries[index].value)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            entries.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(disabled)
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

            Button {
                entries.append(EnvironmentEntry(key: "", value: ""))
            } label: {
                Label("添加变量", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DevBarTheme.accentMiddle)
            .disabled(disabled)
        }
        .disabled(disabled)
    }

    private func localIssue(for index: Int) -> String? {
        let key = entries[index].key
        if key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) == nil {
            return "变量名需匹配 [A-Za-z_][A-Za-z0-9_]*。"
        }
        if entries.indices.contains(where: { $0 != index && entries[$0].key == key }) {
            return "同一范围内的变量名不能重复。"
        }
        return nil
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
