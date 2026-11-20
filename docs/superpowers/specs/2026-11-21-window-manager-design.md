# Window Manager: design

Date: 2026-11-21. Status: draft for approval.

## Intent
Add a **Window Manager** tool to Sidekick, its second tool after Dictation. It moves and resizes the frontmost window in two ways:
- with keyboard shortcuts;
- by dragging a window to a screen edge or corner.

The author uses Rectangle today and wants the same thing inside Sidekick, with Rectangle's default shortcuts, written from scratch. Copying Rectangle's code, name or branding is out; matching its default key combinations and snap areas is in. It is for the author and a few friends, so it must be polished and quiet: no surprises, no nags.

## Goals
- Every Rectangle action that has a default shortcut works with the same default keys.
- Rectangle-style drag-to-snap with a live preview of where the window will land.
- Every shortcut can be changed on the tool's page.
- Follows Sidekick's tool contract. When the tool is off it runs nothing, holds no shortcuts and watches no mouse events.
- Matches Sidekick's look: ink/paper, `Theme`, and the `Motion` springs.

## Non-goals
- Rectangle's actions that have no default key: fourths, sixths, eighths, ninths, move left/right/up/down, center half, center prominently, and the like. The user chose the default-key set only. They can be added later.
- Multi-window actions: tile all, cascade, stacked-window cycling, Todo mode.
- Window gaps, an ignore-app list, and import/export of settings.
- Moving windows between Spaces. Rectangle can't do this either.
- Warning when Rectangle is running. **The user said explicitly not to.**

## Anti-goals
- Using private window APIs or anything that needs SIP turned off.
- Animating the real window's frame step by step. Other apps redraw such moves choppily, so windows jump straight to their target and the motion lives in the snap preview.
- Interfering with ordinary drags, such as text selection, file drags, or moving a window around the middle of the screen.

## Constraints
- Swift 6 strict concurrency, macOS 26, arm64, SwiftUI plus AppKit. Same project setup as the rest of Sidekick (XcodeGen, swift-testing, `scripts/test.sh`).
- Window frames are read and set through the Accessibility API (`AXUIElement`, `kAXPositionAttribute` and `kAXSizeAttribute`), which needs the Accessibility permission.
- Global shortcuts use the KeyboardShortcuts library already in the project, which needs no extra permission. The tool's settings page uses its recorder.
- Detecting window drags needs a global mouse monitor, which works under the Accessibility permission.

## Approaches considered
1. **Accessibility API, KeyboardShortcuts, a global mouse monitor, and a borderless overlay panel for the preview.** **Chosen.** This is the only approach that works on a stock Mac without disabling protections, and it reuses the libraries Sidekick already has.
2. **Private CoreGraphics/SkyLight window APIs.** Rejected because they need SIP turned off for other apps' windows, which breaks an anti-goal. The same constraint ruled out Keep on Top's original design.
3. **A ghost copy of the window that is dragged and then applied.** Rejected because it feels fake. It was the same lesson as the Keep on Top mirror.

## Decided with the user
- It is a Sidekick tool, not a separate app.
- The scope is Rectangle's default-key actions only (option 1 of 3).
- Drag-to-snap areas match Rectangle's.
- Repeated presses cycle sizes, and shortcuts are editable. I proposed both and the user agreed.
- Windows jump into place instantly; only the preview is animated. I proposed this and the user agreed.
- There is no Rectangle-running warning.

## Actions and default shortcuts
These are Rectangle's defaults, using ⌃⌥ as the base. **The builder must check each key against Rectangle's current defaults before coding.** If anything differs, Rectangle's default wins and the change gets noted.

| Action | Default | Result (inside the screen's visible frame) |
|---|---|---|
| Left Half | ⌃⌥← | Left ½ |
| Right Half | ⌃⌥→ | Right ½ |
| Top Half | ⌃⌥↑ | Top ½ |
| Bottom Half | ⌃⌥↓ | Bottom ½ |
| Top Left | ⌃⌥U | Top-left quarter |
| Top Right | ⌃⌥I | Top-right quarter |
| Bottom Left | ⌃⌥J | Bottom-left quarter |
| Bottom Right | ⌃⌥K | Bottom-right quarter |
| First Third | ⌃⌥D | Left ⅓ (top ⅓ on a portrait screen) |
| Center Third | ⌃⌥F | Middle ⅓ |
| Last Third | ⌃⌥G | Right ⅓ (bottom on portrait) |
| First Two Thirds | ⌃⌥E | Left ⅔ (top on portrait) |
| Last Two Thirds | ⌃⌥T | Right ⅔ (bottom on portrait) |
| Maximize | ⌃⌥↩ | Whole visible frame |
| Almost Maximize | none in Rectangle; include it unbound if Rectangle has no default | 90% of the visible frame, centered |
| Maximize Height | ⌃⌥⇧↑ | Full height, keeps x and width |
| Make Larger | ⌃⌥= | Grows by a fixed step on each side, clamped to the screen |
| Make Smaller | ⌃⌥- | Shrinks by the same step, never below a minimum size |
| Center | ⌃⌥C | Same size, centered |
| Restore | ⌃⌥⌫ | The frame from before Sidekick first moved this window |
| Next Display | ⌃⌥⌘→ | Same relative position and size on the next screen |
| Previous Display | ⌃⌥⌘← | Same on the previous screen |

"Visible frame" means the screen's area minus the menu bar and Dock (`NSScreen.visibleFrame`), converted to Accessibility's top-left-origin coordinates. The target screen is the one that contains most of the window.

### Repeated presses
- **Halves.** Pressing the same half shortcut again within a short window, while the window is still at the frame Sidekick set, steps the width (or height for top and bottom) from ½ to ⅔ to ⅓ and back to ½.
- **Thirds.** Pressing First Third again moves it to center, then last. Last Third runs the other way.
- **Any other move** starts a fresh cycle. This includes a different action, a manual move, or a different window.

### Restore
- The first time Sidekick moves a window, it records the window's original frame, keyed by the window.
- Restore puts that frame back and forgets it.
- Dragging a snapped window away from its snapped position also returns it to its original *size*, like Rectangle and Windows. The window stays under the cursor.

### Windows that resist
- Some apps have a minimum or maximum size, or ignore a size change.
- After setting the frame, Sidekick reads it back. If the size came out different, it re-positions the window so the result still sits in the intended area: anchored to the target edge, and centered when the window is too big.
- There's no error HUD in v1.

## Drag-to-snap
- **Detection.** A global mouse monitor watches left-mouse-down, dragged and up events. A drag counts as a *window drag* only when the frontmost window's position changes while the button is held. Text selection and file drags never move a window, so they never trigger a snap.
- **Snap areas,** sized as Rectangle's (a few points from the edge, with corner zones about 20pt):

  | Cursor at | Snaps to |
  |---|---|
  | Left or right edge | Left or right half |
  | Top edge | Maximize |
  | A corner | That quarter |
  | Left or right edge, just below the top corner or just above the bottom corner | Top or bottom half |
  | Bottom edge, left / middle / right third | First / center / last third |
  | Bottom edge: start in the left or right third, then move into the middle | First or last two-thirds |

- **Preview.**
  - The overlay is a borderless, click-through panel at a level above normal windows, on all Spaces.
  - It draws a rounded rectangle over the target frame: a thin ink border with a faint ink fill, using `Theme` colors so it follows light and dark mode.
  - It springs in from the cursor point with `Motion.snappy`. It morphs between targets with `Motion.fluid` when the cursor moves from one area to another, and fades out when the cursor leaves all areas.
- **Drop.** Releasing inside an area applies that action to the dragged window and hides the preview. Releasing outside any area does nothing.
- **Off switch.** A toggle on the tool's page, "Snap windows by dragging", turns the monitor and overlay off. It is on by default.

## Tool integration
- **`WindowManagerTool: Tool`**
  - id `windowManager`, name "Window Manager"
  - symbol `rectangle.split.2x1` (builder may pick a better SF Symbol)
  - summary: "Snap windows to halves, thirds and corners with shortcuts or by dragging to the screen's edges."
  - `permissions: [.accessibility]`
  - `start()` registers the shortcut handlers and starts the drag monitor if it's enabled. `stop()` removes both and hides any preview.
- **Registration.** Registered in `AppEnvironment` after Dictation, so Home and the sidebar list it second. It stays **off by default**: `ToolRegistry`'s default stays `["dictation"]`.
- **Setup steps.** `[.accessibility]` only.
  - Today's `AccessibilityStep` lives in `Tools/Dictation/Steps`. Its copy is about dictation and it calls `DictationEnvironment.startHotkeys()`.
  - It moves to `UI/Onboarding/Steps`, with copy that covers both uses ("Accessibility lets Sidekick control windows and notice your shortcuts"), or a message chosen from the tools being set up.
  - Its "on granted" side effect becomes a hook each tool supplies, such as restarting that tool.
  - Dictation's behaviour must not change.
  - `OnboardingView` currently shows the Accessibility step through `DictationStepHost`, which starts Dictation first. The shared step must not go through that host, or setting up only Window Manager would start Dictation.
  - If Accessibility is revoked while the tool is on, shortcuts and snapping do nothing. They don't crash or show a prompt. Home already shows missing permissions.
- **Page.** One page, "Settings":
  - The snap toggle at the top.
  - The actions, grouped as Halves, Corners, Thirds, Size and Displays. Each row shows the action name with a KeyboardShortcuts recorder.
  - A "Restore defaults" button.
  - It uses the existing `SettingsRow` style.
- **Menu bar.**
  - The flat list of 22 actions would swamp the menu, so the tool's items go in a **"Window Manager" submenu**, each action showing its shortcut.
  - This needs a small change to `ToolMenuItem` or `MenuContent` so a tool can supply a titled group.
  - Choosing an action from the menu applies it to the window that was frontmost before the menu opened.
- **Finish step.**
  - The cheat sheet currently lists every enabled tool's menu items. For Window Manager it would show 22 rows.
  - Instead it shows one line, "Window Manager: see its page for all shortcuts" (wording to the builder), or the four halves.
  - The builder picks the mechanism, for example a flag on `ToolMenuItem`.

## Code layout (proposed)
```
Sidekick/Tools/WindowManager/
  WindowManagerTool.swift      Tool conformance, pages, menu items, start/stop
  WindowAction.swift           enum of the 22 actions, names, default shortcuts, KeyboardShortcuts.Name
  Layout.swift                 pure: (action, window frame, visible frame, cycle state) -> target frame
  CycleState.swift             pure: repeated-press tracking
  AXWindow.swift               frontmost window lookup, get/set frame, read-back, identity
  ScreenGeometry.swift         NSScreen <-> AX coordinate conversion, screen-for-window, display order
  SnapAreas.swift              pure: (cursor point, screen frame, drag history) -> action?
  DragSnapMonitor.swift        NSEvent global monitor, window-drag detection, drives preview + apply
  SnapPreviewPanel.swift       overlay NSPanel + SwiftUI preview view
  RestoreStore.swift           original frames per window
  WindowManagerSettingsView.swift
```
Keep the logic pure where possible (`Layout`, `CycleState`, `SnapAreas`, `ScreenGeometry` conversion) so it can be unit tested without real windows.

## Testing
- **Unit tests (swift-testing):**
  - `Layout` for every action, on landscape and portrait screens, on a screen with an offset origin (a second display to the left of or above the main one), and with a visible frame shortened by the menu bar and Dock.
  - `CycleState`: half and third cycles, and resets.
  - `SnapAreas`: every zone, the boundaries between them, and the bottom-edge two-thirds gesture.
  - Coordinate conversion across multiple screens.
  - Next and Previous Display ordering and the proportional mapping between screens.
  - `RestoreStore`.
  - The tool's `start` and `stop` register and unregister handlers. The drag monitor is off when the toggle is off.
  - `OnboardingFlow` still dedupes `.accessibility` when Dictation and Window Manager are set up together.
- **Manual check:**
  - Every shortcut in Finder, Safari, TextEdit and a fixed-size or minimum-size app (such as System Settings).
  - Repeated presses.
  - Restore.
  - Next and Previous Display with two screens.
  - Drag-snapping to every zone, and checking that text selection and file drags don't snap.
  - Turning the tool off silences everything.
  - Turning it on with Accessibility already granted (from Dictation) shows no setup sheet.

## Calls I made (the user can change any of these)
- The tool is called "Window Manager" and is off by default.
- Snapping by dragging is on by default.
- Almost Maximize is 90%. The Make Larger/Smaller step and the minimum size are left to the builder; Rectangle uses about 30pt.
- The menu uses a submenu, and the finish step condenses this tool's shortcuts.
- The Accessibility step becomes shared.
- There is no HUD when an app refuses a size.

## Left to the builder
- Exact snap-zone sizes and the repeat-press time window.
- How a window's identity is kept across calls, for restore and cycling.
- The SF Symbol.
- Recorder layout details within the existing settings style.
