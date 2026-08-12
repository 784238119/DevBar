import Foundation
import XCTest
@testable import DevBarCore

final class AppConfigTests: XCTestCase {
    func testAppConfigRoundTripsRelativeAndAbsoluteDirectories() throws {
        let config = AppConfig(
            workspaces: [
                WorkspaceConfig(
                    id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                    name: "Local APIs",
                    rootDirectory: "/tmp/devbar-workspace",
                    iconSymbol: "terminal.fill",
                    tintHex: "#FF7A59",
                    environment: [.init(key: "MODE", value: "development")],
                    services: [
                        ServiceConfig(
                            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                            name: "Web",
                            workingDirectory: .relative("web"),
                            command: "npm run dev",
                            includeInStartAll: true,
                            environment: [.init(key: "PORT", value: "3000")],
                            healthCheck: .http(URL(string: "http://127.0.0.1:3000/health")!)
                        ),
                        ServiceConfig(
                            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                            name: "API",
                            workingDirectory: .absolute("/tmp/devbar-api"),
                            command: "./gradlew bootRun",
                            includeInStartAll: false,
                            environment: [],
                            healthCheck: .tcp(host: "127.0.0.1", port: 8080)
                        )
                    ]
                )
            ],
            preferences: .init(
                shellPath: "/bin/zsh",
                logFileSizeMiB: 5,
                logFileCount: 3,
                sigintGraceSeconds: 8,
                sigtermGraceSeconds: 3
            )
        )

        let data = try JSONEncoder().encode(config)
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: data), config)
        XCTAssertEqual(config.schemaVersion, 1)
    }

    func testEmptyConfigUsesDocumentedDefaults() {
        XCTAssertEqual(AppConfig.empty.schemaVersion, 1)
        XCTAssertTrue(AppConfig.empty.workspaces.isEmpty)
        XCTAssertEqual(
            AppConfig.empty.preferences,
            .init(shellPath: "", logFileSizeMiB: 5, logFileCount: 3, sigintGraceSeconds: 8, sigtermGraceSeconds: 3)
        )
        XCTAssertEqual(
            AppConfig.empty.preferences.logViewerEntryLimit,
            PreferencesConfig.defaultLogViewerEntryLimit
        )
        XCTAssertEqual(AppConfig.empty.preferences.logRetentionDays, 7)
    }

    func testLegacyPreferencesUseDefaultLogViewerEntryLimit() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "workspaces": [],
            "preferences": [
                "shellPath": "",
                "logFileSizeMiB": 5,
                "logFileCount": 3,
                "sigintGraceSeconds": 8,
                "sigtermGraceSeconds": 3
            ]
        ])

        let config = try JSONDecoder().decode(AppConfig.self, from: data)

        XCTAssertEqual(
            config.preferences.logViewerEntryLimit,
            PreferencesConfig.defaultLogViewerEntryLimit
        )
        XCTAssertEqual(config.preferences.logRetentionDays, PreferencesConfig.defaultLogRetentionDays)
    }

    func testDecodingFutureSchemaIsRejected() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "workspaces": [],
            "preferences": [
                "shellPath": "",
                "logFileSizeMiB": 5,
                "logFileCount": 3,
                "sigintGraceSeconds": 8,
                "sigtermGraceSeconds": 3
            ]
        ])

        XCTAssertThrowsError(try JSONDecoder().decode(AppConfig.self, from: data)) { error in
            XCTAssertEqual(error as? AppConfigDecodingError, .unsupportedSchemaVersion(2))
        }
    }
}
