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

struct WorkspaceImportDraft: Identifiable, Equatable {
    let id = UUID()
    var workspace: WorkspaceConfig
    var candidates: [DetectedService]
    var selectedCandidateIDs: Set<UUID>
}

enum SettingsNotice: Equatable {
    case checking
    case success(String)
    case failure(String)
}

@MainActor
@Observable
final class SettingsViewModel {
    typealias CommitAction = @MainActor (_ event: ConfigurationEvent) async throws -> AppConfig
    typealias ShellRefreshAction = @MainActor (String) async throws -> Void
    typealias SyntaxCheckAction = @Sendable (String, String) async -> ShellSyntaxResult

    private(set) var baseline: AppConfig
    var draft: AppConfig
    var selectedWorkspaceID: UUID?
    var showsPreferences = false
    var serviceEditor: ServiceEditorDraft?
    var workspaceImport: WorkspaceImportDraft?
    private(set) var isDetectingWorkspace = false
    private(set) var issues: [ValidationIssue] = []
    private(set) var notice: SettingsNotice?
    private(set) var refreshedShellPath: String?
    private(set) var isSaving = false

    let directoryPicker: any DirectoryPicking
    private let validator: ConfigValidator
    private let commitAction: CommitAction
    private let shellRefreshAction: ShellRefreshAction
    private let syntaxCheckAction: SyntaxCheckAction
    private let workspaceDetector: any WorkspaceDetecting
    private let workspaceLocked: @MainActor (UUID) -> Bool
    private let logDirectoryLocked: @MainActor () -> Bool
    @ObservationIgnored private var configurationEventGeneration: UInt64 = 0
    @ObservationIgnored private var pendingConfigurationEventCount = 0

    init(
        configuration: AppConfig,
        directoryPicker: (any DirectoryPicking)? = nil,
        validator: ConfigValidator = ConfigValidator(),
        workspaceLocked: @escaping @MainActor (UUID) -> Bool = { _ in false },
        logDirectoryLocked: @escaping @MainActor () -> Bool = { false },
        commit: @escaping CommitAction,
        refreshShell: @escaping ShellRefreshAction,
        checkSyntax: SyntaxCheckAction? = nil,
        workspaceDetector: any WorkspaceDetecting = WorkspaceDetector()
    ) {
        baseline = configuration
        draft = configuration
        selectedWorkspaceID = configuration.workspaces.first?.id
        self.directoryPicker = directoryPicker ?? NSOpenPanelDirectoryPicker()
        self.validator = validator
        self.workspaceLocked = workspaceLocked
        self.logDirectoryLocked = logDirectoryLocked
        commitAction = commit
        shellRefreshAction = refreshShell
        syntaxCheckAction = checkSyntax ?? { zshPath, command in
            await ShellSyntaxChecker(zshPath: zshPath.isEmpty ? "/bin/zsh" : zshPath).check(command: command)
        }
        self.workspaceDetector = workspaceDetector
    }

    var hasUnsavedChanges: Bool { draft != baseline }
    var isLogDirectoryLocked: Bool { logDirectoryLocked() }
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
    }

    func leavePreferences() {
        if let selectedWorkspaceID,
           draft.workspaces.contains(where: { $0.id == selectedWorkspaceID }) {
            showsPreferences = false
            return
        }
        selectedWorkspaceID = draft.workspaces.first?.id
        showsPreferences = false
    }

    func synchronize(with configuration: AppConfig) {
        guard pendingConfigurationEventCount == 0, draft == baseline else { return }
        let currentSelection = selectedWorkspaceID
        baseline = configuration
        draft = configuration
        selectedWorkspaceID = currentSelection.flatMap { selectedID in
            configuration.workspaces.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? configuration.workspaces.first?.id
    }

    func addWorkspace() async {
        guard let directory = await directoryPicker.chooseDirectory() else { return }
        isDetectingWorkspace = true
        defer { isDetectingWorkspace = false }
        let result = await workspaceDetector.detect(in: directory)
        let workspace = WorkspaceConfig(
            name: directory.lastPathComponent,
            rootDirectory: result.rootDirectory,
            iconSymbol: "terminal.fill",
            tintHex: "#FF7A59",
            environment: [],
            services: []
        )
        workspaceImport = WorkspaceImportDraft(
            workspace: workspace,
            candidates: result.services,
            selectedCandidateIDs: Set(result.services.map(\.id))
        )
    }

    func cancelWorkspaceImport() {
        workspaceImport = nil
    }

    @discardableResult
    func confirmWorkspaceImport(_ importDraft: WorkspaceImportDraft) async -> Bool {
        var workspace = importDraft.workspace
        workspace.services = importDraft.candidates
            .filter { importDraft.selectedCandidateIDs.contains($0.id) }
            .map(\.service)
        draft.workspaces.append(workspace)
        selectWorkspace(workspace.id)
        let committed = await commitWorkspace(workspace.id)
        if committed {
            workspaceImport = nil
        }
        return committed
    }

    func updateWorkspace(_ workspace: WorkspaceConfig) async {
        guard let index = draft.workspaces.firstIndex(where: { $0.id == workspace.id }) else { return }
        draft.workspaces[index] = workspace
        await commitWorkspace(workspace.id)
    }

    func chooseWorkspaceRoot(_ workspaceID: UUID) async {
        guard let index = draft.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let directory = await directoryPicker.chooseDirectory()
        else { return }
        draft.workspaces[index].rootDirectory = directory.standardizedFileURL.path
        await commitWorkspace(workspaceID)
    }

    func chooseLogDirectory() async {
        guard !logDirectoryLocked() else {
            setNotice(.failure("仍有服务正在运行，请全部停止后再切换日志目录。"))
            return
        }
        guard let directory = await directoryPicker.chooseDirectory() else { return }
        draft.preferences.logDirectory = directory.standardizedFileURL.path
        await commitPreferences()
    }

    func deleteWorkspace(_ workspaceID: UUID) async {
        guard !isLocked(workspaceID),
              let index = draft.workspaces.firstIndex(where: { $0.id == workspaceID })
        else { return }
        draft.workspaces.remove(at: index)
        selectedWorkspaceID = draft.workspaces.indices.contains(index)
            ? draft.workspaces[index].id
            : draft.workspaces.last?.id
        await commitEvent(.removeWorkspace(workspaceID), validationIssues: [])
    }

    func moveWorkspaces(fromOffsets: IndexSet, toOffset: Int) async {
        draft.workspaces.move(fromOffsets: fromOffsets, toOffset: toOffset)
        await commitEvent(
            .reorderWorkspaces(draft.workspaces.map(\.id)),
            validationIssues: []
        )
    }

    func moveService(
        workspaceID: UUID,
        serviceID: UUID,
        relativeTo targetServiceID: UUID,
        placeAfterTarget: Bool
    ) async {
        guard serviceID != targetServiceID,
              let workspaceIndex = draft.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let sourceIndex = draft.workspaces[workspaceIndex].services.firstIndex(where: { $0.id == serviceID }),
              let originalTargetIndex = draft.workspaces[workspaceIndex].services.firstIndex(
                  where: { $0.id == targetServiceID }
              )
        else { return }

        let service = draft.workspaces[workspaceIndex].services.remove(at: sourceIndex)
        let targetIndex = originalTargetIndex - (sourceIndex < originalTargetIndex ? 1 : 0)
        let insertionIndex = targetIndex + (placeAfterTarget ? 1 : 0)
        draft.workspaces[workspaceIndex].services.insert(service, at: insertionIndex)
        await commitWorkspace(workspaceID)
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

    func chooseServiceDirectory(
        workspaceID: UUID,
        for service: ServiceConfig
    ) async -> ServiceConfig {
        guard let root = draft.workspaces.first(where: { $0.id == workspaceID })?.rootDirectory,
              let directory = await directoryPicker.chooseDirectory()
        else { return service }
        var updated = service
        updated.workingDirectory = Self.workingDirectory(for: directory, workspaceRoot: root)
        return updated
    }

    @discardableResult
    func commitServiceEditor(
        workspaceID: UUID,
        draft editor: ServiceEditorDraft
    ) async -> Bool {
        guard let workspaceIndex = draft.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            setNotice(.failure("服务所属工作区已不存在，无法保存。"))
            return false
        }
        if let serviceID = editor.serviceID {
            guard let serviceIndex = draft.workspaces[workspaceIndex].services.firstIndex(
                where: { $0.id == serviceID }
            ) else {
                setNotice(.failure("原服务已不存在，无法保存本次编辑。"))
                return false
            }
            draft.workspaces[workspaceIndex].services[serviceIndex] = editor.service
        } else {
            draft.workspaces[workspaceIndex].services.append(editor.service)
        }
        return await commitWorkspace(workspaceID)
    }

    func endServiceEditing() {
        serviceEditor = nil
    }

    func deleteService(workspaceID: UUID, serviceID: UUID) async {
        guard !isLocked(workspaceID),
              let workspaceIndex = draft.workspaces.firstIndex(where: { $0.id == workspaceID }),
              let serviceIndex = draft.workspaces[workspaceIndex].services.firstIndex(where: { $0.id == serviceID })
        else { return }
        draft.workspaces[workspaceIndex].services.remove(at: serviceIndex)
        await commitWorkspace(workspaceID)
    }

    @discardableResult
    func commitWorkspace(_ workspaceID: UUID) async -> Bool {
        guard let index = draft.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return false
        }
        let workspace = draft.workspaces[index]
        let workspaceIssues = validator.validateWorkspace(
            workspace,
            at: "workspaces[\(index)]"
        )
        return await commitEvent(
            .upsertWorkspace(workspace),
            validationIssues: workspaceIssues
        )
    }

    @discardableResult
    func commitPreferences() async -> Bool {
        if draft.preferences.logDirectory != baseline.preferences.logDirectory,
           logDirectoryLocked() {
            draft.preferences.logDirectory = baseline.preferences.logDirectory
            setNotice(.failure("仍有服务正在运行，请全部停止后再切换日志目录。"))
            return false
        }
        return await commitEvent(
            .updatePreferences(draft.preferences),
            validationIssues: validator.validatePreferences(draft.preferences)
        )
    }

    @discardableResult
    func commitWorkspaceEnvironment(
        workspaceID: UUID,
        entries: [EnvironmentEntry]
    ) async -> Bool {
        guard let index = draft.workspaces.firstIndex(where: { $0.id == workspaceID }) else {
            return false
        }
        draft.workspaces[index].environment = entries
        return await commitWorkspace(workspaceID)
    }

    func checkConfiguration() async -> Bool {
        setNotice(.checking)
        issues = validator.validate(draft)
        guard issues.isEmpty else {
            setNotice(.failure("请修正 \(issues.count) 个配置问题。"))
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
            setNotice(.failure("启动命令未通过 zsh 语法检查。"))
            return false
        }
        setNotice(.success("配置检查通过，未启动任何服务。"))
        return true
    }

    func refreshShell() async {
        let path = draft.preferences.shellPath.isEmpty ? "/bin/zsh" : draft.preferences.shellPath
        do {
            try await shellRefreshAction(path)
            refreshedShellPath = path
            if await commitPreferences() {
                setNotice(.success("Shell 环境已刷新并保存。"))
            }
        } catch {
            refreshedShellPath = nil
            setNotice(.failure(error.localizedDescription))
        }
    }

    func discardUnsavedChanges() {
        let currentSelection = selectedWorkspaceID
        draft = baseline
        selectedWorkspaceID = currentSelection.flatMap { selectedID in
            draft.workspaces.contains(where: { $0.id == selectedID }) ? selectedID : nil
        } ?? draft.workspaces.first?.id
        serviceEditor = nil
        issues = []
        setNotice(nil)
        refreshedShellPath = nil
    }

    @discardableResult
    private func commitEvent(
        _ event: ConfigurationEvent,
        validationIssues: [ValidationIssue]
    ) async -> Bool {
        issues = validationIssues
        guard validationIssues.isEmpty else {
            draft = baseline
            issues = []
            normalizeSelection()
            setNotice(.failure("输入无效，已恢复上次配置。"))
            return false
        }

        configurationEventGeneration &+= 1
        let generation = configurationEventGeneration
        pendingConfigurationEventCount += 1
        isSaving = true
        defer {
            pendingConfigurationEventCount -= 1
            isSaving = pendingConfigurationEventCount > 0
        }
        do {
            let committed = try await commitAction(event)
            baseline = committed
            if generation == configurationEventGeneration {
                draft = committed
            }
            issues = []
            normalizeSelection()
            setNotice(nil)
            return true
        } catch {
            if generation == configurationEventGeneration {
                draft = baseline
            }
            normalizeSelection()
            setNotice(.failure(error.localizedDescription))
            return false
        }
    }

    private func normalizeSelection() {
        guard let selectedWorkspaceID,
              !draft.workspaces.contains(where: { $0.id == selectedWorkspaceID })
        else { return }
        self.selectedWorkspaceID = draft.workspaces.first?.id
    }

    private func setNotice(_ newValue: SettingsNotice?) {
        notice = newValue
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
