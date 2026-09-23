import AppKit
import DevBarCore
import SwiftUI

struct MCPSettingsSection: View {
    @Bindable var viewModel: SettingsViewModel
    let mcpService: MCPServiceController
    @State private var confirmsTokenRotation = false

    var body: some View {
        SettingsSectionCard {
            VStack(alignment: .leading, spacing: 13) {
                Label("MCP 服务", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 15, weight: .bold))
                Text("让本机 Agent 查询工作区、服务状态和日志，并启动、停止或重启单个服务。")
                    .font(.system(size: 11))
                    .foregroundStyle(DevBarTheme.textSecondary)

                HStack(spacing: 10) {
                    Circle()
                        .fill(mcpService.isRunning ? .green : .secondary)
                        .frame(width: 8, height: 8)
                    Text(mcpService.isStarting ? "启动中" : (mcpService.isRunning ? "运行中" : "已停止"))
                    Spacer()
                    Button(mcpService.isRunning ? "停止 MCP" : "启动 MCP") {
                        Task {
                            if mcpService.isRunning { await mcpService.stop() }
                            else { await mcpService.start() }
                        }
                    }
                    .disabled(mcpService.isStarting || viewModel.isSaving)
                    .accessibilityIdentifier("preferences.mcp.toggle")
                }

                HStack(spacing: 10) {
                    Text("本机端口")
                    TextField("端口", value: $viewModel.draft.preferences.mcpPort, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .disabled(mcpService.isRunning || mcpService.isStarting)
                        .onSubmit { Task { await viewModel.commitPreferences() } }
                        .accessibilityIdentifier("preferences.mcp.port")
                    Spacer()
                    Text("127.0.0.1")
                        .foregroundStyle(DevBarTheme.textSecondary)
                }
                SettingsFieldError(issue: viewModel.issue(at: "preferences.mcpPort"))
                Text("每次打开 DevBar 后手动启动。端口修改后按 Return 保存；运行时不能修改。")
                    .font(.system(size: 11))
                    .foregroundStyle(DevBarTheme.textSecondary)

                HStack(spacing: 10) {
                    Text(mcpService.token == nil ? "访问令牌尚未生成" : "访问令牌已保存在钥匙串")
                        .font(.system(size: 12))
                    Spacer()
                    Button("复制令牌") {
                        if let token = mcpService.token { copy(token) }
                    }
                    .disabled(mcpService.token == nil)
                    .accessibilityIdentifier("preferences.mcp.copyToken")
                    Button("重新生成") { confirmsTokenRotation = true }
                        .accessibilityIdentifier("preferences.mcp.rotateToken")
                }

                if let error = mcpService.errorMessage {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                }

                Text("HTTP 端点：\(mcpService.endpoint)")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                Text("复制配置会包含令牌；重新生成后，已有 Agent 配置需要同步更新。服务日志可能含有应用输出的敏感信息。")
                    .font(.system(size: 11))
                    .foregroundStyle(DevBarTheme.textSecondary)

                configurationBlock(
                    title: "Codex · HTTP 配置",
                    configuration: mcpService.codexHTTPConfiguration
                )
                configurationBlock(
                    title: "本机 Agent · stdio JSON 配置",
                    configuration: mcpService.stdioJSONConfiguration
                )
            }
        }
        .confirmationDialog(
            "重新生成 MCP 访问令牌？",
            isPresented: $confirmsTokenRotation
        ) {
            Button("重新生成并使旧令牌失效", role: .destructive) {
                mcpService.regenerateToken()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("已复制到 Agent 的 HTTP 和 stdio 配置需要更新。")
        }
        .task { mcpService.loadSavedToken() }
    }

    @ViewBuilder
    private func configurationBlock(title: String, configuration: String?) -> some View {
        if let configuration {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("复制配置") { copy(configuration) }
            }
            Text(redacted(configuration))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(DevBarTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 8))
        } else {
            Text("启动 MCP 后可复制 \(title)。")
                .font(.system(size: 11))
                .foregroundStyle(DevBarTheme.textSecondary)
        }
    }

    private func redacted(_ text: String) -> String {
        guard let token = mcpService.token else { return text }
        return text.replacingOccurrences(of: token, with: "<已隐藏令牌>")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
