import XCTest

@MainActor
final class MenuBarFlowUITests: XCTestCase {
    nonisolated(unsafe) private var temporaryURLs: [URL] = []

    override func tearDownWithError() throws {
        for url in temporaryURLs {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryURLs.removeAll()
    }

    func testFirstLaunchOpensSettingsThenShowsEmptyMenuCTA() throws {
        let app = try launch(configurationJSON: Self.emptyConfiguration)

        XCTAssertTrue(app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["添加第一个工作区"].exists)
        app.buttons["取消"].click()

        XCTAssertTrue(app.descendants(matching: .any)["menu.panel"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["尚未配置工作区"].exists)
        XCTAssertTrue(app.buttons["添加工作区"].exists)
    }

    func testConfiguredWorkspaceShowsServicesAndStartAll() throws {
        let app = try launch(configurationJSON: Self.museCubeConfiguration)

        XCTAssertTrue(app.descendants(matching: .any)["menu.panel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "MuseCube")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Web"].exists)
        XCTAssertTrue(app.staticTexts["Server"].exists)
        XCTAssertTrue(app.buttons["启动全部"].exists)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "DevBar Menu Panel"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testNoAutoStartOrLoginItemCopyIsVisible() throws {
        let app = try launch(configurationJSON: Self.museCubeConfiguration)
        XCTAssertTrue(app.descendants(matching: .any)["menu.panel"].waitForExistence(timeout: 3))

        for forbidden in ["开机自启", "登录启动"] {
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", forbidden)).firstMatch.exists)
        }
    }

    func testSettingsWorkspaceAndServiceEditorAreUsable() throws {
        let app = try launch(configurationJSON: Self.museCubeConfiguration)
        XCTAssertTrue(app.buttons["menu.openSettings"].waitForExistence(timeout: 3))
        app.buttons["menu.openSettings"].click()

        XCTAssertTrue(app.descendants(matching: .any)["settings.root"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.textFields.matching(NSPredicate(format: "value == %@", "MuseCube")).firstMatch.exists)
        XCTAssertTrue(app.buttons["service.add"].exists)
        app.buttons["service.add"].click()
        XCTAssertTrue(app.descendants(matching: .any)["service.editor"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["命令通过非交互 zsh 在前台运行"].exists)
    }

    func testLogsWindowOpensFromMenu() throws {
        let app = try launch(configurationJSON: Self.museCubeConfiguration)
        XCTAssertTrue(app.buttons["menu.openLogs"].waitForExistence(timeout: 3))
        app.buttons["menu.openLogs"].click()

        XCTAssertTrue(app.descendants(matching: .any)["logs.window"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["服务日志"].exists)
        XCTAssertTrue(app.staticTexts["暂无日志"].exists)
    }

    private func launch(configurationJSON: String) throws -> XCUIApplication {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevBarUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryURLs.append(root)
        let configURL = root.appendingPathComponent("fixture.json")
        try Data(configurationJSON.utf8).write(to: configURL)

        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launchEnvironment["DEVBAR_TEST_ROOT"] = root.path
        app.launchEnvironment["DEVBAR_TEST_CONFIG"] = configURL.path
        app.launch()
        app.activate()
        return app
    }

    private static let emptyConfiguration = """
    {
      "schemaVersion": 1,
      "workspaces": [],
      "preferences": {
        "shellPath": "",
        "logFileSizeMiB": 5,
        "logFileCount": 3,
        "sigintGraceSeconds": 8,
        "sigtermGraceSeconds": 3
      }
    }
    """

    private static let museCubeConfiguration = """
    {
      "schemaVersion": 1,
      "workspaces": [
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "name": "MuseCube",
          "rootDirectory": "/tmp",
          "iconSymbol": "terminal.fill",
          "tintHex": "#FF6B58",
          "environment": [],
          "services": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "name": "Web",
              "workingDirectory": { "kind": "relative", "path": "." },
              "command": "npm run dev",
              "includeInStartAll": true,
              "environment": [],
              "healthCheck": { "kind": "none" }
            },
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "name": "Server",
              "workingDirectory": { "kind": "relative", "path": "." },
              "command": "mvn spring-boot:run",
              "includeInStartAll": true,
              "environment": [],
              "healthCheck": { "kind": "none" }
            }
          ]
        }
      ],
      "preferences": {
        "shellPath": "",
        "logFileSizeMiB": 5,
        "logFileCount": 3,
        "sigintGraceSeconds": 8,
        "sigtermGraceSeconds": 3
      }
    }
    """
}
