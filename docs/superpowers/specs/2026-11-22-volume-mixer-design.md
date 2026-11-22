# Volume Mixer: design

Date: 2026-11-22. Status: draft for approval.

## Intent
Add a **Volume Mixer** tool to Sidekick (after Dictation and Window Manager). It lets the user set each app's volume separately from a quick mixer in the menu bar. The user wants something they reach for constantly, and wants Sidekick to remember every app's volume. It is for the author and a few friends, so it must be polished, fast to open, and never make sound worse or riskier than macOS alone.

## Goals
- A speaker icon of its own in the menu bar, shown only while the tool is on. One click opens a small mixer panel.
- The panel has one row per app, with its icon, name, a slider, the percentage, and mute on clicking the icon.
- A system (output device) volume slider sits at the top of the panel.
- Each app's volume and mute state are remembered by app (bundle ID). They're reapplied automatically whenever that app plays sound again, including after Sidekick or the Mac restarts.
- An app whose volume is 100% and unmuted plays exactly as it does without Sidekick: it isn't captured at all.
- It follows the Sidekick tool contract. When off there's no menu bar icon, no capture, and every app's sound is normal. Remembered volumes are kept for next time.
- It matches Sidekick's look: ink and paper, `Theme`, and the `Motion` springs.

## Non-goals
- Boosting above 100%.
- Per-app output device routing (sending one app to headphones and another to speakers).
- Automatic rules, such as ducking music during a call.
- Per-app EQ or effects.
- Controlling apps that play to a device other than the current default output. They keep working normally, just without control (see Edge cases).
- Intel Macs and macOS before 26, which Sidekick already excludes.

## Anti-goals
- Installing a sound driver, needing an admin password, or anything that stays installed when the tool is off.
- Private APIs.
- A burst of full-volume sound from a muted or lowered app at any moment: when the slider is set, when switching device, when the tool is turned off, or if Sidekick crashes. The crash case is limited by what macOS does; see Constraints.
- Noticeable added delay or glitches in apps the user never touched.

## Constraints
- Swift 6 strict concurrency, SwiftUI plus AppKit, macOS 26, arm64. The project setup matches Sidekick's: XcodeGen, swift-testing, and `scripts/test.sh`.
- **Mechanism: Core Audio process taps** (macOS 14.2+).
  - Use `CATapDescription` for the app's processes, with `muteBehavior = .mutedWhenTapped`, created with `AudioHardwareCreateProcessTap`.
  - The tap goes into a private aggregate device whose main subdevice is the current default output.
  - An IO proc copies the tapped audio to the output, scaled by the volume.
  - Process lists come from `kAudioHardwarePropertyProcessObjectList`, with each process's `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID` and `kAudioProcessPropertyIsRunningOutput`.
- **The IO proc runs on a real-time audio thread.** It must not allocate, lock or touch actor-isolated state. Gain values are handed over through lock-free atomics, using the Swift `Synchronization` module's `Atomic`.
- **Permission: "System Audio Recording".**
  - Info.plist needs an `NSAudioCaptureUsageDescription`. Copy: "Sidekick's Volume Mixer adjusts each app's volume by routing its sound through Sidekick. Nothing is recorded or saved."
  - macOS has no public way to check this permission's status in advance. The first tap creation triggers the system prompt.
  - A refused permission shows up as silent buffers or a failed tap. The builder must find a reliable public-API way to detect "granted" for the setup step and the Home card, and document what it chose.
- If Sidekick quits or crashes, macOS removes its taps, and tapped apps go back to normal (full) volume. That's acceptable: the failure is "back to normal", never silence.

## Approaches considered
1. **Core Audio process taps.** Chosen by the user. There's no driver and it's removed cleanly. It's Apple's supported per-app audio API.
2. **A virtual audio driver** (Background Music style HAL plug-in). Rejected: it needs an admin install, breaks across macOS updates, and stays installed when the tool is off.
3. **Per-app scripting of volume.** Rejected: only a few apps, such as Music and Spotify, expose volume.

## Decided with the user
- The scope is a quick menu-bar mixer, with volumes remembered for every app.
- It lives behind its own speaker icon in the menu bar (option A). It is not in Sidekick's main menu.
- The user approved these proposals:
  - Which apps show: apps playing now, plus running apps whose volume was changed.
  - Mute is a click on the app icon.
  - Each playing app shows a small live level.
  - The range is 0–100% with no boost.
  - A system volume slider sits on top.
  - Untouched apps aren't captured.
  - Setup is one "System Audio Recording" step.
  - Off means off, but volumes are remembered.
  - The look is black and white with spring animations.
- The user approved the approach: process taps.

## Behaviour

### Apps and grouping
- An **app** is a running `NSRunningApplication` with a bundle ID and an icon, but not Sidekick itself.
- A Core Audio process belongs to an app if any of these holds:
  - its bundle ID equals the app's;
  - its bundle ID starts with the app's ID plus "." (for example `com.google.Chrome.helper`);
  - its PID is the app's PID, or the app's PID is one of its ancestors by parent PID.
  - Builder: find out which rule actually maps Safari's and other WebKit apps' web-content processes (`com.apple.WebKit.WebContent`), and document it. If they can't be attributed to a single app, they appear as their own "Web content" row. Don't drop them silently.
- **The list shows** apps that have any process with `IsRunningOutput` true, plus running apps that have a stored setting other than 100% and unmuted.
- Rows are sorted by name and stay stable. A row doesn't jump when its app stops or starts playing.
- The list updates live while the panel is open. Rows animate in and out with `Motion.fluid`.

### Volume, mute, persistence
- Volume is stored per bundle ID as `Double` 0...1, and muted as `Bool`.
  - Default: 1.0, unmuted.
  - Stored in UserDefaults under `volumeMixer.settings` as a dictionary keyed by bundle ID.
  - The stored value is what the user last set, whether or not the app is running.
- The gain applied is `muted ? 0 : curve(volume)`. The curve is perceptual: `gain = volume²`, so 50% on the slider sounds roughly half as loud. The label shows the slider percentage.
- **When an app's effective setting is 100% and unmuted,** it has no tap. When the user moves it off 100% (or mutes it), a tap is created. When they return it to 100% and unmuted, the tap is torn down.
  - Tearing down a tap at full volume can't cause a burst, because it's already at full.
  - Creating a tap must not glitch or burst. Start the gain at the current effective level, and ramp gain changes over about 20ms to avoid zipper noise.
- **Reapply on launch:** when an app with a stored non-default setting starts producing output, its tap is created automatically. A short blip at full volume before the tap takes effect is acceptable, but should be kept as small as possible: watch the process list and `IsRunningOutput` changes through property listeners, not polling.
- New processes from an already-tapped app join its tap. For example, a new Chrome tab's helper starts playing: update the tap's process list or recreate the tap.

### Output device changes
- When the default output device changes (headphones plugged in, AirPods connect), every active tap's aggregate device is rebuilt on the new device. The gain is carried over.
- During the switch, err towards brief silence rather than full volume.

### System volume slider
- It shows and sets the default output device's volume (`kAudioDevicePropertyVolumeScalar` on the main element, or on channels 1 and 2 when the device has no main control), and its mute.
- If the device has no software volume (some HDMI and USB devices), the slider is disabled with the caption "This device controls its own volume".
- It stays in sync with changes from the keyboard volume keys or Control Center while the panel is open.

### Revision 2026-11-22: the mixer is a native macOS menu
After the hands-on test, the user asked for the mixer to "look mac native and the same" as Sidekick's own menu bar menu, which is a standard SwiftUI `MenuBarExtra` menu (an `NSMenu`). Decision (approved by the user):
- **Menu, not panel.** The mixer becomes a real `NSMenu` on its status item. That gives it the same material, system font, highlight, open/close behaviour, Esc and click-outside as Sidekick's menu and Apple's Sound menu.
- **This revision replaces the custom panel below.** The ink-and-paper styling and custom sliders described in the original panel section no longer apply to the mixer.
- **Layout:**
  - Bold "Sound" header.
  - System row: speaker glyph (mute), native slider, %. Device name below it as a small grey caption.
  - Separator.
  - "Apps" section header.
  - Per app: app icon and name on one line, then a native slider and % beneath. This avoids the truncation seen with "Google Chrome…".
  - Separator, then "Volume Mixer Settings…".
- **Native controls:** sliders are native (`NSSlider`). Clicking the app icon still mutes; a muted row dims its icon and greys its slider. Dragging a muted app's slider unmutes it.
- **Playing indicator:** the level bars and dots are replaced by one small, subtle grey "playing" mark next to the name.
- **States:**
  - The needsPermission, empty and notice states become disabled grey menu items.
  - The permission state adds an "Open Settings…" item.
  - Rows that play to another device show a disabled slider with "Plays to another device".
- **Bug fix:** apps whose audio comes from a helper (Chrome) must show the parent app's real icon, not a placeholder.

Plan: `docs/superpowers/plans/2026-11-22-volume-mixer-native-menu.md`.

Approaches considered:
1. A real `NSMenu`. Chosen: identical to Sidekick's menu by construction.
2. Restyle the custom panel to imitate a menu. Rejected: it would always be slightly off.

### Menu bar item and panel (original; superseded by the revision above)
- While the tool is on, an `NSStatusItem` shows an SF Symbol speaker (`speaker.wave.2`).
- Clicking it toggles a borderless `NSPanel` anchored under the item.
  - The panel springs open (`Motion.snappy` scale and opacity from the top edge) and closes on a click outside, on Esc, or on a second click on the icon.
  - It's non-activating, so the frontmost app keeps focus.
- **Panel layout** (fixed width of about 320pt):
  ```
  ┌──────────────────────────────────┐
  │ 🔊  MacBook Pro Speakers ━━━━○── │  ← system volume (device name)
  │ ──────────────────────────────── │
  │ 🎵 Music     ▂▅▃  ━━━━━━○──  70% │
  │ 🌐 Safari    ▃▂▅  ━━━━━━━━━○100% │
  │ 💬 Discord        ━━○──────  35% │  ← not playing: no level
  │ ──────────────────────────────── │
  │ Volume Mixer settings…           │
  └──────────────────────────────────┘
  ```
- **Empty state:** "Nothing's playing right now."
- **Panel height** grows with rows up to about 8, then the panel scrolls.
- **Slider styling:** black and white custom sliders in Sidekick's ink and paper, not the grey system slider.
- **Level display:**
  - For tapped apps, show a small three-bar level from the tap's buffers (peak per buffer, published through an atomic and sampled about 20 times a second by the UI).
  - For untapped apps there's no audio to measure, so show a simple animated "playing" indicator driven by `IsRunningOutput` instead. It must not be a fake level that pretends to be live.
- The footer opens Sidekick's main window on the Volume Mixer page.

### Settings page (in Sidekick's main window)
- One page, "Settings", with these rows:
  - "Remembered volumes": every stored app with its volume, plus a reset button that sets it back to 100%.
  - "Reset all".

### Tool integration
- **`VolumeMixerTool: Tool`**
  - id `volumeMixer`, name "Volume Mixer", symbol `speaker.wave.2`
  - Summary: "Set each app's volume from the menu bar. Sidekick remembers it for next time."
  - `permissions: [.systemAudio]`, a new `Permission` case with the title "System Audio Recording".
  - `setupSteps: [.systemAudio]`, a new `OnboardingStep` with its own step view in Sidekick's style that explains why.
  - `menuItems: []`. The mixer lives in its own status item, not Sidekick's menu.
  - Off by default. `ToolRegistry`'s default stays `["dictation"]`.
- **`start()`:** adds the status item, starts process and device listeners, and creates taps for running apps with stored non-default settings.
- **`stop()`:** destroys every tap and aggregate device, removes listeners and the status item, and closes the panel. Every app is back to normal sound.
- A new `Permissions.Pane.systemAudio` deep link to the Privacy & Security pane for System Audio Recording. The builder verifies the URL on macOS 26.

## Edge cases
- **An app playing to a non-default device** (one that picks its own output, such as a DAW or Zoom set to a specific speaker) is out of scope. Builder: detect it if the API allows and show the row disabled with "Plays to another device". If not, document it as a known limitation, and make sure tapping such an app never silences it.
- **Sidekick's own sound** (Dictation's feedback sounds): Sidekick isn't listed.
- **System sounds and alerts** (`systemsoundserverd`, `coreaudiod`): not listed in v1.
- **Permission revoked while on:** taps go silent or fail.
  - Tear down affected taps so apps return to normal. Never leave them silent.
  - The panel shows one line: "Volume Mixer needs System Audio Recording", with a button to open the setting.
- **The machine sleeps and wakes, or a device disappears mid-play:** rebuild on the next default-device notification.

## Code layout (proposed)
```
Sidekick/Tools/VolumeMixer/
  VolumeMixerTool.swift        Tool conformance, start/stop, page
  MixerSettingsStore.swift     pure: per-bundle volume/mute persistence, gain curve
  AppGrouping.swift            pure: map (pid, bundleID, parentPID) processes → apps
  AudioProcessMonitor.swift    Core Audio process list + IsRunningOutput listeners
  AppTap.swift                 one app's process tap + aggregate device + IO proc + atomics
  TapController.swift          decides which apps get taps; device-change rebuilds
  SystemVolume.swift           default output device volume/mute + listener
  MixerStatusItem.swift        NSStatusItem + panel show/hide
  MixerPanel.swift             SwiftUI panel: system row, app rows, sliders, levels
  VolumeMixerSettingsView.swift
Sidekick/UI/Onboarding/Steps/SystemAudioStep.swift
```
Keep the logic pure where possible (`MixerSettingsStore`, `AppGrouping`, and the decision of which apps need a tap) so it's unit-testable without Core Audio. Put the Core Audio layer behind a protocol so `TapController` can be tested with fakes.

## Testing
- **Unit tests:**
  - Settings persistence and defaults.
  - The gain curve.
  - Grouping: Chrome-style helpers, descendants via parent PID, unknown processes.
  - Which apps need a tap for each combination of stored settings and running apps.
  - The list shows playing apps plus changed running apps, and sorts stably.
  - Tool start and stop: no status item or taps left after stop.
- **Manual tests:**
  - Music, Safari (YouTube), Chrome and a call app at different volumes.
  - Mute.
  - Quit and relaunch an app; it comes back at its stored volume.
  - Restart Sidekick.
  - Plug in headphones or connect AirPods mid-song.
  - Turn the tool off; everything is back to full.
  - The system slider stays in sync with the keyboard volume keys.
  - Grant and deny the permission.
  - Dictation and Window Manager are unaffected.

## Calls I made (the user can change any of these)
- **Name and placement:** the tool is called "Volume Mixer", it's off by default, and the panel has a "Volume Mixer settings…" footer link.
- **Sliders:** a perceptual (squared) gain curve, gain changes ramped over 20ms, and custom ink and paper sliders.
- **Level display:** tapped apps get real levels, and untapped playing apps get an honest "playing" indicator instead of fake levels.
- **Out of scope for v1:** system sounds, Sidekick itself, per-app output devices, and a keyboard shortcut to open the panel.
- **Settings page:** it holds only the list of remembered volumes and the resets.

## Settled after the builder check
- **First touch while playing:** when a playing app is first moved off 100%, a brief dropout (up to about 50ms) is acceptable. Doubled audio (the original and the tapped copy playing together) and a full-volume burst are not. Order it as: create the tap, start the IO proc with the target gain, and let `mutedWhenTapped` silence the original. *(my call)*
- **Shared WebKit content:** if `com.apple.WebKit.WebContent` processes can't be attributed to one app, their row is stored under the synthetic key `webkit.webcontent` and titled "Web content". *(my call)*
- **Setup step:** like the other permission steps, it can be continued without granting. If the tool is on without the permission, the status icon still shows and the panel shows only the "needs System Audio Recording" line and the button. *(my call)*
- **Rebuild failure on device change:** retry once. If it still fails, release the app to normal sound (as a crash would) and show "Couldn't keep [App]'s volume on this device" in the panel. Never leave it silent indefinitely. *(my call)*
- **Taps:** one tap and aggregate device per app or one shared aggregate is the builder's choice, as long as untouched apps are unaffected. *(left to builder)*
- **Settings page while off:** it's hidden, like every tool's pages (Sidebar only lists enabled tools). Stored volumes don't apply while off. *(answered by project)*
- **Tests:** unit tests never touch real Core Audio, taps or permission. They use fakes behind the protocol. Real audio is covered by the manual checklist. *(my call)*
- **Status item:** Sidekick's own menu is a SwiftUI `MenuBarExtra`, and the mixer adds a separate AppKit `NSStatusItem`. These two coexist. *(answered by project)*

## Left to the builder
- How to detect the System Audio Recording permission (it must use a public API and be documented).
- Exactly how WebKit content processes are attributed to an app.
- Detecting apps that play to a non-default device.
- Tap and aggregate-device details, level sampling rates, and panel sizes within the style.
