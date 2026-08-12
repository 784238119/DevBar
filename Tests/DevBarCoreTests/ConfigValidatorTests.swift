import Foundation
import XCTest
@testable import DevBarCore

final class ConfigValidatorTests: XCTestCase {
    private var rootURL: URL!

    override func setUpWithError() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevBar-ConfigValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootURL.appending(path: "service"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: rootURL)
    }

    func testRejectsInvalidFieldsInStableWorkspaceServiceFieldOrder() {
        var config = validConfig()
        config.workspaces[0].name = "  "
        config.workspaces[0].rootDirectory = rootURL.appending(path: "missing").path
        config.workspaces[0].iconSymbol = "face.smiling.inverse"
        config.workspaces[0].tintHex = "#000000"
        config.workspaces[0].environment = [
            .init(key: "1TOKEN", value: "a"),
            .init(key: "MODE", value: "a"),
            .init(key: "MODE", value: "b")
        ]
        config.workspaces[0].services[0].name = ""
        config.workspaces[0].services[0].workingDirectory = .relative("../escape")
        config.workspaces[0].services[0].command = "  "
        config.workspaces[0].services[0].environment = [
            .init(key: "BAD-KEY", value: "x"),
            .init(key: "PORT", value: "3000"),
            .init(key: "PORT", value: "3001")
        ]
        config.workspaces[0].services[0].healthCheck = .tcp(host: "127.0.0.1", port: 65_536)
        config.preferences = .init(
            shellPath: rootURL.path,
            logFileSizeMiB: 0,
            logFileCount: 11,
            sigintGraceSeconds: 61,
            sigtermGraceSeconds: 0
        )

        let issues = ConfigValidator(fileManager: .default).validate(config)

        XCTAssertEqual(
            issues.map(\.code),
            [
                .invalidZshPath,
                .invalidPreferenceRange, .invalidPreferenceRange, .invalidPreferenceRange, .invalidPreferenceRange,
                .emptyWorkspaceName, .invalidRootDirectory, .invalidIconSymbol, .invalidTintHex,
                .invalidEnvironmentKey, .duplicateEnvironmentKey,
                .emptyServiceName, .invalidWorkingDirectory, .emptyCommand,
                .invalidEnvironmentKey, .duplicateEnvironmentKey, .invalidTCPPort
            ]
        )
        XCTAssertEqual(issues.map(\.path), [
            "preferences.shellPath",
            "preferences.logFileSizeMiB", "preferences.logFileCount", "preferences.sigintGraceSeconds", "preferences.sigtermGraceSeconds",
            "workspaces[0].name", "workspaces[0].rootDirectory", "workspaces[0].iconSymbol", "workspaces[0].tintHex",
            "workspaces[0].environment[0].key", "workspaces[0].environment[2].key",
            "workspaces[0].services[0].name", "workspaces[0].services[0].workingDirectory", "workspaces[0].services[0].command",
            "workspaces[0].services[0].environment[0].key", "workspaces[0].services[0].environment[2].key", "workspaces[0].services[0].healthCheck.port"
        ])
    }

    func testRejectsHTTPURLWithUnsupportedScheme() {
        var config = validConfig()
        config.workspaces[0].services[0].healthCheck = .http(URL(string: "ftp://localhost/status")!)

        let issues = ConfigValidator(fileManager: .default).validate(config)

        XCTAssertEqual(issues.map(\.code), [.invalidHTTPURL])
        XCTAssertEqual(issues.first?.path, "workspaces[0].services[0].healthCheck.url")
    }

    func testRejectsLogViewerEntryLimitAboveMaximum() {
        var config = validConfig()
        config.preferences.logViewerEntryLimit = 10_001

        let issues = ConfigValidator(fileManager: .default).validate(config)

        XCTAssertEqual(issues.map(\.path), ["preferences.logViewerEntryLimit"])
        XCTAssertEqual(issues.map(\.code), [.invalidPreferenceRange])
    }

    func testValidConfigurationHasNoIssues() {
        XCTAssertTrue(ConfigValidator(fileManager: .default).validate(validConfig()).isEmpty)
    }

    func testWorkspaceMayUseInitialInsteadOfIcon() {
        var config = validConfig()
        config.workspaces[0].iconSymbol = ""

        XCTAssertFalse(
            ConfigValidator(fileManager: .default)
                .validate(config)
                .contains(where: { $0.code == .invalidIconSymbol })
        )
    }

    func testEverySelectableTintIsValid() {
        for tint in ConfigValidator.selectableTintHexes {
            var config = validConfig()
            config.workspaces[0].tintHex = tint

            XCTAssertFalse(
                ConfigValidator(fileManager: .default)
                    .validate(config)
                    .contains(where: { $0.code == .invalidTintHex }),
                "\(tint) is selectable in the UI and must pass validation"
            )
        }
    }

    func testLegacyTintRemainsValid() {
        for tint in ["#FF6B58", "#FF7A59"] {
            var config = validConfig()
            config.workspaces[0].tintHex = tint

            XCTAssertFalse(
                ConfigValidator(fileManager: .default)
                    .validate(config)
                    .contains(where: { $0.code == .invalidTintHex }),
                "\(tint) was used by an earlier DevBar release and must remain valid"
            )
        }
    }

    private func validConfig() -> AppConfig {
        AppConfig(
            workspaces: [
                WorkspaceConfig(
                    name: "Workspace",
                    rootDirectory: rootURL.path,
                    iconSymbol: "terminal.fill",
                    tintHex: "#FF7A59",
                    environment: [],
                    services: [
                        ServiceConfig(
                            name: "Service",
                            workingDirectory: .relative("service"),
                            command: "npm run dev",
                            includeInStartAll: true,
                            environment: [],
                            healthCheck: .none
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
    }
}
