import AppKit
import DevBarCore
import SwiftUI

struct MenuBarPanel: View {
    @Bindable var appState: AppState
    let openSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
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
                                startAll: { Task { await appState.startAll(workspaceID: workspace.id) } },
                                stopAll: { Task { await appState.stopAll(workspaceID: workspace.id) } }
                            )
                        }
                    }
                    .padding(.horizontal, DevBarTheme.panelPadding)
                    .padding(.bottom, 18)
                }
            }
            .scrollIndicators(.hidden)

            footer
        }
        .frame(width: 380, height: 520)
        .background(DevBarTheme.background)
        .foregroundStyle(DevBarTheme.textPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu.panel")
    }

    private var header: some View {
        HStack(spacing: 12) {
            DevBarIcon(size: 44)

            VStack(alignment: .leading, spacing: 1) {
                Text("DevBar")
                    .font(.system(size: 22, weight: .bold))
                Text("本地开发服务")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DevBarTheme.textSecondary)
            }

            Spacer()

            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .background(Color.white.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(DevBarTheme.separator.opacity(0.8), lineWidth: 1)
            )
            .accessibilityLabel("打开设置")
            .accessibilityIdentifier("menu.settings")
        }
        .padding(.horizontal, DevBarTheme.panelPadding)
        .padding(.top, 26)
        .padding(.bottom, 24)
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
                .buttonStyle(.plain)
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

    private var footer: some View {
        HStack {
            Button(action: openSettings) {
                Label("打开设置…", systemImage: "gearshape")
            }
            .accessibilityIdentifier("menu.openSettings")

            Spacer()

            Button(action: quit) {
                Label("退出 DevBar", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("menu.quit")
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(DevBarTheme.textSecondary)
        .padding(.horizontal, DevBarTheme.panelPadding)
        .frame(height: 74)
        .overlay(alignment: .top) {
            Divider().overlay(DevBarTheme.separator.opacity(0.75))
        }
    }

    private func isActive(_ state: ServiceState) -> Bool {
        switch state {
        case .starting, .running, .ready, .unready, .stopping: true
        case .stopped, .failed: false
        }
    }
}
