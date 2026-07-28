import AppKit
import DevBarCore
import Foundation
import Observation
import SwiftUI

@MainActor
protocol DirectoryPicking {
    func chooseDirectory() async -> URL?
}

@MainActor
struct NSOpenPanelDirectoryPicker: DirectoryPicking {
    func chooseDirectory() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        return await panel.begin() == .OK ? panel.url?.standardizedFileURL : nil
    }
}

struct ServiceEditorDraft: Identifiable, Equatable {
    let id = UUID()
    let serviceID: UUID?
    var service: ServiceConfig
}

enum SettingsNotice: Equatable {
    case checking
    case success(String)
    case failure(String)
}

@MainActor
@Observable
final class SettingsViewModel {
    /// The commit boundary receives both snapshots so its production adapter can run
    /// DeletionCoordinator first for removed UUID log directories, then persist config.
    /// It must throw when either Trash or persistence fails.
    typealias CommitAction = @MainActor (_ baseline: AppConfig, _ draft: AppConfig) async throws -> Void
    typealias ShellRefreshAction = @MainActor (String) async throws -> Void
    typealias SyntaxCheckAction = @Sendable (String, String) async -> ShellSyntaxResult

    private(set) var baseline: AppConfig
    var draft: AppConfig
    var selectedWorkspaceID: UUID?
    var showsPreferences = false
    var serviceEditor: ServiceEditorDraft?
    private(set) var issues: [ValidationIssue] = []
    private(set) var notice: SettingsNotice?
    private(set) var refreshedShellPath: String?
    private(set) var isSaving = false

    let directoryPicker: any DirectoryPicking
    private let validator: ConfigValidator
    private let commitAction: CommitAction
    private let shellRefreshAction: ShellRefreshAction
    private let syntaxCheckAction: SyntaxCheckAction
    private let workspaceLocked: @MainActor (UUID) -> Bool

    init(
        configuration: AppConfig,
        directoryPicker: (any DirectoryPicking)? = nil,
        validator: ConfigValidator = ConfigValidator(),
        workspaceLocked: @escaping @MainActor (UUID) -> Bool = { _ in false },
        commit: @escaping CommitAction,
        refreshShell: @escaping ShellRefreshAction,
        checkSyntax: SyntaxCheckAction? = nil
    ) {
        baseline = configuration
        draft = configuration
        selectedWorkspaceID = configuration.workspaces.first?.id
        self.directoryPicker = directoryPicker ?? NSOpenPanelDirectoryPicker()
        self.validator = validator
        self.workspaceLocked = workspaceLocked
        commitAction = commit
        shellRefreshAction = refreshShell
        syntaxCheckAction = checkSyntax ?? { zshPath, command in
            await ShellSyntaxChecker(zshPath: zshPath.isEmpty ? "/bin/zsh" : zshPath).check(command: command)
        }
    }

    var hasUnsavedChanges: Bool { draft != baseline }
    var selectedWorkspaceIndex: Int? {
        guard let selectedWorkspaceID else { return nil }
        return draft.workspaces.firstIndex { $0.id == selectedWorkspaceID }
    }

    var selectedWorkspace: WorkspaceConfig? {
        guard let index = selectedWorkspaceIndex else { return nil }
        return draft.workspaces[index]
    }

    func issue(at path: String) -> ValidationIssue? {
        issues.first { $0.path == path }
    }

    func issues(withPrefix prefix: String) -> [ValidationIssue] {
        issues.filter { $0.path.hasPrefix(prefix) }
    }

    func workspacePath(_ workspaceID: UUID) -> String? {
        guard let index = draft.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return nil }
        return "workspaces[\(index)]"
    }

    func servicePath(workspaceID: UUID, serviceID: UUID) -> String? {
        guard let workspaceIndex = draft.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let serviceIndex = draft.workspaces[workspaceIndex].services.firstIndex(where: { $0.id == serviceID })
        else { return nil }
        return "workspaces[\(workspaceIndex)].services[\(serviceIndex)]"
    }

    func isLocked(_ workspaceID: UUID) -> Bool {
        workspaceLocked(workspaceID)
    }

    func selectWorkspace(_ id: UUID) {
        showsPreferences = false
        selectedWorkspaceID = id
    }

    func selectPreferences() {
        showsPreferences = true
        selectedWorkspaceID = nil
    }

    func addWorkspace() async {
        guard let directory = await directoryPicker.chooseDirectory() else { return }
        let workspace = WorkspaceConfig(
            name: directory.lastPathComponent,
            rootDirectory: directory.standardizedFileURL.path,
            iconSymbol: "terminal.fill",
            tintHex: "#FF7A59",
            environment: [],
            services: []
        )
        draft.workspaces.append(workspace)
        selectWorkspace(workspace.id)
        revalidate()
    }

    func updateWorkspace(_ workspace: WorkspaceConfig) {
        guard let index = draft.workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        draft.workspaces[index] = workspace
        revalidate()
    }

    func chooseWorkspaceRoot(_ workspaceID: UUID) async {
        guard !isLocked(workspaceID),
              let index = draft.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let directory = await directoryPicker.chooseDirectory()
        else { return }
        draft.workspaces[index].rootDirectory = directory.standardizedFileURL.path
        revalidate()
    }

    func deleteWorkspace(_ workspaceID: UUID) {
        guard !isLocked(workspaceID),
              let index = draft.workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return }
        draft.workspaces.remove(at: index)
        selectedWorkspaceID = draft.workspaces.indices.contains(index)
            ? draft.workspaces[index].id
            : draft.workspaces.last?.id
        revalidate()
    }

    func moveWorkspaces(fromOffsets: IndexSet, toOffset: Int) {
        draft.workspaces.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func moveServices(workspaceID: UUID, fromOffsets: IndexSet, toOffset: Int) {
        guard let index = draft.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
        draft.workspaces[index].services.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func beginAddingService(workspaceID: UUID) {
        guard draft.workspaces.contains(where: { $0.id == workspaceID }) else { return }
        serviceEditor = ServiceEditorDraft(
            serviceID: nil,
            service: ServiceConfig(
                name: "新服务",
                workingDirectory: .relative("."),
                command: "",
                includeInStartAll: true
            )
        )
    }

    func beginEditingService(workspaceID: UUID, serviceID: UUID) {
        guard let workspace = draft.workspaces.first(where: { $0.id == workspaceID }),
              let service = workspace.services.first(where: { $0.id == serviceID })
        else { return }
        serviceEditor = ServiceEditorDraft(serviceID: serviceID, service: service)
    }

    func chooseServiceDirectory(workspaceID: UUID) async {
        guard !isLocked(workspaceID), var editor = serviceEditor,
              let root = draft.workspaces.first(where: { $0.id == workspaceID })?.rootDirectory,
              let directory = await directoryPicker.chooseDirectory()
        else { return }
        editor.service.workingDirectory = Self.workingDirectory(for: directory, workspaceRoot: root)
        serviceEditor = editor
    }

    func commitServiceEditor(workspaceID: UUID) {
        guard let workspaceIndex = draft.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let editor = serviceEditor
        else { return }
        if let serviceID = editor.serviceID,
           let serviceIndex = draft.workspaces[workspaceIndex].services.firstIndex(where: { $0.id == serviceID }) {
            draft.workspaces[workspaceIndex].services[serviceIndex] = editor.service
        } else {
            draft.workspaces[workspaceIndex].services.append(editor.service)
        }
        revalidate()
    }

    func deleteService(workspaceID: UUID, serviceID: UUID) {
        guard !isLocked(workspaceID),
              let workspaceIndex = draft.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let serviceIndex = draft.workspaces[workspaceIndex].services.firstIndex(where: { $0.id == serviceID })
        else { return }
        draft.workspaces[workspaceIndex].services.remove(at: serviceIndex)
        revalidate()
    }

    func checkConfiguration() async -> Bool {
        notice = .checking
        issues = validator.validate(draft)
        guard issues.isEmpty else {
            notice = .failure("请修正 \(issues.count) 个配置问题。")
            return false
        }

        let zshPath = draft.preferences.shellPath.isEmpty ? "/bin/zsh" : draft.preferences.shellPath
        for workspace in draft.workspaces {
            for service in workspace.services {
                if case let .invalid(message) = await syntaxCheckAction(zshPath, service.command) {
                    let path = servicePath(workspaceID: workspace.id, serviceID: service.id) ?? "services"
                    issues.append(.init(path: "\(path).command", code: .emptyCommand, message: message))
                }
            }
        }
        guard issues.isEmpty else {
            notice = .failure("启动命令未通过 zsh 语法检查。")
            return false
        }
        notice = .success("配置检查通过，未启动任何服务。")
        return true
    }

    func refreshShell() async {
        let path = draft.preferences.shellPath.isEmpty ? "/bin/zsh" : draft.preferences.shellPath
        do {
            try await shellRefreshAction(path)
            refreshedShellPath = path
            notice = .success("Shell 环境已刷新。")
        } catch {
            refreshedShellPath = nil
            notice = .failure(error.localizedDescription)
        }
    }

    func save() async {
        guard !isSaving else { return }
        if draft.preferences.shellPath != baseline.preferences.shellPath {
            let expected = draft.preferences.shellPath.isEmpty ? "/bin/zsh" : draft.preferences.shellPath
            guard refreshedShellPath == expected else {
                notice = .failure("zsh 路径已改变，请先刷新 Shell 环境。")
                return
            }
        }
        guard await checkConfiguration() else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await commitAction(baseline, draft)
            baseline = draft
            notice = .success("配置已保存。")
        } catch {
            notice = .failure(error.localizedDescription)
        }
    }

    func cancel() {
        draft = baseline
        selectedWorkspaceID = draft.workspaces.first?.id
        showsPreferences = false
        serviceEditor = nil
        issues = []
        notice = nil
        refreshedShellPath = nil
    }

    private func revalidate() {
        issues = validator.validate(draft)
    }

    private static func workingDirectory(for selectedURL: URL, workspaceRoot: String) -> WorkingDirectory {
        let selected = selectedURL.standardizedFileURL
        let root = URL(fileURLWithPath: workspaceRoot, isDirectory: true).standardizedFileURL
        if selected.path == root.path { return .relative(".") }
        if selected.path.hasPrefix(root.path + "/") {
            return .relative(String(selected.path.dropFirst(root.path.count + 1)))
        }
        return .absolute(selected.path)
    }
}
