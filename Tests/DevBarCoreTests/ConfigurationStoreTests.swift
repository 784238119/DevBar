import Foundation
import XCTest
@testable import DevBarCore

final class ConfigurationStoreTests: XCTestCase {
    private var testRoot: URL!
    private var paths: AppPaths!

    override func setUpWithError() throws {
        testRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevBar-ConfigurationStoreTests-\(UUID().uuidString)", isDirectory: true)
        paths = AppPaths(applicationSupport: testRoot.appending(path: "Application Support/DevBar", directoryHint: .isDirectory))
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: testRoot.path) {
            try FileManager.default.removeItem(at: testRoot)
        }
    }

    func testFirstSaveCreatesConfigWithPrivatePermissions() async throws {
        let store = ConfigurationStore(paths: paths)
        try await store.save(config(named: "First"))

        let loaded = try await store.load()
        XCTAssertEqual(loaded, config(named: "First"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.configURL.path))
        XCTAssertEqual(try permissions(at: paths.applicationSupport), 0o700)
        XCTAssertEqual(try permissions(at: paths.configURL), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.backupConfigURL.path))
        XCTAssertTrue(paths.applicationSupport.path.hasPrefix(testRoot.path))
    }

    func testSecondSaveKeepsPreviousValidConfigAsBackup() async throws {
        let store = ConfigurationStore(paths: paths)
        let first = config(named: "First")
        let second = config(named: "Second")
        try await store.save(first)
        try await store.save(second)

        let loaded = try await store.load()
        XCTAssertEqual(loaded, second)
        let backupData = try Data(contentsOf: paths.backupConfigURL)
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: backupData), first)
        XCTAssertEqual(try permissions(at: paths.backupConfigURL), 0o600)
    }

    func testCorruptPrimaryIsPreservedAndBackupIsRecovered() async throws {
        let store = ConfigurationStore(paths: paths)
        let backup = config(named: "Backup")
        try await store.save(backup)
        try await store.save(config(named: "Current"))
        let corruptBytes = Data("{ definitely not JSON".utf8)
        try corruptBytes.write(to: paths.configURL)

        let recovered = try await store.loadResult()
        XCTAssertEqual(recovered.configuration, backup)
        guard case let .backup(preservedCorruptURL) = recovered.source else {
            return XCTFail("Expected backup recovery diagnostics")
        }

        let siblings = try FileManager.default.contentsOfDirectory(at: paths.applicationSupport, includingPropertiesForKeys: nil)
        let corruptCopy = try XCTUnwrap(siblings.first { $0.lastPathComponent.hasPrefix("config.json.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: corruptCopy), corruptBytes)
        XCTAssertEqual(try permissions(at: corruptCopy), 0o600)
        XCTAssertEqual(
            preservedCorruptURL.resolvingSymlinksInPath(),
            corruptCopy.resolvingSymlinksInPath()
        )
    }

    func testSaveOverCorruptPrimaryPreservesOriginalBytesBeforeReplacement() async throws {
        let store = ConfigurationStore(paths: paths)
        try FileManager.default.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)
        let corruptBytes = Data("not valid configuration".utf8)
        try corruptBytes.write(to: paths.configURL)

        try await store.save(config(named: "Replacement"))

        let loaded = try await store.load()
        XCTAssertEqual(loaded, config(named: "Replacement"))
        let siblings = try FileManager.default.contentsOfDirectory(at: paths.applicationSupport, includingPropertiesForKeys: nil)
        let corruptCopy = try XCTUnwrap(siblings.first { $0.lastPathComponent.hasPrefix("config.json.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: corruptCopy), corruptBytes)
        XCTAssertEqual(try permissions(at: corruptCopy), 0o600)
    }

    func testMissingConfigReturnsEmptyConfig() async throws {
        let store = ConfigurationStore(paths: paths)
        let loaded = try await store.loadResult()
        XCTAssertEqual(loaded.configuration, .empty)
        XCTAssertEqual(loaded.source, .empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.configURL.path))
    }

    func testFutureSchemaReturnsExplicitRecoveryError() async throws {
        let store = ConfigurationStore(paths: paths)
        try FileManager.default.createDirectory(at: paths.applicationSupport, withIntermediateDirectories: true)
        try Data("{\"schemaVersion\":2,\"workspaces\":[],\"preferences\":{\"shellPath\":\"\",\"logFileSizeMiB\":5,\"logFileCount\":3,\"sigintGraceSeconds\":8,\"sigtermGraceSeconds\":3}}".utf8)
            .write(to: paths.configURL)

        do {
            _ = try await store.load()
            XCTFail("Expected an unsupported-schema error")
        } catch let error as ConfigurationStoreError {
            XCTAssertEqual(error, .unsupportedSchemaVersion(2))
        }
    }

    private func config(named name: String) -> AppConfig {
        AppConfig(
            workspaces: [
                WorkspaceConfig(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    name: name,
                    rootDirectory: testRoot.path,
                    iconSymbol: "terminal.fill",
                    tintHex: "#FF7A59",
                    environment: [],
                    services: []
                )
            ],
            preferences: .init(shellPath: "", logFileSizeMiB: 5, logFileCount: 3, sigintGraceSeconds: 8, sigtermGraceSeconds: 3)
        )
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}
