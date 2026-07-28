# DevBar Standard App Lifecycle Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make DevBar behave like a normal Dock application with one reusable main window while retaining all menu-bar status and quick actions.

**Architecture:** Replace the agent-only activation policy with a regular macOS application lifecycle and add one fixed-ID SwiftUI main window that reuses the existing settings content. A small `MainWindowCoordinator` is the single entry point for Dock reopen, `⌘,`, and menu-bar navigation; it owns no business state and delegates actual presentation to SwiftUI's `openWindow`.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, XcodeGen 2.46.0, macOS 15+

## Global Constraints

- Keep one shared `AppDependencies` and `AppState` across the main window, menu bar, and log window.
- Closing the last window must not terminate DevBar or stop services.
- `⌘Q` and every explicit quit action must continue through `QuitCoordinator`.
- Keep `MenuBarExtra` and every existing status and service-control action.
- Do not add login launch, automatic service start, or a second configuration window.
- Keep `--ui-testing` isolated from real configuration, real Runner helpers, and the user's shell files.
- Use a fixed main-window scene ID of `main`; all entry points must target that scene.
- Do not infer success from compilation alone: run focused tests, the full test suite, and the manual lifecycle checks.

---

## File Structure

- Create `Sources/DevBarApp/Lifecycle/MainWindowCoordinator.swift`: owns the presentation callback and activation ordering for the unique main window.
- Modify `Sources/DevBarApp/DevBarApplicationDelegate.swift`: handles Dock reopen and explicitly keeps the app alive after the last window closes.
- Modify `Sources/DevBarApp/DevBarApp.swift`: defines the main window, replaces the independent Settings scene, and routes menu-bar and command actions through the coordinator.
- Modify `Configuration/DevBar-Info.plist`: removes agent-only `LSUIElement`.
- Modify `project.yml`: adds a unit-test bundle for app lifecycle behavior and includes it in the aggregate scheme.
- Create `Tests/DevBarAppTests/MainWindowCoordinatorTests.swift`: verifies coordinator registration, activation ordering, Dock reopen, and last-window behavior without launching services.
- Keep `Tests/DevBarUITests/MenuBarFlowUITests.swift` unchanged; it remains the isolated menu-bar interaction suite.

---

### Task 1: Testable Main-Window Lifecycle Boundary

**Files:**
- Create: `Sources/DevBarApp/Lifecycle/MainWindowCoordinator.swift`
- Create: `Tests/DevBarAppTests/MainWindowCoordinatorTests.swift`
- Modify: `project.yml`
- Regenerate: `DevBar.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `@MainActor final class MainWindowCoordinator`
- Produces: `typealias MainWindowOpenAction = @MainActor () -> Void`
- Produces: `func register(openAction: @escaping MainWindowOpenAction)`
- Produces: `@discardableResult func openMainWindow() -> Bool`
- Consumes: an injected `@MainActor () -> Void` activation action, defaulting to `NSApp.activate(ignoringOtherApps: true)`

- [ ] **Step 1: Add the app-test target to XcodeGen**

Add this target to `project.yml`:

```yaml
  DevBarAppTests:
    type: bundle.unit-test
    platform: macOS
    sources: [Tests/DevBarAppTests]
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
    dependencies:
      - target: DevBar
```

Add `DevBarAppTests` to the `DevBar` scheme test targets and add a dedicated scheme:

```yaml
  DevBarAppTests:
    build:
      targets:
        DevBarAppTests: all
    test:
      targets:
        - DevBarAppTests
```

- [ ] **Step 2: Generate the project**

Run:

```bash
xcodegen generate
```

Expected: exit 0; `xcodebuild -project DevBar.xcodeproj -list` includes the `DevBarAppTests` target and scheme.

- [ ] **Step 3: Write failing coordinator tests**

Create `Tests/DevBarAppTests/MainWindowCoordinatorTests.swift`:

```swift
import XCTest
@testable import DevBar

@MainActor
final class MainWindowCoordinatorTests: XCTestCase {
    func testOpenReturnsFalseBeforePresentationActionIsRegistered() {
        var activations = 0
        let coordinator = MainWindowCoordinator { activations += 1 }

        XCTAssertFalse(coordinator.openMainWindow())
        XCTAssertEqual(activations, 0)
    }

    func testOpenActivatesApplicationBeforePresentingMainWindow() {
        var events: [String] = []
        let coordinator = MainWindowCoordinator { events.append("activate") }
        coordinator.register { events.append("open") }

        XCTAssertTrue(coordinator.openMainWindow())
        XCTAssertEqual(events, ["activate", "open"])
    }

    func testReplacingRegistrationUsesOnlyLatestPresentationAction() {
        var events: [String] = []
        let coordinator = MainWindowCoordinator {}
        coordinator.register { events.append("old") }
        coordinator.register { events.append("new") }

        XCTAssertTrue(coordinator.openMainWindow())
        XCTAssertEqual(events, ["new"])
    }
}
```

- [ ] **Step 4: Run the tests and verify the intended failure**

Run:

```bash
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBarAppTests \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  -only-testing:DevBarAppTests/MainWindowCoordinatorTests
```

Expected: FAIL because `MainWindowCoordinator` is not defined.

- [ ] **Step 5: Implement the minimal coordinator**

Create `Sources/DevBarApp/Lifecycle/MainWindowCoordinator.swift`:

```swift
import AppKit

typealias MainWindowOpenAction = @MainActor () -> Void

@MainActor
final class MainWindowCoordinator {
    private let activateApplication: @MainActor () -> Void
    private var openAction: MainWindowOpenAction?

    init(
        activateApplication: @escaping @MainActor () -> Void = {
            NSApp.activate(ignoringOtherApps: true)
        }
    ) {
        self.activateApplication = activateApplication
    }

    func register(openAction: @escaping MainWindowOpenAction) {
        self.openAction = openAction
    }

    @discardableResult
    func openMainWindow() -> Bool {
        guard let openAction else { return false }
        activateApplication()
        openAction()
        return true
    }
}
```

- [ ] **Step 6: Run the focused tests**

Run the command from Step 4.

Expected: all three `MainWindowCoordinatorTests` pass.

- [ ] **Step 7: Commit the lifecycle boundary**

```bash
git add project.yml DevBar.xcodeproj Sources/DevBarApp/Lifecycle Tests/DevBarAppTests
git commit -m "test: add main window lifecycle boundary"
```

---

### Task 2: Dock Reopen and Safe App Lifetime

**Files:**
- Modify: `Sources/DevBarApp/DevBarApplicationDelegate.swift`
- Modify: `Tests/DevBarAppTests/MainWindowCoordinatorTests.swift`

**Interfaces:**
- Consumes: `MainWindowCoordinator.openMainWindow() -> Bool`
- Keeps: `DevBarApplicationDelegate.configure(appState: AppState)` with a non-optional production state
- Produces: `DevBarApplicationDelegate.init(mainWindowCoordinator:)` for lifecycle dependency injection
- Produces: `applicationShouldHandleReopen(_:hasVisibleWindows:) -> Bool`
- Produces: `applicationShouldTerminateAfterLastWindowClosed(_:) -> Bool`

- [ ] **Step 1: Write failing application-delegate tests**

Append to `MainWindowCoordinatorTests.swift`:

```swift
func testDockReopenRoutesToMainWindowCoordinator() {
    var opens = 0
    let coordinator = MainWindowCoordinator {}
    coordinator.register { opens += 1 }
    let delegate = DevBarApplicationDelegate(mainWindowCoordinator: coordinator)

    XCTAssertTrue(
        delegate.applicationShouldHandleReopen(
            NSApplication.shared,
            hasVisibleWindows: false
        )
    )
    XCTAssertEqual(opens, 1)
}

func testClosingLastWindowKeepsMenuBarApplicationRunning() {
    let delegate = DevBarApplicationDelegate()

    XCTAssertFalse(
        delegate.applicationShouldTerminateAfterLastWindowClosed(
            NSApplication.shared
        )
    )
}
```

- [ ] **Step 2: Run the tests and verify the intended failure**

Run:

```bash
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBarAppTests \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData
```

Expected: FAIL because the delegate does not accept a coordinator and does not implement the two lifecycle callbacks.

- [ ] **Step 3: Implement the delegate lifecycle callbacks**

Update `DevBarApplicationDelegate`:

```swift
let mainWindowCoordinator: MainWindowCoordinator

override init() {
    self.mainWindowCoordinator = MainWindowCoordinator()
    super.init()
}

init(mainWindowCoordinator: MainWindowCoordinator) {
    self.mainWindowCoordinator = mainWindowCoordinator
    super.init()
}

func configure(appState: AppState) {
    self.appState = appState
}

func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
) -> Bool {
    mainWindowCoordinator.openMainWindow()
}

func applicationShouldTerminateAfterLastWindowClosed(
    _ sender: NSApplication
) -> Bool {
    false
}
```

Do not change `applicationShouldTerminate`; it remains the only explicit quit gate and continues to use `QuitCoordinator`.

- [ ] **Step 4: Run lifecycle and quit regression tests**

Run:

```bash
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBar \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  -only-testing:DevBarAppTests \
  -only-testing:DevBarCoreTests/QuitCoordinatorTests
```

Expected: app lifecycle tests and all `QuitCoordinatorTests` pass.

- [ ] **Step 5: Commit Dock reopen behavior**

```bash
git add Sources/DevBarApp/DevBarApplicationDelegate.swift Tests/DevBarAppTests/MainWindowCoordinatorTests.swift
git commit -m "feat: keep DevBar active after windows close"
```

---

### Task 3: One Main Window Across Dock, Menu Bar, and App Commands

**Files:**
- Modify: `Configuration/DevBar-Info.plist`
- Modify: `Sources/DevBarApp/DevBarApp.swift`
- Modify: `Tests/DevBarAppTests/MainWindowCoordinatorTests.swift`

**Interfaces:**
- Consumes: `MainWindowCoordinator.register(openAction:)`
- Consumes: `MainWindowCoordinator.openMainWindow() -> Bool`
- Produces: SwiftUI `Window("DevBar", id: "main")`
- Produces: `MainWindowCommands`, replacing the standard `.appSettings` command group
- Keeps: `Window("服务日志", id: "logs")`
- Keeps: production `MenuBarExtra`

- [ ] **Step 1: Add a failing built-product assertion for Dock visibility**

Append this test to `MainWindowCoordinatorTests`:

```swift
func testProductionInfoPlistDoesNotHideApplicationFromDock() throws {
    let bundle = Bundle(for: DevBarApplicationDelegate.self)
    XCTAssertNotEqual(
        bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool,
        true
    )
}
```

- [ ] **Step 2: Run the assertion and verify the intended failure**

Run:

```bash
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBar \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  -only-testing:DevBarAppTests/MainWindowCoordinatorTests/testProductionInfoPlistDoesNotHideApplicationFromDock
```

Expected: FAIL because the built app still contains `LSUIElement=true`.

- [ ] **Step 3: Restore regular Dock behavior**

Remove these lines from `Configuration/DevBar-Info.plist`:

```xml
  <key>LSUIElement</key>
  <true/>
```

Do not add runtime activation-policy switching.

- [ ] **Step 4: Replace the independent Settings scene with the fixed main window**

In `ProductionDevBarApp`:

```swift
private let mainWindowCoordinator: MainWindowCoordinator

init() {
    let dependencies = AppDependencies.live()
    self.dependencies = dependencies
    self.mainWindowCoordinator = applicationDelegate.mainWindowCoordinator
    applicationDelegate.configure(appState: dependencies.appState)
}
```

Replace the `Settings` scene with:

```swift
Window("DevBar", id: "main") {
    SettingsSceneContent(dependencies: dependencies)
}
.defaultSize(width: 980, height: 680)
.commands {
    MainWindowCommands(coordinator: mainWindowCoordinator)
}
```

Keep `MenuBarExtra` and the logs window unchanged except for passing the coordinator into their content.

- [ ] **Step 5: Register SwiftUI presentation and route all configuration entry points**

Pass `mainWindowCoordinator` into `ProductionStatusItem`. Add `@Environment(\.openWindow)` and register once:

```swift
.task {
    mainWindowCoordinator.register {
        openWindow(id: "main")
    }
}
```

Remove the existing first-launch loop that calls `openSettings()`: the fixed main window now opens normally for both empty and configured states.

Pass the coordinator into `ProductionMenuContent` and replace the menu panel's settings action with:

```swift
openSettings: {
    mainWindowCoordinator.openMainWindow()
}
```

Add:

```swift
private struct MainWindowCommands: Commands {
    let coordinator: MainWindowCoordinator

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                coordinator.openMainWindow()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
```

There must be no remaining production use of `@Environment(\.openSettings)` or a SwiftUI `Settings` scene.

- [ ] **Step 6: Preserve deterministic UI-test mode**

Keep `UITestDevBarApp` and `MenuBarFlowUITests` unchanged and isolated. Its normal titled test window continues to drive `MenuBarPanel`; do not make UI tests read the real Application Support directory or invoke the real Runner.

Run:

```bash
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBar \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  -only-testing:DevBarUITests/MenuBarFlowUITests
```

Expected: all menu panel, settings editor, logs, fixture, and no-auto-start-copy tests pass.

- [ ] **Step 7: Run static checks and the full test suite**

Run:

```bash
rg -n "LSUIElement" Configuration/DevBar-Info.plist
rg -n "@Environment\\(\\\\.openSettings\\)|^[[:space:]]*Settings \\{" Sources/DevBarApp/DevBarApp.swift
git diff --check
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBar \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData
```

Expected:

- both `rg` commands return no matches, proving no production `LSUIElement`, `@Environment(\.openSettings)`, or independent `Settings` scene remains;
- `git diff --check` exits 0;
- all core, RunnerKit, app lifecycle, and UI tests pass.

- [ ] **Step 8: Perform the manual lifecycle acceptance**

Build and open:

```bash
xcodebuild \
  -project DevBar.xcodeproj \
  -scheme DevBar \
  -destination 'platform=macOS' \
  -derivedDataPath DerivedData \
  build
open DerivedData/Build/Products/Debug/DevBar.app
```

Verify:

1. Dock icon appears and one DevBar main window opens.
2. Closing the main window leaves both Dock and menu-bar icons active.
3. Clicking the Dock icon reopens one main window without duplication.
4. Menu-bar “设置” and `⌘,` both front the same main window.
5. Menu-bar service state and quick actions remain usable with the main window closed.
6. Logs still open in one separate log window.
7. `⌘Q` with an active test service shows the existing safe-quit confirmation; cancelling keeps the app running, and confirming exits without a residual managed process.

- [ ] **Step 9: Commit the user-visible lifecycle**

```bash
git add Configuration/DevBar-Info.plist Sources/DevBarApp/DevBarApp.swift Tests/DevBarAppTests/MainWindowCoordinatorTests.swift
git commit -m "feat: add normal Dock and main window lifecycle"
```

---

## Final Review Gate

Before declaring completion:

- Confirm the implementation diff contains no unrelated refactor.
- Confirm the generated Xcode project matches `project.yml`.
- Confirm no test accesses the user's real DevBar configuration or starts a real configured service.
- Report automated test results separately from manual Dock/window/service verification.
- Report any unverified manual item explicitly; do not infer it from a passing build.
