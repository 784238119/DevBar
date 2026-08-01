import Foundation
import XCTest
@testable import DevBarCore

final class WorkspaceDetectorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "DevBarWorkspaceDetectorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDetectsPreferredPackageScriptWithoutExecutingIt() throws {
        let package = #"{"name":"web-app","scripts":{"build":"dangerous","dev":"vite","start":"node server.js"}}"#
        try Data(package.utf8).write(to: root.appending(path: "package.json"))

        let result = WorkspaceDetector.detectSynchronously(in: root)

        XCTAssertEqual(result.services.count, 1)
        XCTAssertEqual(result.services[0].service.name, "web-app")
        XCTAssertEqual(result.services[0].service.command, "npm run dev")
        XCTAssertEqual(result.services[0].service.workingDirectory, .relative("."))
        XCTAssertEqual(result.services[0].source, "package.json")
    }

    func testDetectsOneLevelModulesAndComposeButSkipsNodeModules() throws {
        let api = root.appending(path: "api", directoryHint: .isDirectory)
        let ignored = root.appending(path: "node_modules/ignored", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try Data("<plugin><artifactId>spring-boot-maven-plugin</artifactId></plugin>".utf8)
            .write(to: api.appending(path: "pom.xml"))
        try Data(#"{"scripts":{"dev":"vite"}}"#.utf8).write(to: ignored.appending(path: "package.json"))
        try Data().write(to: root.appending(path: "compose.yml"))

        let result = WorkspaceDetector.detectSynchronously(in: root)

        XCTAssertEqual(result.services.map(\.service.name), ["api", "Compose"])
        XCTAssertEqual(result.services.map(\.service.command), ["mvn spring-boot:run", "docker compose up"])
        XCTAssertEqual(result.services[0].service.workingDirectory, .relative("api"))
        XCTAssertFalse(result.services[1].service.includeInStartAll)
    }

    func testPrefersExecutableBuildWrappers() throws {
        try Data("<artifactId>spring-boot-maven-plugin</artifactId>".utf8)
            .write(to: root.appending(path: "pom.xml"))
        let wrapper = root.appending(path: "mvnw")
        try Data("#!/bin/sh\n".utf8).write(to: wrapper)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let result = WorkspaceDetector.detectSynchronously(in: root)

        XCTAssertEqual(result.services.map(\.service.command), ["./mvnw spring-boot:run"])
    }

    func testPlainMavenAndGradleBuildFilesDoNotProduceSpringBootCommands() throws {
        try Data("<project><artifactId>library</artifactId></project>".utf8)
            .write(to: root.appending(path: "pom.xml"))
        try Data("plugins { java }".utf8)
            .write(to: root.appending(path: "build.gradle.kts"))

        let result = WorkspaceDetector.detectSynchronously(in: root)

        XCTAssertTrue(result.services.isEmpty)
    }

    func testGradleBootRunRequiresSpringBootPluginEvidence() throws {
        try Data(#"plugins { id("org.springframework.boot") version "3.5.0" }"#.utf8)
            .write(to: root.appending(path: "build.gradle.kts"))

        let result = WorkspaceDetector.detectSynchronously(in: root)

        XCTAssertEqual(result.services.map(\.service.command), ["gradle bootRun"])
    }
}
