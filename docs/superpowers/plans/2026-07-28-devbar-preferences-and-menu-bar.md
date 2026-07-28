# DevBar Preferences and Menu Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make preferences a full-window page, add an immediately persisted menu-bar visibility checkbox and new status icon, and eliminate the service editor's optional-binding crash.

**Architecture:** Keep workspace configuration in `AppConfig`, but store the immediate application-chrome preference in a small `UserDefaults`-backed observable object shared by the app scene and preferences view. Render preferences and workspace configuration as mutually exclusive root layouts. Give the service editor a local `ServiceConfig` draft and use explicit commit/cancel boundaries instead of live bindings into optional presentation state.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Observation, XCTest, XcodeGen

## Global Constraints

- macOS deployment target remains 15.
- The Dock icon and main window remain available when the menu-bar icon is hidden.
- “显示菜单栏图标” applies immediately and is not reverted by the settings footer’s “取消”.
- Existing `AppConfig` schema version 1 and `includeInStartAll` semantics remain unchanged.
- No login launch, automatic service start, second `AppState`, or second settings window is introduced.
- Production user defaults and UI-test defaults must remain isolated.

---

### Task 1: Persisted menu-bar presentation preference

**Files:**
- Create: `Sources/DevBarApp/Preferences/AppPresentationPreferences.swift`
- Create: `Tests/DevBarAppTests/AppPresentationPreferencesTests.swift`
- Modify: `project.yml`
- Modify: `DevBar.xcodeproj/project.pbxproj`

**Interfaces:**
- Produces: `@MainActor @Observable final class AppPresentationPreferences`
- Produces: `var showsMenuBarIcon: Bool`
- Produces: `init(defaults: UserDefaults, showsMenuBarIconKey: String = "showsMenuBarIcon")`

- [ ] **Step 1: Write persistence tests**

Add tests that use a unique `UserDefaults` suite, clear it before and after each test, and verify:

```swift
func testMenuBarIconDefaultsToVisible() {
    let preferences = AppPresentationPreferences(defaults: defaults)
    XCTAssertTrue(preferences.showsMenuBarIcon)
}

func testMenuBarIconVisibilityPersistsImmediately() {
    let preferences = AppPresentationPreferences(defaults: defaults)
    preferences.showsMenuBarIcon = false
    XCTAssertFalse(AppPresentationPreferences(defaults: defaults).showsMenuBarIcon)
}
```

- [ ] **Step 2: Run the focused test and confirm it fails**

Run:

```bash
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBarAppTests \
  -derivedDataPath /tmp/DevBarDerivedData \
  -only-testing:DevBarAppTests/AppPresentationPreferencesTests
```

Expected: compilation fails because `AppPresentationPreferences` does not exist.

- [ ] **Step 3: Implement the observable preference**

Implement a main-actor object that reads an absent key as `true` and writes in `didSet`:

```swift
@MainActor
@Observable
final class AppPresentationPreferences {
    private let defaults: UserDefaults
    private let showsMenuBarIconKey: String

    var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: showsMenuBarIconKey) }
    }

    init(defaults: UserDefaults, showsMenuBarIconKey: String = "showsMenuBarIcon") {
        self.defaults = defaults
        self.showsMenuBarIconKey = showsMenuBarIconKey
        showsMenuBarIcon = defaults.object(forKey: showsMenuBarIconKey) == nil
            ? true
            : defaults.bool(forKey: showsMenuBarIconKey)
    }
}
```

Do not call `synchronize()` and do not add this property to `PreferencesConfig`.

- [ ] **Step 4: Register files in XcodeGen and regenerate the project**

Add the source and test files to their existing directory-backed target sources, then run:

```bash
xcodegen generate
```

Confirm the generated project contains both files and preserves all existing targets.

- [ ] **Step 5: Run the focused tests**

Run the Task 1 test command again.

Expected: both tests pass.

### Task 2: Full-page preferences and recoverable workspace navigation

**Files:**
- Modify: `Sources/DevBarApp/Views/Settings/SettingsRootView.swift`
- Modify: `Sources/DevBarApp/Views/Settings/PreferencesView.swift`
- Modify: `Sources/DevBarApp/ViewModels/SettingsViewModel.swift`
- Create: `Tests/DevBarAppTests/SettingsViewModelNavigationTests.swift`
- Modify: `Tests/DevBarUITests/MenuBarFlowUITests.swift`

**Interfaces:**
- Produces: `func leavePreferences()`
- Preserves: `func selectPreferences()`
- Consumes: `AppPresentationPreferences`

- [ ] **Step 1: Write navigation-state tests**

Construct `SettingsViewModel` with no-op commit/refresh actions and verify:

```swift
func testSelectingPreferencesPreservesWorkspaceSelection() {
    let workspace = WorkspaceConfig.fixture()
    let viewModel = makeViewModel(workspaces: [workspace])
    viewModel.selectPreferences()
    XCTAssertTrue(viewModel.showsPreferences)
    XCTAssertEqual(viewModel.selectedWorkspaceID, workspace.id)
}

func testLeavingPreferencesRestoresAnExistingWorkspace() {
    let workspace = WorkspaceConfig.fixture()
    let viewModel = makeViewModel(workspaces: [workspace])
    viewModel.selectPreferences()
    viewModel.leavePreferences()
    XCTAssertFalse(viewModel.showsPreferences)
    XCTAssertEqual(viewModel.selectedWorkspaceID, workspace.id)
}
```

Use a file-local fixture instead of changing production initializers.

- [ ] **Step 2: Run the focused tests and confirm failure**

Run:

```bash
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBarAppTests \
  -derivedDataPath /tmp/DevBarDerivedData \
  -only-testing:DevBarAppTests/SettingsViewModelNavigationTests
```

Expected: failure because `selectPreferences()` clears the selection and `leavePreferences()` is missing.

- [ ] **Step 3: Correct preference navigation state**

Change `selectPreferences()` to set only `showsPreferences = true`. Implement `leavePreferences()` so it:

1. keeps the selected workspace when it still exists;
2. otherwise selects the first existing workspace;
3. sets `showsPreferences = false`.

- [ ] **Step 4: Render mutually exclusive root layouts**

Refactor `SettingsRootView` so:

```swift
Group {
    if viewModel.showsPreferences {
        VStack(spacing: 0) {
            PreferencesView(
                viewModel: viewModel,
                presentationPreferences: presentationPreferences
            )
            footer
        }
    } else {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                workspaceContent
                footer
            }
        }
    }
}
.frame(width: 980, height: 680)
```

The preferences branch must not construct `settings.sidebar`.

- [ ] **Step 5: Add the page-level navigation and menu-bar checkbox**

Update `PreferencesView` to accept `AppPresentationPreferences`. In its header:

- show “返回工作区” when `draft.workspaces` is not empty and call `leavePreferences()`;
- show “添加工作区” when empty and call `await addWorkspace()`.

Add a clearly separated “应用外观” card:

```swift
Toggle("显示菜单栏图标", isOn: Binding(
    get: { presentationPreferences.showsMenuBarIcon },
    set: { presentationPreferences.showsMenuBarIcon = $0 }
))
```

Include help text explaining that Dock and the main window remain available.

- [ ] **Step 6: Add UI assertions**

Extend the isolated UI host so the test can open preferences and assert:

- `settings.sidebar` does not exist in preferences;
- `preferences.addWorkspace` exists with no workspaces;
- workspace mode still exposes `settings.sidebar`.

Do not open a real `NSOpenPanel` in UI tests; only verify the button’s existence.

- [ ] **Step 7: Run navigation and UI tests**

Run:

```bash
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBar \
  -derivedDataPath /tmp/DevBarDerivedData \
  -only-testing:DevBarAppTests/SettingsViewModelNavigationTests \
  -only-testing:DevBarUITests/MenuBarFlowUITests
```

Expected: tests pass without reading or writing production configuration.

### Task 3: Bind menu-bar insertion and replace status icon

**Files:**
- Modify: `Sources/DevBarApp/DevBarApp.swift`
- Modify: `Sources/DevBarApp/AppDependencies.swift`
- Create: `Tests/DevBarAppTests/StatusItemSymbolTests.swift`

**Interfaces:**
- Consumes: `AppPresentationPreferences.showsMenuBarIcon`
- Produces: `func statusItemSymbol(for aggregateStatus: AggregateStatus) -> String`

- [ ] **Step 1: Add status-symbol mapping tests**

Move the mapping into an internal pure function or internal type and verify:

```swift
XCTAssertEqual(statusItemSymbol(for: .neutral), "hammer")
XCTAssertEqual(statusItemSymbol(for: .working), "hammer.fill")
XCTAssertEqual(statusItemSymbol(for: .ready), "checkmark.circle.fill")
XCTAssertEqual(statusItemSymbol(for: .error), "exclamationmark.triangle.fill")
```

- [ ] **Step 2: Run the focused tests and confirm failure**

Run:

```bash
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBarAppTests \
  -derivedDataPath /tmp/DevBarDerivedData \
  -only-testing:DevBarAppTests/StatusItemSymbolTests
```

Expected: compilation fails because the pure mapping does not exist.

- [ ] **Step 3: Share a stable presentation-preference instance**

Create the production instance once in `ProductionDevBarApp.init()` using `.standard`. Pass the same object to settings content. The UI-test app must use a unique defaults suite or in-memory-isolated test instance.

- [ ] **Step 4: Bind scene insertion**

Change production `MenuBarExtra` to the `isInserted` initializer with:

```swift
Binding(
    get: { presentationPreferences.showsMenuBarIcon },
    set: { presentationPreferences.showsMenuBarIcon = $0 }
)
```

Hiding the scene must not terminate the app, close the main window, stop services, or replace dependencies.

- [ ] **Step 5: Replace the icon mapping**

Use the tested mapping function from `ProductionStatusItem` and retain the “DevBar” accessibility label.

- [ ] **Step 6: Run focused and lifecycle tests**

Run:

```bash
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBarAppTests \
  -derivedDataPath /tmp/DevBarDerivedData
```

Expected: presentation, symbol, main-window coordinator, and application lifecycle tests pass.

### Task 4: Replace fragile service-editor bindings with a local draft

**Files:**
- Modify: `Sources/DevBarApp/Views/Settings/SettingsRootView.swift`
- Modify: `Sources/DevBarApp/Views/Settings/ServiceEditorSheet.swift`
- Modify: `Sources/DevBarApp/ViewModels/SettingsViewModel.swift`
- Create: `Tests/DevBarAppTests/ServiceEditorStateTests.swift`

**Interfaces:**
- Produces: `@discardableResult func commitServiceEditor(workspaceID: UUID, draft: ServiceEditorDraft) -> Bool`
- Produces: `func endServiceEditing()`
- Produces: `func chooseServiceDirectory(workspaceID: UUID, for service: ServiceConfig) async -> ServiceConfig`

- [ ] **Step 1: Write state-boundary tests**

Verify:

```swift
func testCancelingEditorDoesNotMutateConfiguration() {
    let viewModel = makeViewModelWithOneService()
    viewModel.beginEditingService(workspaceID: workspaceID, serviceID: serviceID)
    var editor = try XCTUnwrap(viewModel.serviceEditor)
    editor.service.command = "replacement"
    viewModel.endServiceEditing()
    XCTAssertEqual(viewModel.draft.workspaces[0].services[0].command, "original")
}

func testCommittingEditorUpdatesExactlyOneService() {
    let viewModel = makeViewModelWithOneService()
    viewModel.beginEditingService(workspaceID: workspaceID, serviceID: serviceID)
    var editor = try XCTUnwrap(viewModel.serviceEditor)
    editor.service.command = "replacement"
    XCTAssertTrue(viewModel.commitServiceEditor(workspaceID: workspaceID, draft: editor))
    XCTAssertEqual(viewModel.draft.workspaces[0].services.map(\.command), ["replacement"])
}

func testCommitFailsSafelyWhenWorkspaceDisappears() {
    let viewModel = makeViewModelWithOneService()
    viewModel.beginEditingService(workspaceID: workspaceID, serviceID: serviceID)
    let editor = try XCTUnwrap(viewModel.serviceEditor)
    viewModel.deleteWorkspace(workspaceID)
    XCTAssertFalse(viewModel.commitServiceEditor(workspaceID: workspaceID, draft: editor))
}
```

- [ ] **Step 2: Run the focused tests and confirm failure**

Run:

```bash
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBarAppTests \
  -derivedDataPath /tmp/DevBarDerivedData \
  -only-testing:DevBarAppTests/ServiceEditorStateTests
```

Expected: compilation fails because the explicit draft commit and end methods are missing.

- [ ] **Step 3: Add explicit ViewModel boundaries**

Make commit consume the provided `ServiceEditorDraft`. For existing services, fail if the target service no longer exists. For new services, append only when the workspace exists. On failure, set a user-visible failure notice and return `false`.

Add `endServiceEditing()` to set `serviceEditor = nil`.

Change directory selection to return an updated copy of the provided local service rather than mutating `serviceEditor`.

- [ ] **Step 4: Give the Sheet local state**

Initialize:

```swift
@State private var service: ServiceConfig
private let serviceID: UUID?

init(viewModel: SettingsViewModel, workspaceID: UUID, draft: ServiceEditorDraft) {
    self.viewModel = viewModel
    self.workspaceID = workspaceID
    serviceID = draft.serviceID
    _service = State(initialValue: draft.service)
}
```

Bind controls directly to `$service` and derived bindings over `service.healthCheck`. Delete `serviceBinding(_:)`, `mutateService(_:)`, and the `preconditionFailure`.

- [ ] **Step 5: Make dismissal explicit and idempotent**

Create a draft from `serviceID` and local `service` only when saving. If commit succeeds, call `endServiceEditing()`. Cancel and close call `endServiceEditing()` without committing. Add `.sheet(item:onDismiss:)` so system dismissal also clears editor state.

- [ ] **Step 6: Run service-editor and UI tests**

Run:

```bash
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBar \
  -derivedDataPath /tmp/DevBarDerivedData \
  -only-testing:DevBarAppTests/ServiceEditorStateTests \
  -only-testing:DevBarUITests/MenuBarFlowUITests
```

Expected: editing, canceling, closing, and saving no longer terminate the app, and the configuration changes only on save.

### Task 5: Full regression and deliverable verification

**Files:**
- Modify only if verification exposes a defect in files already listed above.

**Interfaces:**
- Verifies all interfaces from Tasks 1–4.

- [ ] **Step 1: Regenerate and check project drift**

Run:

```bash
xcodegen generate
git diff --check
```

Confirm no target or scheme is unintentionally removed.

- [ ] **Step 2: Run all automated tests**

Run:

```bash
xcodebuild test \
  -project DevBar.xcodeproj \
  -scheme DevBar \
  -derivedDataPath /tmp/DevBarDerivedData
```

Expected: all unit, integration, application lifecycle, and UI tests pass.

- [ ] **Step 3: Build the application**

Run:

```bash
xcodebuild build \
  -project DevBar.xcodeproj \
  -scheme DevBar \
  -configuration Debug \
  -derivedDataPath /tmp/DevBarDerivedData
```

Expected: `** BUILD SUCCEEDED **` and a runnable `DevBar.app` exists under the derived-data products directory.

- [ ] **Step 4: Self-review the final diff**

Check:

- no `preconditionFailure` remains in service editor code;
- menu visibility writes no `AppConfig` field;
- UI-test defaults cannot mutate `.standard`;
- preferences does not construct the sidebar;
- hiding the menu icon does not touch service lifecycle;
- `git diff --check` is clean.

- [ ] **Step 5: Hand off for user testing**

Report the build path, automated verification status, and these manual checks:

1. preferences uses the full window;
2. add/return workspace navigation works;
3. menu icon hides, restores, and persists;
4. Dock/main window remain after hiding it;
5. command editing, canceling, and saving do not exit the app.
