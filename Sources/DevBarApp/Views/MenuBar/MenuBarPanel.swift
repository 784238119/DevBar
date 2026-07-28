import AppKit
import DevBarCore
import SwiftUI

struct MenuBarPanel: View {
    @Bindable var appState: AppState
    let openSettings: () -> Void
    let openLogs: (UUID) -> Void
    @State private var scrollContentHeight: CGFloat = 1

    private let maximumPanelHeight: CGFloat = 520
    private let headerHeight: CGFloat = 60

    private var maximumScrollHeight: CGFloat {
        maximumPanelHeight - headerHeight
    }

    private var serviceSummary: (text: String, color: Color) {
        let states = appState.config.workspaces
            .flatMap(\.services)
            .map { appState.serviceStates[$0.id] ?? .stopped }

        guard !states.isEmpty else {
            return ("尚未配置服务", DevBarTheme.textSecondary)
        }

        let failedCount = states.filter {
            if case .failed = $0 { return true }
            return false
        }.count
        if failedCount > 0 {
            return ("\(failedCount) 个服务异常", .red)
        }

        if states.contains(where: {
            switch $0 {
            case .starting, .stopping: true
            default: false
            }
        }) {
            return ("正在更新服务状态", .orange)
        }

        let unreadyCount = states.filter {
            if case .unready = $0 { return true }
            return false
        }.count
        if unreadyCount > 0 {
            return ("\(unreadyCount) 个服务等待就绪", .orange)
        }

        let activeCount = states.filter(isActive).count
        if activeCount == 0 {
            return ("\(states.count) 个服务 · 全部已停止", DevBarTheme.textSecondary)
        }
        if activeCount == states.count {
            return ("\(states.count) 个服务 · 全部已启动", .green)
        }
        return ("\(activeCount)/\(states.count) 个服务已启动", .green)
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                scrollContent
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: ScrollContentHeightPreferenceKey.self,
                                value: geometry.size.height
                            )
                        }
                    }
            }
            .scrollIndicators(.hidden)
            .frame(height: min(scrollContentHeight, maximumScrollHeight))
            .onPreferenceChange(ScrollContentHeightPreferenceKey.self) { height in
                scrollContentHeight = max(height, 1)
            }
        }
        .frame(width: 380)
        .background(DevBarTheme.background)
        .foregroundStyle(DevBarTheme.textPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu.panel")
    }

    @ViewBuilder
    private var scrollContent: some View {
        if appState.config.workspaces.isEmpty {
            emptyState
        } else {
            LazyVStack(spacing: 14) {
                ForEach(Array(appState.config.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    WorkspaceCardView(
                        workspace: workspace,
                        states: appState.serviceStates,
                        initiallyExpanded: index == 0,
                        toggleService: { serviceID in
                            Task {
                                if isActive(appState.serviceStates[serviceID] ?? .stopped) {
                                    await appState.stop(serviceID: serviceID)
                                } else {
                                    await appState.start(serviceID: serviceID, workspaceID: workspace.id)
                                }
                            }
                        },
                        openLogs: openLogs,
                        startAll: { Task { await appState.startAll(workspaceID: workspace.id) } },
                        stopAll: { Task { await appState.stopAll(workspaceID: workspace.id) } }
                    )
                }
            }
            .padding(.horizontal, DevBarTheme.panelPadding)
            .padding(.bottom, 18)
        }
    }

    private var header: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(serviceSummary.color)
                    .frame(width: 7, height: 7)
                Text(serviceSummary.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DevBarTheme.textSecondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(DevBarTheme.surfaceStrong, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(DevBarTheme.separator.opacity(0.8), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(serviceSummary.text)

            Spacer()

            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(DevBarPressButtonStyle())
            .background(DevBarTheme.surfaceStrong, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DevBarTheme.separator.opacity(0.8), lineWidth: 1)
            )
            .accessibilityLabel("打开设置")
            .accessibilityIdentifier("menu.settings")
        }
        .padding(.horizontal, DevBarTheme.panelPadding)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(DevBarTheme.accentMiddle)
            Text("尚未配置工作区")
                .font(.system(size: 17, weight: .bold))
            Text("添加项目目录和启动命令后，\n就能从菜单栏一键启动。")
                .multilineTextAlignment(.center)
                .font(.system(size: 12))
                .foregroundStyle(DevBarTheme.textSecondary)
                .lineSpacing(3)
            Button("添加工作区", action: openSettings)
                .buttonStyle(DevBarPressButtonStyle())
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 36)
                .background(DevBarTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: DevBarTheme.controlRadius, style: .continuous))
                .accessibilityIdentifier("workspace.add")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
        .padding(.horizontal, 24)
    }

    private func isActive(_ state: ServiceState) -> Bool {
        switch state {
        case .starting, .running, .ready, .unready, .stopping: true
        case .stopped, .failed: false
        }
    }
}

private struct ScrollContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 1

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
