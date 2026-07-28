import Foundation
import XCTest
@testable import DevBarCore

final class DeletionCoordinatorTests: XCTestCase {
    func testServiceDeletionTrashesOnlyExactUUIDDerivedDirectoryBeforeSaving() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createServiceLogs()
        let recorder = OperationRecorder()
        let trasher = RecordingTrasher(recorder: recorder)
        let store = RecordingConfigurationStore(recorder: recorder)
        let coordinator = DeletionCoordinator(paths: fixture.paths, trasher: trasher, configurationStore: store)

        let result = try await coordinator.delete(
            .service(workspaceID: fixture.workspaceID, serviceID: fixture.serviceID),
            from: fixture.configuration
        )

        let expectedTarget = fixture.paths.logsRootURL
            .appendingPathComponent(fixture.workspaceID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(fixture.serviceID.uuidString.lowercased(), isDirectory: true)
            .standardizedFileURL
        let operations = await recorder.operations
        XCTAssertEqual(operations, [.trash(expectedTarget), .save])
        guard case let .deleted(configuration) = result else {
            return XCTFail("Expected successful deletion, got \(result)")
        }
        XCTAssertTrue(configuration.workspaces[0].services.isEmpty)
        XCTAssertNotEqual(expectedTarget, fixture.paths.logsRootURL)
    }

    func testMissingLogDirectoryIsSuccessAndStillSavesConfiguration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let recorder = OperationRecorder()
        let trasher = RecordingTrasher(recorder: recorder)
        let store = RecordingConfigurationStore(recorder: recorder)
        let coordinator = DeletionCoordinator(paths: fixture.paths, trasher: trasher, configurationStore: store)

        let result = try await coordinator.delete(
            .service(workspaceID: fixture.workspaceID, serviceID: fixture.serviceID),
            from: fixture.configuration
        )

        let operations = await recorder.operations
        XCTAssertEqual(operations, [.save])
        guard case .deleted = result else { return XCTFail("Expected deletion when logs are absent") }
    }

    func testTrashFailureDoesNotSaveConfiguration() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createServiceLogs()
        let recorder = OperationRecorder()
        let trasher = RecordingTrasher(recorder: recorder, failure: "Trash unavailable")
        let store = RecordingConfigurationStore(recorder: recorder)
        let coordinator = DeletionCoordinator(paths: fixture.paths, trasher: trasher, configurationStore: store)

        let result = try await coordinator.delete(
            .service(workspaceID: fixture.workspaceID, serviceID: fixture.serviceID),
            from: fixture.configuration
        )

        let operations = await recorder.operations
        XCTAssertEqual(operations.count, 1)
        guard case let .trashFailed(original, message) = result else {
            return XCTFail("Expected trash failure, got \(result)")
        }
        XCTAssertEqual(original, fixture.configuration)
        XCTAssertTrue(message.contains("kept the configuration unchanged"))
    }

    func testSaveFailureAfterTrashReportsLogsRecoverableAndKeepsOriginalLiveConfig() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createServiceLogs()
        let recorder = OperationRecorder()
        let trasher = RecordingTrasher(recorder: recorder)
        let store = RecordingConfigurationStore(recorder: recorder, failure: "disk full")
        let coordinator = DeletionCoordinator(paths: fixture.paths, trasher: trasher, configurationStore: store)

        let result = try await coordinator.delete(
            .service(workspaceID: fixture.workspaceID, serviceID: fixture.serviceID),
            from: fixture.configuration
        )

        guard case let .configurationSaveFailed(original, proposed, recovery, message) = result else {
            return XCTFail("Expected save failure, got \(result)")
        }
        XCTAssertEqual(original, fixture.configuration)
        XCTAssertTrue(proposed.workspaces[0].services.isEmpty)
        XCTAssertEqual(recovery, .recoverableFromTrash)
        XCTAssertTrue(message.contains("restored from Trash"))
    }

    func testSymlinkedServiceLogDirectoryIsRejectedWithoutTrashOrSave() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let workspaceLogs = fixture.workspaceLogsURL
        try FileManager.default.createDirectory(at: workspaceLogs, withIntermediateDirectories: true)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.serviceLogsURL, withDestinationURL: outside)
        let recorder = OperationRecorder()
        let coordinator = DeletionCoordinator(
            paths: fixture.paths,
            trasher: RecordingTrasher(recorder: recorder),
            configurationStore: RecordingConfigurationStore(recorder: recorder)
        )

        do {
            _ = try await coordinator.delete(
                .service(workspaceID: fixture.workspaceID, serviceID: fixture.serviceID),
                from: fixture.configuration
            )
            XCTFail("Expected unsafe symlink rejection")
        } catch let error as DeletionCoordinatorError {
            guard case .unsafeLogPath = error else { return XCTFail("Unexpected error \(error)") }
        }
        let operations = await recorder.operations
        XCTAssertTrue(operations.isEmpty)
    }

    func testSymlinkedLogsRootIsRejectedEvenWhenTargetWouldAppearMissing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(at: fixture.paths.applicationSupport, withIntermediateDirectories: true)
        let outside = fixture.root.appendingPathComponent("outside-root", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.paths.logsRootURL, withDestinationURL: outside)
        let recorder = OperationRecorder()
        let coordinator = DeletionCoordinator(
            paths: fixture.paths,
            trasher: RecordingTrasher(recorder: recorder),
            configurationStore: RecordingConfigurationStore(recorder: recorder)
        )

        do {
            _ = try await coordinator.delete(
                .workspace(workspaceID: fixture.workspaceID),
                from: fixture.configuration
            )
            XCTFail("Expected unsafe logs root rejection")
        } catch let error as DeletionCoordinatorError {
            guard case .unsafeLogPath = error else { return XCTFail("Unexpected error \(error)") }
        }
        let operations = await recorder.operations
        XCTAssertTrue(operations.isEmpty)
    }

    func testWorkspaceDeletionUsesOnlyWorkspaceUUIDDirectory() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.createServiceLogs()
        let recorder = OperationRecorder()
        let coordinator = DeletionCoordinator(
            paths: fixture.paths,
            trasher: RecordingTrasher(recorder: recorder),
            configurationStore: RecordingConfigurationStore(recorder: recorder)
        )

        let result = try await coordinator.delete(
            .workspace(workspaceID: fixture.workspaceID),
            from: fixture.configuration
        )

        let operations = await recorder.operations
        XCTAssertEqual(operations.first, .trash(fixture.workspaceLogsURL.standardizedFileURL))
        guard case let .deleted(configuration) = result else { return XCTFail("Expected workspace deletion") }
        XCTAssertTrue(configuration.workspaces.isEmpty)
    }

    func testPreparingMultipleServiceRemovalsTrashesAllLogsWithoutPersistingIntermediateConfig() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let secondServiceID = UUID()
        var original = fixture.configuration
        original.workspaces[0].services.append(
            ServiceConfig(
                id: secondServiceID,
                name: "Second",
                workingDirectory: .absolute(fixture.root.path),
                command: "echo second"
            )
        )
        try fixture.createServiceLogs()
        let secondLogs = fixture.workspaceLogsURL
            .appendingPathComponent(secondServiceID.uuidString.lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: secondLogs, withIntermediateDirectories: true)
        var proposed = original
        proposed.workspaces[0].services = []

        let recorder = OperationRecorder()
        let coordinator = DeletionCoordinator(
            paths: fixture.paths,
            trasher: RecordingTrasher(recorder: recorder),
            configurationStore: RecordingConfigurationStore(recorder: recorder)
        )

        let movedCount = try await coordinator.prepareConfigurationChanges(
            from: original,
            to: proposed
        )

        XCTAssertEqual(movedCount, 2)
        let operations = await recorder.operations
        XCTAssertEqual(
            operations,
            [
                .trash(fixture.serviceLogsURL.standardizedFileURL),
                .trash(secondLogs.standardizedFileURL)
            ]
        )
        XCTAssertFalse(operations.contains(.save))
    }
}

private final class Fixture {
    let root: URL
    let paths: AppPaths
    let workspaceID = UUID()
    let serviceID = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        paths = AppPaths(applicationSupport: root.appendingPathComponent("Application Support/DevBar", isDirectory: true))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var workspaceLogsURL: URL {
        paths.logsRootURL.appendingPathComponent(workspaceID.uuidString.lowercased(), isDirectory: true)
    }

    var serviceLogsURL: URL {
        workspaceLogsURL.appendingPathComponent(serviceID.uuidString.lowercased(), isDirectory: true)
    }

    var configuration: AppConfig {
        AppConfig(
            workspaces: [WorkspaceConfig(
                id: workspaceID,
                name: "Workspace",
                rootDirectory: root.path,
                iconSymbol: "terminal.fill",
                tintHex: "#FF7A59",
                environment: [],
                services: [ServiceConfig(
                    id: serviceID,
                    name: "Service",
                    workingDirectory: .absolute(root.path),
                    command: "echo test"
                )]
            )],
            preferences: .default
        )
    }

    func createServiceLogs() throws {
        try FileManager.default.createDirectory(at: serviceLogsURL, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum RecordedOperation: Equatable, Sendable {
    case trash(URL)
    case save
}

private actor OperationRecorder {
    private(set) var operations: [RecordedOperation] = []

    func append(_ operation: RecordedOperation) {
        operations.append(operation)
    }
}

private actor RecordingTrasher: Trashing {
    private let recorder: OperationRecorder
    private let failure: String?

    init(recorder: OperationRecorder, failure: String? = nil) {
        self.recorder = recorder
        self.failure = failure
    }

    func moveToTrash(_ url: URL) async throws {
        await recorder.append(.trash(url.standardizedFileURL))
        if let failure {
            throw NSError(domain: "DeletionTests.Trash", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }
    }
}

private actor RecordingConfigurationStore: ConfigurationPersisting {
    private let recorder: OperationRecorder
    private let failure: String?

    init(recorder: OperationRecorder, failure: String? = nil) {
        self.recorder = recorder
        self.failure = failure
    }

    func persist(_ configuration: AppConfig) async throws {
        await recorder.append(.save)
        if let failure {
            throw NSError(domain: "DeletionTests.Save", code: 1, userInfo: [NSLocalizedDescriptionKey: failure])
        }
    }
}
