# Volume Mixer native menu Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Volume Mixer's custom black panel with a native `NSMenu` that looks and behaves like Sidekick's own menu bar menu and Apple's Sound menu.

**Architecture:**
- `MixerStatusItem` keeps its public interface: `MixerMenuBar` (`install()`, `remove()`, `isInstalled`) and its current init. That way `VolumeMixerTool` and Task 8 tests are untouched.
- Internally, the status item gets an `NSMenu` with a delegate.
- The menu's rows are `NSMenuItem`s. Rows with sliders use custom AppKit views (`NSSlider`, `NSImageView`/`NSButton`, `NSTextField` labels) sized to the menu's width and styled with system fonts and colours.
- The old `MixerPanel` NSPanel, its SwiftUI views and the panel's key/mouse monitors are deleted.
- Pure helpers in `MixerPanel.swift` that the new menu still needs move into a smaller file. Their tests are kept or updated: percent formatting, slider math, the held-row merge, and the speaker glyph.

**Tech Stack:** Swift 6, AppKit (`NSMenu`, `NSMenuItem.view`, `NSSlider`), swift-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-22-volume-mixer-design.md`, section "Revision 2026-11-22: the mixer is a native macOS menu".

## Global Constraints
- **Native only.** Use system fonts (`NSFont.menuFont(ofSize: 0)`, and `.systemFont(ofSize: 11)` for captions) and system colours (`.labelColor`, `.secondaryLabelColor`, `.tertiaryLabelColor`).
  - Sliders are native `NSSlider`. Don't paint the menu's background, and don't use ink/paper `Theme` colours in the menu.
- **Copy:**
  - Header "Sound"
  - Section header "Apps"
  - "Volume Mixer Settings…"
  - "Nothing's playing right now."
  - "Volume Mixer needs System Audio Recording" plus an "Open Settings…" item
  - "Plays to another device"
  - "This device controls its own volume"
  - The notice text comes from `TapController.notice`.
- **Live while open.** All of these must update while the menu is open, without reopening it:
  - rows appearing and disappearing
  - system volume changes from the keyboard volume keys
  - the playing indicator
  - mute state

  Menus run the run loop in event-tracking mode, so any timers or observation hops must work in `.common` modes. Modify the open menu's items in place.
- **Behaviour kept:**
  - Clicking the app icon toggles mute.
  - Dragging a muted app's slider unmutes it.
  - `controller.refresh()` runs when the menu opens.
  - The needsPermission "Open Settings…" runs `SystemAudioPermission.request()`. If permission isn't granted, it opens the pane. Either way it then calls `controller.refresh()`. Guard all of this with `isInstalled`.
  - "Volume Mixer Settings…" calls `openSettings`.
- **Off means off.** `remove()` closes the menu if it's open (`cancelTracking()`), stops every timer and observation, and removes the `NSStatusItem`. It is idempotent.
- **Icons.** Each row's icon is the owning app's icon: `NSRunningApplication(processIdentifier:)` for the app's pid, or `NSWorkspace.shared.icon(forFile:)` from `urlForApplication(withBundleIdentifier:)`.
  - Never use a helper's or a generic placeholder icon.
  - Web content uses the `globe` SF Symbol as a template.
  - Fix the Chrome placeholder seen in testing.
- **Tests:** `scripts/test.sh`, with the full suite green at the end. Unit tests never touch real Core Audio, the real permission probe or a real `NSStatusItem`.
- **Commits:** each commit message ends with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. Never push.

## Review Focus
1. **Menu updates while open.** Rows, volume keys and mute all update live during menu tracking. Verify by hand with the volume keys and by starting or stopping playback while the menu is open.
2. **Slider drag inside a menu.** Dragging is smooth, the menu doesn't close mid-drag, and each value reaches the controller.
3. **`remove()` while the menu is open** leaves nothing behind.
4. **Icon resolution** for helper-based apps (Chrome, Discord) and for Web content.
5. **Long app names** don't truncate badly at the chosen width, and the width stays stable as rows change.

---

### Task 1: Native mixer menu

**Files:**
- Modify: `Sidekick/Tools/VolumeMixer/MixerStatusItem.swift`. It owns the `NSMenu` and delegate, builds the items, and handles live updates.
- Create:
  - `Sidekick/Tools/VolumeMixer/MixerMenuRows.swift`: the AppKit row views (system row, app row, caption row).
  - `Sidekick/Tools/VolumeMixer/MixerMenuModel.swift`: pure helpers moved out of MixerPanel.swift, plus `MixerMenuModel.items(...)`, which maps controller and system-volume state to an ordered list of menu entries.
- Delete: `Sidekick/Tools/VolumeMixer/MixerPanel.swift`, once its pure helpers have moved.
- Test: update or move the existing panel tests. Add `SidekickTests/VolumeMixer/MixerMenuModelTests.swift`.

**Interfaces:**
- Consumes:
  - `TapController`: `rows`, `needsPermission`, `notice`, `setVolume`, `toggleMute`, `level(for:)`, `refresh()`
  - `SystemVolume`: `deviceName`, `volume`, `muted`, `canMute`, `setVolume`, `toggleMute`
- Produces:
  - `MixerStatusItem`'s existing init and `MixerMenuBar` conformance, unchanged.
  - `enum MixerMenuEntry: Equatable { case header(String), system, deviceCaption(String), separator, sectionHeader(String), app(MixerRow), caption(String), action(String) }`
  - `static func MixerMenuModel.entries(rows: [MixerRow], needsPermission: Bool, notice: String?, deviceName: String) -> [MixerMenuEntry]`

- [ ] **Step 1: Write failing tests for `MixerMenuModel.entries`:**
  - `normalLayout`: `[.header("Sound"), .system, .deviceCaption(name), .separator, .sectionHeader("Apps"), .app…, .separator, .action("Volume Mixer Settings…")]`
  - `emptyShowsNothingPlaying`: `.caption("Nothing's playing right now.")` in place of the app rows.
  - `needsPermissionReplacesApps`: `.caption("Volume Mixer needs System Audio Recording")` and `.action("Open Settings…")`, with no app rows and no system row change.
  - `noticeShownAsCaption`: the notice text appears as a caption after the app rows.
  - Keep or adapt the existing helper tests that moved.
- [ ] **Step 2:** Run the new suite and expect FAIL.
- [ ] **Step 3:** Implement the model, the row views and the `NSMenu` wiring.
  - The delegate's `menuWillOpen` calls `refresh()`, builds the items and starts the live updates. `menuDidClose` stops them.
  - App rows:
    - Line 1: the icon (16pt, the mute button), the name, and the playing mark (a small `.tertiaryLabelColor` symbol such as `waveform`, shown only while `isPlaying`).
    - Line 2: a full-width small slider and a right-aligned %.
  - Mute dims the icon (alpha about 0.4) and disables the slider's look but keeps it draggable for the unmute rule.
  - Use a fixed width of about 300pt.
  - Delete `MixerPanel.swift` and any now-dead code.
- [ ] **Step 4:** Run the suite, then the full `scripts/test.sh`. Expect PASS. Run `xcodegen generate`.
- [ ] **Step 5: Manual check.** Build the Debug app into a separate derived-data path (not `.build-dd`, which the user is running) and launch it with an `-enabledTools` override, as earlier tasks did.
  - Screenshot the open menu next to Sidekick's own menu for the report.
  - Verify the Review Focus items 1–5, playing Music and a YouTube tab in Chrome.
  - Restore anything you change and quit the instance you launched.
- [ ] **Step 6:** Commit `feat(volume-mixer): native menu mixer`.
