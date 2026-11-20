# Sidekick: design and v1 plan

## Context
Sidekick is a Mac app inspired by Windows PowerToys. It is a set of small tools that each person switches on or off. It's a passion project for the author and a few friends, released on GitHub, but it should still be polished, with clear first-run setup. The visual style is black and white and minimal, with fluid motion. It reuses the look of the author's existing app, Parrot (`~/Documents/Parrot`, repo `xanderlzy/parrot`).

Parrot (on-device voice dictation) is being **retired into Sidekick** as the Dictation tool. Sidekick takes over Parrot's design system, app shell, and release tooling.

**v1 = shell + Keep on Top + Dictation.** Any further tools will be planned separately when the author asks for them.

## Goals / non-goals / anti-goals
- **Goals**
  - Each tool can be switched on or off independently. A tool that is off runs no code, uses no shortcut, and asks for no permissions.
  - Feels the same as Parrot: ink/paper only, the three springs, slide-and-fade transitions.
  - Setup clearly explains each tool and why it needs each permission, and only asks for permissions the chosen tools need.
  - Each milestone ends as a working, releasable app.
- **Non-goals**
  - The Mac App Store.
  - Intel Macs and versions before macOS 26 (inherited from Parrot).
  - Typing or clicking inside a pinned window.
- **Anti-goals**
  - Pinning that requires turning off macOS security protections (SIP) or loading code into other apps.
  - Any tool slowing down the others.
  - Asking for permissions up front for tools the user didn't choose.

## Decisions made with the user
- **Distribution:** GitHub releases, a self-signed build, and Sparkle auto-updates, all as in Parrot.
- **Shell:** a menu bar icon plus a settings window. No Dock icon, except while the window is open.
- **Keep on Top:** the user presses a keyboard shortcut and the frontmost window stays on top. The main use is watching it (a video or notes), not interacting with it.
- **Parrot:** becomes the Dictation tool. The Parrot repo stops getting updates and its README points to Sidekick. When Dictation is first enabled, the user's Parrot history and settings are imported.

## Approaches considered (how to reuse Parrot)
- **Copy Parrot's code into Sidekick:** chosen once Parrot was folded in. Sidekick becomes the single home for the code.
- **Shared Swift package used by both apps:** unnecessary because Parrot is being retired.
- **Rebuild from scratch:** more work for the same result.

## Architecture
- **Starting point:** a new XcodeGen project at `~/Documents/Sidekick`, seeded from Parrot.
  - Copy `project.yml`, `scripts/`, and `Design/`, then rename Parrot to Sidekick.
  - Same settings as Parrot: Swift 6, macOS 26, arm64, Sparkle 2.10.1, swift-testing.
  - Dependencies:
    - WhisperKit 1.1.1, carried over from Parrot.
    - **KeyboardShortcuts** (sindresorhus), new. It provides key-combination shortcuts with a recorder control and needs no Accessibility permission. The Parrot code it builds on only supports single modifier keys.

```
Sidekick/
  App/        SidekickApp (MenuBarExtra), AppDelegate, AppEnvironment
  Core/       Tool.swift (protocol), ToolRegistry, Permissions (+screenRecording), LoginItem, Updater
  Design/     Theme, Components, Formatting           ← copied from Parrot/Design (rename ParrotInk/Paper)
  UI/Window/  MainWindowController, RootView, Sidebar, HomeView (tool grid), GeneralSettingsView
  UI/Onboarding/  OnboardingFlow (generic), OnboardingView, StepLayout/PrimaryButton/DoneBadge/ProgressDots
  Tools/KeepOnTop/  KeepOnTopTool, PinController, MirrorPanel, WindowFinder
  Tools/Dictation/  DictationTool + Parrot's Audio, Input, Output, Pipeline, Polish, Transcription, Data, Pill, History/Home views, ParrotImporter
SidekickTests/
```

**The tool contract** (`Core/Tool.swift`): every tool implements the same small set of things.
```swift
@MainActor protocol Tool: AnyObject, Identifiable {
  var id: String { get }                 // "keepOnTop", "dictation"
  var name: String { get }; var symbol: String { get }; var summary: String { get }
  var permissions: [Permission] { get }  // shown on its card + drives onboarding steps
  func start()                           // enabled: register shortcuts, observers
  func stop()                            // disabled: tear down everything, release resources
  var onboardingSteps: [OnboardingStep] { get }   // tool-specific steps after permissions
  var pages: [ToolPage] { get }          // sidebar entries (Dictation: Home, History, Settings)
  var settingsView: AnyView { get }
}
```
- `ToolRegistry` (an `@Observable`) stores which tools are enabled in `@AppStorage`. It calls `start()` or `stop()` whenever a tool is toggled, and at launch for every enabled tool.
- Parrot's `MainTab` enum becomes a sidebar built dynamically from the registry.

## Screens
**Settings window.** 800×560 with Parrot's window chrome and sliding sidebar indicator.
```
SIDEKICK
  Home          ← grid of tool cards: symbol, name, one line, permissions needed, MonoToggle
  ─────
  Keep on Top   ← shortcut recorder, pinned-window list, options
  Dictation  ▸  Home · History · Settings   (Parrot's pages, only when enabled)
  ─────
  General       ← launch at login, updates, permission status for all tools
v0.1.0
```
- Turning a tool on in Home makes its sidebar entry appear (a fluid insert). If the tool needs permissions that haven't been granted, it opens a mini-flow for just that tool's permission steps, reusing the onboarding step views.

**Menu bar menu.**
- Open Sidekick…
- Each enabled tool with its shortcut shown, e.g. "Pin Front Window ⌃⌥T". Plus "Unpin All" while any window is pinned.
- Check for Updates…
- Quit

**First-run setup.**
1. Welcome
2. **Choose your tools:** cards with toggles. Keep on Top is on by default; Dictation is off.
3. Permission steps for the chosen tools:
   - Keep on Top: Screen Recording.
   - Dictation: Microphone, Accessibility, speech model, Apple Intelligence.
4. Each tool's own steps, such as Dictation's practice and try-it steps.
5. Finish: launch at login, plus a cheat sheet of the shortcuts.

The step list is built from the chosen tools, extending Parrot's tested `OnboardingFlow`.
- **Screen Recording:**
  - Check with `CGPreflightScreenCaptureAccess`; request with `CGRequestScreenCaptureAccess`; deep link to `?Privacy_ScreenCapture`.
  - macOS may only apply the permission after a relaunch. If so, the step shows a "Quit & Reopen" button and setup resumes at the same step, using a stored onboarding step index.

## Keep on Top (v1)
- **Shortcut:** default ⌃⌥T, changeable. It pins the frontmost window, or unpins it if it's already pinned.
- **Finding the window:** the top on-screen window of the frontmost app, from `CGWindowListCopyWindowInfo` in z-order (layer 0), matched to an `SCWindow` from `SCShareableContent`.
- **Mirror:**
  - A borderless `NSPanel` at `.floating` level with `[.canJoinAllSpaces, .fullScreenAuxiliary]`, the same panel setup as Parrot's `PillPanel`.
  - It shows an `SCStream` with `SCContentFilter(desktopIndependentWindow:)`, rendered into a layer at the display's refresh rate.
  - It is a live copy, so it updates while the real window stays wherever it was.
- **Motion (proposed by me, can be changed):**
  - On pin, the mirror appears exactly over the real window, then springs into a picture-in-picture size (about 35% of the window, keeping its proportions) in the nearest screen corner, using `Motion.fluid`.
  - It can be dragged and snaps to corners with a spring. It can be resized while keeping its proportions.
  - On unpin, it shrinks and fades out.
- **Hover controls:** a small capsule appears in the mirror's top corner with Unpin, Show original (brings the real app forward), and opacity (100/75/50%).
- **Several pins:** multiple windows can be pinned at once. They're listed on the tool's page with an Unpin button for each.
- **Edge cases:**
  - Original window closed: the mirror animates out.
  - Original window minimized or on another Space (capture stops): the mirror freezes on its last frame with a small "paused" dot.
  - Sidekick can't pin its own windows.
  - Screen Recording not granted: the shortcut opens the permission mini-flow instead.

## Dictation (v1, moved in from Parrot)
- **Moving the code:** Parrot's engine folders move under `Tools/Dictation/` with as few changes as possible. Its Home, History and Settings views become the tool's `pages`. Its pill stays.
- **Start and stop:** `start()` starts the hotkey event tap and pipeline, and `stop()` tears them down. Parrot's `AppEnvironment` setup is split into the shared parts and the Dictation-only parts.
- **Permissions:** Microphone, Accessibility, Speech, and the optional Whisper model download only appear when Dictation is enabled.
- **`ParrotImporter`:**
  - Runs on Dictation's first enable.
  - If Parrot's UserDefaults domain or SwiftData store exists, it copies the settings and history into Sidekick's store, then shows "Imported N dictations from Parrot".
  - It runs once and never changes Parrot's own files.
- **Retiring Parrot:** after Sidekick v1 ships, the README gets a "moved to Sidekick" note, with a final Parrot appcast entry whose release notes link to Sidekick. Done in the Parrot repo; I'll check with you before pushing.

## Build order (v1)
1. Set up the project: copy Parrot's `project.yml`, scripts (including a new certificate "Sidekick Self-Signed"), Design and the app icon script, and rename everything. Add KeyboardShortcuts. The app should launch to an empty shell.
2. Build the core: the `Tool` protocol, `ToolRegistry`, Permissions (adding Screen Recording), the window, a sidebar built from the registry, the Home grid of tools, and General settings.
3. Make setup generic: the welcome screen, choosing tools, assembling permission and tool steps from the chosen tools, the Screen Recording relaunch-and-resume, the finish step, and the menu bar menu.
4. Keep on Top: WindowFinder, PinController, MirrorPanel with its motion and hover controls, the shortcut, the tool's settings page, and the edge cases above.
5. Move Dictation in: copy Parrot's engine, split the environment, connect `start`/`stop`, its onboarding steps, its pages, and `ParrotImporter`.
6. Release: new Sparkle keys, a new appcast, a README with the install steps from Parrot, then `scripts/release.sh 0.1.0`. A new GitHub repo `xanderlzy/sidekick` (I'll confirm with you before creating or pushing). Then the Parrot retirement notice.

The approved design will also be saved in the repo as `docs/superpowers/specs/2026-11-20-sidekick-design.md`.

## Calls I made (correct any of these)
- Default shortcut ⌃⌥T for Keep on Top.
- Keep on Top is on by default in setup; Dictation is off.
- The pinned copy moves to a corner as picture-in-picture rather than sitting exactly over the original window.
- The menu bar icon is an SF Symbol, and the app icon is made by an adapted `make-icon.swift`. I'll propose a mark: a white square in a black squircle.
- The bundle ID follows Parrot's pattern.

## Verification
- **Unit tests (swift-testing, `scripts/test.sh`):**
  - ToolRegistry: turning tools on and off, and that this persists.
  - The generic OnboardingFlow builds the right steps for each combination of tools.
  - PinController: pin/unpin toggling, the multiple-pins list, and choosing the nearest corner.
  - ParrotImporter against a fixture defaults domain and store.
  - The Parrot tests that carry over, including the window staying on screen.
- **Manual end-to-end:**
  - Clean install, then setup with only Keep on Top. Check that no Mic or Accessibility prompt appears.
  - Pin a YouTube tab and a Notes window, drag, resize, switch Spaces, close a source window, unpin all.
  - Turn on Dictation from Home. Check that only its steps run, that the Parrot history is imported, and that dictation works in TextEdit.
  - Turn Dictation off and check that Fn no longer does anything.
  - Run `release.sh` to a test tag and check that Sparkle updates from the previous build.
