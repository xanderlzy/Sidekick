# Transcribe: design

Date: 2026-11-26. Status: draft for approval.

## Intent
Add a **Transcribe** tool to Sidekick (after Dictation, Window Manager and Volume Mixer). The user drops audio or video files, mainly video lectures, and gets a transcript made on this Mac with the speech engines Dictation already uses. The transcript must be easy to read, easy to copy, and exportable as `.txt`. Lectures are long (45–90 minutes) and tend to pile up, so the tool queues files, shows progress, and keeps every transcript to come back to.

## Goals
- A Transcribe page in the Sidekick window with a drop area. Dropping one or many audio/video files adds them to a queue.
- Files are transcribed **one at a time**, in the order dropped. Each queued file appears straight away in the list of transcripts as "Waiting…".
- The file being transcribed shows its progress (percent or a progress bar) in the list, so a long lecture visibly isn't stuck.
- Each transcript is shown as **paragraphs, each starting with a timestamp** (`[04:12]`), the time that paragraph starts in the recording.
- A **switch hides timestamps**. Copy and `.txt` export follow what's on screen: with timestamps hidden, they give clean paragraphs.
- A **cleanup switch, off by default**, runs the Apple Intelligence cleanup from Dictation (removes leftover filler, false starts and repeats). It's hidden on Macs where Apple Intelligence isn't available.
  - **It's decided before transcribing.** It's a Transcribe setting, and each file takes the setting's value at the moment it's added to the queue. Flipping it later doesn't change files already waiting or transcripts already made. A transcript made without cleanup stays that way, unless the user transcribes the file again.
  - Cleanup runs as the last step of that file's job, a paragraph at a time, and it's included in the file's progress.
- **Copy** puts the whole transcript on the clipboard. The text is also selectable, so part of it can be copied.
- **Export** saves a `.txt` file through a save panel, named after the transcript's title by default.
- **Every transcript is kept** in a list of past transcripts. Each one can be reopened, copied, exported, renamed or deleted.
- Each transcript's title starts as the file name without its extension (`Lecture 4 - Entropy`), and can be renamed.
- **Engine:** Whisper if it's downloaded, otherwise Apple's engine. This works the same way as Dictation.
- An **engine picker** for Transcribe, **separate from Dictation's**. Changing one doesn't change the other.
- If Whisper isn't downloaded, the picker offers the same download Dictation uses. There is **one Whisper download on disk**, shared by both tools.
- A waiting or in-progress file can be **cancelled** from the list. Cancelling removes the item from the list entirely, including any text done so far.
- A **notification** when each file finishes (for example "Lecture 4 is transcribed"), and when one fails.
- Closing the Sidekick window doesn't stop the queue. Sidekick stays in the menu bar and keeps working.
- If Sidekick quits mid-queue, the in-progress file and all waiting files are marked **"Stopped"**, each with a **Retry** button. They don't restart on their own at the next launch.
- **Partial work is kept.** Text is saved as it's produced, not only at the end. If a file stops partway (quit, tool turned off, engine error), its item shows as **"Incomplete (stopped at 48:10)"**. The text done so far can be read, copied and exported like a finished transcript. **Retry transcribes the whole file again from the start** and replaces the partial text when it finishes. It doesn't resume from where it stopped.
- It follows the Sidekick tool contract (`Tool`, `ToolRegistry`), the Sidekick look (`Theme`, `Motion`), XcodeGen, swift-testing and `scripts/test.sh`.

## Non-goals
- Languages other than English. Both engines are set to English, the same as Dictation.
- Speaker names ("Professor:", "Student:").
- Jumping from a paragraph to that moment in the video, or playing the audio inside Sidekick.
- Export formats other than `.txt` (no subtitles such as `.srt`, no `.docx`).
- `.mkv`, `.webm` and other formats macOS can't read without extra software.
- Dropping files onto the menu bar icon. Possibly later.
- Transcribing several files at the same time.
- Editing the transcript text, other than renaming the title.

## Anti-goals
- Dictation getting slower, stuck, or broken because of Transcribe. In particular, a dictation must never wait behind a lecture.
- Losing a finished transcript, or the text done so far on an unfinished one. Text is saved as it's produced, and only the user deletes transcripts.
- The cleanup pass silently changing meaning. It's off by default, and its output goes through the same checks Dictation uses (`PolishGuard`).
- An hour-long job starting without the user asking, for example on relaunch.
- Anything leaving the Mac. No network use except the Whisper model download the user starts.

## Constraints
- Swift 6 strict concurrency, SwiftUI plus AppKit, macOS 26, arm64. WhisperKit is already a dependency at 1.1.x.
- **Engines.** Both are English only:
  - Whisper: `openai_whisper-small.en`, located by `WhisperModelStore`.
  - Apple: `SpeechTranscriber` / `SpeechAnalyzer` with locale en-US.
- **Whisper model ownership has to move.** Today `WhisperModelStore` lives inside `DictationEnvironment`, which only exists after Dictation is turned on. Transcribe must be able to download, find and use the model with Dictation turned off. The model store moves to something both tools can reach. The stored path key `whisperModelPath` and the folder `Application Support/Sidekick/Models` stay the same, so existing downloads keep working.
- **Dictation's engine setting stays where it is** (`transcriber` key). Transcribe gets its own key.
- **Memory.** Whisper `small.en` uses several hundred MB when loaded. Two Whisper transcriptions must never run at once.
- **Video files.** The engines need audio, so Sidekick first reads the audio track out of the file with AVFoundation (`AVAsset` / `AVAssetReader`). Anything AVFoundation can open with an audio track is accepted, which covers at least `.mp4`, `.mov`, `.m4a`, `.mp3`, `.wav`, `.aiff` and `.caf`. Anything else is rejected at drop time with "This format isn't supported." A file with no audio track gets "This file has no audio."
- **Sidekick doesn't copy the files.** It keeps the file's location and reads the file when its turn comes. If the file has moved or been deleted by then, the item shows "File not found."
- **Notifications** need the user's permission (UserNotifications). Ask the first time a file is queued, not during onboarding. If it's refused, everything still works without notifications.
- **Cleanup on long text.** `FoundationPolisher` caps a whole dictation at 15 seconds of cleanup (`totalBudget`), which is too short for a lecture. Transcribe needs to use it without that cap, a paragraph at a time, keeping the per-chunk timeout and the `PolishGuard.accept` check. If a paragraph's cleanup is rejected or times out, that paragraph stays as Whisper wrote it.

## Approaches considered
1. **Run files through Dictation's live path.** Sidekick would feed the file's audio through `Transcriber.begin/append/finish` as if it were a long dictation. Rejected: that path returns plain text with no timestamps and no progress, Whisper's version holds the whole recording in memory, and changing it risks breaking Dictation.
2. **A separate file path per engine that shares the engines. Chosen by the user.** Each engine reads a whole file through its own file API and returns text pieces with start times, plus progress:
   - Whisper: `WhisperKit.transcribe` with timestamps on and a progress callback.
   - Apple: `SpeechAnalyzer` analyzing the file, with `audioTimeRange` on its results.

   Transcribe and Dictation share the model download, the engine setup and the cleanup step, but neither depends on the other's code path.
3. **Cut files into 30-second pieces and dictate each one.** Rejected: words and sentences get cut at every boundary, which hurts accuracy, and Whisper already splits long audio more carefully on its own.

## Decided with the user
- Main use: video lectures. Transcripts must be easy to read, copy, and export as `.txt`.
- Layout: option B. Paragraphs, each with a timestamp, plus a switch to hide timestamps. Timestamps help scanning only; they don't need to link back to the video.
- Keep a list of past transcripts.
- A cleanup switch, off by default.
- Engine: Whisper if downloaded, Apple's engine otherwise, with a picker. The picker is separate from Dictation's, and the Whisper download is shared.
- Several dropped files form a queue and are transcribed one after another.
- The user confirmed these proposals:
  - Closing the window doesn't stop the queue.
  - A notification when each file finishes.
  - Quitting marks unfinished items "Stopped" with Retry, and nothing restarts on its own.
  - Files aren't copied ("File not found" if moved).
  - Waiting and in-progress items can be cancelled.
  - Titles come from the file name and can be renamed.
  - Dropping only on the Transcribe page.
  - English only.
- Build approach 2: a separate file path that shares the engines.
- **Dictation switches to Apple's engine while Transcribe is busy with Whisper.** If Dictation is set to Whisper and a Transcribe job is running on Whisper, that dictation uses Apple's engine instead of waiting. When the job finishes, Dictation goes back to Whisper. The switch is silent, with no message in the pill.
- **Cleanup is decided before transcribing**, not per transcript afterwards (see Goals).
- **Partial text is kept** when a file stops partway, and Retry starts over (see Goals).

## My calls (not discussed; open to change)
- **Cancel removes the item** from the list, including partial text. Stopped and failed items stay, with Retry.
- **Whisper's original text is always stored** next to the cleaned text when cleanup ran, even though the UI shows only the cleaned version. It costs almost nothing, and it keeps the option of showing both later.
- **Timestamp switch scope:** one remembered display setting for all transcripts, not per transcript.
- **A "Choose Files…" button** next to the drop area, opening a standard file picker, for people who'd rather not drag.
- **Transcripts are kept until deleted.** Dictation's retention setting (auto-delete after N days) doesn't apply to Transcribe.
- **Failed items** (unreadable file, engine error) show a short reason and Retry, the same as Stopped items. Any partial text is kept, as for Stopped items.
- **Turning the tool off** stops the queue the same way quitting does: the in-progress item becomes Incomplete, and waiting items become Stopped. Saved transcripts are kept.
- **Paragraph breaks:** a new paragraph starts at a pause in speech longer than about 1.5 seconds, or when a paragraph grows past about 120 words, whichever comes first. Each paragraph's timestamp is its first segment's start time. These numbers are starting points the builder can tune against a real lecture.
- **Timestamp format:** `[mm:ss]`, or `[h:mm:ss]` once a recording passes an hour.

## Left to the builder
- Where the shared Whisper model store and the "Whisper is busy" signal live, and whether Transcribe shares Dictation's loaded `WhisperKit` instance or loads its own, while keeping the memory constraint above.
- The storage model, in a separate SwiftData store such as `Transcripts.store` next to `History.store`. It needs the title, file location, date added, duration, engine used, status, timed segments, and the cleaned text when cleanup ran.
- The exact page layout (list plus detail, or one page with a settings section), following Sidekick's existing pages and `Theme`.
- Whether Apple's engine needs the Speech Recognition permission for file input. If it does, add Sidekick's existing `.speech` setup step to Transcribe.
- Whether Apple's speech assets need installing before the first file (`AppleTranscriber.prepare()` already handles that for Dictation).
- How segments are saved as they arrive (how often, and how a crash mid-save is handled), so partial text survives a quit or crash.
- Tests: paragraph building and timestamp formatting, copy/export text with and without timestamps, queue order, cancel removing the item, Stopped/Incomplete on quit, partial text kept, Retry replacing partial text, file-not-found, unsupported formats, the cleanup setting being taken when a file is queued, cleanup fallback per paragraph, and Dictation's switch to Apple while Whisper is busy.

## Open questions
None. The builder check's questions were answered by the user (see Decided with the user).
