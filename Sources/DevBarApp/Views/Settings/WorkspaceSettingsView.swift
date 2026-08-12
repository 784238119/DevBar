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
    @State private var expandedServiceIDs: Set<UUID> = []
    @State private var hoveredServiceID: UUID?
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
                VStack(spacing: 0) {
                    ForEach(Array(workspace.services.enumerated()), id: \.element.id) { index, service in
                        serviceCard(service, at: index)

                        if index < workspace.services.count - 1 {
                            Divider()
                                .padding(.leading, 66)
                        }
                    }

                    Divider()

                    Text("点击服务名称可编辑详情，拖拽右侧图标可调整顺序。")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(DevBarTheme.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 38, alignment: .center)
                        .accessibilityIdentifier("service.list.hint")
                }
                .background(DevBarTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(DevBarTheme.separator.opacity(0.58), lineWidth: 0.75)
                }
                .shadow(color: DevBarTheme.surfaceShadow.opacity(0.22), radius: 10, y: 4)
                .coordinateSpace(name: "service-list")
                .animation(.snappy(duration: 0.22), value: workspace.services.map(\.id))
                .animation(.snappy(duration: 0.20), value: expandedServiceIDs)
            }
        }
    }

    private func serviceCard(_ service: ServiceConfig, at index: Int) -> some View {
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

                Button {
                    toggleServiceExpansion(service.id)
                } label: {
                    Image(systemName: expandedServiceIDs.contains(service.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DevBarTheme.textPrimary)
                        .frame(width: 24, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expandedServiceIDs.contains(service.id) ? "收起启动命令" : "展开启动命令")
                .accessibilityLabel(expandedServiceIDs.contains(service.id) ? "收起 \(service.name)" : "展开 \(service.name)")
                .accessibilityIdentifier("service.disclosure.\(service.id.uuidString.lowercased())")

                Button {
                    viewModel.beginEditingService(workspaceID: workspace.id, serviceID: service.id)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(service.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DevBarTheme.textPrimary)
                            .lineLimit(1)
                        Text(directoryText(service.workingDirectory))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DevBarTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(locked)
                .help(locked ? "请先停止服务再编辑" : "编辑服务")
                .accessibilityIdentifier("service.edit.\(service.id.uuidString.lowercased())")

                compactHealthDetail(service.healthCheck)
                    .frame(width: 126, alignment: .leading)

                Toggle(
                    "加入启动全部",
                    isOn: $workspace.services[index].includeInStartAll
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Color(devBarHex: workspace.tintHex))
                .onChange(of: workspace.services[index].includeInStartAll) {
                    Task { await viewModel.commitWorkspace(workspace.id) }
                }
                .help("加入启动全部")
                .accessibilityIdentifier("service.includeInStartAll.\(service.id.uuidString.lowercased())")

                Menu {
                    Button {
                        viewModel.beginEditingService(workspaceID: workspace.id, serviceID: service.id)
                    } label: {
                        Label("编辑服务", systemImage: "pencil")
                    }
                    .disabled(locked)

                    Divider()

                    Button(role: .destructive) {
                        servicePendingDeletion = service
                    } label: {
                        Label("删除服务", systemImage: "trash")
                    }
                    .disabled(locked)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DevBarTheme.textSecondary)
                        .frame(width: 30, height: 32)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("服务操作")
                .accessibilityLabel("服务操作 \(service.name)")
                .accessibilityIdentifier("service.actions.\(service.id.uuidString.lowercased())")

                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(locked ? DevBarTheme.textSecondary.opacity(0.45) : DevBarTheme.textSecondary)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
                    .gesture(serviceDragGesture(for: service))
                    .help(locked ? "服务运行中，无法排序" : "拖拽调整顺序")
                    .accessibilityLabel("拖拽排序 \(service.name)")
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 76)

            if expandedServiceIDs.contains(service.id) {
                HStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(DevBarTheme.textSecondary)
                        .frame(width: 32, height: 32)

                    VStack(alignment: .leading, spacing: 5) {
                        Text("启动命令")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DevBarTheme.textSecondary)
                        Text(service.command.isEmpty ? "未设置" : service.command)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DevBarTheme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .frame(height: 62)
                .background(Color(devBarHex: workspace.tintHex).opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(DevBarTheme.separator.opacity(0.45), lineWidth: 0.75)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityIdentifier("service.command.\(service.id.uuidString.lowercased())")
            }
        }
        .background(
            hoveredServiceID == service.id
                ? Color(devBarHex: workspace.tintHex).opacity(0.035)
                : Color.clear
        )
        .onHover { isHovered in
            hoveredServiceID = isHovered ? service.id : nil
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

    private func toggleServiceExpansion(_ serviceID: UUID) {
        if expandedServiceIDs.contains(serviceID) {
            expandedServiceIDs.remove(serviceID)
        } else {
            expandedServiceIDs.insert(serviceID)
        }
    }

    private func serviceDragGesture(for service: ServiceConfig) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("service-list"))
            .onChanged { value in
                guard !locked else { return }
                if draggedServiceID == nil {
                    expandedServiceIDs.removeAll()
                }
                draggedServiceID = service.id
                serviceDragOffset = clampedServiceDragOffset(
                    value.translation.height,
                    for: service.id
                )
            }
            .onEnded { _ in
                guard !locked else { return }
                finishServiceDrag(service.id)
            }
    }

    private func clampedServiceDragOffset(_ proposedOffset: CGFloat, for serviceID: UUID) -> CGFloat {
        guard let index = workspace.services.firstIndex(where: { $0.id == serviceID }) else {
            return 0
        }
        let rowStride: CGFloat = 77
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

        let rowStride: CGFloat = 77
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
    private func compactHealthDetail(_ health: HealthCheckConfig) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DevBarTheme.textSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text("健康检查")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DevBarTheme.textSecondary)

                switch health {
                case .none:
                    Text("无检查")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DevBarTheme.textPrimary)
                case .http:
                    healthKindBadge("HTTP", color: .blue)
                case .tcp:
                    healthKindBadge("TCP", color: .green)
                }
            }
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
