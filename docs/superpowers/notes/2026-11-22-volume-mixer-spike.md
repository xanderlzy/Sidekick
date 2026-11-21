# Volume Mixer: Core Audio spike findings

Date: 2026-11-22. Machine: MacBook Pro (arm64), **macOS 27.2 (build 26B123)**, Swift 6.4.2. The default output was MacBook Pro Speakers. One virtual output device was also installed (Microsoft Teams Audio, `MSLoopbackDriverDevice_UID`).

The spike code was throwaway Swift CLIs in the session scratchpad and is not committed. To measure, I tapped as a reader (a non-muting tap) to get sample peaks, and recorded the built-in mic. Acoustic levels are the 440 Hz Goertzel magnitude of a 440 Hz test tone, per 10 ms chunk, so room noise doesn't count. Permission was attributed to the responsible app (VS Code, already granted "System Audio Recording Only"). I also used two ad-hoc-signed `.app` probes with their own bundle IDs to see the undetermined and denied states.

Later tasks follow this doc. Where it differs from the plan or spec, this doc wins.

---

## 1. Process list, and which process carries each app's audio

### Answer
- **Chrome:** audio comes from one long-lived helper, `com.google.Chrome.helper` ("Google Chrome Helper (Aperitif)", the audio service). Its parent PID is Chrome's. The bundle-prefix rule and the parent-PID rule both map it.
- **Safari / WebKit:** audio comes from **`com.apple.WebKit.GPU`**, not `com.apple.WebKit.WebContent`. WebContent processes never appear in `kAudioHardwarePropertyProcessObjectList`. Each WebKit host app (Safari, Outlook, Raycast and others) gets its **own** GPU process, but its parent PID is **1 (launchd)** and its bundle ID is generic. **No public rule can map it to Safari.** Only `responsibility_get_pid_responsible_for_pid` can (it returned Safari's PID), and that is SPI, so it's ruled out by the no-private-API anti-goal.
- **Other XPC helpers act the same way.** Quick Look playing audio inside Safari showed up as `com.apple.quicklook.QuickLookUIService`, with parent PID 1 and Safari as the responsible process.
- **Music (observed, fix round 1):** audio comes from the app process itself: `pid=2963 ppid=1 out=1 devs=[81] bundle=com.apple.Music`. The bundle-ID-equality rule maps it. A gain-0.3 tap gave tapIn 0.250 → out 0.075, and a gain-0 tap gave out 0.000. After `pause`, `IsRunningOutput` stayed 1 for at least 1 s, so don't treat it as "playing" for level display (see §2 on IO callbacks).
- **`afplay` / CLIs:** these have an empty bundle ID. They aren't `NSRunningApplication`s with a bundle, so they're never listed.

**Ruling for AppGrouping.** Keep the three spec rules: equal bundle ID, `<appID>.` prefix, or an ancestor by parent PID. Then add one rule:
- A process whose bundle ID is `com.apple.WebKit.GPU` or `com.apple.WebKit.WebContent` maps to the synthetic **`webkit.webcontent` "Web content"** row. That row's tap includes **all** such processes.
- Consequence: lowering "Web content" lowers web audio in **every** WebKit app (Safari, Mail, Outlook's web views, Raycast…). The row's subtitle or help text should say so.
- Any other process that maps to no app (for example QuickLookUIService) stays unlisted and untapped. That's safe, because it simply plays normally.

### Evidence (process list while playing)
```
pid=6065  ppid=6032 out=1 devs=[81] bundle=com.google.Chrome.helper  (Google Chrome Helper (Aperitif))   ← Chrome pid 6032
pid=49770 ppid=1    out=1 devs=[81] bundle=com.apple.WebKit.GPU       (responsible pid = Safari 49756)
pid=49795 ppid=1    out=1 devs=[81] bundle=com.apple.quicklook.QuickLookUIService (responsible = Safari)
pid=2901  ppid=1    out=0           bundle=com.apple.WebKit.GPU       (responsible = Raycast)
pid=8513  ppid=1    out=0           bundle=com.apple.WebKit.GPU       (responsible = Microsoft Outlook)
```
`PROC_PIDUNIQIDENTIFIERINFO` / `proc_bsdinfowithuniqid` aren't in the public SDK (they don't compile). The only public link is `pbi_ppid`, which is 1.

### Exact API
- List: `AudioObjectGetPropertyData(kAudioObjectSystemObject, kAudioHardwarePropertyProcessObjectList)` → `[AudioObjectID]`.
- Per object:
  - `kAudioProcessPropertyPID` (`pid_t`)
  - `kAudioProcessPropertyBundleID` (`CFString`, +1 retained, may be empty)
  - `kAudioProcessPropertyIsRunningOutput` (`UInt32`)
  - `kAudioProcessPropertyDevices` with **scope `kAudioObjectPropertyScopeOutput`** (`[AudioObjectID]`)
- Parent PID: `proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &proc_bsdinfo, size)` → `pbi_ppid`. It returns 0 bytes for some system daemons; treat that as "no parent".
- PID → object: `kAudioHardwarePropertyTranslatePIDToProcessObject` with the `pid_t` as qualifier. It returns 0 for a pid with no audio object. Passing 0 into a tap makes `AudioHardwareCreateProcessTap` fail with `'!obj'`.

### Listener behaviour (this matters for "reapply on launch")
- **`kAudioProcessPropertyIsRunningOutput` listeners never fired** on macOS 27.2. I tested scope Global and Wildcard over several start/stop cycles, and polling showed the value changing.
- **`kAudioProcessPropertyIsRunning` (Global)** and **`kAudioProcessPropertyDevices` (Output scope)** do fire within a few ms of start and stop. In the callback, re-read `IsRunningOutput` and `Devices`.
- `kAudioHardwarePropertyProcessObjectList` fires (twice per change) when processes appear or disappear. Add the per-process listeners to new objects there.
- So AudioProcessMonitor listens to `ProcessObjectList`, plus `IsRunning` and `Devices`(output) on every process object. It does not use `IsRunningOutput` listeners.

---

## 2. Tapping one app: quieter, not doubled, first-touch dropout

### Answer
- **It works as the spec describes.** A 0.3 gain gives 0.29–0.32× at the mic on a steady tone (afplay and Chrome). Safari's GPU process tapped fine too.
- **Muting is complete.** With gain 0 the mic reads the noise floor (≤0.002 against 0.10 at full), for a live tap and for a tap created before the app started playing.
- **Not doubled.** Doubling would read ≥0.7× at gain 0.3 (1 ± 0.3). It never did.
- **First-touch dropout** (spec order: create tap, then aggregate, then IO proc started at the target gain): typically **one 10 ms chunk** at 5–17% of full, then the target level. That's ~10–20 ms, well inside the 50 ms allowance. Measured over 6 fresh-process runs. One early run (the first tap of the session, mic just started) showed ~140 ms of quiet. I couldn't reproduce it, so treat 150 ms as a worst case.
- **No burst on teardown.** Destroying the tap returns the app to full level within one 10 ms chunk, with no gap and no overshoot.
- **A tap created while the app is silent costs nothing and has no blip.** The aggregate's IO proc **isn't called at all** while none of the tapped processes is outputting (callback count stays 0). It starts by itself when the app begins playing, and that first audio is already muted (the gain-0 test gave silence from the first sample). So "reapply on launch" should create the tap as soon as the process object appears (`ProcessObjectList` change), before it plays.
- **New processes can join a live tap without rebuilding it.** Set `kAudioTapPropertyDescription` with an updated `processes` array (status 0). Audio from the added process appeared within one 250 ms sample. Use this when a tapped app spawns another audio process.
- Setup cost: `AudioHardwareCreateProcessTap` takes ~40–55 ms, `AudioHardwareCreateAggregateDevice` ~6–14 ms, IO proc create and start <10 ms, first IO callback ~80–100 ms after starting. Do it off the main thread, because it can block for seconds (see §3).
- Measurement caveat: the built-in speakers have adaptive DSP. In some runs where playback started from idle, the level settled at 0.45–0.6× instead of 0.3×, then slowly drifted. The tap's own output peaks were exactly 0.3× and the gain-0 test was clean, so this is the speaker processing, not leakage.

### Evidence (mic, 440 Hz magnitude relative to full; each value is a 10 ms chunk)
```
afplay  0.3 live:  … 0.994 0.956 0.968 0.971 1.002 0.779 0.079 0.311 0.290 0.340 0.317 …   during/after = 0.298
Chrome  0.3 live:  … 0.962 0.951 0.691 0.098 0.196 0.185 0.248 0.272 0.292 0.334 …         during/after = 0.316
Chrome  0 pre-created: 0.001 … 0.001 (whole playback)   then 0.143 after teardown
Chrome  0 live:    0.096 0.095 0.056 0.000 0.001 0.000 …                                    (half-second averages)
```

### Exact API (what worked)
```swift
let desc = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
desc.uuid = UUID(); desc.isPrivate = true; desc.muteBehavior = .mutedWhenTapped; desc.name = "Sidekick <bundleID>"
var tap = AudioObjectID(0); AudioHardwareCreateProcessTap(desc, &tap)
// tap format: kAudioTapPropertyFormat → here 48 kHz, 2 ch, Float32 interleaved (flags 9, 8 bytes/frame)
let dict: [String: Any] = [
  kAudioAggregateDeviceNameKey: "...", kAudioAggregateDeviceUIDKey: UUID().uuidString,
  kAudioAggregateDeviceMainSubDeviceKey: defaultOutputUID,            // kAudioDevicePropertyDeviceUID of default output
  kAudioAggregateDeviceIsPrivateKey: true, kAudioAggregateDeviceIsStackedKey: false,
  kAudioAggregateDeviceTapAutoStartKey: true,
  kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: defaultOutputUID]],
  kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]]]
var agg = AudioObjectID(0); AudioHardwareCreateAggregateDevice(dict as CFDictionary, &agg)
AudioDeviceCreateIOProcIDWithBlock(&procID, agg, ioQueue) { _, inData, _, outData, _ in
  // SPIKE ONLY (built-in speakers): the tap was the last inData buffer and outData had one
  // interleaved stereo buffer. Don't hard-code this — see "Buffer layout" below.
}
AudioDeviceStart(agg, procID)
// teardown: AudioDeviceStop → AudioDeviceDestroyIOProcID → AudioHardwareDestroyAggregateDevice → AudioHardwareDestroyProcessTap
```
- **Buffer layout was verified on one device only** (MacBook Pro Speakers: no input streams, one 2-channel interleaved output stream). Production must not assume it:
  - At aggregate creation (and again after every rebuild), read the aggregate's `kAudioDevicePropertyStreamConfiguration` for input and output scope (`AudioBufferList` of channel counts), and `kAudioStreamPropertyVirtualFormat` per stream from `kAudioDevicePropertyStreams`.
  - Read the tap's own format with `kAudioTapPropertyFormat`. Locate the tap's input buffer explicitly: the input stream whose channel count and format match it, at index (number of subdevice input streams). Precompute these indices before starting IO, and pass them to the IO proc as constants.
  - Map the tap's stereo into the output's first stream: channels 1–2 if it's interleaved with ≥2 channels, or buffers 0–1 if it's non-interleaved. Mono: (L+R)/2. Zero every other output buffer and channel.
  - If the layout is anything not recognised (no matching tap stream, non-Float32, a channel count of 0), **don't start the IO proc**. Destroy the tap so the app plays normally, and log it. Never guess, because a wrong guess means noise or silence.
- Update the tap in place: `AudioObjectSetPropertyData(tap, kAudioTapPropertyDescription, size = MemoryLayout<CATapDescription?>.size, &optionalDesc)`. This works for changing `processes` and for changing `muteBehavior`.
- **First-touch order ("unmuted, then flip"):** this is the only order production uses.
  1. Check the permission gate (§3, "Gate").
  2. Create the tap with `.unmuted`. Start the IO proc with output gain **0**.
  3. Set `muteBehavior = .mutedWhenTapped` through `kAudioTapPropertyDescription`. The call takes ~23 ms.
  4. **After that call returns,** set the target gain. The IO proc ramps from 0 to the target over ~20 ms (the spec's ramp, starting at 0).

  In the spike I stored the gain *before* the flip, so for ~23 ms the copy played on top of the not-yet-muted original. That's the likely cause of the ≤1.10× peaks. Ramping after the flip removes that overlap, at the cost of ≤~25 ms of extra dip (still within 50 ms).

  Measured with the spike's order, over 5 runs: 4 had no 10 ms chunk below 10% of full, and 1 had a single 10 ms dip (5%). There was no doubling (≤1.10×).
- **Teardown is a step, not a ramp.** Destroying the tap of a lowered app makes it jump **instantly** to its full, normal level. That happens when it returns to 100%, when the tool is turned off, and on a release after a failed rebuild. The original can't be ramped: we don't own its gain. "No overshoot" only means it never goes above normal. So for the tool-off and release cases, the spec's "no full-volume burst when the tool is turned off" can't be met literally with taps. It's the same "back to normal" as a crash. **Controller: please rule on this** (accept it, or turn the tool off by first ramping each lowered app's slider to 100%, so the jump is from near-full).

---

## 3. Permission (System Audio Recording)

### What it looks like
| State | `AudioHardwareCreateProcessTap` | aggregate / IO proc | Buffers |
|---|---|---|---|
| Granted | `noErr` | `noErr` | real audio |
| **Undetermined** | `noErr` | `AudioDeviceCreateIOProcIDWithBlock` **blocks the calling thread** while the system prompt is up (22.7 s in one run, until the user answered). The prompt reads: "“Probe” would like access to record your system audio." plus the `NSAudioCaptureUsageDescription` text. | after Allow: real audio |
| **Denied** | `noErr` | `noErr`, the IO proc runs normally | **all zeros** |

- **Danger: with permission denied, a `.mutedWhenTapped` tap still mutes the target app.** Measured: a denied app tapping afplay at gain 1.0 made the mic level go from 0.050 to **0.0012** (silence) for the tap's lifetime, then back to 0.060.
- So production must **never** create a muting tap without first confirming permission. If permission is lost, tear the taps down; never leave an app muted.
- No status code ever reports denial. Everything returns `noErr`.

### Chosen detection: a self-tap probe (public APIs only)
1. Play an inaudible signal from Sidekick itself: an `AVAudioEngine` with an `AVAudioSourceNode` making a 1 kHz sine at **1e-5** amplitude (−100 dBFS) into the main mixer.
2. Create an **unmuted** private tap on Sidekick's own process object (`TranslatePIDToProcessObject(getpid())`), plus a private aggregate and IO proc as above.
3. In the IO proc, flag any non-zero sample.
   - **Granted:** the first callback has peak 1.0e-5. Verdict in ~50 ms.
   - **Denied:** 20 callbacks (~200 ms) all exactly 0.0.
4. Tear down the tap and aggregate, and stop the engine.

Measured: the granted CLI → GRANTED in 57 ms. The granted app → GRANTED in 48–56 ms. The denied app (Probe2) → DENIED after 20 all-zero callbacks, 466 ms in total.

### When the probe runs (one rule)
When the status is undetermined, the probe *is* what shows the system prompt, and it blocks until the user answers. So:

- **Persisted flag `volumeMixer.permissionPrompted`** (UserDefaults, default false).
  - While it's false, **nothing probes automatically**. Every "granted?" question (the setup step, the Home card, tool start, the panel) answers **not granted** without touching Core Audio.
  - The only way to set it is the setup step's / panel's **"Grant" button**. That sets the flag, then runs the probe.
- **Once the flag is true,** the probe may run automatically. The status is then granted or denied and no prompt appears (unless someone reset TCC, which just shows the prompt again, the same as Grant would). It runs:
  - on tool start,
  - when the setup step or Home card appears, if the cached result is older than 30 s,
  - on the revocation triggers below.
- **Thread and timeout.** The probe runs on a dedicated serial background queue, never the main actor. Only one probe runs at a time, and later requests join the running one.
  - **Grant-initiated probe:** the caller waits up to **60 s**. That covers the user reading the prompt.
  - **Automatic probe:** the caller waits up to **2 s**.
  - **On timeout:** the caller gets `unknown`, which is treated as not granted. Don't create or flip muting taps, and keep the status as "not granted / checking". The probe is *abandoned*, not cancelled. When the blocked Core Audio call finally returns, the probe thread itself tears down its tap, aggregate and engine, and stores whatever result it got into the cache (with a timestamp). That way a late "Allow" still takes effect.
- **Home card "granted?":** show the cached result. If the flag is false, show "not granted" (the setup step). If the cache is older than 30 s, start an automatic probe in the background and update the card when it finishes. The card never blocks.

### Gate before any muting tap
- **A probe must have returned GRANTED within the last 30 s** before:
  - any `.mutedWhenTapped` flip (first touch), and
  - any muted pre-creation (reapply on launch).
- If the last GRANTED is older than that, run an automatic probe first and wait (≤2 s). If the result isn't GRANTED, don't mute. A pre-creation is skipped, and the app plays at full; it's retried on the next trigger.
- **Fast path:** if a tap in this session has delivered non-zero input within the last 30 s, that counts as a GRANTED probe. Zero input is **never** evidence either way.
- With the unmuted-then-flip order, an app can't be silenced by a stale result before the gate runs. A pre-created muted tap is covered by the watchdog below.

### Revocation watchdog
- **Primary trigger:** callbacks are running but every sample is zero.
  - The aggregate's IO proc only runs while at least one tapped process is outputting (§2). So "IO callbacks are happening" already means "something is playing", and no `IsRunningOutput` listener is needed.
  - In the IO proc, keep an atomic count of consecutive all-zero callbacks. A ~1 Hz main-side timer checks it.
  - If ≥1 s of callbacks have been all-zero, run an automatic probe. Silent content (for example a paused video that keeps its stream open) is possible, and the probe tells it apart from revocation.
- **Backup trigger:** a periodic probe every 30 s while any tap exists.
- **On DENIED or `unknown` from these:** tear down every tap at once (apps return to normal), and show the "needs System Audio Recording" line.
- **Worst-case silent window after revocation:**
  - ≈ 1 s (zero-run threshold) + ≤1 s (timer granularity) + ~0.5 s (the denied probe, which needs 20 zero callbacks) + teardown, so **≈2.5 s** of a tapped, playing app being silent.
  - If the 2 s probe times out, it's 1 s + 1 s + 2 s → **≈4 s** (teardown on `unknown`).
  - An app that isn't playing isn't silenced in any audible sense.
- *Not verified live:* toggling the permission off while a tap is running. That would have meant changing the user's own grants. The expected symptom is zero buffers (as in the denied state), which is what this watchdog catches.

### Deep link (verified on macOS 27.2)
- `x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture` opens **Privacy & Security → "Screen & System Audio Recording"**. The pane has two lists: "Screen & System Audio Recording" and "System Audio Recording Only".
- `…com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture` gave LaunchServices error -600 (Settings was quitting at the time), so prefer the `com.apple.preference.security` form, which matches the existing `Permissions.Pane` URLs.
- Note: **Sidekick (`com.sidekick.app`) is already listed and enabled under "Screen & System Audio Recording"** on this Mac. Ad-hoc spike apps that the user allowed did not appear in either list.

### Other notes
- The first IO-proc creation of a session for an already-granted client took 2.2 s once (probably the TCC lookup). Later ones took <10 ms. Another reason to keep setup off the main actor.
- `tccutil reset AudioCapture <bundle>` can't reset an app that LaunchServices doesn't know (it fails with -10814), so it's no help for development builds outside /Applications.

---

## 4. Apps playing to a non-default device

### Answer: detectable, and it **must** be detected
- `kAudioProcessPropertyDevices` (scope **Output**) lists the devices a process is currently playing to. For a player sent to the Teams virtual device it read `[57]`, while the default output is `81`. The `Devices` listener fires when this changes (see §1). It's empty while the process isn't outputting.
- **Hazard:** tapping such a process **moves its audio to the default output.** A process playing only to the Teams device was silent at the speakers (0.0007), went to full level at the speakers (0.168) while a muted tap with gain 1.0 existed, then went silent again. So a tap would *break* a DAW or call app that picks its own device.
- `CATapDescription.deviceUID` / `.stream` didn't help. Restricting a `stereoMixdownOfProcesses` tap to `BuiltInSpeakerDevice` still captured (and pulled to the speakers) the Teams-bound audio.

**Ruling:**
- **A process may be in a tap only if its output `Devices` is empty, or is exactly `[defaultOutput]`.** Any other value is "plays to another device", and the process is excluded from every tap. That includes playing to the default device **and** another one at once.
  - The multi-device case wasn't observed in the spike (no test produced it). Given the "audio is pulled to the default device" result below, tapping it would at least mute the other device's copy. So it's excluded conservatively.
- If all of an app's playing processes are like that, show the row disabled with "Plays to another device", and tear down any tap on it.
- Re-evaluate on every `Devices` notification and on default-device changes.
- A process with an empty `Devices` (not playing) can stay in a pre-created tap. If it later starts on another device, the `Devices` listener fires and it must be removed from the tap's `processes` (with `kAudioTapPropertyDescription`) at once.
- Known gap: the `Devices` notification comes a few ms *after* the process has started playing into the tap. A process that starts directly on another device while already in a pre-created tap may get a brief moment of audio on the default device before it's removed. (The delay wasn't measured precisely. Listener events arrived within ~5 ms of the poll seeing the change.)
- **Fresh-launch processes** have no last-known device. Rule:
  - Pre-create the muted tap for them (subject to the §3 gate) when the app's bundle ID has a stored non-default setting **and** hasn't been seen playing to another device this session. Keep an in-memory set of bundle IDs flagged "plays to another device"; it's cleared on relaunch of Sidekick.
  - For a flagged bundle ID, **wait**: add its processes to a tap only after the first `Devices` notification shows `[defaultOutput]`, and accept the short full-volume blip.
  - This keeps reapply-on-launch blip-free for the common case. The rare app that picks its own device leaks for a few ms at most, once per session.

---

## Cleanup done
- Every tap and aggregate the spike created was destroyed. Each was private, and the device list afterwards showed only the 3 real devices.
- afplay was stopped, the Chrome test tab was closed, and Safari (launched by the spike) was quit. System Settings was closed.
- Music was left "stopped". It had been paused before. The spike's `play` attempts failed and it was stopped.
- Left on the system: TCC entries for two ad-hoc spike bundles, `local.mixerspike.probe` (allowed) and `local.mixerspike.probe2` (denied). Their binaries were only in the scratchpad, and the entries don't show in the Settings lists. VS Code also gained microphone access during the spike, from a mic prompt the user answered.
