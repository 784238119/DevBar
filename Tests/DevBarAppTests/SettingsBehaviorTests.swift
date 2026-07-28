import DevBarCore
import XCTest
@testable import DevBar

@MainActor
final class SettingsBehaviorTests: XCTestCase {
    func testSelectingPreferencesPreservesWorkspaceSelection() {
        let workspace = makeWorkspace()
        let viewModel = makeViewModel(workspaces: [workspace])

        viewModel.selectPreferences()

        XCTAssertTrue(viewModel.showsPreferences)
        XCTAssertEqual(viewModel.selectedWorkspaceID, workspace.id)
    }

    func testLeavingPreferencesRestoresExistingWorkspace() {
        let workspace = makeWorkspace()
        let viewModel = makeViewModel(workspaces: [workspace])
        viewModel.selectPreferences()

        viewModel.leavePreferences()

        XCTAssertFalse(viewModel.showsPreferences)
        XCTAssertEqual(viewModel.selectedWorkspaceID, workspace.id)
    }

    func testDiscardingChangesRestoresBaselineAndStaysInPreferences() {
        let workspace = makeWorkspace()
        let viewModel = makeViewModel(workspaces: [workspace])
        viewModel.selectPreferences()
        viewModel.draft.workspaces[0].name = "Changed"
        viewModel.draft.preferences.logFileCount = 9

        viewModel.discardUnsavedChanges()

        XCTAssertEqual(viewModel.draft.workspaces[0].name, "Workspace")
        XCTAssertEqual(viewModel.draft.preferences.logFileCount, PreferencesConfig.default.logFileCount)
        XCTAssertTrue(viewModel.showsPreferences)
        XCTAssertEqual(viewModel.selectedWorkspaceID, workspace.id)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testDiscardingChangesFallsBackWhenSelectionNoLongerExists() {
        let first = makeWorkspace()
        let second = makeWorkspace()
        let viewModel = makeViewModel(workspaces: [first, second])
        viewModel.selectedWorkspaceID = UUID()
        viewModel.draft.workspaces[0].name = "Changed"

        viewModel.discardUnsavedChanges()

        XCTAssertEqual(viewModel.selectedWorkspaceID, first.id)
        XCTAssertFalse(viewModel.hasUnsavedChanges)
    }

    func testEndingEditorDiscardsUncommittedChanges() throws {
        let service = makeService(command: "original")
        let workspace = makeWorkspace(services: [service])
        let viewModel = makeViewModel(workspaces: [workspace])
        viewModel.beginEditingService(workspaceID: workspace.id, serviceID: service.id)
        var editor = try XCTUnwrap(viewModel.serviceEditor)
        editor.service.command = "replacement"

        viewModel.endServiceEditing()

        XCTAssertNil(viewModel.serviceEditor)
        XCTAssertEqual(viewModel.draft.workspaces[0].services[0].command, "original")
    }

    func testCommittingEditorUpdatesExactlyOneService() async throws {
        let service = makeService(command: "original")
        let workspace = makeWorkspace(services: [service])
        let viewModel = makeViewModel(workspaces: [workspace])
        viewModel.beginEditingService(workspaceID: workspace.id, serviceID: service.id)
        var editor = try XCTUnwrap(viewModel.serviceEditor)
        editor.service.command = "replacement"

        let committed = await viewModel.commitServiceEditor(
            workspaceID: workspace.id,
            draft: editor
        )
        XCTAssertTrue(committed)
        XCTAssertEqual(
            viewModel.draft.workspaces[0].services.map(\.command),
            ["replacement"]
        )
    }

    func testCommitFailsSafelyWhenWorkspaceDisappears() async throws {
        let service = makeService(command: "original")
        let workspace = makeWorkspace(services: [service])
        let viewModel = makeViewModel(workspaces: [workspace])
        viewModel.beginEditingService(workspaceID: workspace.id, serviceID: service.id)
        let editor = try XCTUnwrap(viewModel.serviceEditor)
        await viewModel.deleteWorkspace(workspace.id)

        let committed = await viewModel.commitServiceEditor(
            workspaceID: workspace.id,
            draft: editor
        )
        XCTAssertFalse(committed)
        XCTAssertEqual(viewModel.draft.workspaces, [])
    }

    func testSuccessfulEventDoesNotShowSaveNotice() async {
        let viewModel = SettingsViewModel(
            configuration: AppConfig(workspaces: [], preferences: .default),
            commit: { event in
                self.apply(event, to: AppConfig(workspaces: [], preferences: .default))
            },
            refreshShell: { _ in }
        )
        viewModel.draft.preferences.logFileCount += 1

        await viewModel.commitPreferences()

        XCTAssertNil(viewModel.notice)
    }

    func testRunningServicePreventsLogDirectoryChange() async {
        let original = AppConfig(workspaces: [], preferences: .default)
        let viewModel = SettingsViewModel(
            configuration: original,
            logDirectoryLocked: { true },
            commit: { _ in
                XCTFail("Locked log directory must not be committed.")
                return original
            },
            refreshShell: { _ in }
        )
        viewModel.draft.preferences.logDirectory = "/tmp/another-log-root"

        let committed = await viewModel.commitPreferences()

        XCTAssertFalse(committed)
        XCTAssertEqual(
            viewModel.draft.preferences.logDirectory,
            PreferencesConfig.defaultLogDirectory
        )
        guard case .failure = viewModel.notice else {
            return XCTFail("Expected a running-service failure notice.")
        }
    }

    func testFailedWorkspaceEventRollsBackOnlyThatEvent() async {
        let workspace = makeWorkspace()
        let viewModel = SettingsViewModel(
            configuration: AppConfig(workspaces: [workspace], preferences: .default),
            commit: { _ in throw SettingsTestError.persistence },
            refreshShell: { _ in }
        )
        viewModel.draft.workspaces[0].name = "Unsaved"

        let committed = await viewModel.commitWorkspace(workspace.id)

        XCTAssertFalse(committed)
        XCTAssertEqual(viewModel.draft.workspaces[0].name, "Workspace")
        XCTAssertEqual(viewModel.baseline.workspaces[0].name, "Workspace")
        guard case .failure = viewModel.notice else {
            return XCTFail("Expected a persistence failure notice")
        }
    }

    func testSelectingCurrentPaletteTintCommitsWithoutRollback() async {
        let workspace = makeWorkspace()
        let viewModel = makeViewModel(workspaces: [workspace])
        guard let tint = ConfigValidator.selectableTintHexes.first else {
            return XCTFail("The selectable tint palette must not be empty")
        }
        viewModel.draft.workspaces[0].tintHex = tint

        let committed = await viewModel.commitWorkspace(workspace.id)

        XCTAssertTrue(committed)
        XCTAssertEqual(viewModel.draft.workspaces[0].tintHex, tint)
        XCTAssertEqual(viewModel.baseline.workspaces[0].tintHex, tint)
        XCTAssertNil(viewModel.notice)
    }

    func testDraggingServiceDownPlacesItAfterTarget() async {
        let first = makeService(command: "first")
        let second = makeService(command: "second")
        let third = makeService(command: "third")
        let workspace = makeWorkspace(services: [first, second, third])
        let viewModel = makeViewModel(workspaces: [workspace])

        await viewModel.moveService(
            workspaceID: workspace.id,
            serviceID: first.id,
            relativeTo: second.id,
            placeAfterTarget: true
        )

        XCTAssertEqual(
            viewModel.draft.workspaces[0].services.map(\.command),
            ["second", "first", "third"]
        )
    }

    func testDraggingServiceUpPlacesItBeforeTarget() async {
        let first = makeService(command: "first")
        let second = makeService(command: "second")
        let third = makeService(command: "third")
        let workspace = makeWorkspace(services: [first, second, third])
        let viewModel = makeViewModel(workspaces: [workspace])

        await viewModel.moveService(
            workspaceID: workspace.id,
            serviceID: third.id,
            relativeTo: first.id,
            placeAfterTarget: false
        )

        XCTAssertEqual(
            viewModel.draft.workspaces[0].services.map(\.command),
            ["third", "first", "second"]
        )
    }

    func testStatusItemSymbolsPreserveBrandAndStateMeaning() {
        XCTAssertEqual(statusItemSymbol(for: .neutral), "hammer")
        XCTAssertEqual(statusItemSymbol(for: .working), "hammer.fill")
        XCTAssertEqual(statusItemSymbol(for: .ready), "checkmark.circle.fill")
        XCTAssertEqual(statusItemSymbol(for: .error), "exclamationmark.triangle.fill")
    }

    private func makeViewModel(workspaces: [WorkspaceConfig]) -> SettingsViewModel {
        var configuration = AppConfig(workspaces: workspaces, preferences: .default)
        return SettingsViewModel(
            configuration: configuration,
            commit: { event in
                configuration = self.apply(event, to: configuration)
                return configuration
            },
            refreshShell: { _ in }
        )
    }

    private func makeWorkspace(services: [ServiceConfig] = []) -> WorkspaceConfig {
        WorkspaceConfig(
            name: "Workspace",
            rootDirectory: "/tmp",
            iconSymbol: "hammer.fill",
            tintHex: "#FF7A59",
            environment: [],
            services: services
        )
    }

    private func makeService(command: String) -> ServiceConfig {
        ServiceConfig(
            name: "Service",
            workingDirectory: .relative("."),
            command: command
        )
    }

    private func apply(_ event: ConfigurationEvent, to configuration: AppConfig) -> AppConfig {
        var result = configuration
        switch event {
        case let .upsertWorkspace(workspace):
            if let index = result.workspaces.firstIndex(where: { $0.id == workspace.id }) {
                result.workspaces[index] = workspace
            } else {
                result.workspaces.append(workspace)
            }
        case let .removeWorkspace(workspaceID):
            result.workspaces.removeAll { $0.id == workspaceID }
        case let .reorderWorkspaces(ids):
            let byID = Dictionary(uniqueKeysWithValues: result.workspaces.map { ($0.id, $0) })
            result.workspaces = ids.compactMap { byID[$0] }
        case let .updatePreferences(preferences):
            result.preferences = preferences
        }
        return result
    }
}

private enum SettingsTestError: Error {
    case persistence
}
