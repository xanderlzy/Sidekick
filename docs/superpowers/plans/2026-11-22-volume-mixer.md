# Volume Mixer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Volume Mixer tool to Sidekick. It has its own menu bar speaker icon that opens a black and white panel, where each app's volume and mute can be set. Volumes are remembered per app and applied through Core Audio process taps.

**Architecture:**
- **Pure logic, unit-tested without Core Audio:**
  - `AppVolume` and `MixerSettingsStore` handle persistence and the gain curve.
  - `AppGrouping` maps audio processes to apps.
  - `MixerRules` decides which rows show and which apps need a tap.
- **Core Audio behind protocols:** `AudioSystem` and `TapHandle`. They have live implementations, `CoreAudioSystem` and `AppTap`.
- **`TapController`:** an `@Observable`, `@MainActor` class that reconciles taps with settings, processes and the output device. Tests use fakes.
- **UI:** `MixerStatusItem`, `MixerPanel` and `SystemVolume`.
- **`VolumeMixerTool`:** plugs into the existing `Tool`, `ToolRegistry` and onboarding contract.

**Tech Stack:**
- Swift 6 strict concurrency, SwiftUI + AppKit, macOS 26 arm64.
- CoreAudio: the process tap APIs `CATapDescription`, `AudioHardwareCreateProcessTap` and aggregate devices.
- `Synchronization.Atomic` for values shared with the audio thread.
- XcodeGen: `project.yml` globs `Sidekick/` and `SidekickTests/`. Regenerate and commit `Sidekick.xcodeproj` with each task that adds files.
- swift-testing.

**Spec:** `docs/superpowers/specs/2026-11-22-volume-mixer-design.md`

## Global Constraints
- **Concurrency:** Swift 6 strict concurrency. Types that touch AppKit or the UI are `@MainActor`. Pure value types are `Sendable`.
- **No private APIs.** Install no driver and need no admin password.
- **The real-time IO proc** never allocates, locks, logs or touches actor-isolated state. Gain and level cross threads only through `Atomic`.
- **Tool identity:**
  - id `"volumeMixer"`, name `"Volume Mixer"`, symbol `"speaker.wave.2"`
  - summary "Set each app's volume from the menu bar. Sidekick remembers it for next time."
  - `permissions: [.systemAudio]`, `setupSteps: [.systemAudio]`, `menuItems: []`
  - Off by default: `ToolRegistry`'s default stays `["dictation"]`.
- **Permission title** "System Audio Recording".
  - Info.plist `NSAudioCaptureUsageDescription`: "Sidekick's Volume Mixer adjusts each app's volume by routing its sound through Sidekick. Nothing is recorded or saved."
- **Settings:** stored in UserDefaults under `volumeMixer.settings`, keyed by bundle ID. The synthetic key `webkit.webcontent` is titled "Web content".
- **Gain:** `muted ? 0 : volume²`. The range is 0–100% with no boost. Gain changes ramp over about 20ms.
- **Untouched apps are never tapped.** An app at 100% and unmuted has no tap.
- **Off means off:** no status item, no taps, no listeners. Stored volumes are kept.
- **Never stuck silent.** On failure (permission, rebuild after one retry, app gone), release the app to normal sound.
- **Copy:**
  - "Nothing's playing right now."
  - "This device controls its own volume"
  - "Volume Mixer needs System Audio Recording"
  - "Couldn't keep [App]'s volume on this device"
  - "Volume Mixer settings…"
- **Motion:** the panel opens with `Motion.snappy` (scale and opacity from the top edge). Rows insert and remove with `Motion.fluid`. Ink and paper only (`Theme`).
- **Dictation and Window Manager behaviour must not change.**
- **Tests:** `scripts/test.sh <Suite>` runs one suite and `scripts/test.sh` runs everything. Every task ends with the full suite green. Unit tests never touch real Core Audio, taps or the permission.
- **Commits:** end each message with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.

## Review Focus
1. **The output device changes while a lowered or muted app is playing.** The new tap starts at the same gain, with no full-volume burst. Test: Task 5, `deviceChangeRebuildsWithSameGain`.
2. **A tapped app quits or stops playing.** Its tap is released, nothing crashes, and the row behaves per the rules. Test: Task 5, `appQuitReleasesTap`.
3. **Tap creation fails** because the permission is missing or revoked. No half-built taps are left, and `needsPermission` becomes true. Test: Task 5, `tapCreationFailureMarksPermission`.
4. **Rebuild fails on a new device.** It retries once, then releases the app and shows the notice. Test: Task 5, `rebuildFailureReleasesAfterOneRetry`.
5. **Back to 100% and unmuted, or the tool turned off.** Every tap is released, and nothing in the menu bar is left behind. Tests: Task 5, `backToDefaultReleasesTap`; Task 8, `stopLeavesNothingBehind`.

---

### Task 1: Core Audio spike and findings

A throwaway investigation that settles the four things the spec leaves to the builder, before production code depends on them.

**Files:**
- Create: `docs/superpowers/notes/2026-11-22-volume-mixer-spike.md`, the findings.
- Spike code goes only in the session scratchpad and is never committed.

- [ ] **Step 1:** Build a tiny Swift command-line or test app.
  - It lists `kAudioHardwarePropertyProcessObjectList` with each process's PID, bundle ID, `IsRunningOutput` and parent PID (via `proc_pidinfo` / `PROC_PIDTBSDINFO`).
  - Play audio in Music, Safari (YouTube) and Chrome, and record which processes appear and how WebKit content processes relate to Safari.
- [ ] **Step 2:** Tap one playing app.
  - Use `CATapDescription(stereoMixdownOfProcesses:)` with `muteBehavior = .mutedWhenTapped`, plus a private aggregate device on the default output and an IO proc applying 0.3 gain.
  - Confirm the app is quieter and not doubled, and measure the first-touch dropout.
- [ ] **Step 3:** Work out permission detection.
  - Record what tap creation and buffers look like when System Audio Recording is denied versus granted.
  - Choose a public-API way to decide "granted" without audio playing (for the setup step) and while running (to detect revocation).
  - Verify the System Settings deep link for the pane on macOS 26.
- [ ] **Step 4:** Check whether a process playing to a non-default device can be detected, for example through `kAudioProcessPropertyDevices`.
- [ ] **Step 5:** Write the findings doc, with one section per question: answer, evidence, and the exact API calls to use. Commit: `docs: Volume Mixer spike findings`.

Later tasks follow this doc. Where it contradicts this plan's assumptions on these four points, the doc wins. Record that as a ruling in the ledger.

---

### Task 2: Settings store and gain curve

**Files:**
- Create: `Sidekick/Tools/VolumeMixer/MixerSettingsStore.swift`
- Test: `SidekickTests/VolumeMixer/MixerSettingsStoreTests.swift`

**Interfaces (produces):**
- `struct AppVolume: Codable, Equatable, Sendable`
  - `var volume: Double` (0...1) and `var muted: Bool`
  - `static let standard = AppVolume(volume: 1, muted: false)`
  - `var isStandard: Bool`
  - `var gain: Float`
- `@MainActor final class MixerSettingsStore`
  - `static let key = "volumeMixer.settings"`
  - `init(defaults: UserDefaults = .standard)`
  - `func setting(for key: String) -> AppVolume`
  - `func set(_ value: AppVolume, for key: String)`
  - `func reset(_ key: String)` and `func resetAll()`
  - `var all: [String: AppVolume]`

- [ ] **Step 1: Write the failing tests** (sandboxed `UserDefaults(suiteName:)`):
  - `unknownAppIsStandard`: `setting(for: "x") == .standard`.
  - `setPersistsAcrossInstances`: set `0.4` muted, then a new store on the same defaults reads it back.
  - `settingStandardRemovesEntry`: after setting `.standard`, `all["x"] == nil`.
  - `resetAndResetAll`: entries are removed and `setting` returns `.standard`.
  - `gainCurve`:
    - `AppVolume(volume: 0.5, muted: false).gain == 0.25`
    - `volume 1 → 1`
    - `volume 0 → 0`
    - `muted volume 0.8 → 0`
  - `volumeIsClamped`: `set(AppVolume(volume: 1.4, ...))` is stored as 1.0, and `-0.2` as 0.
- [ ] **Step 2:** Run `scripts/test.sh MixerSettingsStoreTests`. Expect FAIL (types don't exist).
- [ ] **Step 3:** Implement it. Store `[String: AppVolume]` JSON-encoded as `Data` under the key. Setting `.standard` removes the entry, so `all` is exactly the "remembered volumes" list.
- [ ] **Step 4:** Run the suite, then the full suite. Expect PASS.
- [ ] **Step 5:** Run `xcodegen generate`, then commit `feat(volume-mixer): settings store and gain curve`.

---

### Task 3: App grouping and mixer rules

**Files:**
- Create:
  - `Sidekick/Tools/VolumeMixer/AppGrouping.swift`
  - `Sidekick/Tools/VolumeMixer/MixerRules.swift`
- Test:
  - `SidekickTests/VolumeMixer/AppGroupingTests.swift`
  - `SidekickTests/VolumeMixer/MixerRulesTests.swift`

**Interfaces (produces):**
- `struct AudioProcess: Equatable, Sendable { let objectID: AudioObjectID; let pid: pid_t; let bundleID: String?; let isRunningOutput: Bool }`
- `struct RunningApp: Equatable, Sendable { let pid: pid_t; let bundleID: String; let name: String }`
- `enum AppGrouping`
  - `static let webContentKey = "webkit.webcontent"`
  - `static func group(processes: [AudioProcess], apps: [RunningApp], ownBundleID: String, parentOf: (pid_t) -> pid_t?) -> [String: [AudioProcess]]`
  - The result is keyed by app bundle ID or `webContentKey`.
- `struct MixerRow: Identifiable, Equatable, Sendable { let id: String; let name: String; let isPlaying: Bool; let setting: AppVolume }`
- `enum MixerRules`
  - `static func rows(groups: [String: [AudioProcess]], apps: [RunningApp], settings: [String: AppVolume]) -> [MixerRow]`
  - `static func tapTargets(groups: [String: [AudioProcess]], settings: [String: AppVolume]) -> [String: [AudioObjectID]]`

- [ ] **Step 1: Write the failing grouping tests:**
  - `exactBundleMatch`
  - `helperPrefixMatch`: `com.google.Chrome.helper` maps to `com.google.Chrome`, but `com.google.Chromecast` does not.
  - `descendantByParentPID`: a process with no bundle ID whose grandparent is the app's PID maps to the app.
  - `ownProcessesExcluded`: processes matching `ownBundleID` are dropped.
  - `unattributedWebContentGetsSyntheticKey`: `com.apple.WebKit.WebContent` with no attributable parent maps to `webContentKey`.
  - `unknownDaemonDropped`: for example `com.apple.systemsoundserverd`.
  - `parentLoopTerminates`: a `parentOf` cycle doesn't hang.
- [ ] **Step 2: Write the failing rules tests:**
  - `playingAppShows`
  - `changedRunningAppShowsWhenSilent`
  - `standardSilentAppHidden`
  - `rowsSortedByName`: uses `localizedStandardCompare`, and the order is stable whether or not each app is playing.
  - `webContentRowTitled`: the title is "Web content".
  - `tapTargetsOnlyNonStandard`: an app at 100% unmuted gets no target, even while playing.
  - `tapTargetsIncludeAllProcessesOfGroup`: includes silent processes, so new helpers join.
  - `nonStandardButNoProcessesNoTarget`
- [ ] **Step 3:** Run both suites. Expect FAIL.
- [ ] **Step 4:** Implement them.
  - Grouping walks `parentOf` with a visited set and a depth cap of 16.
  - If Task 1's findings show a better rule for WebKit, apply it here, and add a test that mirrors the observed process shape.
- [ ] **Step 5:** Run the suites and the full suite. Expect PASS. Commit `feat(volume-mixer): app grouping and mixer rules`.

---

### Task 4: Core Audio layer (live processes, devices, tap)

**Files:**
- Create:
  - `Sidekick/Tools/VolumeMixer/AudioSystem.swift`: protocols plus `CoreAudioSystem`.
  - `Sidekick/Tools/VolumeMixer/AppTap.swift`
  - `Sidekick/Tools/VolumeMixer/GainRamp.swift`: pure ramp math used by the IO proc.
- Test: `SidekickTests/VolumeMixer/GainRampTests.swift`

**Interfaces (produces):**
- `@MainActor protocol AudioSystem: AnyObject`
  - `func processes() -> [AudioProcess]`
  - `func runningApps() -> [RunningApp]`
  - `func parent(of pid: pid_t) -> pid_t?`
  - `func defaultOutputDevice() -> AudioDeviceID?`
  - `func deviceName(_ id: AudioDeviceID) -> String`
  - `func startListening(onProcessesChanged: @escaping @MainActor () -> Void, onDefaultDeviceChanged: @escaping @MainActor () -> Void)`
  - `func stopListening()`
  - `func makeTap(processes: [AudioObjectID], device: AudioDeviceID, gain: Float) throws -> any TapHandle`
- `@MainActor protocol TapHandle: AnyObject`
  - `func setGain(_ gain: Float)`
  - `var level: Float { get }`: the latest peak, 0...1.
  - `func setProcesses(_ ids: [AudioObjectID]) throws`
  - `func invalidate()`
- `struct GainRamp: Sendable`
  - `init(sampleRate: Double, duration: Double = 0.02)`
  - `mutating func next(target: Float) -> Float`: the per-sample gain, moving linearly toward the target and reaching it after `duration`.
- `AppTap: TapHandle` is the live implementation: tap, aggregate device and IO proc, with gain and level in `Atomic<UInt32>` (Float bit patterns).
- `CoreAudioSystem: AudioSystem` registers property listeners on:
  - `kAudioHardwarePropertyProcessObjectList`
  - `IsRunningOutput` for each process (re-registered when the list changes)
  - `kAudioHardwarePropertyDefaultOutputDevice`

  Callbacks hop to the main actor.

- [ ] **Step 1: Write the failing tests:**
  - `rampReachesTargetInDuration`: at 48 kHz, after 960 samples the gain equals the target.
  - `rampIsMonotonic`
  - `rampHoldsWhenAtTarget`
- [ ] **Step 2:** Run `scripts/test.sh GainRampTests`. Expect FAIL. Then implement `GainRamp` and run again. Expect PASS.
- [ ] **Step 3:** Implement `CoreAudioSystem` and `AppTap` following Task 1's findings doc.
  - `invalidate()` stops the IO proc and destroys the aggregate device and the tap, in that order, and is idempotent.
  - `deinit` must not be the only cleanup path.
- [ ] **Step 4: Manual check.** A temporary DEBUG-only hook, removed before commit, taps Music at 0.3 for 5 seconds and then invalidates it. Expected: Music is quieter, then returns to normal, with no doubling. Note the result in the report.
- [ ] **Step 5:** Run the full suite. Expect PASS. Commit `feat(volume-mixer): Core Audio process and tap layer`.

---

### Task 5: TapController (reconcile, device changes, failures)

**Files:**
- Create: `Sidekick/Tools/VolumeMixer/TapController.swift`
- Test:
  - `SidekickTests/VolumeMixer/TapControllerTests.swift`
  - `SidekickTests/VolumeMixer/FakeAudioSystem.swift`: records `makeTap` calls and can throw on demand; fake taps record gain, processes and invalidation.

**Interfaces:**
- Consumes: Tasks 2–4.
- Produces `@MainActor @Observable final class TapController`:
  - `init(system: any AudioSystem, store: MixerSettingsStore)`
  - `private(set) var rows: [MixerRow]`
  - `private(set) var needsPermission: Bool`
  - `private(set) var notice: String?`
  - `func start()` and `func stop()`
  - `func setVolume(_ volume: Double, for key: String)`
  - `func toggleMute(_ key: String)`
  - `func level(for key: String) -> Float?`: nil when untapped.
  - `func refresh()`: re-reads processes and apps, recomputes rows, and reconciles taps.
  - `var activeTapKeys: Set<String>`, for tests.

- [ ] **Step 1: Write the failing tests** (fake system with Music playing):
  - `startTapsStoredNonStandardApps`
  - `untouchedAppNeverTapped`
  - `lowerCreatesTapAtTargetGain`: `setVolume(0.5)` creates one tap with gain 0.25.
  - `furtherChangesUpdateGainWithoutNewTap`
  - `backToDefaultReleasesTap`
  - `muteTapsAtZeroAndUnmuteRestores`
  - `newHelperProcessJoinsTap`: `setProcesses` is called with the added ID.
  - `appQuitReleasesTap`: the processes vanish, so the tap is invalidated, and the row is kept only if the rules keep it.
  - `deviceChangeRebuildsWithSameGain`: the old tap is invalidated, and the new tap is on the new device with the same gain. The new tap is created before the old one is invalidated, or the fake records the order, as Task 1's findings require.
  - `rebuildFailureReleasesAfterOneRetry`: `makeTap` throws twice on the new device, so there is no tap for that key and the notice reads "Couldn't keep Music's volume on this device".
  - `tapCreationFailureMarksPermission`: the fake throws a permission-shaped error, so `needsPermission == true`, no taps remain, and the setting is still stored.
  - `stopReleasesEverything`: after `stop()`, every fake tap is invalidated and the listeners are stopped.
  - `settingsPersistThroughController`: `setVolume` writes to the store.
- [ ] **Step 2:** Run `scripts/test.sh TapControllerTests`. Expect FAIL.
- [ ] **Step 3:** Implement it.
  - Reconcile by diffing `MixerRules.tapTargets` against the active taps.
  - On a device change, rebuild every tap, then rebuild failures with one retry.
  - Classify a permission error per Task 1's findings.
  - If Task 1 found that playing to a non-default device is detectable:
    - those apps are never tapped;
    - their row is disabled with the caption "Plays to another device";
    - add the test `otherDeviceAppNotTapped`.

    If it isn't detectable, record that as a known limitation in the findings doc.
- [ ] **Step 4:** Run the suite and the full suite. Expect PASS. Commit `feat(volume-mixer): tap controller`.

---

### Task 6: System Audio Recording permission and setup step

**Files:**
- Modify:
  - `Sidekick/Core/Permission.swift`: add the case `systemAudio`.
  - `Sidekick/Core/Permissions.swift`: `static var systemAudio: Bool`, `Pane.systemAudio`, and a request helper per Task 1.
  - `Sidekick/UI/Onboarding/OnboardingFlow.swift`: `case systemAudio`, plus `isPermission` and `isSatisfied`.
  - `Sidekick/UI/Onboarding/OnboardingView.swift`: route the step.
  - `Sidekick/Resources/Info.plist`: add `NSAudioCaptureUsageDescription`.
- Create: `Sidekick/UI/Onboarding/Steps/SystemAudioStep.swift`, modelled on `AccessibilityStep`.
- Test: extend `SidekickTests` OnboardingFlow tests: `systemAudioIsPermissionStep`, and `setupStepsForMixerOnlyAsksSystemAudio` using a stub tool with `setupSteps: [.systemAudio]`.

**Step copy:**
- Title: "Allow System Audio Recording".
- Message: "Volume Mixer changes an app's volume by passing its sound through Sidekick. Nothing is recorded or saved. Turn on Sidekick in the list that opens."
- Buttons: "Open Settings" (requests, then opens the pane), "Continue" once granted, and a secondary "Later", since this step can be continued without granting.

- [ ] **Step 1:** Write the failing tests. Run them and expect FAIL.
- [ ] **Step 2:** Implement it. Any `switch` over `Permission` or `OnboardingStep` elsewhere must handle the new case; the compiler will list them.
- [ ] **Step 3:** Run the full suite. Expect PASS. Commit `feat(volume-mixer): System Audio Recording permission and setup step`.

---

### Task 7: Status item, panel and system volume

**Files:**
- Create:
  - `Sidekick/Tools/VolumeMixer/SystemVolume.swift`
  - `Sidekick/Tools/VolumeMixer/MixerStatusItem.swift`
  - `Sidekick/Tools/VolumeMixer/MixerPanel.swift`: the NSPanel plus the SwiftUI `MixerView`, `InkSlider` and `LevelBars`.

**Interfaces (produces):**
- `@MainActor @Observable final class SystemVolume`
  - `var deviceName: String`, `var volume: Double?` (nil when there's no software control), `var muted: Bool`
  - `func setVolume(_:)`, `func toggleMute()`, `func start()`, `func stop()`
  - Listens on the default device, its volume and its mute.
- `@MainActor protocol MixerMenuBar: AnyObject { func install(); func remove(); var isInstalled: Bool { get } }`
- `MixerStatusItem: MixerMenuBar`, `init(controller: TapController, systemVolume: SystemVolume, openSettings: @escaping @MainActor () -> Void)`
  - The `NSStatusItem` uses the `speaker.wave.2` template image.
  - Clicking toggles the panel.
  - It's a non-activating borderless panel anchored under the item, closed by a click outside (a global mouse monitor installed only while it's open), by Esc, or by clicking the icon again.

**Panel content:**
- Width 320.
- **System row:** speaker glyph (mute), device name, and slider. When `volume == nil` the slider is disabled with the caption "This device controls its own volume".
- **App rows:** icon (`NSRunningApplication` icon, or the `globe` symbol for Web content; clicking it toggles mute, and a muted row dims), name, `LevelBars`, `InkSlider` and the %.
  - `LevelBars` shows the real level from `controller.level(for:)` sampled at 20 Hz while the panel is open.
  - An untapped playing app gets a gentle pulsing three-dot "playing" indicator.
  - A silent app shows nothing.
- **Body states:**
  - `needsPermission` replaces the body with "Volume Mixer needs System Audio Recording" and an "Open Settings" button.
  - `notice` shows as a caption line.
  - With no rows it shows "Nothing's playing right now."
- More than 8 rows scroll.
- **Footer:** "Volume Mixer settings…" calls `openSettings`.
- `controller.refresh()` runs when the panel opens.

- [ ] **Step 1:** Implement `SystemVolume`.
  - Use `kAudioDevicePropertyVolumeScalar` and `kAudioDevicePropertyMute` on the main element, falling back to channels 1 and 2 (average for display, set both).
  - Rebind on default device changes.
- [ ] **Step 2:** Implement the status item, panel and views in Sidekick's style.
- [ ] **Step 3:** Build, run the full suite, and expect PASS. Manual check: install the item from a DEBUG hook, open the panel, and confirm the layout, the empty state, and that the system slider tracks the keyboard volume keys. Remove the hook.
- [ ] **Step 4:** Commit `feat(volume-mixer): menu bar mixer panel`.

---

### Task 8: VolumeMixerTool, settings page and registration

**Files:**
- Create:
  - `Sidekick/Tools/VolumeMixer/VolumeMixerTool.swift`
  - `Sidekick/Tools/VolumeMixer/VolumeMixerSettingsView.swift`
- Modify: `Sidekick/App/AppEnvironment.swift`: register `VolumeMixerTool()` after `WindowManagerTool()`.
- Test: `SidekickTests/VolumeMixer/VolumeMixerToolTests.swift`

**Interfaces:**
- `VolumeMixerTool: Tool` with the identity from Global Constraints and `init(defaults: UserDefaults = .standard, system: (any AudioSystem)? = nil, menuBar: ((TapController, SystemVolume) -> any MixerMenuBar)? = nil)`.
- `start()`: `controller.start()`, `systemVolume.start()`, `menuBar.install()`. It's idempotent.
- `stop()`: the reverse. It's idempotent.
- `pages`: one `ToolPage(id: "settings", title: "Settings")` showing `VolumeMixerSettingsView`.
  - The view lists "Remembered volumes" from `store.all` (app icon and name resolved by bundle ID, falling back to the bundle ID, and "Web content" for the synthetic key).
  - Each row has its % and a "Reset" button, plus "Reset all".
  - Empty state: "No remembered volumes yet."
  - Uses `SettingsSection` and `SettingsRow`.
- `openSettings` calls `AppEnvironment.shared.window.show(.page(tool: "volumeMixer", page: "settings"))`.

- [ ] **Step 1: Write the failing tests** (fake system and fake menu bar):
  - `identity`: id, name, permissions and setupSteps.
  - `startInstallsMenuBarAndStartsController`
  - `stopLeavesNothingBehind`: the menu bar is removed, every fake tap is invalidated, the listeners are stopped, and stored settings are untouched.
  - `startStopIdempotent`
  - `offByDefault`: a fresh `ToolRegistry` doesn't enable `volumeMixer`.
- [ ] **Step 2:** Run `scripts/test.sh VolumeMixerToolTests`. Expect FAIL. Then implement and register. Run the full suite. Expect PASS.
- [ ] **Step 3:** Commit `feat(volume-mixer): tool, settings page, registration`.

---

### Task 9: Manual verification in the real app

- [ ] Build and launch Sidekick, and turn on Volume Mixer from Home. The setup sheet shows only the System Audio Recording step. Grant it.
- [ ] Play Music, YouTube in Safari, YouTube in Chrome, and a call or Discord.
  - Set each to a different volume and mute one.
  - Each changes independently, with no doubling and no full-volume burst.
  - Safari's row (or "Web content") works.
- [ ] Quit and relaunch Music. It comes back at its stored volume. Quit and relaunch Sidekick, and the volumes are still applied.
- [ ] Plug in headphones or connect AirPods mid-song. Lowered apps stay lowered, and the system row shows the new device.
- [ ] Use the keyboard volume keys while the panel is open. The system slider follows.
- [ ] Turn the tool off. The icon disappears and every app is back to normal. Turn it on again, and the volumes return.
- [ ] Revoke the permission in System Settings while the tool is on. Apps return to normal and the panel shows the permission line.
- [ ] Check that Dictation (Fn) and Window Manager shortcuts still work.
- [ ] Note the results in the ledger. Fix any failure through the normal task loop.
