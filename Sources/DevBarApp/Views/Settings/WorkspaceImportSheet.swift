import DevBarCore
import SwiftUI

struct WorkspaceImportSheet: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var importDraft: WorkspaceImportDraft

    init(viewModel: SettingsViewModel, importDraft: WorkspaceImportDraft) {
        self.viewModel = viewModel
        _importDraft = State(initialValue: importDraft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsEventStatus(isSaving: viewModel.isSaving, notice: viewModel.notice)
            VStack(alignment: .leading, spacing: 5) {
                Text("导入工作区")
                    .font(.system(size: 20, weight: .bold))
                Text("DevBar 只读取项目配置。确认后才会保存，且不会安装依赖或启动服务。")
                    .font(.system(size: 12))
                    .foregroundStyle(DevBarTheme.textSecondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                TextField("工作区名称", text: $importDraft.workspace.name)
                    .textFieldStyle(.roundedBorder)
                Label(importDraft.workspace.rootDirectory, systemImage: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(DevBarTheme.textSecondary)
                    .lineLimit(1)
            }

            Divider()

            if importDraft.candidates.isEmpty {
                ContentUnavailableView(
                    "没有发现可识别的服务",
                    systemImage: "magnifyingglass",
                    description: Text("仍可创建空工作区，之后手动添加服务。")
                )
                .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("发现 \(importDraft.candidates.count) 个候选服务")
                        .font(.system(size: 13, weight: .semibold))
                    Text("取消勾选不需要的项目，也可以在导入后继续编辑。")
                        .font(.system(size: 11))
                        .foregroundStyle(DevBarTheme.textSecondary)
                }

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($importDraft.candidates) { $candidate in
                            candidateRow(candidate: $candidate)
                        }
                    }
                }
                .frame(minHeight: 180, maxHeight: 330)

                if hasInvalidSelectedCandidate {
                    Label("所选服务的名称和启动命令不能为空。", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Button("取消") { viewModel.cancelWorkspaceImport() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(importDraft.candidates.isEmpty ? "创建空工作区" : "导入所选服务") {
                    Task { await viewModel.confirmWorkspaceImport(importDraft) }
                }
                .buttonStyle(SettingsGradientButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(
                    importDraft.workspace.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || hasInvalidSelectedCandidate
                        || viewModel.isSaving
                )
            }
        }
        .padding(22)
        .frame(width: 590)
        .background(DevBarTheme.background)
        .interactiveDismissDisabled(viewModel.isSaving)
    }

    private var hasInvalidSelectedCandidate: Bool {
        importDraft.candidates.contains { candidate in
            guard importDraft.selectedCandidateIDs.contains(candidate.id) else { return false }
            return candidate.service.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || candidate.service.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func candidateRow(candidate: Binding<DetectedService>) -> some View {
        let id = candidate.wrappedValue.id
        return HStack(alignment: .top, spacing: 12) {
            Toggle(
                "",
                isOn: Binding(
                    get: { importDraft.selectedCandidateIDs.contains(id) },
                    set: { selected in
                        if selected {
                            importDraft.selectedCandidateIDs.insert(id)
                        } else {
                            importDraft.selectedCandidateIDs.remove(id)
                        }
                    }
                )
            )
            .labelsHidden()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    TextField("服务名称", text: candidate.service.name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(candidate.wrappedValue.source)
                        .font(.system(size: 10))
                        .foregroundStyle(DevBarTheme.textSecondary)
                }
                TextField("启动命令", text: candidate.service.command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
            }
        }
        .padding(12)
        .background(DevBarTheme.surfaceSubtle, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .opacity(importDraft.selectedCandidateIDs.contains(id) ? 1 : 0.58)
    }
}
