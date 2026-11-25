# Transcribe Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Transcribe tool. The user drops audio/video files (lectures) onto a page. They're queued, transcribed on-device one at a time with Whisper or Apple's engine, and kept as readable, timestamped paragraphs that can be copied or exported as `.txt`.

**Architecture:**
- Files go through a **file path that's separate from Dictation's live path**:
  - `AudioExtractor` turns any AVFoundation-readable file into a temporary 16 kHz mono `.caf`.
  - A `FileTranscriber` (Whisper or Apple) turns that into timed `Segment`s, with progress.
  - `TranscribeQueue` runs the jobs one at a time and saves segments into a SwiftData `TranscriptStore` as they arrive.
- The Whisper model store moves to a new app-level `SpeechEngines` that both tools share. It also carries the "Whisper is busy" flag that makes Dictation switch to Apple's engine while a job runs.

**Tech Stack:** Swift 6, SwiftUI + AppKit, SwiftData, AVFoundation, Speech (`SpeechAnalyzer`), WhisperKit 1.1.x, UserNotifications, swift-testing, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-11-26-transcribe-design.md`

## Global Constraints
- macOS 26, arm64, Swift 6 strict concurrency. Run tests with `scripts/test.sh [Suite]`, and run `xcodegen` after adding files (`scripts/test.sh` does it).
- English only. Whisper variant `openai_whisper-small.en`. Apple locale `en-US`.
- Keep the existing keys and folder: `whisperModelPath`, `Application Support/Sidekick/Models`, and Dictation's engine key `transcriber`.
- New UserDefaults keys:
  - `transcribeEngine` (default `whisper`; `TranscriberKind.effective` falls back to Apple until Whisper is downloaded)
  - `transcribeCleanup` (default `false`)
  - `transcribeShowTimestamps` (default `true`)
- Store file: `Application Support/Sidekick/Transcripts.store`.
- Only one Whisper transcription at a time, app-wide.
- Copy (exact):
  - "This format isn't supported."
  - "This file has no audio."
  - "File not found."
  - "Incomplete (stopped at {t})"
  - "Stopped"
  - "Waiting…"
  - notification "{title} is transcribed" / "{title} couldn't be transcribed"
  - "No speech found in this file."
- Paragraphs break on a pause > 1.5 s or past 120 words. Timestamps are `[mm:ss]`, or `[h:mm:ss]` from one hour on.
- Look and feel: `Theme`, `Motion`, `PageHeader`, `SettingsSection`/`SettingsRow`, `MonoButtonStyle`, `MonoToggleStyle`, `ProgressBar`.
- No network use other than the user-started Whisper download.

## Review Focus
1. **A file with no speech** (silence, music only) should finish as Done and show "No speech found in this file." It shouldn't show as failed, and it shouldn't show a blank page. Covered in Task 3 and Task 6.
2. **The same file dropped twice** should give two separate items, each transcribed. Covered in Task 6.
3. **A folder or a non-media file in a multi-file drop** should be rejected one by one with "This format isn't supported.", while the valid files in the same drop still queue. Covered in Task 6.
4. **Quitting or turning the tool off during the cleanup step** should leave the transcript Done with its uncleaned text. Transcription finished, so it isn't Incomplete, and cleanup is simply skipped. Covered in Task 6.
5. **Transcribe set to Whisper with the model removed before a job starts** should run that job on Apple's engine without failing. Covered in Task 6.

---

### Task 1: Shared speech engines + Dictation's switch to Apple while Whisper is busy

**Files:**
- Create: `Sidekick/Core/SpeechEngines.swift`
- Modify: `Sidekick/Tools/Dictation/Transcription/WhisperTranscriber.swift` (`TranscriberKind.effective`)
- Modify: `Sidekick/Tools/Dictation/DictationEnvironment.swift`, `Sidekick/Tools/Dictation/DictationTool.swift`, `Sidekick/Tools/Dictation/Pages/DictationSettingsView.swift`, `Sidekick/App/AppEnvironment.swift`
- Test: `SidekickTests/WhisperTranscriberTests.swift`, `SidekickTests/DictationToolTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor @Observable final class SpeechEngines`:
    - `init(defaults: UserDefaults = .standard)`
    - `let whisperModel: WhisperModelStore`
    - `var whisperBusy: Bool` (set by Transcribe)
    - `static let shared` (used by the app, not by tests)
  - `TranscriberKind.effective(selected:whisperReady:whisperBusy:) -> TranscriberKind`, with `whisperBusy` defaulting to `false`.
  - `DictationEnvironment.init(storeDirectory:defaults:engines:)`, where `engines: SpeechEngines`, and `DictationTool.init(..., engines: SpeechEngines = .shared)` passes it through.
  - `EngineSettings(env:)` becomes `EngineSettings(engineKey: String, defaultEngine: TranscriberKind, models: WhisperModelStore, onChange: @MainActor () -> Void)`, so Transcribe can reuse it in Task 7.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func busyWhisperFallsBackToApple() {
    #expect(TranscriberKind.effective(selected: .whisper, whisperReady: true, whisperBusy: true) == .apple)
    #expect(TranscriberKind.effective(selected: .whisper, whisperReady: true, whisperBusy: false) == .whisper)
}
```
In `DictationToolTests`:

```swift
@Test @MainActor func dictationUsesAppleWhileTranscribeBusy() {
    let engines = SpeechEngines(defaults: defaults)
    // fake a downloaded model at a temp folder, select whisper
    // engines.whisperBusy = true → env.effectiveEngine == .apple; false → .whisper
}
```

- [ ] **Step 2: Run** `scripts/test.sh WhisperTranscriberTests` and `scripts/test.sh DictationToolTests`. Expected: they fail to compile (no `whisperBusy` parameter, no `SpeechEngines`).

- [ ] **Step 3: Implement.**
  - Move `WhisperModelStore` ownership into `SpeechEngines`.
  - `DictationEnvironment.effectiveEngine` passes `engines.whisperBusy`.
  - `currentTranscriber()` already returns Apple whenever the effective engine isn't Whisper, so the switch is silent, with nothing changing in the pill.
  - `AppEnvironment` builds the `DictationTool` with `SpeechEngines.shared`.
  - The Dictation settings view calls the generalized `EngineSettings` with `TranscriberKind.storageKey`, `.apple`, `env.engines.whisperModel` and `env.warmUpEngine`.

- [ ] **Step 4: Run** `scripts/test.sh`. Expected: everything passes, including the existing Dictation tests.

- [ ] **Step 5: Commit** `refactor(dictation): share the Whisper model app-wide; fall back to Apple while Whisper is busy`

---

### Task 2: Transcript data and store

**Files:**
- Create: `Sidekick/Tools/Transcribe/Data/Transcript.swift`, `Sidekick/Tools/Transcribe/Data/TranscriptStore.swift`
- Test: `SidekickTests/Transcribe/TranscriptStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct Segment: Codable, Hashable, Sendable { var start: Double; var end: Double; var text: String }`
  - `struct Paragraph: Codable, Hashable, Sendable { var start: Double; var text: String }`
  - `enum TranscriptStatus: String, Codable { case waiting, transcribing, done, incomplete, stopped, failed }`
  - `@Model final class Transcript` with these fields:
    - `id: UUID`, `title: String`, `fileURL: URL`, `dateAdded: Date`, `queuedAt: Date` (the queue-order key; Retry bumps it), `duration: Double`
    - `engine: String?` (TranscriberKind raw value, set when the job starts)
    - `wantsCleanup: Bool` (snapshot taken at queue time)
    - `statusRaw: String`, `stoppedAt: Double?`, `failureReason: String?`
    - `segmentsData: Data` (JSON `[Segment]`)
    - `cleanedData: Data?` (JSON `[Paragraph]`)
    - Computed: `status`, `segments`, `cleaned`.
  - `@MainActor final class TranscriptStore` with:
    - `let container: ModelContainer`
    - `static func makeContainer(in directory: URL) throws -> ModelContainer` (file `Transcripts.store`)
    - `func add(fileURL: URL, wantsCleanup: Bool) -> Transcript` (title = file name without extension, status `.waiting`)
    - `func save()`, `func delete(_:)`
    - `func recoverAfterLaunch()`:
      - `.transcribing` becomes `.incomplete` (with `stoppedAt` = last segment end, or 0)
      - `.waiting` becomes `.stopped`
    - `func all() -> [Transcript]`, newest first

- [ ] **Step 1: Write the failing tests:**
  - `addUsesFileNameAsTitle`: `Lecture 4 - Entropy.mp4` gives the title `Lecture 4 - Entropy` and the status `.waiting`.
  - `segmentsRoundTrip`
  - `recoverMarksTranscribingIncompleteAndWaitingStopped`: `stoppedAt` equals the last segment's `end`.
  - `deleteRemoves`

  Use an in-memory container.
- [ ] **Step 2: Run** `scripts/test.sh TranscriptStoreTests`. Expected: FAIL, because the types aren't defined yet.
- [ ] **Step 3: Implement** in the files above. Follow `HistoryStore`'s container pattern.
- [ ] **Step 4: Run** `scripts/test.sh TranscriptStoreTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcribe): transcript model and store`

---

### Task 3: Paragraphs, timestamps and export text

**Files:**
- Create: `Sidekick/Tools/Transcribe/TranscriptFormatter.swift`
- Test: `SidekickTests/Transcribe/TranscriptFormatterTests.swift`

**Interfaces:**
- Produces `enum TranscriptFormatter` with:
  - `static func paragraphs(_ segments: [Segment], pause: Double = 1.5, maxWords: Int = 120) -> [Paragraph]`
  - `static func timestamp(_ seconds: Double) -> String` (with brackets)
  - `static func text(_ paragraphs: [Paragraph], timestamps: Bool) -> String`: paragraphs joined by `"\n\n"`, each prefixed with `timestamp + " "` when `timestamps` is on. An empty input gives `"No speech found in this file."`

- [ ] **Step 1: Write the failing tests:**

```swift
@Test func breaksOnPauseOverThreshold() {
    let s = [Segment(start: 0, end: 2, text: "One."), Segment(start: 2.5, end: 4, text: "Two."),
             Segment(start: 6, end: 8, text: "Three.")]
    #expect(TranscriptFormatter.paragraphs(s) == [Paragraph(start: 0, text: "One. Two."), Paragraph(start: 6, text: "Three.")])
}
@Test func breaksPastMaxWords()   // 3 segments × 50 words, no pauses → 2 paragraphs (100 + 50)
@Test func timestampFormats() {
    #expect(TranscriptFormatter.timestamp(252) == "[04:12]")
    #expect(TranscriptFormatter.timestamp(3599) == "[59:59]")
    #expect(TranscriptFormatter.timestamp(3600) == "[1:00:00]")
}
@Test func textWithAndWithoutTimestamps() {
    let p = [Paragraph(start: 0, text: "A."), Paragraph(start: 65, text: "B.")]
    #expect(TranscriptFormatter.text(p, timestamps: true) == "[00:00] A.\n\n[01:05] B.")
    #expect(TranscriptFormatter.text(p, timestamps: false) == "A.\n\nB.")
}
@Test func emptyTranscriptSaysNoSpeech()
@Test func trimsAndSkipsBlankSegments()
```
- [ ] **Step 2: Run** `scripts/test.sh TranscriptFormatterTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** A paragraph is closed *before* adding a segment that would push it past `maxWords`. A paragraph that's already longer on its own stays whole.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcribe): paragraphs and timestamps`

---

### Task 4: Audio extraction

**Files:**
- Create: `Sidekick/Tools/Transcribe/Engine/AudioExtractor.swift`
- Test: `SidekickTests/Transcribe/AudioExtractorTests.swift` (reuses `SpeechFixture`)

**Interfaces:**
- Produces:
  - `enum ExtractError: Error, Equatable { case notFound, unsupported, noAudio }`, with `var message: String` returning the exact copy from Global Constraints.
  - `struct ExtractedAudio: Sendable { let url: URL; let duration: Double }`: a temporary 16 kHz mono Float32 `.caf`. The caller deletes it.
  - `enum AudioExtractor`:
    - `static func validate(_ url: URL) async -> ExtractError?`: a cheap check used at drop time. It checks that the file exists, isn't a directory, that `AVURLAsset` is readable, and that it has at least one audio track.
    - `static func extract(_ url: URL) async throws -> ExtractedAudio`: uses `AVAssetReader` with `AVAssetReaderAudioMixOutput` to produce linear PCM 16 kHz mono, writes it with `AVAudioFile`, and checks for `Task.isCancelled` between buffers.

- [ ] **Step 1: Write the failing tests:**
  - `extractsAiffTo16kMono`: the result has a sample rate of 16000, 1 channel, and a duration within 0.2 s of the source.
  - `extractsAudioFromMovie`: build a small `.mov` with `AVAssetExportSession` from the `SpeechFixture` audio, then check the duration matches.
  - `missingFileIsNotFound`
  - `textFileIsUnsupported`
  - `folderIsUnsupported`
  - `videoWithoutAudioIsNoAudio`: write one black frame with `AVAssetWriter`.
- [ ] **Step 2: Run** `scripts/test.sh AudioExtractorTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcribe): extract audio from audio and video files`

---

### Task 5: File transcribers (Whisper and Apple)

**Files:**
- Create: `Sidekick/Tools/Transcribe/Engine/FileTranscriber.swift`, `Sidekick/Tools/Transcribe/Engine/WhisperFileTranscriber.swift`, `Sidekick/Tools/Transcribe/Engine/AppleFileTranscriber.swift`
- Test: `SidekickTests/Transcribe/FileTranscriberTests.swift`

**Interfaces:**
- Produces:

```swift
protocol FileTranscriber: Sendable {
    /// `onSegments` gets each newly finished batch, in order, with times in seconds from the file start.
    /// `onProgress` gets 0...1. Throws CancellationError when the task is cancelled.
    func transcribe(_ audio: ExtractedAudio,
                    onSegments: @escaping @Sendable ([Segment]) -> Void,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws
}
```
- `WhisperFileTranscriber(modelFolder: URL)`:
  - Loads its own `WhisperKit` the same way `WhisperTranscriber.prepare` does.
  - Reads samples with `AudioProcessor.loadAudioAsFloatArray(fromPath:)`.
  - Calls `transcribe(audioArray:decodeOptions:callback:segmentCallback:)` with `DecodingOptions(language: "en", skipSpecialTokens: true, withoutTimestamps: false, chunkingStrategy: .vad)`.
  - `segmentCallback` maps to `Segment`s, with the text passed through `WhisperTranscriber.clean`; empty ones are dropped.
  - Progress is the last segment's `end / duration`.
  - The `callback` returns `false` once `Task.isCancelled`, which stops the run.
- `AppleFileTranscriber()`:
  - Uses `SpeechTranscriber(locale: en-US, preset: .transcription)` on `SpeechAnalyzer`, with `start(inputAudioFile:finishAfterFile: true)` (or the equivalent current API).
  - Each final result becomes one `Segment` from `result.range` (start and end in seconds).
  - Progress is the result's end divided by the duration.
  - Calls `AssetInventory` install first, the same as `AppleTranscriber.prepare`.
- **Verify, and write down in the PR:** whether file input needs the Speech Recognition permission. If it does, add `.speech` to `TranscribeTool.permissions` and `setupSteps` in Task 7.

- [ ] **Step 1: Write the failing tests**, both integration tests like the existing ones, using a `SpeechFixture` sentence run through `AudioExtractor.extract`:
  - `whisperTinyReturnsTimedSegments`: uses `openai_whisper-tiny.en`, as in `WhisperTranscriberTests`. Checks that the joined text contains "testing", the first `start` is ≥ 0, `end` never goes backwards, and the last progress is ≥ 0.9.
  - `appleReturnsTimedSegments`: the same assertions.
  - `whisperCancelStops`: cancel the task straight after starting, and expect `CancellationError` (or a return with no further segments) within 5 s.
- [ ] **Step 2: Run** `scripts/test.sh FileTranscriberTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the three files.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcribe): whole-file transcription with timestamps for Whisper and Apple`

---

### Task 6: The queue (with cleanup and notifications)

**Files:**
- Create:
  - `Sidekick/Tools/Transcribe/TranscribeQueue.swift`
  - `Sidekick/Tools/Transcribe/TranscriptCleaner.swift`
  - `Sidekick/Tools/Transcribe/TranscribeNotifier.swift`
- Test: `SidekickTests/Transcribe/TranscribeQueueTests.swift`, `SidekickTests/Transcribe/TranscriptCleanerTests.swift`

**Interfaces:**
- Consumes:
  - `TranscriptStore` and `Transcript` (Task 2)
  - `TranscriptFormatter.paragraphs` (Task 3)
  - `AudioExtractor` and `ExtractError` (Task 4)
  - `FileTranscriber` (Task 5)
  - `SpeechEngines.whisperBusy` (Task 1)
- Produces:
  - `struct TranscriptCleaner { init(client: LanguageModelClient); func clean(_ paragraphs: [Paragraph], onProgress: @Sendable (Double) -> Void) async -> [Paragraph] }`:
    - Each paragraph goes through `FoundationPolisher(client:, totalBudget: .seconds(86_400)).polish(text)`, which keeps the per-chunk timeout and `PolishGuard`.
    - Starts are kept.
    - Returns the input unchanged if `!client.isAvailable` or the task is cancelled. Paragraphs done before the cancel are thrown away.
  - `protocol TranscribeNotifier: Sendable { func requestPermissionIfNeeded() async; func finished(title: String); func failed(title: String) }`, plus `UserNotificationsNotifier` (UNUserNotificationCenter) and `SilentNotifier` for tests.
  - `@MainActor @Observable final class TranscribeQueue`:
    - `init(store: TranscriptStore, engines: SpeechEngines, defaults: UserDefaults, notifier: TranscribeNotifier, cleanerClient: LanguageModelClient, makeTranscriber: @escaping (TranscriberKind, URL?) -> FileTranscriber)`
    - `private(set) var progress: [UUID: Double]` (UI only, not saved)
    - `private(set) var rejected: [(name: String, reason: String)]` (the last drop's rejections, for the UI)
    - `func enqueue(_ urls: [URL]) async`:
      - Validates each URL; rejected ones go to `rejected`.
      - Valid ones become `store.add(fileURL:wantsCleanup: defaults.bool(forKey: "transcribeCleanup"))`.
      - Asks for notification permission on the first enqueue.
      - Starts the runner.
    - `func cancel(_ t: Transcript)`: deletes the item. If it's the one running, cancels its task first.
    - `func retry(_ t: Transcript)`: clears segments, `cleanedData`, `stoppedAt` and the reason, sets `.waiting`, and sets `queuedAt = .now` so it goes to the end of the queue.
    - `func stopAll()`: the running item becomes `.incomplete` with `stoppedAt`. Waiting items become `.stopped`. If the running item was in its cleanup step, it becomes `.done` with `cleanedData = nil`.
    - `var isRunning: Bool`
  - **Runner:** handles one item at a time, oldest `.waiting` first by `queuedAt`. For each item:
    1. Mark it `.transcribing`.
    2. Extract the audio. If that fails, mark it `.failed` with the error's message and notify `failed`.
    3. Pick the engine: `TranscriberKind.effective(selected: transcribeEngine, whisperReady: engines.whisperModel.isReady)`. If that's Whisper, set `engines.whisperBusy = true` until the item ends.
    4. Transcribe, appending each segment batch to the item and saving every time.
    5. If `wantsCleanup`, clean the paragraphs.
    6. Mark it `.done` and notify `finished`.
    7. Always delete the temporary `.caf` afterwards.

- [ ] **Step 1: Write the failing tests**, using a `FakeFileTranscriber` (scripted segments, optional delay, optional throw), an in-memory store and `SilentNotifier`:
  - `runsOneAtATimeInDropOrder`
  - `sameFileTwiceMakesTwoItems`
  - `mixedDropQueuesValidAndRejectsOthers`: one `.aiff`, one folder and one `.txt` give 1 queued item and 2 rejections, both reading "This format isn't supported."
  - `segmentsSavedAsTheyArrive`: midway through a delayed fake, the store's item already has its first segments.
  - `cancelRemovesItem`, both while waiting and while running.
  - `stopAllMarksIncompleteAndStopped`: checks that `stoppedAt` equals the last segment's end.
  - `retryReplacesPartialText`
  - `missingFileFails`: delete the file after enqueue. The item ends `.failed` with "File not found."
  - `silentFileFinishesDone`: the fake returns no segments, and the status is `.done`.
  - `cleanupSettingSnapshotAtQueueTime`: queue with the setting on, then turn it off. The item still gets cleaned.
  - `stopDuringCleanupLeavesDoneUncleaned`
  - `whisperBusyOnlyWhileWhisperJobRuns`
  - `whisperRemovedFallsBackToApple`: selected is Whisper and the model isn't ready, so `makeTranscriber` is called with `.apple`.

  In `TranscriptCleanerTests`, using `FakeModel` from `PolisherTests`:
  - `cleansEachParagraphKeepingStarts`
  - `rejectedParagraphStaysRaw`
  - `unavailableModelReturnsInput`
- [ ] **Step 2: Run** `scripts/test.sh TranscribeQueueTests` and `scripts/test.sh TranscriptCleanerTests`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** both commands. Expected: PASS.
- [ ] **Step 5: Commit** `feat(transcribe): queue with partial saves, cleanup and notifications`

---

### Task 7: The tool and its pages

**Files:**
- Create:
  - `Sidekick/Tools/Transcribe/TranscribeTool.swift`
  - `Sidekick/Tools/Transcribe/Pages/TranscribeView.swift` (drop area, Choose Files…, list)
  - `Sidekick/Tools/Transcribe/Pages/TranscriptDetailView.swift`
  - `Sidekick/Tools/Transcribe/Pages/TranscribeSettingsView.swift`
- Modify: `Sidekick/App/AppEnvironment.swift` (register after `VolumeMixerTool()`), `README.md` (the Tools list)
- Test: `SidekickTests/Transcribe/TranscribeToolTests.swift`

**Interfaces:**
- Consumes: `TranscribeQueue`, `TranscriptStore`, `TranscriptFormatter.text`, `EngineSettings` (Task 1)
- Produces: `TranscribeTool` with:
  - `id "transcribe"`, `name "Transcribe"`, `symbol "text.quote"`
  - `summary "Drop audio or video files and get a transcript. Runs entirely on this Mac."`
  - `permissions []` and `setupSteps []`, unless Task 5 found that Speech Recognition is needed
  - Pages: `"transcripts"` ("Transcripts") and `"settings"` ("Settings")
  - `start()`:
    - Builds the store and queue once, with `TranscriptStore.makeContainer(in: DictationEnvironment.defaultStoreDirectory)`, and falls back to in-memory as `DictationEnvironment` does.
    - Calls `recoverAfterLaunch()` once per process.
  - `stop()` calls `queue.stopAll()`.
  - Quitting: `NSApplication.willTerminateNotification` also calls `queue.stopAll()`.
- UI:
  - **List:**
    - Rows show the title, date, duration and status. A running row shows a `ProgressBar`.
    - Waiting rows say "Waiting…". Stopped rows say "Stopped". Incomplete rows say "Incomplete (stopped at {t})".
    - Failed rows show the reason.
    - Stopped, incomplete and failed rows have Retry. Waiting and running rows have Cancel.
    - Rejections from the last drop appear as a short note above the list.
  - **Detail:**
    - Paragraphs, from `cleaned`, or else `TranscriptFormatter.paragraphs(segments)`.
    - Selectable text.
    - The `transcribeShowTimestamps` toggle.
    - Copy, which puts `TranscriptFormatter.text(...)` on `NSPasteboard.general`.
    - Export, through `NSSavePanel` with the default name `"{title}.txt"`, writing UTF-8 with the same text as Copy.
    - Rename (the title field), and Delete.
    - Incomplete transcripts show the same actions.
  - **Settings:**
    - `EngineSettings(engineKey: "transcribeEngine", defaultEngine: .whisper, models: engines.whisperModel, onChange: {})`
    - A "Clean up transcripts" toggle on `transcribeCleanup`, with the detail "Removes filler words. Applies to files you add after turning it on." It's hidden when `!SystemModelClient().isAvailable`.

- [ ] **Step 1: Write the failing tests:**
  - `toolMetadata`
  - `stopMarksQueueStopped`
  - `exportTextMatchesCopyText`: call the shared function the view uses, `TranscribeTool.exportText(for:timestamps:)`.
  - `startRecoversOnlyOnce`
- [ ] **Step 2: Run** `scripts/test.sh TranscribeToolTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the tool, the views and the registration, then add the README line: `- **Transcribe**: drop audio or video files (like lectures) and get a timestamped transcript to copy or export. Runs on-device.`
- [ ] **Step 4: Run** `scripts/test.sh`. Expected: the full suite passes.
- [ ] **Step 5: Manual check** with the `run` skill:
  1. Drop a real lecture `.mp4` and a `.mkv`. The `.mkv` is rejected, and the `.mp4` shows progress and then paragraphs.
  2. Toggle timestamps, then Copy and Export.
  3. Quit midway and relaunch. The item shows Incomplete with its text, and Retry starts over.
  4. Dictate while a Whisper job runs. Dictation works immediately.
- [ ] **Step 6: Commit** `feat(transcribe): Transcribe tool, pages and registration`
