# DevBar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Finder-launchable native macOS menu-bar app that configures, starts, monitors, logs, and safely stops local zsh-based development services grouped into workspaces.

**Architecture:** An XcodeGen-generated Xcode project contains the SwiftUI `DevBar` app, static `DevBarCore` and `DevBarRunnerKit` libraries, an embedded `DevBarRunner` command-line helper, unit-test bundles, and a UI-test bundle. The app owns configuration, state, health checks, and logs; one Runner per service owns the foreground zsh process group and cleans it up when the GUI control pipe closes.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Foundation, Network, XCTest/XCUITest, Xcode 26.6, XcodeGen as a development-only project generator.

## Global Constraints

- Minimum deployment target: macOS 15.0; verify the release build on the current Apple Silicon macOS 26 machine.
- Runtime dependencies: Apple frameworks only; XcodeGen is development-only.
- Pin XcodeGen to a declared minimum version in `project.yml`; keep the generated `DevBar.xcodeproj` committed so the project can be opened without regenerating it.
- Shell support: executable zsh only; default to `$SHELL` when it resolves to zsh, otherwise `/bin/zsh`.
- No App Sandbox, login item, launch agent, service auto-start, notification center, automatic restart, dependency ordering, custom stop command, import/export, cloud sync, or secret storage.
- Runtime commands are non-interactive, receive `/dev/null` as stdin, have no TTY, and must remain in the Runner-owned process group.
- Configuration path: `~/Library/Application Support/DevBar/config.json`; retain one `config.json.bak`.
- Log path: `~/Library/Application Support/DevBar/Logs/<workspace-id>/<service-id>/`; default rotation is 5 MiB × 3 files and the UI keeps 2,000 lines.
- Stop sequence: `SIGINT` with an 8-second default grace period, `SIGTERM` with a 3-second default grace period, then `SIGKILL`.
- HTTP health checks accept 200–399; TCP checks require a successful connection; poll every 2 seconds with a 1-second timeout and no overlapping probe.
- UI must match `docs/superpowers/specs/assets/devbar-menubar-warm-prism.png` and `docs/superpowers/specs/assets/devbar-settings-warm-prism-v2.png`.
- Deleting DevBar configuration must never delete project directories or project files.
- Tests must use isolated temporary Application Support roots and must never read or change the user's real DevBar configuration.

---

## File Structure

```text
Brewfile
.gitignore
project.yml
Configuration/
  DevBar-Info.plist
Sources/
  DevBarApp/
    DevBarApp.swift
    AppDelegate.swift
    AppDependencies.swift
    Theme/DevBarTheme.swift
    ViewModels/SettingsViewModel.swift
    ViewModels/LogViewModel.swift
    Views/MenuBar/MenuBarPanel.swift
    Views/MenuBar/WorkspaceCardView.swift
    Views/MenuBar/ServiceRowView.swift
    Views/Settings/SettingsRootView.swift
    Views/Settings/WorkspaceSettingsView.swift
    Views/Settings/ServiceEditorSheet.swift
    Views/Settings/PreferencesView.swift
    Views/Logs/LogWindowView.swift
  DevBarCore/
    Models/AppConfig.swift
    Models/ServiceState.swift
    Paths/AppPaths.swift
    Paths/Trashing.swift
    Configuration/ConfigValidator.swift
    Configuration/ConfigurationStore.swift
    Shell/ZshResolver.swift
    Shell/ShellEnvironmentProvider.swift
    Shell/ShellSyntaxChecker.swift
    Shell/EnvironmentMerger.swift
    Runtime/RunnerProtocol.swift
    Runtime/RunnerClient.swift
    Runtime/ProcessSupervisor.swift
    Health/HealthChecker.swift
    Logging/UTF8StreamDecoder.swift
    Logging/LogSanitizer.swift
    Logging/RotatingLogWriter.swift
    Logging/LogStore.swift
    State/AppState.swift
  DevBarRunnerKit/
    PosixSpawner.swift
    ProcessGroupTerminator.swift
    RunnerChannel.swift
    RunnerSession.swift
  DevBarRunner/
    main.swift
Resources/
  Assets.xcassets/
    Contents.json
  AppIcon-master.png
Scripts/
  build-release.sh
  make-app-icon.sh
  verify-app.sh
Fixtures/
  Acceptance/
    npm/package.json
    npm/server.mjs
    java/EchoServer.java
Tests/
  DevBarCoreTests/
  DevBarRunnerKitTests/
  DevBarUITests/
README.md
```

`DevBarCore` owns product behavior and remains UI-independent. `DevBarRunnerKit` owns POSIX-only process behavior. `DevBarApp` owns presentation and dependency composition. Tests mirror these boundaries.

---

### Task 1: Reproducible Xcode Project and Embedded Helper Skeleton

**Files:**
- Create: `Brewfile`
- Create: `.gitignore`
- Create: `project.yml`
- Create: `Configuration/DevBar-Info.plist`
- Create: `Sources/DevBarCore/DevBarCore.swift`
- Create: `Sources/DevBarRunnerKit/DevBarRunnerKit.swift`
- Create: `Sources/DevBarApp/DevBarApp.swift`
- Create: `Sources/DevBarRunner/main.swift`
- Create: `Resources/Assets.xcassets/Contents.json`
- Create: `Tests/DevBarCoreTests/ProjectSmokeTests.swift`
- Create: `Tests/DevBarRunnerKitTests/ProjectSmokeTests.swift`
- Create: `Tests/DevBarUITests/ProjectSmokeUITests.swift`
- Generate and commit: `DevBar.xcodeproj`

**Interfaces:**
- Produces: Xcode schemes `DevBar`, `DevBarCoreTests`, `DevBarRunnerKitTests`, and `DevBarUITests`.
- Produces: built helper at `DevBar.app/Contents/Helpers/DevBarRunner`.

- [ ] **Step 1: Declare the development tool and ignored artifacts**

```ruby
# Brewfile
brew "xcodegen"
```

```gitignore
.DS_Store
DerivedData/
build/
*.xcresult
xcuserdata/
```

- [ ] **Step 2: Install XcodeGen and record the version**

Run: `brew bundle`

Expected: `xcodegen --version` exits 0. Record the installed version in the implementation task commentary; do not add XcodeGen as a runtime dependency.

- [ ] **Step 3: Create the target graph in `project.yml`**

Use these target names and relationships:

```yaml
name: DevBar
options:
  bundleIdPrefix: com.calo
  minimumXcodeGenVersion: "2.46.0"
  deploymentTarget:
    macOS: "15.0"
settings:
  base:
    SWIFT_VERSION: "6.0"
    MACOSX_DEPLOYMENT_TARGET: "15.0"
targets:
  DevBarCore:
    type: library.static
    platform: macOS
    sources: [Sources/DevBarCore]
  DevBarRunnerKit:
    type: library.static
    platform: macOS
    sources: [Sources/DevBarRunnerKit]
    dependencies:
      - target: DevBarCore
  DevBarRunner:
    type: tool
    platform: macOS
    sources: [Sources/DevBarRunner]
    dependencies:
      - target: DevBarCore
      - target: DevBarRunnerKit
  DevBar:
    type: application
    platform: macOS
    sources: [Sources/DevBarApp]
    resources: [Resources]
    info:
      path: Configuration/DevBar-Info.plist
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.calo.DevBar
        CODE_SIGN_STYLE: Manual
        CODE_SIGN_IDENTITY: "-"
    dependencies:
      - target: DevBarCore
      - target: DevBarRunner
        embed: false
        link: false
    postBuildScripts:
      - name: Embed DevBarRunner
        inputFiles:
          - "$(BUILT_PRODUCTS_DIR)/DevBarRunner"
        script: |
          set -euo pipefail
          helper_dir="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
          mkdir -p "${helper_dir}"
          cp -f "${BUILT_PRODUCTS_DIR}/DevBarRunner" "${helper_dir}/DevBarRunner"
          chmod 755 "${helper_dir}/DevBarRunner"
        outputFiles:
          - "$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Helpers/DevBarRunner"
  DevBarCoreTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/DevBarCoreTests]
    dependencies:
      - target: DevBarCore
  DevBarRunnerKitTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/DevBarRunnerKitTests]
    dependencies:
      - target: DevBarCore
      - target: DevBarRunnerKit
  DevBarUITests:
    type: bundle.ui-testing
    platform: macOS
    sources: [Tests/DevBarUITests]
    settings:
      base:
        TEST_TARGET_NAME: DevBar
    dependencies:
      - target: DevBar
schemes:
  DevBar:
    build:
      targets:
        DevBar: all
        DevBarRunner: all
    test:
      targets:
        - DevBarCoreTests
        - DevBarRunnerKitTests
        - DevBarUITests
```

- [ ] **Step 4: Create a menu-bar-only app plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key><string>DevBar</string>
  <key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
  <key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$(MACOSX_DEPLOYMENT_TARGET)</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
```

- [ ] **Step 5: Add compile-only entry points**

```swift
// Sources/DevBarApp/DevBarApp.swift
import SwiftUI

@main
struct DevBarApp: App {
    var body: some Scene {
        MenuBarExtra("DevBar", systemImage: "terminal.fill") {
            Text("DevBar")
        }
        .menuBarExtraStyle(.window)
    }
}
```

```swift
// Sources/DevBarRunner/main.swift
import Foundation

FileHandle.standardError.write(Data("DevBarRunner skeleton\n".utf8))
```

Create a valid empty asset catalog `Contents.json` and one `XCTestCase` smoke test in each test target. Each smoke test imports its production module where applicable and asserts `true`; this verifies target/module wiring before behavior tests replace the scaffolding.

- [ ] **Step 6: Generate and verify the project**

Run:

```bash
xcodegen generate
xcodebuild -project DevBar.xcodeproj -scheme DevBar -destination 'platform=macOS' -derivedDataPath DerivedData build
```

Expected: `** BUILD SUCCEEDED **`.

Run: `test -x DerivedData/Build/Products/Debug/DevBar.app/Contents/Helpers/DevBarRunner`

Expected: exit 0.

- [ ] **Step 7: Commit the scaffold**

```bash
git add Brewfile .gitignore project.yml Configuration Sources Tests DevBar.xcodeproj
git commit -m "build: scaffold DevBar app and runner targets"
```

---

### Task 2: Versioned Configuration Domain, Validation, and Atomic Persistence

**Files:**
- Create: `Sources/DevBarCore/Models/AppConfig.swift`
- Create: `Sources/DevBarCore/Paths/AppPaths.swift`
- Create: `Sources/DevBarCore/Configuration/ConfigValidator.swift`
- Create: `Sources/DevBarCore/Configuration/ConfigurationStore.swift`
- Create: `Tests/DevBarCoreTests/AppConfigTests.swift`
- Create: `Tests/DevBarCoreTests/ConfigValidatorTests.swift`
- Create: `Tests/DevBarCoreTests/ConfigurationStoreTests.swift`

**Interfaces:**
- Produces: `AppConfig`, `WorkspaceConfig`, `ServiceConfig`, `WorkingDirectory`, `EnvironmentEntry`, `HealthCheckConfig`, and `PreferencesConfig`.
- Produces: `ConfigValidator.validate(_:) -> [ValidationIssue]`.
- Produces: `actor ConfigurationStore` with `load()` and `save(_:)`; deletion is a validated draft save coordinated with log trashing in Task 10.
- Produces: `AppPaths` with injected Application Support root.

- [ ] **Step 1: Write failing model round-trip tests**

```swift
func testAppConfigRoundTripsRelativeAndAbsoluteDirectories() throws {
    let config = AppConfig.sampleForTests
    let data = try JSONEncoder().encode(config)
    XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: data), config)
    XCTAssertEqual(config.schemaVersion, 1)
}
```

Run: `xcodebuild test -project DevBar.xcodeproj -scheme DevBar -destination 'platform=macOS' -only-testing:DevBarCoreTests/AppConfigTests`

Expected: FAIL because the configuration types do not exist.

- [ ] **Step 2: Implement the exact configuration types**

```swift
public struct AppConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int = 1
    public var workspaces: [WorkspaceConfig]
    public var preferences: PreferencesConfig
}

public enum WorkingDirectory: Codable, Equatable, Sendable {
    case relative(String)
    case absolute(String)
}

public enum HealthCheckConfig: Codable, Equatable, Sendable {
    case none
    case http(URL)
    case tcp(host: String, port: Int)
}
```

Implement these configuration types without renaming or omitting fields:

```swift
public struct WorkspaceConfig: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var rootDirectory: String
    public var iconSymbol: String
    public var tintHex: String
    public var environment: [EnvironmentEntry]
    public var services: [ServiceConfig]
}

public struct ServiceConfig: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var workingDirectory: WorkingDirectory
    public var command: String
    public var includeInStartAll: Bool
    public var environment: [EnvironmentEntry]
    public var healthCheck: HealthCheckConfig
}

public struct EnvironmentEntry: Codable, Equatable, Sendable {
    public var key: String
    public var value: String
}

public struct PreferencesConfig: Codable, Equatable, Sendable {
    public var shellPath: String
    public var logFileSizeMiB: Int
    public var logFileCount: Int
    public var sigintGraceSeconds: Int
    public var sigtermGraceSeconds: Int
}
```

Use UUIDs and preserve array order. `AppConfig.empty` uses schema `1`, no workspaces, zsh resolved by Task 3, and defaults `5`, `3`, `8`, `3`.

- [ ] **Step 3: Write failing validation tests**

Cover empty names, missing/non-directory roots, relative paths containing `..`, duplicate environment keys, invalid environment names, unapproved SF Symbols/theme colors, HTTP schemes other than `http`/`https`, TCP ports outside `1...65535`, zsh path executability, and preference ranges.

```swift
func testRejectsEnvironmentKeyBeginningWithDigit() {
    let issues = ConfigValidator(fileManager: .default)
        .validate(.sampleWithEnvironmentKey("1TOKEN"))
    XCTAssertTrue(issues.contains { $0.code == .invalidEnvironmentKey })
}
```

- [ ] **Step 4: Implement deterministic validation**

```swift
public struct ValidationIssue: Equatable, Sendable {
    public enum Code: String, Sendable {
        case emptyWorkspaceName, invalidRootDirectory, invalidWorkingDirectory
        case emptyServiceName, emptyCommand, invalidEnvironmentKey
        case duplicateEnvironmentKey, invalidHTTPURL, invalidTCPPort
        case invalidZshPath, invalidPreferenceRange
    }
    public let path: String
    public let code: Code
    public let message: String
}
```

Return all issues in stable workspace/service/field order so the UI can anchor errors.

- [ ] **Step 5: Write failing atomic-save and backup-recovery tests**

Use a unique temporary directory. Verify:

- first save creates `config.json`;
- second save keeps the first value as `config.json.bak`;
- corrupt `config.json` loads `.bak` and preserves the corrupt bytes as a timestamped `.corrupt-*` sibling;
- an absent file returns `AppConfig.empty`;
- no test touches the real home directory.

- [ ] **Step 6: Implement `AppPaths` and `ConfigurationStore`**

```swift
public struct AppPaths: Sendable {
    public let applicationSupport: URL
    public var configURL: URL { applicationSupport.appending(path: "config.json") }
    public var backupConfigURL: URL { applicationSupport.appending(path: "config.json.bak") }
    public var logsRootURL: URL { applicationSupport.appending(path: "Logs") }
}

public actor ConfigurationStore {
    public init(paths: AppPaths, fileManager: FileManager = .default)
    public func load() throws -> AppConfig
    public func save(_ config: AppConfig) throws
}
```

Create the DevBar Application Support directory with mode `0700`. Encode sorted, pretty-printed JSON; write and synchronize a same-directory temporary file with mode `0600`. If the current main file decodes and has supported schema `1`, copy it to `config.json.bak.next`, synchronize it, atomically rename that copy over `.bak`, and only then atomically rename the new temporary file over the main file. Never move the current main file away before its replacement is ready. Reject unsupported future schema versions with an explicit recovery error instead of decoding them as version `1`.

- [ ] **Step 7: Run all configuration tests**

Run: `xcodebuild test -project DevBar.xcodeproj -scheme DevBar -destination 'platform=macOS' -only-testing:DevBarCoreTests`

Expected: all configuration tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/DevBarCore Tests/DevBarCoreTests
git commit -m "feat: add versioned workspace configuration"
```

---

### Task 3: Deterministic zsh Environment Capture and Command Validation

**Files:**
- Create: `Sources/DevBarCore/Shell/ShellCommandExecutor.swift`
- Create: `Sources/DevBarCore/Shell/ZshResolver.swift`
- Create: `Sources/DevBarCore/Shell/ShellEnvironmentProvider.swift`
- Create: `Sources/DevBarCore/Shell/ShellSyntaxChecker.swift`
- Create: `Sources/DevBarCore/Shell/EnvironmentMerger.swift`
- Create: `Tests/DevBarCoreTests/ShellEnvironmentProviderTests.swift`
- Create: `Tests/DevBarCoreTests/ZshResolverTests.swift`
- Create: `Tests/DevBarCoreTests/EnvironmentMergerTests.swift`

**Interfaces:**
- Produces: `ShellCommandExecuting.run(executable:arguments:environment:timeout:)`.
- Produces: `ZshResolver.resolve(environment:) throws -> ZshResolution`.
- Produces: `actor ShellEnvironmentProvider.refresh() async throws -> [String: String]`.
- Produces: `actor ShellEnvironmentProvider.cachedOrRefresh() async throws -> [String: String]`.
- Produces: `ShellSyntaxChecker.check(command:) async -> ShellSyntaxResult`.
- Produces: `EnvironmentMerger.merge(captured:workspace:service:)`.

- [ ] **Step 1: Write failing environment parser tests**

Feed bytes containing preamble text, `DEVBAR_ENV_BEGIN\0`, NUL-separated `KEY=value` entries, `DEVBAR_ENV_END\0`, and trailing text. Assert only entries between markers are returned and values containing `=` remain intact.

```swift
func testParserIgnoresZshrcOutputOutsideSentinels() throws {
    let bytes = Data("banner\nDEVBAR_ENV_BEGIN\0PATH=/opt/bin\0A=x=y\0DEVBAR_ENV_END\0".utf8)
    XCTAssertEqual(try ShellEnvironmentParser.parse(bytes), ["PATH": "/opt/bin", "A": "x=y"])
}
```

- [ ] **Step 2: Implement sentinel parsing and a timeout-capable executor**

The executor must launch the short-lived zsh in its own process group, collect stdout/stderr separately without deadlocking on full pipes, and terminate the whole group with `SIGTERM` then `SIGKILL` on timeout. It is only for environment capture and syntax checks, not long-lived services. The timeout test starts a child process and proves both parent and child are gone.

- [ ] **Step 3: Write failing zsh resolution and merge-precedence tests**

Verify `$SHELL` is accepted only when it is an executable regular file and `<candidate> --version` reports zsh. Verify a non-zsh `$SHELL` falls back to an executable `/bin/zsh` with a user-visible warning, while two invalid candidates return an error. Do not accept a directory or rely only on a filename suffix.

```swift
func testServiceOverridesWorkspaceAndCapturedEnvironment() {
    let merged = EnvironmentMerger.merge(
        captured: ["MODE": "shell", "PATH": "/bin"],
        workspace: [.init(key: "MODE", value: "workspace")],
        service: [.init(key: "MODE", value: "service")]
    )
    XCTAssertEqual(merged["MODE"], "service")
    XCTAssertEqual(merged["PATH"], "/bin")
}
```

- [ ] **Step 4: Implement capture and merge**

Invoke the validated zsh with:

```swift
["-l", "-i", "-c",
 "printf 'DEVBAR_ENV_BEGIN\\0'; /usr/bin/env -0; printf 'DEVBAR_ENV_END\\0'"]
```

Use a 5-second timeout. Cache only the last successful dictionary in memory. `cachedOrRefresh()` returns the cache or performs the first capture. A failed refresh returns an error and does not discard a previous successful cache; when no cache exists, service launch is blocked with the captured stderr and timeout guidance.

- [ ] **Step 5: Add command syntax checking**

Run zsh with `["-n", "-c", command]`. Return `.valid` for exit 0 and `.invalid(stderr)` otherwise. Never run the actual service command.

- [ ] **Step 6: Run focused and real-zsh integration tests**

Run:

```bash
xcodebuild test -project DevBar.xcodeproj -scheme DevBar -destination 'platform=macOS' \
  -only-testing:DevBarCoreTests/ShellEnvironmentProviderTests \
  -only-testing:DevBarCoreTests/EnvironmentMergerTests
```

Expected: parser, timeout, cache preservation, syntax, and precedence tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/DevBarCore/Shell Tests/DevBarCoreTests
git commit -m "feat: capture deterministic zsh environment"
```

---

### Task 4: Runner Protocol, POSIX Process Group, and Crash Cleanup

**Files:**
- Create: `Sources/DevBarCore/Runtime/RunnerProtocol.swift`
- Create: `Sources/DevBarRunnerKit/PosixSpawner.swift`
- Create: `Sources/DevBarRunnerKit/ProcessGroupTerminator.swift`
- Create: `Sources/DevBarRunnerKit/RunnerChannel.swift`
- Create: `Sources/DevBarRunnerKit/RunnerSession.swift`
- Modify: `Sources/DevBarRunner/main.swift`
- Create: `Tests/DevBarRunnerKitTests/RunnerProtocolTests.swift`
- Create: `Tests/DevBarRunnerKitTests/ProcessGroupTerminatorTests.swift`
- Create: `Tests/DevBarRunnerKitTests/RunnerSessionIntegrationTests.swift`

**Interfaces:**
- Produces: `RunnerLaunchRequest`, `RunnerCommand`, and `RunnerEvent`, all Codable/Sendable and carrying `runID`.
- Produces: `PosixSpawner.spawn(_:) -> SpawnedProcess`.
- Produces: `ProcessGroupTerminator.stop(pgid:grace:) async -> StopResult`.
- Produces: `RunnerSession.run() async -> Int32`.

- [ ] **Step 1: Write failing protocol round-trip tests**

```swift
func testRunnerEventsRoundTripAsOneJSONObjectPerLine() throws {
    let event = RunnerEvent.started(runID: UUID(), pid: 123, pgid: 456)
    let line = try RunnerCodec.encodeLine(event)
    XCTAssertEqual(try RunnerCodec.decodeLine(line, as: RunnerEvent.self), event)
}
```

- [ ] **Step 2: Implement the control messages**

```swift
public struct RunnerLaunchRequest: Codable, Equatable, Sendable {
    public let runID: UUID
    public let zshPath: String
    public let command: String
    public let workingDirectory: String
    public let environment: [String: String]
    public let sigintGraceSeconds: Int
    public let sigtermGraceSeconds: Int
}

public enum RunnerCommand: Codable, Equatable, Sendable {
    case stop(runID: UUID)
}

public enum RunnerEvent: Codable, Equatable, Sendable {
    case started(runID: UUID, pid: Int32, pgid: Int32)
    case stopPhase(runID: UUID, signal: Int32)
    case exited(runID: UUID, code: Int32?, signal: Int32?)
    case error(runID: UUID, message: String)
}
```

Use newline-delimited JSON only on command/event pipes. Keep service stdout/stderr as raw bytes on separate file descriptors.

Use this ownership table and close every unused end immediately after `spawn`; set `FD_CLOEXEC` on every descriptor that must not reach the managed zsh or its descendants:

| Channel | GUI owns | Runner owns | Payload |
|---|---|---|---|
| command | write end | read end | one launch line, then stop lines |
| event | read end | write end | `RunnerEvent` JSON lines |
| stdout | read end | write end | raw bytes |
| stderr | read end | write end | raw bytes |

The GUI write end must be the only surviving writer for the command pipe so a GUI crash deterministically produces EOF in Runner.

- [ ] **Step 3: Write a failing process-group integration test**

The test creates a temporary script that starts a foreground child, which starts a grandchild. Capture all PIDs, call the terminator, then assert `kill(pid, 0)` returns `ESRCH` for the shell, child, and grandchild.

- [ ] **Step 4: Implement POSIX spawning**

Use `posix_spawn_file_actions_*` to:

- set the working directory before execution;
- connect stdin to `/dev/null`;
- connect stdout/stderr to dedicated pipes.

Execute exactly `zshPath -c command` with the merged environment and no login/interactivity flags. Use `posix_spawnattr_setflags(..., POSIX_SPAWN_SETPGROUP)` and `posix_spawnattr_setpgroup(..., 0)` so the spawned zsh becomes a new process-group leader. The Runner must remain outside that group. Close unrelated control descriptors in the child file actions.

- [ ] **Step 5: Implement staged group termination**

```swift
public struct StopGrace: Equatable, Sendable {
    public let sigint: Duration
    public let sigterm: Duration
}

public enum StopResult: Equatable, Sendable {
    case exitedAfterInterrupt
    case exitedAfterTerminate
    case killed
    case alreadyExited
}
```

Signal with `kill(-pgid, signal)`, poll group existence without blocking the main actor, and emit the matching `stopPhase` event before each signal.

- [ ] **Step 6: Implement Runner EOF cleanup**

`RunnerSession` reads the launch request, starts zsh, forwards raw stdout/stderr, and waits concurrently for a stop command, child exit, or command-pipe EOF. EOF is ownership loss and must invoke the same staged stop sequence before Runner exits. Reap the direct child with `waitpid`; the test must also assert no zombie remains.

- [ ] **Step 7: Wire the helper executable**

`main.swift` maps the inherited file-descriptor numbers from launch arguments, constructs `RunnerSession`, and exits with its result. Reject missing/duplicate descriptors with an error event and nonzero exit.

- [ ] **Step 8: Run Runner tests**

Run: `xcodebuild test -project DevBar.xcodeproj -scheme DevBar -destination 'platform=macOS' -only-testing:DevBarRunnerKitTests`

Expected: protocol, process-tree, staged-signal, normal-exit, explicit-stop, and control-EOF tests pass with no surviving test processes.

- [ ] **Step 9: Commit**

```bash
git add Sources/DevBarCore/Runtime Sources/DevBarRunnerKit Sources/DevBarRunner Tests/DevBarRunnerKitTests
git commit -m "feat: add crash-safe service runner"
```

---

### Task 5: GUI Runner Client and Idempotent Service State Machine

**Files:**
- Create: `Sources/DevBarCore/Models/ServiceState.swift`
- Create: `Sources/DevBarCore/Runtime/RunnerClient.swift`
- Create: `Sources/DevBarCore/Runtime/ProcessSupervisor.swift`
- Create: `Tests/DevBarCoreTests/ProcessSupervisorTests.swift`
- Create: `Tests/DevBarCoreTests/RunnerClientIntegrationTests.swift`

**Interfaces:**
- Produces: `ServiceState`, `ServiceRuntime`, and `ServiceRuntimeEvent`.
- Produces: `RunnerControlling` protocol for test fakes.
- Produces: `actor ProcessSupervisor.start(service:workspace:)`, `stop(serviceID:)`, `startAll(workspace:)`, and `stopAll(workspaceID:)`.

- [ ] **Step 1: Write failing state-machine tests**

Cover:

- duplicate starts create one Runner;
- duplicate stops create one stop command;
- `.failed` may restart with a new `runID`;
- `startAll` includes only stopped services with `includeInStartAll`;
- one start failure does not stop siblings;
- stale events with an old `runID` are ignored;
- any unsolicited exit, including code 0, becomes `.failed(.unexpectedExit)`;
- an exit after a requested stop becomes `.stopped`.

- [ ] **Step 2: Define the exact state**

```swift
public enum ServiceState: Equatable, Sendable {
    case stopped
    case starting(runID: UUID)
    case running(runID: UUID)
    case ready(runID: UUID)
    case unready(runID: UUID, reason: String)
    case stopping(runID: UUID)
    case failed(ServiceFailure)
}
```

```swift
public protocol RunnerControlling: Sendable {
    func launch(_ request: RunnerLaunchRequest) async throws -> AsyncStream<ServiceRuntimeEvent>
    func stop(runID: UUID) async throws
}
```

- [ ] **Step 3: Implement `RunnerClient`**

Resolve the embedded helper relative to `Bundle.main.bundleURL/Contents/Helpers/DevBarRunner`. Create four pipes and launch the helper with `posix_spawn` file actions that map only the Runner-owned ends to fixed descriptors `3...6`. Close the opposite ends in both processes, set close-on-exec on the GUI ends, send exactly one launch request, decode event lines, and expose stdout/stderr as runtime events. Closing or deinitializing the client must close the command pipe. If spawn or the initial write fails, close all eight ends and reap any child that was created.

- [ ] **Step 4: Implement `ProcessSupervisor`**

Keep mutable runtime state inside the actor. Publish state changes through `AsyncStream`. Resolve and revalidate working directories at every launch, obtain `cachedOrRefresh()` environment, and merge workspace/service values before constructing a launch request. If environment capture is unavailable, fail only that service without spawning Runner. Do not perform UI work in the actor.

- [ ] **Step 5: Run focused tests**

Run:

```bash
xcodebuild test -project DevBar.xcodeproj -scheme DevBar -destination 'platform=macOS' \
  -only-testing:DevBarCoreTests/ProcessSupervisorTests \
  -only-testing:DevBarCoreTests/RunnerClientIntegrationTests
```

Expected: all state and embedded-helper tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/DevBarCore/Models Sources/DevBarCore/Runtime Tests/DevBarCoreTests
git commit -m "feat: supervise workspace service lifecycles"
```

---

### Task 6: HTTP/TCP Readiness Checks

**Files:**
- Create: `Sources/DevBarCore/Health/HealthChecker.swift`
- Create: `Tests/DevBarCoreTests/HealthCheckerTests.swift`

**Interfaces:**
- Produces: `HealthProbing.probe(_:) async -> HealthProbeResult`.
- Produces: `actor HealthChecker.start(serviceID:runID:config:) -> AsyncStream<HealthProbeResult>`.
- Consumes: `HealthCheckConfig` and current `runID`.

- [ ] **Step 1: Write failing HTTP boundary tests**

Use an injected `URLProtocol` to return 199, 200, 302, 399, 400, timeout, and transport error. Assert only 200–399 pass.

- [ ] **Step 2: Write failing non-overlap and cancellation tests**

Use a blocking fake probe. Advance a controllable clock past multiple 2-second intervals and assert only one request is in flight. Cancel the checker and assert no later result is emitted.

- [ ] **Step 3: Implement HTTP and TCP probes**

Use ephemeral `URLSession` with a 1-second request/resource timeout. Use `NWConnection` for TCP, complete on `.ready`, fail on `.failed`, and cancel on the same 1-second deadline.

- [ ] **Step 4: Implement polling**

```swift
public enum HealthProbeResult: Equatable, Sendable {
    case ready
    case unready(String)
}
```

Emit the first probe immediately, then every 2 seconds. Include `runID` at the supervisor boundary so stale health results cannot update a restarted service.

- [ ] **Step 5: Integrate with `ProcessSupervisor`**

Start health polling only after the Runner emits `started`. With `.none`, transition to `.running` after 1 second of continued process life. With HTTP/TCP, transition between `.ready` and `.unready` without killing or restarting the process.

- [ ] **Step 6: Run tests and commit**

Run: `xcodebuild test -project DevBar.xcodeproj -scheme DevBar -destination 'platform=macOS' -only-testing:DevBarCoreTests/HealthCheckerTests`

Expected: all status-code, timeout, TCP, non-overlap, cancellation, and stale-run tests pass.

```bash
git add Sources/DevBarCore/Health Sources/DevBarCore/Runtime Tests/DevBarCoreTests
git commit -m "feat: add service readiness checks"
```

---

### Task 7: UTF-8 Log Pipeline, Sanitization, Rotation, and Search Buffer

**Files:**
- Create: `Sources/DevBarCore/Logging/UTF8StreamDecoder.swift`
- Create: `Sources/DevBarCore/Logging/LogSanitizer.swift`
- Create: `Sources/DevBarCore/Logging/RotatingLogWriter.swift`
- Create: `Sources/DevBarCore/Logging/LogStore.swift`
- Create: `Tests/DevBarCoreTests/UTF8StreamDecoderTests.swift`
- Create: `Tests/DevBarCoreTests/LogSanitizerTests.swift`
- Create: `Tests/DevBarCoreTests/RotatingLogWriterTests.swift`
- Create: `Tests/DevBarCoreTests/LogStoreTests.swift`

**Interfaces:**
- Produces: `LogEntry(timestamp:stream:text:)`.
- Produces: `actor LogStore.append(_:workspaceID:serviceID:)`, `loadRecent(workspaceID:serviceID:limit:)`, `entries(serviceID:)`, `clearView(serviceID:)`, and `deleteHistory(serviceID:)`.
- Consumes: raw stdout/stderr events from `ProcessSupervisor`.

- [ ] **Step 1: Write failing incremental UTF-8 tests**

Split a multi-byte Chinese scalar across two chunks, include invalid bytes, and assert the decoder emits correct text plus U+FFFD for invalid input without losing adjacent bytes.

- [ ] **Step 2: Write failing sanitizer tests**

Verify removal of CSI colors, OSC title sequences, carriage-return progress updates, and other C0 controls while preserving newline and tab. Split CSI and OSC sequences across input chunks to require stateful sanitization.

- [ ] **Step 3: Implement decoder and sanitizer**

Keep incomplete trailing UTF-8 bytes between chunks. Keep incomplete terminal-control sequences in sanitizer state until the next chunk. Normalize `\r\n` and lone `\r` to newline for stable log rows. Never log the process environment or launch request.

- [ ] **Step 4: Write failing rotation tests**

Use a 64-byte threshold and 3 files for speed. Append enough lines to rotate four times and append one logical row larger than 64 bytes. Assert only current + two archives remain, no file exceeds the configured threshold, and newest content is retained.

- [ ] **Step 5: Implement rotation and in-memory cap**

Use one UTF-8 line per sanitized logical row:

```text
2026-07-28T12:34:56.789Z	stdout	text
```

Escape embedded tab/newline/backslash as `\t`, `\n`, and `\\` so startup loading can recover timestamp, stream, and text. Name files `current.log`, `current.log.1`, and `current.log.2`; `logFileCount` is the total including `current.log`. Rotate before a write that would exceed the configured size. Split an oversized disk row into valid continuation rows before rotation so no file exceeds the threshold; the live in-memory entry remains unsplit. Keep the newest 2,000 `LogEntry` values per service in memory.

- [ ] **Step 6: Write failing startup-history tests**

Create rotated fixtures containing more than 2,000 rows. Assert `loadRecent` reads archives oldest-to-newest, returns only the newest 2,000 valid rows, replaces malformed UTF-8, skips malformed record headers with one warning, and never reads outside the exact UUID-derived log directory.

- [ ] **Step 7: Integrate with runtime events and startup history**

Timestamp and tag stdout/stderr separately. Load recent history lazily when a service log is first opened after launch. A disk-write/read failure emits one nonblocking `LogStoreWarning`, continues retaining available memory entries, and does not stop the service. Tests pass values resembling `TOKEN=secret` and assert environment dictionaries are never serialized; command output remains user-controlled and is not falsely redacted.

- [ ] **Step 8: Run tests and commit**

Run: `xcodebuild test -project DevBar.xcodeproj -scheme DevBar -destination 'platform=macOS' -only-testing:DevBarCoreTests`

Expected: all core tests pass, including exact rotation counts and ANSI stripping.

```bash
git add Sources/DevBarCore/Logging Sources/DevBarCore/Runtime Tests/DevBarCoreTests
git commit -m "feat: add bounded service logging"
```

---

### Task 8: Main-Actor App State, Dependency Composition, and UI-Test Mode

**Files:**
- Create: `Sources/DevBarCore/State/AppState.swift`
- Create: `Sources/DevBarApp/AppDependencies.swift`
- Create: `Tests/DevBarCoreTests/AppStateTests.swift`
- Modify: `Sources/DevBarApp/DevBarApp.swift`

**Interfaces:**
- Produces: `@MainActor @Observable final class AppState`.
- Produces: `AppDependencies.live()` and `AppDependencies.uiTesting(configuration:)`.
- Consumes: configuration, shell environment, supervisor, health, and logs.

- [ ] **Step 1: Write failing app-state tests**

Test first-launch state, aggregate menu-bar color (including configuration and log-warning red states), workspace start/stop delegation, configuration recovery warning, running-service edit locks, and quit preparation.

- [ ] **Step 2: Implement dependency protocols**

Expose narrow protocols for configuration, process supervision, shell environment, and logs. Production actors conform directly; UI tests receive deterministic in-memory fakes.

- [ ] **Step 3: Implement `AppState`**

```swift
@MainActor
@Observable
public final class AppState {
    public private(set) var config: AppConfig
    public private(set) var serviceStates: [UUID: ServiceState]
    public private(set) var alert: AppAlert?
    public var isFirstLaunch: Bool { config.workspaces.isEmpty }

    public func startAll(workspaceID: UUID) async
    public func stopAll(workspaceID: UUID) async
    public func save(_ config: AppConfig) async
    public func prepareToQuit() async -> QuitResult
}
```

Subscribe to actor streams in tasks owned by `AppState`; cancel them in `deinit`. At application startup, call `cachedOrRefresh()` once. Surface fallback/refresh failures without blocking settings; block only service starts until a valid cache exists.

- [ ] **Step 4: Add deterministic UI-test launch mode**

When process arguments contain `--ui-testing`, require an isolated Application Support root from `DEVBAR_TEST_ROOT`, load fixture JSON from `DEVBAR_TEST_CONFIG`, and substitute a fake Runner that emits scripted states. In this mode only, expose `MenuBarPanel` in a normal titled `WindowGroup` so XCUITest can drive the same view without automating macOS's protected status-menu extra. Production still uses only `MenuBarExtra`, never creates the test-host window, and must not inspect the test environment variables unless the argument is present.

- [ ] **Step 5: Run tests and commit**

Run: `xcodebuild test -project DevBar.xcodeproj -scheme DevBar -destination 'platform=macOS' -only-testing:DevBarCoreTests/AppStateTests`

Expected: all app-state tests pass on the main actor.

```bash
git add Sources/DevBarCore/State Sources/DevBarApp Tests/DevBarCoreTests
git commit -m "feat: compose observable DevBar state"
```

---

### Task 9: Approved Theme, App Icon, Menu-Bar Panel, and First-Run Flow

**Files:**
- Create: `Sources/DevBarApp/Theme/DevBarTheme.swift`
- Create: `Sources/DevBarApp/Views/MenuBar/MenuBarPanel.swift`
- Create: `Sources/DevBarApp/Views/MenuBar/WorkspaceCardView.swift`
- Create: `Sources/DevBarApp/Views/MenuBar/ServiceRowView.swift`
- Create: `Scripts/make-app-icon.sh`
- Create: `Resources/AppIcon-master.png`
- Create: `Resources/Assets.xcassets/AppIcon.appiconset/Contents.json`
- Create: `Tests/DevBarUITests/MenuBarFlowUITests.swift`
- Modify: `project.yml`
- Modify: `Sources/DevBarApp/DevBarApp.swift`

**Interfaces:**
- Produces: reusable color/spacing/radius/shadow tokens.
- Produces: accessibility identifiers `menu.panel`, `workspace.<uuid>`, `workspace.startAll.<uuid>`, and `service.toggle.<uuid>`.
- Consumes: `AppState`.

- [ ] **Step 1: Generate a real app icon from the approved visual language**

Use the built-in ImageGen tool with `docs/superpowers/specs/assets/devbar-settings-warm-prism-v2.png` as a style reference and this prompt:

```text
Create a production-quality macOS app icon for DevBar. Use a rounded-square warm coral-to-pink-to-lilac gradient with a simple centered white developer chevron-and-slash mark. Match the approved DevBar settings visual, use native macOS icon depth and subtle highlight, no text, no letters, no watermark, no device frame, 1024 x 1024.
```

Save the selected output as `Resources/AppIcon-master.png`. Do not crop the settings screenshot.

- [ ] **Step 2: Build the icon set deterministically**

`Scripts/make-app-icon.sh` creates 16, 32, 64, 128, 256, 512, and 1024 pixel PNGs with `sips`, writes the exact `Contents.json`, and runs `xcrun actool` indirectly through the app build. Set `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` for the app target. Run the script and inspect the 16 px and 1024 px outputs.

- [ ] **Step 3: Write failing UI tests**

Launch with an empty test root. Assert:

- settings opens automatically on first launch;
- after closing settings, the menu panel contains “尚未配置工作区” and “添加工作区”;
- with the MuseCube fixture, “启动全部”, “Web”, and “Server” are visible;
- no visible string contains “开机自启” or “登录启动”.

- [ ] **Step 4: Implement theme tokens**

```swift
enum DevBarTheme {
    static let background = Color(red: 1.00, green: 0.98, blue: 0.96)
    static let textPrimary = Color(red: 0.12, green: 0.11, blue: 0.10)
    static let accent = LinearGradient(
        colors: [Color(red: 1.00, green: 0.36, blue: 0.22),
                 Color(red: 0.93, green: 0.25, blue: 0.55),
                 Color(red: 0.66, green: 0.32, blue: 0.96)],
        startPoint: .leading,
        endPoint: .trailing
    )
    static let majorRadius: CGFloat = 20
    static let controlRadius: CGFloat = 11
}
```

Use one subtle shadow on the popover/workspace surface. Use separators, spacing, and typography instead of nested cards.

- [ ] **Step 5: Implement the menu panel**

Match the approved menu image at a 380 × 520 pt frame. Show the DevBar header, settings button, scrollable workspace cards, per-service actions, start/stop-all action, empty state, “打开设置…”, and “退出 DevBar”.

- [ ] **Step 6: Wire first-launch behavior**

On empty configuration, open the settings window once per app launch. Closing it leaves the empty menu-panel CTA. Never create a sample workspace.

- [ ] **Step 7: Run build and UI tests**

Run:

```bash
xcodegen generate
xcodebuild test -project DevBar.xcodeproj -scheme DevBar -destination 'platform=macOS' \
  -only-testing:DevBarUITests/MenuBarFlowUITests
```

Expected: first-launch, fixture, and no-auto-start-copy tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/DevBarApp Resources Scripts Tests/DevBarUITests project.yml DevBar.xcodeproj
git commit -m "feat: build DevBar menu-bar experience"
```

---

### Task 10: Workspace, Service, and Global Preferences GUI

**Files:**
- Create: `Sources/DevBarApp/ViewModels/SettingsViewModel.swift`
- Create: `Sources/DevBarApp/Views/Settings/SettingsRootView.swift`
- Create: `Sources/DevBarApp/Views/Settings/WorkspaceSettingsView.swift`
- Create: `Sources/DevBarApp/Views/Settings/ServiceEditorSheet.swift`
- Create: `Sources/DevBarApp/Views/Settings/PreferencesView.swift`
- Create: `Sources/DevBarCore/Paths/Trashing.swift`
- Create: `Tests/DevBarCoreTests/DeletionCoordinatorTests.swift`
- Create: `Tests/DevBarUITests/SettingsFlowUITests.swift`
- Modify: `Sources/DevBarApp/DevBarApp.swift`

**Interfaces:**
- Produces: accessibility identifiers `settings.sidebar`, `workspace.add`, `service.add`, `service.editor`, `config.check`, `config.save`, and `preferences.refreshShell`.
- Consumes: `ConfigValidator`, `ShellSyntaxChecker`, `ShellEnvironmentProvider`, and `AppState`.

- [ ] **Step 1: Write failing settings UI tests**

Cover:

- create a workspace with a selected root;
- add Web with a relative directory and Server with an external absolute directory;
- reorder workspaces and services and preserve the new array order after relaunch;
- choose an allowed SF Symbol and preset tint;
- toggle “加入启动全部”;
- invalid environment key anchors an inline error;
- environment editors warn against passwords/tokens/keys and workspace summaries display counts, never values;
- “检查配置” does not start a fake service;
- active workspace locks root/environment/delete controls;
- a moved root/service directory appears invalid, cannot start, and can be reselected;
- deleting either a service or workspace moves only its exact fake log directory to a fake Trash adapter before removing config;
- Preferences contains no login or auto-start control.

- [ ] **Step 2: Implement directory picking behind a protocol**

Production uses `NSOpenPanel` configured for one directory and no files. UI tests inject deterministic URLs. Convert paths under the root to `.relative`; otherwise store `.absolute`.

- [ ] **Step 3: Implement transactional settings editing**

`SettingsViewModel` edits a draft `AppConfig`, validates without mutating live config, runs syntax/environment checks, and calls `AppState.save` only after success. Cancel discards the draft. Reordering changes only the workspace/service arrays and remains enabled while services run.

- [ ] **Step 4: Implement workspace and service views**

Match the approved settings visual at 980 × 680 pt. Use sidebar selection, compact workspace header, allowed SF Symbol/preset tint pickers, public-variable count, service objects, “加入启动全部”, Add Service, and Save. The full service Sheet edits name, directory, command, inclusion flag, plain environment entries, and none/HTTP/TCP health configuration. Show invalid-directory repair controls in place; do not offer Start/Stop actions anywhere in settings.

- [ ] **Step 5: Implement destructive-operation safety**

Define `Trashing`:

```swift
public protocol Trashing: Sendable {
    func moveToTrash(_ url: URL) async throws
}
```

Resolve deletion targets only through `AppPaths.logsRootURL` plus validated UUID path components; assert the standardized target remains a descendant of `logsRootURL`. Move the service/workspace log directory first, treating a missing log directory as success; save the removed configuration second. If Trash fails, do not save the deletion. If configuration save fails after Trash succeeds, keep the original live configuration, say explicitly that logs are recoverable from Trash, and offer retry. Never pass a project root, service working directory, symlink-resolved path outside `logsRootURL`, or the logs root itself to `Trashing`.

- [ ] **Step 6: Implement global preferences**

Expose only zsh path, log size/count, SIGINT/SIGTERM grace values, and “刷新 Shell 环境”. Enforce documented ranges and require a successful refresh before saving a changed zsh path. Environment editors show a persistent warning that values are plain-text configuration and must not contain passwords, tokens, or keys. Do not add any auto-start control.

- [ ] **Step 7: Run UI and core tests**

Run:

```bash
xcodebuild test -project DevBar.xcodeproj -scheme DevBar -destination 'platform=macOS' \
  -only-testing:DevBarUITests/SettingsFlowUITests \
  -only-testing:DevBarCoreTests
```

Expected: settings flows and all core tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/DevBarApp Sources/DevBarCore Tests
git commit -m "feat: add workspace configuration UI"
```

---

### Task 11: Log Window, Quit Coordination, and Runtime Polish

**Files:**
- Create: `Sources/DevBarApp/ViewModels/LogViewModel.swift`
- Create: `Sources/DevBarApp/Views/Logs/LogWindowView.swift`
- Create: `Sources/DevBarApp/AppDelegate.swift`
- Create: `Tests/DevBarUITests/LogAndQuitUITests.swift`
- Create: `Tests/DevBarCoreTests/QuitCoordinatorTests.swift`
- Modify: `Sources/DevBarApp/DevBarApp.swift`
- Modify: `Sources/DevBarCore/State/AppState.swift`

**Interfaces:**
- Produces: log-window commands `openLog(serviceID:)`, `search(query:)`, `pauseAutoScroll`, `clearView`, `openLogDirectory`, and `deleteHistory`.
- Produces: `QuitCoordinator.requestQuit() async -> QuitDecision`.
- Consumes: `LogStore` and `ProcessSupervisor.stopAll`.

- [ ] **Step 1: Write failing log-window tests**

With 2,100 fixture lines, assert the UI receives the newest 2,000; search filters only loaded rows; pause prevents scroll-position changes; clear view leaves files; delete history requires confirmation.

- [ ] **Step 2: Implement `LogViewModel` and `LogWindowView`**

Use a service picker, stdout/stderr visual distinction, search field, pause/resume, clear view, open directory, and delete history. Keep the 900 × 600 pt initial and 720 × 440 pt minimum size.

- [ ] **Step 3: Write failing quit tests**

Cover:

- no running service exits immediately;
- running services produce a confirmation list;
- cancel keeps all services;
- confirm requests all stops and waits for terminal states;
- stop timeout still waits through SIGKILL completion before application termination.

- [ ] **Step 4: Implement AppKit quit interception**

`AppDelegate.applicationShouldTerminate(_:)` returns `.terminateLater` when services are active, asks `QuitCoordinator`, then calls `NSApp.reply(toApplicationShouldTerminate:)`. Ensure only one quit dialog/task exists at a time.

- [ ] **Step 5: Add app/window activation polish**

Opening settings or logs calls `NSApp.activate()` and brings the correct window forward even though `LSUIElement` is true. Menu-panel status icon reflects neutral/yellow/green/red aggregate state.

- [ ] **Step 6: Run tests and commit**

Run:

```bash
xcodebuild test -project DevBar.xcodeproj -scheme DevBar -destination 'platform=macOS' \
  -only-testing:DevBarUITests/LogAndQuitUITests \
  -only-testing:DevBarCoreTests/QuitCoordinatorTests
```

Expected: log and quit scenarios pass without leaving Runner or shell processes.

```bash
git add Sources Tests
git commit -m "feat: add logs and safe app termination"
```

---

### Task 12: Release Packaging, End-to-End Verification, and Usage Documentation

**Files:**
- Create: `Scripts/build-release.sh`
- Create: `Scripts/verify-app.sh`
- Create: `Fixtures/Acceptance/npm/package.json`
- Create: `Fixtures/Acceptance/npm/server.mjs`
- Create: `Fixtures/Acceptance/java/EchoServer.java`
- Create: `README.md`
- Modify: `project.yml`
- Regenerate and modify: `DevBar.xcodeproj`

**Interfaces:**
- Produces: `build/DevBar.app`.
- Produces: repeatable verification of plist, signing, helper embedding, launch, configuration, service lifecycle, and cleanup.

- [ ] **Step 1: Write a failing bundle verification script**

`Scripts/verify-app.sh <app-path>` must fail unless:

- the path is a macOS app bundle;
- bundle ID is `com.calo.DevBar`;
- minimum system is 15.0;
- `LSUIElement` is true;
- `Contents/MacOS/DevBar` and `Contents/Helpers/DevBarRunner` are executable;
- `codesign --verify --deep --strict` succeeds;
- no bundle plist key introduces login/auto-start behavior.

Run against a nonexistent path.

Expected: nonzero exit with `DevBar.app not found`.

- [ ] **Step 2: Implement release packaging**

```bash
#!/bin/zsh
set -euo pipefail
repo_root="${0:A:h:h}"
derived="${repo_root}/DerivedData"
output="${repo_root}/build"
stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT

xcodegen generate --spec "${repo_root}/project.yml"
xcodebuild \
  -project "${repo_root}/DevBar.xcodeproj" \
  -scheme DevBar \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "${derived}" \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p "${output}"
ditto "${derived}/Build/Products/Release/DevBar.app" "${stage}/DevBar.app"
codesign --force --sign - "${stage}/DevBar.app/Contents/Helpers/DevBarRunner"
codesign --force --sign - "${stage}/DevBar.app"
"${repo_root}/Scripts/verify-app.sh" "${stage}/DevBar.app"
rm -rf "${output}/DevBar.app"
mv "${stage}/DevBar.app" "${output}/DevBar.app"
```

- [ ] **Step 3: Run the complete automated suite**

Run:

```bash
mkdir -p build
rm -rf build/DevBarTests.xcresult
xcodegen generate
xcodebuild test -project DevBar.xcodeproj -scheme DevBar -destination 'platform=macOS' \
  -derivedDataPath DerivedData -resultBundlePath build/DevBarTests.xcresult
```

Expected: all unit, integration, and UI tests pass.

- [ ] **Step 4: Build and verify the release app**

Run: `Scripts/build-release.sh`

Expected: `build/DevBar.app` exists and `Scripts/verify-app.sh build/DevBar.app` exits 0.

- [ ] **Step 5: Create deterministic npm and Java acceptance fixtures**

`Fixtures/Acceptance/npm/package.json` declares only `"dev": "node server.mjs"`. `server.mjs` starts an HTTP server on `127.0.0.1:41731`, writes `npm-ready` to stdout, writes one `npm-stderr-check` line to stderr, and handles `SIGINT`/`SIGTERM` by closing the server before exit.

`Fixtures/Acceptance/java/EchoServer.java` uses Java source-file mode to open `ServerSocket` on `127.0.0.1:41732`, prints `java-ready`, writes one `java-stderr-check` line, uses try-with-resources, and stays in its foreground accept loop. No fixture detaches or daemonizes.

```json
{
  "private": true,
  "scripts": {
    "dev": "node server.mjs"
  }
}
```

```javascript
import http from "node:http";

const server = http.createServer((_request, response) => {
  response.writeHead(200, { "content-type": "text/plain" });
  response.end("ok\n");
});
server.listen(41731, "127.0.0.1", () => {
  console.log("npm-ready");
  console.error("npm-stderr-check");
});
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
```

```java
import java.net.InetAddress;
import java.net.ServerSocket;

class EchoServer {
    public static void main(String[] args) throws Exception {
        try (var server = new ServerSocket(41732, 50, InetAddress.getByName("127.0.0.1"))) {
            System.out.println("java-ready");
            System.err.println("java-stderr-check");
            while (true) {
                try (var socket = server.accept()) {
                    socket.getOutputStream().write("ok\n".getBytes());
                }
            }
        }
    }
}
```

- [ ] **Step 6: Perform the real npm/Java acceptance flow**

Use the committed foreground fixtures, not the user's production repositories:

1. Confirm `node --version`, `npm --version`, and `java --version` exit 0; record the versions.
2. Create one “DevBar Acceptance” workspace rooted at `Fixtures/Acceptance`.
3. Configure Web at relative directory `npm`, command `npm run dev`, HTTP health `http://127.0.0.1:41731/`; configure Server at relative directory `java`, command `java EchoServer.java`, TCP health `127.0.0.1:41732`.
4. Start both from the menu panel.
5. Verify stdout/stderr, process state, configured HTTP/TCP readiness, and the approved colors/layout.
6. Stop Web individually; verify its descendants are gone.
7. Start Web again, then stop the workspace; verify every descendant is gone.
8. Start both again, force-quit only the GUI process, and verify both Runner-owned groups are cleaned up.
9. Reopen from Finder and verify configuration/log history remains and no service starts automatically.

- [ ] **Step 7: Compare UI against both approved references**

Capture the menu panel at 380 × 520 pt and settings at 980 × 680 pt. For each screen, place the approved reference and current capture into one side-by-side comparison image at 1× using the workspace image-composition runtime, then inspect that combined image. Fix visible hierarchy, padding, typography, radius, gradient, shadow, clipping, contrast, focus, hover/disabled states, or incorrect-copy differences; regenerate the combined image and rerun the relevant UI tests after every correction pass.

- [ ] **Step 8: Write the user README**

Document:

- build with `brew bundle` and `Scripts/build-release.sh`;
- launch `build/DevBar.app` from Finder;
- create a workspace and foreground services;
- zsh-only environment capture and “刷新 Shell 环境”;
- no TTY/interactive commands, aliases, functions, or detached daemons;
- log location and rotation;
- no login or automatic startup;
- app is local/ad-hoc signed and not intended for redistribution.

- [ ] **Step 9: Final repository checks**

Run:

```bash
git diff --check
git status --short
xcodebuild -project DevBar.xcodeproj -scheme DevBar -showBuildSettings >/dev/null
Scripts/verify-app.sh build/DevBar.app
! rg -n 'SMAppService|SMLoginItem|LSSharedFileList|LaunchAgent|开机自启|登录启动' \
  Sources/DevBarApp Configuration
```

Expected: no whitespace errors, only intended files changed, build settings load, and app verification succeeds.

- [ ] **Step 10: Commit**

```bash
git add Scripts Fixtures README.md project.yml DevBar.xcodeproj
git commit -m "build: package verified DevBar app"
```

---

## Plan Completion Criteria

- Every approved specification section maps to at least one task:
  - configuration/persistence: Tasks 2 and 10;
  - zsh environment/security boundary: Tasks 3 and 10;
  - Runner/process cleanup: Tasks 4 and 5;
  - health state: Task 6;
  - logs: Tasks 7 and 11;
  - first-run/menu/settings visuals: Tasks 8–10;
  - quit behavior: Task 11;
  - Finder-launchable app and acceptance: Task 12.
- No task may be accepted solely because the project compiles; its focused tests and stated observable behavior must pass.
- Do not proceed to the next task with unrelated failing tests or surviving fixture processes.
- Each commit must contain only the task's files plus generated `DevBar.xcodeproj` changes required by that task.
