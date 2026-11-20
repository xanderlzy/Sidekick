# Window Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Window Manager tool to Sidekick. It moves and resizes the frontmost window with Rectangle's 23 default-key actions, and snaps windows dragged to screen edges or corners, with an animated preview.

**Architecture:**
- **Pure logic.** `Layout`, `CycleState`, `RestoreStore`, `SnapAreas`, `ScreenGeometry` and `DragClassifier` are unit-tested without real windows. All of their geometry is in Accessibility (AX) coordinates: global, with the origin at the primary screen's top-left and y pointing down.
- **Thin AppKit/AX adapters.** `AXWindow`, `DragSnapMonitor` and `SnapPreviewPanel` do the system work.
- **`WindowMover`** ties the pure logic to windows through a `WindowHandle` protocol, so it can be tested with a fake window.
- **`WindowManagerTool`** plugs into the existing `Tool` / `ToolRegistry` / onboarding contract.

**Tech Stack:**
- Swift 6 strict concurrency, SwiftUI + AppKit, macOS 26 arm64.
- XcodeGen. `project.yml` globs `Sidekick/` and `SidekickTests/`, so new files need no project edits.
- swift-testing.
- KeyboardShortcuts 2.x: `onKeyDown(for:)`, `removeHandler(for:)`, `reset(_:)`, `Recorder`, `globalKeyboardShortcut`.
- The ApplicationServices AX APIs.

**Spec:** `docs/superpowers/specs/2026-11-21-window-manager-design.md`

## Global Constraints
- **Concurrency:** Swift 6 strict concurrency. Every new type that touches AppKit, AX or KeyboardShortcuts is `@MainActor`. Pure value types are `Sendable`.
- **No private APIs** (SkyLight/CGS, `_AXUIElementGetWindow`), and nothing that needs SIP off.
- **Off means off:** when the tool is off, there are no key handlers, no mouse monitor and no panel.
- **Tool identity:**
  - id `"windowManager"`, name `"Window Manager"`
  - `permissions: [.accessibility]`, `setupSteps: [.accessibility]`
  - Off by default: `ToolRegistry`'s default stays `["dictation"]`.
- **Summary copy:** "Snap windows to halves, thirds and corners with shortcuts or by dragging to the screen's edges."
- **Motion:** windows jump instantly. Only the snap preview animates: `Motion.snappy` in, `Motion.fluid` between targets, then a fade out.
- **No Rectangle-running warning,** anywhere.
- **Dictation's behaviour must not change.**
- **Tests:** run `scripts/test.sh <SuiteName>` for one suite and `scripts/test.sh` for the full suite. Every task ends with the full suite green.
- **Commits:** end each commit message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.

## Review Focus
1. **No usable window.** With no focused window, a full-screen or minimized window, or a click on the Dock or desktop, every action does nothing and nothing crashes. Tests: Task 4, `noWindowIsNoOp` and `fullScreenIsNoOp`.
2. **Displays at negative coordinates.** With a display to the left of or above the main one, layouts land on the correct screen. Tests: Task 1, `layoutOnDisplayLeftOfMain` and `layoutOnDisplayAboveMain`.
3. **Apps that refuse the size** (a minimum or fixed size). The window still lands anchored inside the target area and isn't pushed off screen. Tests: Task 4, `minSizeWindowAnchoredRight` and `fixedSizeCentered`.
4. **Drags that aren't window moves** (resizing a window by its edge, text selection, file drags) never show a preview or snap. Tests: Task 7, `resizeIsNotWindowDrag` and `stillWindowIsNotWindowDrag`.
5. **Crossing the edge between two displays** never snaps. Test: Task 6, `sharedEdgeDoesNotSnap`.

---

### Task 1: Actions, screen geometry and layout math

**Files:**
- Create:
  - `Sidekick/Tools/WindowManager/WindowAction.swift`
  - `Sidekick/Tools/WindowManager/ScreenGeometry.swift`
  - `Sidekick/Tools/WindowManager/Layout.swift`
- Test:
  - `SidekickTests/WindowManager/LayoutTests.swift`
  - `SidekickTests/WindowManager/ScreenGeometryTests.swift`
  - `SidekickTests/WindowManager/WindowActionTests.swift`

**Interfaces (produces):**
- **`WindowAction`:** `enum WindowAction: String, CaseIterable, Sendable` with exactly these 23 cases, in this order: `leftHalf, rightHalf, topHalf, bottomHalf, topLeft, topRight, bottomLeft, bottomRight, firstThird, centerThird, lastThird, firstTwoThirds, centerTwoThirds, lastTwoThirds, maximize, almostMaximize, maximizeHeight, larger, smaller, center, restore, nextDisplay, previousDisplay`.
  - `var title: String`, such as "Left Half", "Center Two Thirds", "Make Larger" or "Next Display".
  - `var group: WindowAction.Group`, with `enum Group: String, CaseIterable { case halves = "Halves", corners = "Corners", thirds = "Thirds", size = "Size", displays = "Displays" }`.
    - The two-thirds actions belong to Thirds.
    - Maximize, almost maximize, maximize height, larger, smaller, center and restore belong to Size.
  - `var defaultShortcut: KeyboardShortcuts.Shortcut?`
  - `var shortcutName: KeyboardShortcuts.Name`, with raw value `"wm.\(rawValue)"` and the default attached. A `static let` dictionary backs it, so each `Name` is built exactly once.
- **`Display`:** `struct Display: Equatable, Sendable { let frame: CGRect; let visible: CGRect }`, in AX coordinates.
- **`ScreenGeometry`** (a caseless enum):
  - `flip(_ r: CGRect, primaryHeight: CGFloat) -> CGRect` converts between Cocoa and AX coordinates (`y' = primaryHeight - r.maxY`). It is its own inverse.
  - `flip(_ p: CGPoint, primaryHeight: CGFloat) -> CGPoint`
  - `currentDisplays() -> [Display]` (`@MainActor`) builds from `NSScreen.screens`, with primaryHeight = `NSScreen.screens[0].frame.height`.
  - `ordered(_ displays: [Display]) -> [Display]` sorts by `frame.minX`, then `frame.minY`.
  - `display(for window: CGRect, in displays: [Display]) -> Display?` returns the display with the largest intersection. If none intersects, the one containing the window's centre. Otherwise nil.
  - `neighbor(of d: Display, in displays: [Display], offset: Int) -> Display` steps through the ordered list, wrapping around.
- **`Layout`** (a caseless enum):
  - `static func target(for action: WindowAction, window: CGRect, display: Display, displays: [Display], step: Int) -> CGRect?`
  - Returns nil for `.restore`, which `WindowMover` handles, and for display moves when there's only one display.
  - `static let sizeStep: CGFloat = 30`
  - `static let minSize = CGSize(width: 200, height: 150)`
  - `static let almostMaximizeFraction: CGFloat = 0.9`

- [ ] **Step 1: Write the failing tests**

Fixtures:
- `let main = Display(frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), visible: CGRect(x: 0, y: 25, width: 1600, height: 900))`, which has a 25pt menu bar and a 75pt Dock.
- `let portrait = Display(frame: CGRect(x: 1600, y: 0, width: 1000, height: 1600), visible: CGRect(x: 1600, y: 0, width: 1000, height: 1600))`

`LayoutTests`:
- `leftHalf`: `target(.leftHalf, …, step: 0) == CGRect(x: 0, y: 25, width: 800, height: 900)`.
- `halfCycleSteps`:
  - `.rightHalf` step 1 gives width 1066.67 at x 533.33 (½ to ⅔).
  - Step 2 gives width 533.33 (⅓).
  - Step 3 gives width 800 again.
  - `.topHalf` step 1 gives height 600.
- `cornersQuarter`: `.bottomRight` gives `CGRect(x: 800, y: 475, width: 800, height: 450)`.
- `thirdsLandscape`:
  - `.firstThird` gives x 0 and width 533.33 at step 0, x 533.33 at step 1, and x 1066.67 at step 2.
  - `.lastThird` step 1 gives x 533.33.
  - `.centerThird` gives x 533.33 at any step.
- `thirdsPortrait`: on `portrait`, `.firstThird` gives `CGRect(x: 1600, y: 0, width: 1000, height: 533.33)`.
- `twoThirds`:
  - `.firstTwoThirds` gives x 0, width 1066.67.
  - `.centerTwoThirds` gives x 266.67, width 1066.67.
  - `.lastTwoThirds` gives x 533.33.
- `maximizeVariants`:
  - `.maximize` gives `main.visible`.
  - `.almostMaximize` gives `CGRect(x: 80, y: 70, width: 1440, height: 810)`.
  - `.maximizeHeight` with window `(100, 300, 500, 200)` gives `(100, 25, 500, 900)`.
- `largerSmaller`:
  - Window `(400, 300, 600, 400)`: `.larger` gives `(370, 270, 660, 460)`, and `.smaller` gives `(430, 330, 540, 340)`.
  - `.larger` on a window flush with `visible` stays inside `visible`.
  - `.smaller` on a 200×150 window keeps its size.
- `centerKeepsSize`: window `(0, 25, 400, 300)` gives `(600, 325, 400, 300)`.
- `nextDisplayProportional`:
  - The `main` left half moves to `portrait` as `(1600, 0, 500, 1600)`.
  - With order `[main, portrait]`, `nextDisplay` from `portrait` wraps to `main`.
  - With only `[main]`, it returns nil.
- `layoutOnDisplayLeftOfMain`: `Display(frame: (-1440, 100, 1440, 900), visible: same)`, `.leftHalf` gives `(-1440, 100, 720, 900)`.
- `layoutOnDisplayAboveMain`: `Display(frame: (0, -1080, 1920, 1080), visible: same)`, `.bottomHalf` gives `(0, -540, 1920, 540)`.
- `restoreIsNil`: `.restore` returns nil.

`ScreenGeometryTests`:
- `flipRoundTrips`: `flip(flip(r, h), h) == r`, and `flip(CGRect(x: 0, y: 0, width: 100, height: 25), primaryHeight: 1000) == CGRect(x: 0, y: 975, width: 100, height: 25)`.
- `displayForWindowPicksLargestOverlap`: a window with 60% of its area on `portrait` returns `portrait`.
- `displayForOffscreenWindowIsNil`
- `orderedLeftToRight`

`WindowActionTests`, `defaultsMatchRectangle`:
- Assert `defaultShortcut` for every case, using the spec table. Among them:
  - `.leftHalf == .init(.leftArrow, modifiers: [.control, .option])`
  - `.maximizeHeight == .init(.upArrow, modifiers: [.control, .option, .shift])`
  - `.restore == .init(.delete, modifiers: [.control, .option])`
  - `.centerTwoThirds == .init(.r, modifiers: [.control, .option])`
  - `.nextDisplay == .init(.rightArrow, modifiers: [.control, .option, .command])`
  - `.almostMaximize == nil`
- `WindowAction.allCases.count == 23`.
- All non-nil defaults are distinct.

- [ ] **Step 2: Run the tests and confirm they fail**

Run: `scripts/test.sh LayoutTests`. Expected: compile errors, because the types aren't defined yet.

- [ ] **Step 3: Implement `WindowAction`, `Display`, `ScreenGeometry` and `Layout` with the signatures above**
  - All layout happens within `display.visible`.
  - A display is portrait when `visible.height > visible.width`. On portrait displays, thirds and two-thirds split vertically, and halves keep their names.
  - Half cycle fractions are `[1/2, 2/3, 1/3][step % 3]`.
  - Third positions are `firstThird: [0, 1, 2][step % 3]` and `lastThird: [2, 1, 0][step % 3]`. Other actions ignore `step`.
  - Display moves map the window proportionally from the source's visible frame to the destination's visible frame, then clamp to the destination.
  - Make Larger grows the window by `sizeStep` on each side, intersected with `visible`.
  - Make Smaller shrinks it by `sizeStep` on each side, never below `minSize`. At that floor, the window keeps its current size.

- [ ] **Step 4: Run the tests and confirm they pass**

Run `scripts/test.sh LayoutTests`, then `ScreenGeometryTests`, then `WindowActionTests`. Expected: all pass.

- [ ] **Step 5: Commit**

`git add Sidekick/Tools/WindowManager SidekickTests/WindowManager && git commit -m "feat(window-manager): actions, screen geometry and layout"`

---

### Task 2: Repeat-press cycling and restore memory

**Files:**
- Create:
  - `Sidekick/Tools/WindowManager/CycleState.swift`
  - `Sidekick/Tools/WindowManager/RestoreStore.swift`
- Test:
  - `SidekickTests/WindowManager/CycleStateTests.swift`
  - `SidekickTests/WindowManager/RestoreStoreTests.swift`

**Interfaces:**
- Consumes: `WindowAction`.
- Produces `struct CycleState: Sendable`:
  - `mutating func step(for action: WindowAction, window: AnyHashable, currentFrame: CGRect) -> Int` returns the step to use.
  - `mutating func didSet(_ frame: CGRect, for action: WindowAction, window: AnyHashable)`
  - `static let cycling: Set<WindowAction> = [.leftHalf, .rightHalf, .topHalf, .bottomHalf, .firstThird, .lastThird]`
  - There's no time limit on repeats. This was the builder's call in the spec, and matches Rectangle.
- Produces `struct RestoreStore: Sendable`:
  - `mutating func rememberIfNeeded(_ frame: CGRect, for window: AnyHashable)` records only the first move.
  - `func original(for window: AnyHashable) -> CGRect?`
  - `mutating func take(for window: AnyHashable) -> CGRect?` returns the frame and forgets it.
  - Holds at most 100 entries, evicting the oldest first.

- [ ] **Step 1: Write the failing tests**
  - `firstPressIsStepZero`
  - `repeatSameActionAdvances`: after `didSet(f, .leftHalf, w)`, `step(.leftHalf, w, currentFrame: f)` returns 1, then 2, then 0, with a `didSet` between each call.
  - `frameWithin2ptStillRepeats`: a frame off by 1.5pt still advances.
  - `movedWindowResets`: a frame off by 10pt gives 0.
  - `otherActionResets`: `.rightHalf` after `.leftHalf` gives 0.
  - `otherWindowResets`
  - `nonCyclingAlwaysZero`: `.maximize` twice gives 0 and 0.
  - `rememberOnlyFirst`: remembering A, then B, leaves `original == A`.
  - `takeForgets`: `take` returns A, then nil.
  - `evictsOldestPast100`

- [ ] **Step 2: Run the tests and confirm they fail**

`scripts/test.sh CycleStateTests` fails to compile.

- [ ] **Step 3: Implement the two structs**

Frame equality uses a 2pt tolerance on each edge.

- [ ] **Step 4: Run the tests and confirm they pass**

`scripts/test.sh CycleStateTests` and `scripts/test.sh RestoreStoreTests` pass.

- [ ] **Step 5: Commit**

`git commit -m "feat(window-manager): repeat-press cycling and restore memory"`

---

### Task 3: Accessibility window adapter

**Files:**
- Create: `Sidekick/Tools/WindowManager/AXWindow.swift`
- Test: `SidekickTests/WindowManager/AXWindowTests.swift`. Keep it light: only the identity wrapper is tested.

**Interfaces (produces):**
- **`WindowHandle`:**
  ```swift
  @MainActor protocol WindowHandle: AnyObject {
      var id: AnyHashable { get }
      var frame: CGRect? { get }      // nil when AX fails
      var isFullScreen: Bool { get }
      var isMinimized: Bool { get }
      @discardableResult func setFrame(_ frame: CGRect) -> Bool
  }
  ```
- **`@MainActor final class AXWindow: WindowHandle`:**
  - `init(element: AXUIElement)`
  - `static func focused() -> AXWindow?` goes from `NSWorkspace.shared.frontmostApplication` to `AXUIElementCreateApplication(pid)` to `kAXFocusedWindowAttribute`.
  - `static func at(_ axPoint: CGPoint) -> AXWindow?` calls `AXUIElementCopyElementAtPosition` on the system-wide element. It then takes the element's `kAXWindowAttribute`, or the element itself if its role is `kAXWindowRole`.
  - `id` is `AnyHashable(AXElementKey(element))`.
  - `setFrame` sets size, then position, then size again, because some apps clamp to the current screen. It returns false if any `AXUIElementSetAttributeValue` fails, including when Accessibility has been revoked.
  - `isFullScreen` reads `"AXFullScreen"`, and `isMinimized` reads `kAXMinimizedAttribute`.
- **`struct AXElementKey: Hashable`** wraps an `AXUIElement`, using `CFHash` and `CFEqual`.

- [ ] **Step 1: Write the failing test**

`keyEqualityForSameElement`: two `AXElementKey` values built from the same `AXUIElementCreateApplication(getpid())` are equal and hash the same.

- [ ] **Step 2: Run the test and confirm it fails**

`scripts/test.sh AXWindowTests` fails to compile.

- [ ] **Step 3: Implement `AXWindow` and `AXElementKey`**

- [ ] **Step 4: Run the test and confirm it passes**

`scripts/test.sh AXWindowTests` passes.

- [ ] **Step 5: Commit**

`git commit -m "feat(window-manager): accessibility window adapter"`

---

### Task 4: WindowMover (apply an action to a window)

**Files:**
- Create: `Sidekick/Tools/WindowManager/WindowMover.swift`
- Modify: `Sidekick/Tools/WindowManager/Layout.swift`, to add `adjust`.
- Test: `SidekickTests/WindowManager/WindowMoverTests.swift`. It includes a `FakeWindow: WindowHandle` with optional `minSize`, optional `fixedSize`, `failsSet`, `isFullScreen` and `isMinimized`.

**Interfaces:**
- Consumes: `Layout.target`, `ScreenGeometry`, `CycleState`, `RestoreStore`, `WindowHandle`, `AXWindow.focused`.
- **`Layout.adjust(target: CGRect, actual: CGSize, visible: CGRect) -> CGRect`:**
  - If the actual width differs from the target's:
    - If the target touches only `visible.minX`, keep `minX`.
    - If it touches only `visible.maxX`, keep `maxX`.
    - Otherwise centre on `target.midX`.
  - Apply the same rules vertically.
  - Then shift the result so it stays inside `visible` wherever it fits.
- **`@MainActor final class WindowMover`:**
  - `init(displays: @escaping @MainActor () -> [Display] = ScreenGeometry.currentDisplays, focusedWindow: @escaping @MainActor () -> (any WindowHandle)? = AXWindow.focused)`
  - `func perform(_ action: WindowAction)` acts on the focused window.
  - `func perform(_ action: WindowAction, on window: any WindowHandle)`
  - `func lastApplied(for window: AnyHashable) -> CGRect?`
  - `var restore: RestoreStore` is internal, so Task 7 can read it.
- **What `perform(_:on:)` does, in order:**
  1. Bail out if the window is full screen or minimized, or its `frame` is nil.
  2. Pick the display with `ScreenGeometry.display(for:in:)`.
  3. For `.restore`, call `restore.take` and set that frame.
  4. For any other action:
     - `step = cycle.step(...)`, then `target = Layout.target(...)`. Bail out if the target is nil.
     - `restore.rememberIfNeeded(current)`, then `setFrame(target)`.
     - Read the frame back. If its size differs by more than 2pt, `setFrame(Layout.adjust(...))` using the destination display's visible frame.
     - Finally, `cycle.didSet(final frame)`.

- [ ] **Step 1: Write the failing tests**
  - `appliesLeftHalf`: the fake ends at `(0, 25, 800, 900)` on Task 1's `main` display.
  - `repeatCyclesToTwoThirds`: two `perform(.leftHalf)` calls give width 1066.67.
  - `restoreReturnsOriginal`:
    - Start at `(100, 100, 500, 400)`, then run `.maximize`, `.leftHalf` and `.restore`. The window returns to `(100, 100, 500, 400)`.
    - A second `.restore` changes nothing.
  - `minSizeWindowAnchoredRight`: a fake with a 1000pt minimum width, given `.rightHalf`, ends with `maxX == 1600` and width 1000.
  - `fixedSizeCentered`: a fake fixed at 700×700, given `.maximize`, ends centred in `visible`.
  - `noWindowIsNoOp`: `focusedWindow` returns nil, and `perform(.leftHalf)` doesn't crash.
  - `fullScreenIsNoOp`: the fake's frame doesn't change.
  - `failedSetIsNoOp`: with `failsSet`, nothing crashes and `lastApplied` is nil.

- [ ] **Step 2: Run the tests and confirm they fail**

`scripts/test.sh WindowMoverTests` fails to compile.

- [ ] **Step 3: Implement `Layout.adjust` and `WindowMover`**

- [ ] **Step 4: Run the tests and confirm they pass**

Run `scripts/test.sh WindowMoverTests`, then the full `scripts/test.sh`.

- [ ] **Step 5: Commit**

`git commit -m "feat(window-manager): window mover with cycling, restore and resistant-window anchoring"`

---

### Task 5: The tool: shortcuts, settings page, menu and shared Accessibility step

**Files:**
- Create:
  - `Sidekick/Tools/WindowManager/WindowManagerTool.swift`
  - `Sidekick/Tools/WindowManager/WindowManagerSettingsView.swift`
- Move: `Sidekick/Tools/Dictation/Steps/AccessibilityStep.swift` to `Sidekick/UI/Onboarding/Steps/AccessibilityStep.swift`
- Modify:
  - `Sidekick/Core/Tool.swift`: add `menuTitle`, `accessibilityGranted()` and `ToolMenuItem.inCheatSheet`.
  - `Sidekick/UI/Onboarding/OnboardingView.swift`: route `.accessibility` outside `DictationStepHost`.
  - `Sidekick/Tools/Dictation/DictationTool.swift`: implement `accessibilityGranted()`.
  - `Sidekick/App/SidekickApp.swift`: add the submenu in `MenuContent`.
  - `Sidekick/UI/Onboarding/Steps/FinishStep.swift`: filter by `inCheatSheet`.
  - `Sidekick/App/AppEnvironment.swift`: register the tool after Dictation.
- Test:
  - `SidekickTests/WindowManager/WindowManagerToolTests.swift`
  - Additions to `DictationToolTests.swift` and `OnboardingFlowTests.swift`

**Interfaces:**
- Consumes: `WindowAction.shortcutName`, `WindowMover.perform(_:)`.
- **Additions to `Tool.swift`:**
  - `var menuTitle: String? { get }`. When it's set, the tool's menu items go in a submenu with that title. A protocol extension makes it `nil` by default.
  - `func accessibilityGranted()`, called when the shared step sees the permission granted. A protocol extension makes it do nothing by default.
  - `ToolMenuItem` gains `var inCheatSheet: Bool = true`, a memberwise init parameter with a default value, so existing call sites still compile.
- **`@MainActor final class WindowManagerTool: Tool`:**
  - `init(defaults: UserDefaults = .standard, mover: WindowMover = WindowMover(), snapping: (any SnapController)? = nil)`.
    - Until Task 7, this task declares `@MainActor protocol SnapController: AnyObject { func start(); func stop() }` in `WindowManagerTool.swift`.
  - `private(set) var isRunning: Bool`
  - `static let snapEnabledKey = "windowManager.snapEnabled"`, true by default.
  - `start()` registers `KeyboardShortcuts.onKeyDown(for: action.shortcutName) { mover.perform(action) }` for every action. If snapping is enabled, it also starts the snap controller. Calling `start()` twice has no extra effect.
  - `stop()` calls `KeyboardShortcuts.removeHandler(for:)` for every action, then `snapping?.stop()`.
  - `func setSnapping(_ on: Bool)`
  - `accessibilityGranted()` calls `stop()` then `start()` if the tool is running.
  - `menuTitle = "Window Manager"`.
  - `menuItems` has one item per action, in `allCases` order. `inCheatSheet` is true only for the four halves.
  - `pages = [ToolPage(id: "settings", title: "Settings")]`.
- **`WindowManagerSettingsView`** follows `DictationSettingsView`'s scroll and spacing structure:
  - `PageHeader("Window Manager")`.
  - A `SettingsSection("Snapping")` with a "Snap windows by dragging" row. Its detail reads "Drag a window to an edge or corner of the screen." Its `MonoToggleStyle` toggle calls `setSnapping`.
  - One `SettingsSection` per `WindowAction.Group`, each row with a `KeyboardShortcuts.Recorder(for: action.shortcutName)` control.
  - A "Restore default shortcuts" button at the bottom, which calls `KeyboardShortcuts.reset(WindowAction.allCases.map(\.shortcutName))`.
- **Shared Accessibility step:**
  - `AccessibilityStep(next:)` no longer takes a `DictationEnvironment`.
  - Title: "Allow Accessibility".
  - Message: "Accessibility lets Sidekick notice your shortcuts, paste dictated text and move windows. Turn on Sidekick in the list that opens."
  - On grant, it calls `AppEnvironment.shared.registry.tools.forEach { $0.accessibilityGranted() }` in place of `env.startHotkeys()`, then keeps the existing window-show and auto-advance.
  - `DictationTool.accessibilityGranted()` calls `env?.startHotkeys()`, and does nothing if `env` is nil.
  - In `OnboardingView.step(_:)`, `.accessibility` becomes `AccessibilityStep(next: advance(from: s))`, no longer wrapped in `dictationStep`.

- [ ] **Step 1: Write the failing tests**

`WindowManagerToolTests`:
- `identity`: the id, name, `permissions == [.accessibility]`, `setupSteps == [.accessibility]` and `menuTitle == "Window Manager"`.
- `menuHasAllActionsWithFourInCheatSheet`: there are 23 items, and exactly `[leftHalf, rightHalf, topHalf, bottomHalf]` have `inCheatSheet`.
- `startStopIdempotent`: start twice, then stop. `isRunning` tracks this, and a fake `SnapController` sees `start` once and `stop` once.
- `snapToggleOffSkipsSnapping`:
  - With `defaults.set(false, forKey: snapEnabledKey)`, `start()` doesn't start the fake.
  - `setSnapping(true)` while running starts it.
- `notEnabledByDefault`: `ToolRegistry(tools: [DictationTool(...), WindowManagerTool(...)], defaults: sandbox)` has only `"dictation"` enabled.

`DictationToolTests`:
- `accessibilityGrantedWithoutEnvDoesNotStart`: a fresh `DictationTool(startServices: false)` still has `env == nil` after `accessibilityGranted()`.

`OnboardingFlowTests`:
- `windowManagerAndDictationShareAccessibility`: two `FakeTool`s with setup steps `[.accessibility]` and `[.microphone, .accessibility]` produce `.accessibility` only once.

- [ ] **Step 2: Run the tests and confirm they fail**

`scripts/test.sh WindowManagerToolTests` fails to compile.

- [ ] **Step 3: Implement everything above**

This covers the tool, the protocol additions, moving the shared step, the `OnboardingView` routing, the menu, the cheat sheet and the registration. In `MenuContent`, when `tool.menuTitle` is set, wrap that tool's buttons in `Menu(title) { … }`, keeping `.globalKeyboardShortcut` on each.

- [ ] **Step 4: Run the full suite and confirm it passes**

`scripts/test.sh` passes, including the existing Dictation and onboarding suites.

- [ ] **Step 5: Check the settings page render**

Add a `WindowManagerSettingsView` case to `ScreenRenderTests`, following the existing pattern. Run `TEST_RUNNER_SIDEKICK_RENDER_SCREENS=1 scripts/test.sh ScreenRenderTests` and look at the PNG in `.superpowers/screens/`. The rows should line up, the recorders should fit, and nothing should be clipped at 800×560.

- [ ] **Step 6: Commit**

`git commit -m "feat(window-manager): tool, shortcuts, settings page, menu; share Accessibility step"`

---

### Task 6: Snap areas

**Files:**
- Create: `Sidekick/Tools/WindowManager/SnapAreas.swift`
- Test: `SidekickTests/WindowManager/SnapAreasTests.swift`

**Interfaces:**
- Consumes: `Display`, `WindowAction`.
- Produces `SnapAreas` (a caseless enum):
  - `static func action(at cursor: CGPoint, on display: Display, displays: [Display], previous: WindowAction?) -> WindowAction?`
  - `edgeMargin: CGFloat = 5`, `cornerSize: CGFloat = 20`, `shortEdgeSize: CGFloat = 145`
- **Rules.** The cursor is in AX coordinates and is measured against `display.frame`, not the visible frame.
  - **At an edge** means the cursor is within `edgeMargin` of that edge, and a 1pt probe just past the edge at the cursor's position falls inside no other display.
  - **Corner:** at the left or right edge within `cornerSize` of the top or bottom, or at the top or bottom edge within `cornerSize` of the left or right. Snaps to that quarter.
  - **Left or right edge:**
    - Within `shortEdgeSize` of the top gives `.topHalf`.
    - Within `shortEdgeSize` of the bottom gives `.bottomHalf`.
    - Anywhere else gives `.leftHalf` or `.rightHalf`.
  - **Top edge** gives `.maximize`.
  - **Bottom edge** is split into thirds of the width, giving `.firstThird`, `.centerThird` or `.lastThird`. In the middle third:
    - If `previous` is `.firstThird` or `.firstTwoThirds`, it gives `.firstTwoThirds`.
    - If `previous` is `.lastThird` or `.lastTwoThirds`, it gives `.lastTwoThirds`.

- [ ] **Step 1: Write the failing tests**

These use Task 1's `main` display, plus a left neighbour `Display(frame: (-1440, 0, 1440, 900), …)`.
- `leftEdge`: `(2, 500)` gives `.leftHalf`.
- `rightEdge`: `(1598, 500)` gives `.rightHalf`.
- `topEdge`: `(800, 1)` gives `.maximize`.
- `corners`: `(1, 1)` gives `.topLeft`, and `(1599, 999)` gives `.bottomRight`.
- `shortEdgeHalves`: `(1, 100)` gives `.topHalf`, and `(1, 900)` gives `.bottomHalf`.
- `bottomThirds`: `(200, 999)` gives `.firstThird`, `(800, 999)` gives `.centerThird`, and `(1400, 999)` gives `.lastThird`.
- `bottomTwoThirdsGesture`: `(800, 999)` gives:
  - `.firstTwoThirds` with previous `.firstThird`;
  - `.lastTwoThirds` with previous `.lastThird`;
  - `.firstTwoThirds` with previous `.firstTwoThirds`.
- `interiorIsNil`: `(800, 500)` gives nil.
- `sharedEdgeDoesNotSnap`: with the left neighbour present, `(2, 500)` gives nil while `(1598, 500)` gives `.rightHalf`.

- [ ] **Step 2: Run the tests and confirm they fail**

`scripts/test.sh SnapAreasTests` fails to compile.

- [ ] **Step 3: Implement `SnapAreas.action`**

- [ ] **Step 4: Run the tests and confirm they pass**

`scripts/test.sh SnapAreasTests` passes.

- [ ] **Step 5: Commit**

`git commit -m "feat(window-manager): snap areas"`

---

### Task 7: Drag-to-snap monitor and preview

**Files:**
- Create:
  - `Sidekick/Tools/WindowManager/DragClassifier.swift`
  - `Sidekick/Tools/WindowManager/DragSnapMonitor.swift`
  - `Sidekick/Tools/WindowManager/SnapPreviewPanel.swift`
- Modify: `WindowManagerTool.swift`. Move the `SnapController` protocol into `DragSnapMonitor.swift`, and have the default init create `DragSnapMonitor(mover:)`.
- Test: `SidekickTests/WindowManager/DragClassifierTests.swift`

**Interfaces:**
- Consumes: `SnapAreas.action`, `ScreenGeometry`, `WindowMover.perform(_:on:)`, `WindowMover.lastApplied(for:)`, `WindowMover.restore`, `AXWindow.at(_:)`.
- **`DragClassifier`** (a caseless enum):
  - `static func isWindowDrag(start: CGRect, now: CGRect) -> Bool`: true when the origin has moved more than 2pt and the size is unchanged (±1pt).
  - `static func unsnapFrame(current: CGRect, original: CGSize, cursor: CGPoint) -> CGRect`: the original size, placed so the cursor stays at the same fraction across the title bar. `x = cursor.x - (cursor.x - current.minX) * original.width / current.width`, and `y = current.minY`.
- **`@MainActor final class DragSnapMonitor: SnapController`:**
  - `init(mover: WindowMover)`
  - `start()` adds one `NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp])`.
  - `stop()` removes the monitor, hides the preview and resets state.
  - **Mouse down:** `window = AXWindow.at(cursorAX)` and `startFrame = window.frame`.
  - **Dragged, before the drag is classified:** read `window.frame`. Once `isWindowDrag` is true, mark this drag as a window drag. At that moment, if `mover.lastApplied(for: id)` matches the current frame (±2pt) and `mover.restore.original(for: id)` exists, set `unsnapFrame` and call `restore.take`.
  - **Dragged, once it is a window drag:** find the display under the cursor and call `SnapAreas.action(previous: lastAction)`. Show, update or hide the preview with `Layout.target(...)` for that action, at step 0.
  - **Mouse up:** if there's an action, `mover.perform(action, on: window)`. Always hide the preview and reset.
- **`@MainActor final class SnapPreviewPanel`:**
  - `func show(_ axRect: CGRect, on display: Display)` and `func hide()`.
  - It's a borderless, non-activating `NSPanel`:
    - `ignoresMouseEvents = true`, `level = .floating`
    - `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]`
    - a clear background, sized to cover the target display's frame (converted to Cocoa coordinates).
  - Its SwiftUI content is a `RoundedRectangle(cornerRadius: Theme.corner)`, inset 6pt inside the target rect, with fill `Theme.fg(0.08)` and a 1.5pt `Theme.fg(0.5)` stroke.
  - **Animation:**
    - The first show starts as a 40×40 rect at the cursor and springs to the target with `Motion.snappy`.
    - A change of target animates with `Motion.fluid`.
    - Hide fades to opacity 0 with `Motion.snappy`, then orders the panel out.

- [ ] **Step 1: Write the failing tests**
  - `moveIsWindowDrag`: start `(100, 100, 500, 400)`, now `(150, 120, 500, 400)`, gives true.
  - `resizeIsNotWindowDrag`: now `(100, 100, 560, 400)` gives false, and so does `(90, 100, 510, 400)`, a left-edge resize.
  - `stillWindowIsNotWindowDrag`: the same frame gives false.
  - `unsnapKeepsCursorFraction`: current `(0, 25, 800, 900)`, original 400×300 and cursor `(400, 30)` give `(200, 25, 400, 300)`.

- [ ] **Step 2: Run the tests and confirm they fail**

`scripts/test.sh DragClassifierTests` fails to compile.

- [ ] **Step 3: Implement**

Write `DragClassifier`, `SnapPreviewPanel` and `DragSnapMonitor`, and wire the monitor into `WindowManagerTool`'s default init.

- [ ] **Step 4: Run the full suite and confirm it passes**

`scripts/test.sh` passes.

- [ ] **Step 5: Commit**

`git commit -m "feat(window-manager): drag-to-snap with animated preview"`

---

### Task 8: Manual verification in the real app

**Files:** none, unless a defect is found. Fix any defect within this task, and add its regression test to the suite that owns that code.

- [ ] **Step 1: Build and launch**

Build and launch the Debug app, using the run skill or `xcodebuild` followed by `open`. Turn on Window Manager from Home. With Accessibility already granted, no setup sheet should appear.

- [ ] **Step 2: Work through the spec's manual checklist**

Record each line's result in the ledger.
- Every shortcut works in Finder, Safari, TextEdit and System Settings (which has a minimum size).
- Repeated presses cycle as specified.
- Restore works.
- Next and Previous Display work on two screens. If only one screen is available, record them as untested.
- Dragging to each zone shows the preview: it animates in, morphs between zones, and fades out.
- Text selection, file drags and resizing a window by its edge never snap.
- Dragging a snapped window away restores its original size under the cursor.
- Turning off "Snap windows by dragging" stops drag snapping.
- Turning the tool off silences everything.
- The submenu's actions apply to the previously frontmost window.
- Dictation still works.

- [ ] **Step 3: Commit any fixes**

`git commit -m "fix(window-manager): …"`
