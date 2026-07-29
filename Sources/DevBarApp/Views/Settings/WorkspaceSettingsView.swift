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
    @State private var showsEnvironmentEditor = false
    @State private var servicePendingDeletion: ServiceConfig?
    @State private var draggedServiceID: UUID?
    @State private var serviceDragOffset: CGFloat = 0
    @FocusState private var isWorkspaceNameFocused: Bool

    private var locked: Bool { viewModel.isLocked(workspace.id) }
    private var workspacePath: String { "workspaces[\(workspaceIndex)]" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SettingsEventStatus(isSaving: viewModel.isSaving, notice: viewModel.notice)
                header
                customization
                services
            }
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var header: some View {
        HStack(spacing: 14) {
            WorkspaceIconContent(workspace: workspace, fontSize: 24, fontWeight: .bold)
                .frame(width: 52, height: 52)
                .background(
                    LinearGradient(
                        colors: [Color(devBarHex: workspace.tintHex), DevBarTheme.accentEnd],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 15, style: .continuous)
                )
                .shadow(color: Color(devBarHex: workspace.tintHex).opacity(0.20), radius: 14, y: 6)

            VStack(alignment: .leading, spacing: 6) {
                TextField("工作区名称", text: $workspace.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 23, weight: .bold))
                    .accessibilityIdentifier("workspace.name")
                    .focused($isWorkspaceNameFocused)
                    .onSubmit {
                        Task { await viewModel.commitWorkspace(workspace.id) }
                    }
                    .onChange(of: isWorkspaceNameFocused) { wasFocused, isFocused in
                        guard wasFocused, !isFocused else { return }
                        Task { await viewModel.commitWorkspace(workspace.id) }
                    }
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
                    Task { await viewModel.deleteWorkspace(workspace.id) }
                } label: {
                    Label("删除工作区", systemImage: "trash")
                }
                .disabled(locked)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 18))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("工作区操作")
        }
    }

    private var customization: some View {
        SettingsSectionCard {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Label("主题色", systemImage: "paintpalette")
                        .font(.system(size: 13, weight: .bold))
                    HStack(spacing: 10) {
                        ForEach(ConfigValidator.selectableTintHexes, id: \.self) { tint in
                            Button {
                                workspace.tintHex = tint
                                Task { await viewModel.commitWorkspace(workspace.id) }
                            } label: {
                                Circle()
                                    .fill(Color(devBarHex: tint))
                                    .frame(width: 21, height: 21)
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
                        Label("不使用图标（显示首字）", systemImage: "character")
                            .tag("")
                        ForEach(Array(ConfigValidator.allowedIconSymbols).sorted(), id: \.self) { symbol in
                            Label(symbol, systemImage: symbol).tag(symbol)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(maxWidth: 200, alignment: .leading)
                    .onChange(of: workspace.iconSymbol) {
                        Task { await viewModel.commitWorkspace(workspace.id) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Divider().frame(height: 86)

                Button {
                    showsEnvironmentEditor = true
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("公共环境", systemImage: "globe")
                                .font(.system(size: 13, weight: .bold))
                            Label("\(workspace.environment.count) 个普通变量", systemImage: "circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(DevBarTheme.textSecondary)
                        }
                        Spacer(minLength: 16)
                        Image(systemName: locked ? "lock.fill" : "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(locked ? Color.orange : DevBarTheme.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(locked)
                .accessibilityIdentifier("workspace.environment.open")
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showsEnvironmentEditor) {
            EnvironmentEditorSheet(
                entries: workspace.environment,
                disabled: locked,
                issueForIndex: { index in
                    viewModel.issue(at: "\(workspacePath).environment[\(index)].key")
                },
                save: { entries in
                    await viewModel.commitWorkspaceEnvironment(
                        workspaceID: workspace.id,
                        entries: entries
                    )
                },
                close: {
                    showsEnvironmentEditor = false
                }
            )
        }
    }

    private var services: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("服务")
                    .font(.system(size: 17, weight: .bold))
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
                VStack(spacing: 12) {
                    ForEach(workspace.services) { service in
                        serviceCard(service)
                    }
                }
                .coordinateSpace(name: "service-list")
                .animation(.snappy(duration: 0.22), value: workspace.services.map(\.id))
            }
        }
    }

    private func serviceCard(_ service: ServiceConfig) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)

                Image(systemName: serviceIcon(service))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color(devBarHex: workspace.tintHex))
                    .frame(width: 36, height: 36)
                    .background(Color(devBarHex: workspace.tintHex).opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(service.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 20)

                Toggle(
                    "加入启动全部",
                    isOn: Binding(
                        get: {
                            workspace.services.first(where: { $0.id == service.id })?.includeInStartAll ?? false
                        },
                        set: { isIncluded in
                            guard let index = workspace.services.firstIndex(where: { $0.id == service.id }) else {
                                return
                            }
                            workspace.services[index].includeInStartAll = isIncluded
                            Task { await viewModel.commitWorkspace(workspace.id) }
                        }
                    )
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("加入启动全部")
                .accessibilityIdentifier("service.includeInStartAll.\(service.id.uuidString.lowercased())")
            }
            .frame(height: 48)

            HStack(spacing: 0) {
                serviceDetail(
                    title: "目录",
                    systemImage: "folder",
                    value: directoryText(service.workingDirectory)
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                detailDivider

                serviceDetail(
                    title: "启动命令",
                    systemImage: "terminal",
                    value: service.command.isEmpty ? "未设置" : service.command,
                    monospaced: true
                )
                .frame(maxWidth: .infinity, alignment: .leading)

                healthDetail(service.healthCheck)
                    .padding(.leading, 14)
                    .frame(width: 164, alignment: .leading)
                    .overlay(alignment: .leading) {
                        Divider()
                            .frame(height: 28)
                    }

                Button {
                    servicePendingDeletion = service
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.red)
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(locked)
                .help("删除服务")
                .accessibilityLabel("删除服务 \(service.name)")
            }
            .frame(height: 40)
        }
        .padding(.horizontal, 14)
        .background(DevBarTheme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DevBarTheme.separator.opacity(0.58), lineWidth: 0.75)
        )
        .shadow(color: DevBarTheme.surfaceShadow.opacity(0.28), radius: 12, y: 5)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.beginEditingService(workspaceID: workspace.id, serviceID: service.id)
        }
        .overlay(alignment: .trailing) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DevBarTheme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(DevBarTheme.separator.opacity(0.74), lineWidth: 0.75)
                    )

                Rectangle()
                    .fill(DevBarTheme.surface)
                    .frame(width: 3, height: 86)
                    .offset(x: -11)

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DevBarTheme.textSecondary)
            }
            .frame(width: 24, height: 88)
            .contentShape(Rectangle())
            .offset(x: 11)
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .named("service-list"))
                    .onChanged { value in
                        draggedServiceID = service.id
                        serviceDragOffset = clampedServiceDragOffset(
                            value.translation.height,
                            for: service.id
                        )
                    }
                    .onEnded { _ in
                        finishServiceDrag(service.id)
                    }
            )
            .accessibilityLabel("拖拽排序 \(service.name)")
        }
        .offset(y: draggedServiceID == service.id ? serviceDragOffset : 0)
        .zIndex(draggedServiceID == service.id ? 1 : 0)
        .confirmationDialog(
            "删除“\(servicePendingDeletion?.name ?? service.name)”服务？",
            isPresented: Binding(
                get: { servicePendingDeletion?.id == service.id },
                set: { isPresented in
                    if !isPresented, servicePendingDeletion?.id == service.id {
                        servicePendingDeletion = nil
                    }
                }
            )
        ) {
            Button("删除服务", role: .destructive) {
                servicePendingDeletion = nil
                Task {
                    await viewModel.deleteService(
                        workspaceID: workspace.id,
                        serviceID: service.id
                    )
                }
            }
            Button("取消", role: .cancel) {
                servicePendingDeletion = nil
            }
        } message: {
            Text("服务配置会被移除，此操作无法撤销。")
        }
    }

    private func clampedServiceDragOffset(_ proposedOffset: CGFloat, for serviceID: UUID) -> CGFloat {
        guard let index = workspace.services.firstIndex(where: { $0.id == serviceID }) else {
            return 0
        }
        let rowStride: CGFloat = 100
        let minimum = -CGFloat(index) * rowStride
        let maximum = CGFloat(workspace.services.count - index - 1) * rowStride
        return min(max(proposedOffset, minimum), maximum)
    }

    private func finishServiceDrag(_ serviceID: UUID) {
        guard let sourceIndex = workspace.services.firstIndex(where: { $0.id == serviceID }) else {
            draggedServiceID = nil
            serviceDragOffset = 0
            return
        }

        let rowStride: CGFloat = 100
        let proposedIndex = sourceIndex + Int((serviceDragOffset / rowStride).rounded())
        let targetIndex = min(max(proposedIndex, 0), workspace.services.count - 1)

        withAnimation(.snappy(duration: 0.22)) {
            draggedServiceID = nil
            serviceDragOffset = 0
        }

        guard targetIndex != sourceIndex else { return }
        let targetServiceID = workspace.services[targetIndex].id
        Task {
            await viewModel.moveService(
                workspaceID: workspace.id,
                serviceID: serviceID,
                relativeTo: targetServiceID,
                placeAfterTarget: targetIndex > sourceIndex
            )
        }
    }

    private var detailDivider: some View {
        Divider()
            .frame(height: 24)
            .padding(.horizontal, 12)
    }

    private func serviceDetail(
        title: String,
        systemImage: String,
        value: String,
        monospaced: Bool = false
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DevBarTheme.textSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DevBarTheme.textSecondary)
                Text(value)
                    .font(
                        monospaced
                            ? .system(size: 11, weight: .semibold, design: .monospaced)
                            : .system(size: 11, weight: .medium)
                    )
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
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
    private func healthDetail(_ health: HealthCheckConfig) -> some View {
        switch health {
        case .none:
            serviceDetail(title: "健康检查", systemImage: "waveform.path.ecg", value: "无检查")
        case let .http(url):
            HStack(spacing: 6) {
                healthKindBadge("HTTP", color: .blue)
                VStack(alignment: .leading, spacing: 4) {
                    Text("健康检查")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DevBarTheme.textSecondary)
                    Text(url.host.map { $0 + url.path } ?? url.absoluteString)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        case let .tcp(host, port):
            HStack(spacing: 6) {
                healthKindBadge("TCP", color: .green)
                VStack(alignment: .leading, spacing: 4) {
                    Text("健康检查")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DevBarTheme.textSecondary)
                    Text(verbatim: tcpEndpoint(host: host, port: port))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private func tcpEndpoint(host: String, port: Int) -> String {
        host == "127.0.0.1" || host == "localhost"
            ? String(port)
            : "\(host):\(String(port))"
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
