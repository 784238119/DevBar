import DevBarCore
import SwiftUI

struct WorkspaceSettingsView: View {
    @Bindable var viewModel: SettingsViewModel
    let workspaceID: UUID

    var body: some View {
        if let index = viewModel.draft.workspaces.firstIndex(where: { $0.id == workspaceID }) {
            WorkspaceSettingsContent(
                viewModel: viewModel,
                workspace: $viewModel.draft.workspaces[index],
                workspaceIndex: index
            )
        } else {
            ContentUnavailableView("工作区不存在", systemImage: "questionmark.folder")
        }
    }
}

private struct WorkspaceSettingsContent: View {
    @Bindable var viewModel: SettingsViewModel
    @Binding var workspace: WorkspaceConfig
    let workspaceIndex: Int

    private var locked: Bool { viewModel.isLocked(workspace.id) }
    private var workspacePath: String { "workspaces[\(workspaceIndex)]" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                customization
                services
            }
            .padding(.horizontal, 28)
            .padding(.top, 28)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text(String(workspace.name.prefix(1)).uppercased())
                .font(.system(size: 27, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(
                    LinearGradient(
                        colors: [Color(devBarHex: workspace.tintHex), DevBarTheme.accentEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 17, style: .continuous)
                )
                .shadow(color: Color(devBarHex: workspace.tintHex).opacity(0.24), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                TextField("工作区名称", text: $workspace.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 25, weight: .bold))
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                    Text(displayPath(workspace.rootDirectory))
                        .lineLimit(1)
                    Button {
                        Task { await viewModel.chooseWorkspaceRoot(workspace.id) }
                    } label: {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    .buttonStyle(.borderless)
                    .disabled(locked)
                    .accessibilityLabel("重新选择工作区目录")
                }
                .font(.system(size: 12))
                .foregroundStyle(DevBarTheme.textSecondary)
                SettingsFieldError(issue: viewModel.issue(at: "\(workspacePath).rootDirectory"))
            }

            Spacer()

            if locked {
                Label("服务运行中，目录、环境和删除已锁定", systemImage: "lock.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Color.orange.opacity(0.10), in: Capsule())
            }

            Menu {
                Button(role: .destructive) {
                    viewModel.deleteWorkspace(workspace.id)
                } label: {
                    Label("删除工作区", systemImage: "trash")
                }
                .disabled(locked)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
            }
            .menuStyle(.borderlessButton)
        }
    }

    private var customization: some View {
        SettingsSectionCard {
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    Label("主题色", systemImage: "paintpalette")
                        .font(.system(size: 13, weight: .bold))
                    HStack(spacing: 12) {
                        ForEach(["#FF7A59", "#F59E0B", "#FF5C8A", "#A78BFA", "#0EA5E9", "#34C759"], id: \.self) { tint in
                            Button {
                                workspace.tintHex = tint
                            } label: {
                                Circle()
                                    .fill(Color(devBarHex: tint))
                                    .frame(width: 24, height: 24)
                                    .overlay {
                                        if workspace.tintHex.uppercased() == tint {
                                            Circle().stroke(.white, lineWidth: 3)
                                            Circle().stroke(Color(devBarHex: tint), lineWidth: 2).padding(-3)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("主题色 \(tint)")
                        }
                    }

                    Picker("图标", selection: $workspace.iconSymbol) {
                        ForEach(Array(ConfigValidator.allowedIconSymbols).sorted(), id: \.self) { symbol in
                            Label(symbol, systemImage: symbol).tag(symbol)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: 230, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().frame(height: 112)

                DisclosureGroup {
                    EnvironmentEditor(
                        entries: $workspace.environment,
                        disabled: locked,
                        issueForIndex: { index in
                            viewModel.issue(at: "\(workspacePath).environment[\(index)].key")
                        }
                    )
                    .padding(.top, 12)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("公共环境", systemImage: "globe")
                            .font(.system(size: 13, weight: .bold))
                        Label("\(workspace.environment.count) 个普通变量", systemImage: "circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(DevBarTheme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("服务")
                    .font(.system(size: 18, weight: .bold))
                Text("\(workspace.services.count)")
                    .foregroundStyle(DevBarTheme.textSecondary)
                Spacer()
                Button {
                    viewModel.beginAddingService(workspaceID: workspace.id)
                } label: {
                    Label("添加服务", systemImage: "plus")
                }
                .buttonStyle(SettingsGradientButtonStyle())
                .accessibilityIdentifier("service.add")
            }

            if workspace.services.isEmpty {
                SettingsSectionCard {
                    HStack {
                        Label("尚未添加服务", systemImage: "terminal")
                            .foregroundStyle(DevBarTheme.textSecondary)
                        Spacer()
                        Text("支持 npm、Java 和任意前台 zsh 命令")
                            .font(.system(size: 11))
                            .foregroundStyle(DevBarTheme.textSecondary)
                    }
                }
            } else {
                ForEach(Array(workspace.services.enumerated()), id: \.element.id) { index, service in
                    serviceCard(service, index: index)
                }
            }
        }
    }

    private func serviceCard(_ service: ServiceConfig, index: Int) -> some View {
        HStack(spacing: 16) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 9, height: 9)
                Image(systemName: serviceIcon(service))
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(devBarHex: workspace.tintHex))
                    .frame(width: 46, height: 46)
                    .background(Color(devBarHex: workspace.tintHex).opacity(0.09), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(service.name).font(.system(size: 15, weight: .bold))
                    Label(directoryText(service.workingDirectory), systemImage: "folder")
                        .font(.system(size: 11))
                        .foregroundStyle(DevBarTheme.textSecondary)
                        .lineLimit(1)
                }
                .frame(width: 170, alignment: .leading)

                Divider().frame(height: 48)
                VStack(alignment: .leading, spacing: 5) {
                    Text("启动命令").font(.system(size: 10)).foregroundStyle(DevBarTheme.textSecondary)
                    Text(service.command.isEmpty ? "未设置" : service.command)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                healthBadge(service.healthCheck)

                Image(systemName: service.includeInStartAll ? "checkmark.square.fill" : "square")
                    .font(.system(size: 19))
                    .foregroundStyle(service.includeInStartAll ? DevBarTheme.accentStart : DevBarTheme.textSecondary)
                    .accessibilityLabel(service.includeInStartAll ? "已加入启动全部" : "未加入启动全部")

                Menu {
                    Button("编辑") {
                        viewModel.beginEditingService(workspaceID: workspace.id, serviceID: service.id)
                    }
                    Button("上移") {
                        viewModel.moveServices(
                            workspaceID: workspace.id,
                            fromOffsets: IndexSet(integer: index),
                            toOffset: max(0, index - 1)
                        )
                    }
                    .disabled(index == 0)
                    Button("下移") {
                        viewModel.moveServices(
                            workspaceID: workspace.id,
                            fromOffsets: IndexSet(integer: index),
                            toOffset: min(workspace.services.count, index + 2)
                        )
                    }
                    .disabled(index == workspace.services.count - 1)
                    Button(role: .destructive) {
                        viewModel.deleteService(workspaceID: workspace.id, serviceID: service.id)
                    } label: {
                        Text("删除")
                    }
                    .disabled(locked)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 26, height: 26)
                }
                .menuStyle(.borderlessButton)
        }
        .padding(.horizontal, 16)
        .frame(height: 88)
        .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(DevBarTheme.separator.opacity(0.72)))
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.beginEditingService(workspaceID: workspace.id, serviceID: service.id)
        }
    }

    private func directoryText(_ directory: WorkingDirectory) -> String {
        switch directory {
        case let .relative(path): path
        case let .absolute(path): path
        }
    }

    private func displayPath(_ path: String) -> String {
        guard !path.isEmpty else { return "尚未选择目录" }
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private func serviceIcon(_ service: ServiceConfig) -> String {
        service.command.lowercased().contains("java") || service.command.lowercased().contains("mvn")
            ? "cup.and.saucer.fill"
            : "chevron.left.forwardslash.chevron.right"
    }

    @ViewBuilder
    private func healthBadge(_ health: HealthCheckConfig) -> some View {
        switch health {
        case .none:
            Text("无检查")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DevBarTheme.textSecondary)
                .frame(width: 140, alignment: .leading)
        case let .http(url):
            HStack(spacing: 6) {
                healthKindBadge("HTTP", color: .blue)
                Text(url.host.map { $0 + url.path } ?? url.absoluteString)
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)
        case let .tcp(host, port):
            HStack(spacing: 6) {
                healthKindBadge("TCP", color: .green)
                Text(host == "127.0.0.1" || host == "localhost" ? "\(port)" : "\(host):\(port)")
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)
        }
    }

    private func healthKindBadge(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(color.opacity(0.10), in: Capsule())
    }
}
