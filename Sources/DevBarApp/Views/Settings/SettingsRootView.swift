import DevBarCore
import SwiftUI

struct SettingsRootView: View {
    @Bindable var viewModel: SettingsViewModel
    let presentationPreferences: AppPresentationPreferences
    let updateController: AppUpdateController

    var body: some View {
        ZStack(alignment: .top) {
            Group {
                if viewModel.showsPreferences {
                    PreferencesView(
                        viewModel: viewModel,
                        presentationPreferences: presentationPreferences,
                        updateController: updateController
                    )
                } else {
                    HStack(spacing: 0) {
                        sidebar
                        Divider().overlay(DevBarTheme.separator.opacity(0.7))
                        workspaceContent
                    }
                }
            }
            .ignoresSafeArea(.container, edges: .top)

            titlebarGlass
                .allowsHitTesting(false)
                .ignoresSafeArea(.container, edges: .top)
        }
        .frame(width: 980, height: 680)
        .background(background.ignoresSafeArea())
        .containerBackground(for: .window) {
            background
        }
        .foregroundStyle(DevBarTheme.textPrimary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.root")
        .sheet(item: $viewModel.serviceEditor, onDismiss: {
            viewModel.endServiceEditing()
        }) { draft in
            if let workspaceID = viewModel.selectedWorkspaceID {
                ServiceEditorSheet(
                    viewModel: viewModel,
                    workspaceID: workspaceID,
                    draft: draft
                )
            }
        }
        .sheet(item: $viewModel.workspaceImport, onDismiss: {
            viewModel.cancelWorkspaceImport()
        }) { importDraft in
            WorkspaceImportSheet(viewModel: viewModel, importDraft: importDraft)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("工作区")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DevBarTheme.textSecondary)
                .padding(.horizontal, 18)
                .padding(.top, 22)
                .padding(.bottom, 10)

            List {
                ForEach(Array(viewModel.draft.workspaces.enumerated()), id: \.element.id) { index, workspace in
                    Button {
                        viewModel.selectWorkspace(workspace.id)
                    } label: {
                        HStack(spacing: 10) {
                            WorkspaceIconContent(workspace: workspace, fontSize: 15, fontWeight: .bold)
                                .frame(width: 32, height: 32)
                                .background(Color(devBarHex: workspace.tintHex), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text(workspace.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 9)
                        .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                        .background(
                            viewModel.selectedWorkspaceID == workspace.id && !viewModel.showsPreferences
                                ? DevBarTheme.accentStart.opacity(0.10)
                                : .clear,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )
                        .overlay(alignment: .leading) {
                            if viewModel.selectedWorkspaceID == workspace.id && !viewModel.showsPreferences {
                                Capsule()
                                    .fill(DevBarTheme.accentMiddle)
                                    .frame(width: 3, height: 22)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace.\(workspace.id.uuidString.lowercased())")
                    .contextMenu {
                        Button("上移") {
                            Task {
                                await viewModel.moveWorkspaces(
                                    fromOffsets: IndexSet(integer: index),
                                    toOffset: max(0, index - 1)
                                )
                            }
                        }
                        .disabled(index == 0)
                        Button("下移") {
                            Task {
                                await viewModel.moveWorkspaces(
                                    fromOffsets: IndexSet(integer: index),
                                    toOffset: min(viewModel.draft.workspaces.count, index + 2)
                                )
                            }
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
                Label(
                    viewModel.isDetectingWorkspace ? "正在识别…" : "添加工作区",
                    systemImage: viewModel.isDetectingWorkspace ? "magnifyingglass" : "plus.circle"
                )
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .frame(height: 42)
                    .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
            .disabled(viewModel.isDetectingWorkspace)
            .accessibilityIdentifier("workspace.add")

            Spacer()

            Divider().overlay(DevBarTheme.separator.opacity(0.65))
            Button {
                viewModel.selectPreferences()
            } label: {
                Label("偏好设置", systemImage: "gearshape")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .frame(height: 52)
                    .background(viewModel.showsPreferences ? DevBarTheme.accentStart.opacity(0.10) : .clear)
                    .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .buttonStyle(.plain)
        }
        .frame(width: 196)
        .background(DevBarTheme.surfaceSubtle)
    }

    @ViewBuilder
    private var workspaceContent: some View {
        Group {
            if let workspaceID = viewModel.selectedWorkspaceID {
                WorkspaceSettingsView(viewModel: viewModel, workspaceID: workspaceID)
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Button(viewModel.isDetectingWorkspace ? "正在识别…" : "选择目录") {
                Task { await viewModel.addWorkspace() }
            }
                .buttonStyle(SettingsGradientButtonStyle())
                .disabled(viewModel.isDetectingWorkspace)
        }
    }

    private var background: some View {
        ZStack {
            DevBarTheme.background
            RadialGradient(
                colors: [DevBarTheme.auroraBlue.opacity(0.22), .clear],
                center: .topLeading,
                startRadius: 4,
                endRadius: 470
            )
            RadialGradient(
                colors: [DevBarTheme.auroraMint.opacity(0.16), .clear],
                center: .topTrailing,
                startRadius: 8,
                endRadius: 440
            )
            RadialGradient(
                colors: [DevBarTheme.accentMiddle.opacity(0.08), .clear],
                center: .bottomTrailing,
                startRadius: 20,
                endRadius: 520
            )
        }
    }

    /// Lets the page continue beneath the traffic lights while softly
    /// separating overlapping controls from the content below.
    private var titlebarGlass: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)

            LinearGradient(
                colors: [
                    Color.white.opacity(0.14),
                    DevBarTheme.auroraBlue.opacity(0.06),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .frame(height: 72)
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black.opacity(0.94), location: 0.48),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .accessibilityHidden(true)
    }
}
