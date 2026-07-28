import DevBarCore
import SwiftUI

struct SettingsRootView: View {
    @Bindable var viewModel: SettingsViewModel
    let close: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(DevBarTheme.separator.opacity(0.7))
            mainContent
        }
        .frame(width: 980, height: 680)
        .background(background)
        .foregroundStyle(DevBarTheme.textPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.root")
        .sheet(item: $viewModel.serviceEditor) { _ in
            if let workspaceID = viewModel.selectedWorkspaceID {
                ServiceEditorSheet(viewModel: viewModel, workspaceID: workspaceID)
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("工作区")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DevBarTheme.textSecondary)
                .padding(.horizontal, 20)
                .padding(.top, 26)
                .padding(.bottom, 12)

            List {
                ForEach(Array(viewModel.draft.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    Button {
                        viewModel.selectWorkspace(workspace.id)
                    } label: {
                        HStack(spacing: 11) {
                            Text(String(workspace.name.prefix(1)).uppercased())
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .background(Color(devBarHex: workspace.tintHex), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            Text(workspace.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 48)
                        .background(
                            viewModel.selectedWorkspaceID == workspace.id && !viewModel.showsPreferences
                                ? DevBarTheme.accentStart.opacity(0.10)
                                : .clear,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace.\(workspace.id.uuidString.lowercased())")
                    .contextMenu {
                        Button("上移") {
                            viewModel.moveWorkspaces(fromOffsets: IndexSet(integer: index), toOffset: max(0, index - 1))
                        }
                        .disabled(index == 0)
                        Button("下移") {
                            viewModel.moveWorkspaces(fromOffsets: IndexSet(integer: index), toOffset: min(viewModel.draft.workspaces.count, index + 2))
                        }
                        .disabled(index == viewModel.draft.workspaces.count - 1)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityIdentifier("settings.sidebar")

            Button {
                Task { await viewModel.addWorkspace() }
            } label: {
                Label("添加工作区", systemImage: "plus.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .frame(height: 46)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("workspace.add")

            Spacer()

            Divider().overlay(DevBarTheme.separator.opacity(0.65))
            Button {
                viewModel.selectPreferences()
            } label: {
                Label("偏好设置", systemImage: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 22)
                    .frame(height: 58)
                    .background(viewModel.showsPreferences ? Color.black.opacity(0.045) : .clear)
            }
            .buttonStyle(.plain)
        }
        .frame(width: 220)
        .background(Color.white.opacity(0.45))
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            Group {
                if viewModel.showsPreferences {
                    PreferencesView(viewModel: viewModel)
                } else if let workspaceID = viewModel.selectedWorkspaceID {
                    WorkspaceSettingsView(viewModel: viewModel, workspaceID: workspaceID)
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(DevBarTheme.accentMiddle)
            Text("添加第一个工作区")
                .font(.system(size: 20, weight: .bold))
            Text("选择一个项目目录，再添加 npm、Java 或其他前台启动命令。")
                .font(.system(size: 12))
                .foregroundStyle(DevBarTheme.textSecondary)
            Button("选择目录") { Task { await viewModel.addWorkspace() } }
                .buttonStyle(SettingsGradientButtonStyle())
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let notice = viewModel.notice {
                noticeView(notice)
            }
            Spacer()
            Button("取消") {
                viewModel.cancel()
                close()
            }
            .keyboardShortcut(.cancelAction)
            Button("检查配置") { Task { await viewModel.checkConfiguration() } }
                .accessibilityIdentifier("config.check")
            Button {
                Task { await viewModel.save() }
            } label: {
                Label(viewModel.isSaving ? "保存中…" : "保存", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(SettingsGradientButtonStyle())
            .disabled(viewModel.isSaving || !viewModel.hasUnsavedChanges)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("config.save")
        }
        .padding(.horizontal, 26)
        .frame(height: 72)
        .background(Color.white.opacity(0.48))
        .overlay(alignment: .top) { Divider().overlay(DevBarTheme.separator.opacity(0.65)) }
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

    private var background: some View {
        ZStack {
            DevBarTheme.background
            RadialGradient(
                colors: [DevBarTheme.accentStart.opacity(0.10), .clear],
                center: .topLeading,
                startRadius: 10,
                endRadius: 520
            )
            RadialGradient(
                colors: [DevBarTheme.accentEnd.opacity(0.12), .clear],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 520
            )
        }
    }
}
