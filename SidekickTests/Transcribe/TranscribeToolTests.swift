import Foundation
import SwiftData
import Testing
@testable import Sidekick

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TranscribeToolTests {
    let defaults = UserDefaults(suiteName: "TranscribeToolTests-\(UUID())")!
    let storeDirectory = FileManager.default.temporaryDirectory.appending(path: "TranscribeToolTests-\(UUID())")
    /// Never the real temporary folder: other suites extract audio there in parallel.
    let tempDirectory = FileManager.default.temporaryDirectory.appending(path: "TranscribeToolTests-tmp-\(UUID())")

    func makeTool(_ transcribers: [FakeFileTranscriber] = []) -> TranscribeTool {
        let script = TranscriberScript(transcribers)
        return TranscribeTool(defaults: defaults, storeDirectory: storeDirectory,
                              engines: SpeechEngines(defaults: defaults), notifier: SilentNotifier(),
                              cleanerClient: FakeModel { $0 }, makeTranscriber: { script.make($0, $1) },
                              tempDirectory: tempDirectory)
    }

    @Test func toolMetadata() {
        let tool = makeTool()
        #expect(tool.id == "transcribe")
        #expect(tool.name == "Transcribe")
        #expect(tool.symbol == "text.quote")
        #expect(tool.summary == "Drop audio or video files and get a transcript. Runs entirely on this Mac.")
        #expect(tool.permissions.isEmpty)
        #expect(tool.setupSteps.isEmpty)
        #expect(tool.menuItems.isEmpty)
        #expect(tool.pages.map(\.id) == ["transcripts", "settings"])
        #expect(tool.pages.map(\.title) == ["Transcripts", "Settings"])
    }

    @Test func stopMarksQueueStopped() async throws {
        let gate = Gate()
        let fake = FakeFileTranscriber([[seg(0, 2, "one")], [seg(2, 5, "two")]], pauseAfter: 1, gate: gate)
        let tool = makeTool([fake])
        tool.start()
        let queue = try #require(tool.queue)
        let store = try #require(tool.store)
        await queue.enqueue([try QueueFixture.file("Running"), try QueueFixture.file("Waiting")])
        await until("first batch saved") { store.all().first { $0.title == "Running" }?.segments.count == 1 }

        tool.stop()
        let running = try #require(store.all().first { $0.title == "Running" })
        #expect(running.status == .incomplete)
        #expect(running.stoppedAt == 2)
        #expect(store.all().first { $0.title == "Waiting" }?.status == .stopped)
        await queue.waitUntilIdle()
        #expect(running.status == .incomplete)
        #expect(running.segments == [seg(0, 2, "one")])

        // Turning the tool back on keeps the same store and queue, and doesn't restart anything.
        tool.start()
        #expect(tool.queue === queue)
        #expect(tool.store === store)
        #expect(!queue.isRunning)
        tool.stop()
    }

    @Test func exportTextMatchesCopyText() throws {
        let store = TranscriptStore(container: try ModelContainer(
            for: Transcript.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let t = store.add(fileURL: URL(fileURLWithPath: "/tmp/Lecture.mp4"), wantsCleanup: false)
        t.segments = [seg(0, 2, "Hello there."), seg(5, 7, "After a pause."), seg(3700, 3702, "An hour in.")]

        let paragraphs = TranscriptFormatter.paragraphs(t.segments)
        #expect(TranscribeTool.exportText(for: t, timestamps: true)
                == TranscriptFormatter.text(paragraphs, timestamps: true))
        #expect(TranscribeTool.exportText(for: t, timestamps: true)
                == "[00:00] Hello there.\n\n[00:05] After a pause.\n\n[1:01:40] An hour in.")
        #expect(TranscribeTool.exportText(for: t, timestamps: false)
                == "Hello there.\n\nAfter a pause.\n\nAn hour in.")

        // Cleaned text wins when present.
        t.cleaned = [Paragraph(start: 0, text: "Hello there. After a pause.")]
        #expect(TranscribeTool.exportText(for: t, timestamps: true) == "[00:00] Hello there. After a pause.")
        #expect(TranscribeTool.paragraphs(for: t) == [Paragraph(start: 0, text: "Hello there. After a pause.")])

        // No speech.
        t.cleaned = nil
        t.segments = []
        #expect(TranscribeTool.exportText(for: t, timestamps: true) == "No speech found in this file.")
    }

    @Test func statusLines() throws {
        let store = TranscriptStore(container: try ModelContainer(
            for: Transcript.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let t = store.add(fileURL: URL(fileURLWithPath: "/tmp/Lecture.mp4"), wantsCleanup: false)
        #expect(TranscribeTool.statusText(for: t) == "Waiting…")
        t.status = .stopped
        #expect(TranscribeTool.statusText(for: t) == "Stopped")
        t.status = .incomplete
        t.stoppedAt = 754.9
        #expect(TranscribeTool.statusText(for: t) == "Incomplete (stopped at 12:34)")
        t.stoppedAt = 3725
        #expect(TranscribeTool.statusText(for: t) == "Incomplete (stopped at 1:02:05)")
        t.status = .failed
        t.failureReason = "File not found."
        #expect(TranscribeTool.statusText(for: t) == "File not found.")
        t.status = .done
        #expect(TranscribeTool.statusText(for: t) == nil)
    }

    @Test func renameKeepsOldTitleWhenBlank() throws {
        let tool = makeTool()
        tool.start()
        let store = try #require(tool.store)
        let t = store.add(fileURL: URL(fileURLWithPath: "/tmp/Lecture 3.mp4"), wantsCleanup: false)
        #expect(tool.rename(t, to: "   ") == "Lecture 3")
        #expect(t.title == "Lecture 3")
        #expect(tool.rename(t, to: "  Week 3: Entropy \n") == "Week 3: Entropy")
        #expect(t.title == "Week 3: Entropy")
        #expect(!t.hasChanges)
    }

    @Test func deleteRoutesByStatus() throws {
        let tool = makeTool()
        tool.start()
        let store = try #require(tool.store)
        let waiting = store.add(fileURL: URL(fileURLWithPath: "/tmp/Waiting.mp4"), wantsCleanup: false)
        let done = store.add(fileURL: URL(fileURLWithPath: "/tmp/Done.mp4"), wantsCleanup: false)
        done.status = .done
        #expect(!TranscribeTool.deleteNeedsConfirmation(waiting))
        #expect(TranscribeTool.deleteNeedsConfirmation(done))
        tool.delete(waiting)
        tool.delete(done)
        #expect(store.all().isEmpty)
    }

    @Test func confirmationCheckReadsStoredBytes() throws {
        let tool = makeTool()
        tool.start()
        let store = try #require(tool.store)
        let t = store.add(fileURL: URL(fileURLWithPath: "/tmp/Running.mp4"), wantsCleanup: false)
        // Waiting, nothing transcribed yet: Cancel removes it straight away.
        #expect(!TranscribeTool.hasStoredText(t))
        #expect(!TranscribeTool.deleteNeedsConfirmation(t))

        // Running with partial text: Cancel must ask first, just like Delete.
        t.status = .transcribing
        t.segments = [seg(0, 2, "most of an hour")]
        #expect(TranscribeTool.hasStoredText(t))
        #expect(TranscribeTool.deleteNeedsConfirmation(t))

        // Retry clears the text; cleaned text alone also counts.
        t.segments = []
        #expect(!TranscribeTool.hasStoredText(t))
        t.cleaned = [Paragraph(start: 0, text: "Cleaned.")]
        #expect(TranscribeTool.hasStoredText(t))
    }

    @Test func deleteIgnoresAlreadyRemovedItem() throws {
        let tool = makeTool()
        tool.start()
        let store = try #require(tool.store)
        let t = store.add(fileURL: URL(fileURLWithPath: "/tmp/Twice.mp4"), wantsCleanup: false)
        t.status = .done
        store.save()
        tool.delete(t)
        tool.delete(t)  // A second confirmation for the same item is a no-op.
        #expect(store.all().isEmpty)
        #expect(tool.rename(t, to: "New") == "New")
    }

    @Test func startRecoversOnlyOnce() throws {
        // An item left mid-transcription by a quit.
        do {
            let container = try TranscriptStore.makeContainer(in: storeDirectory)
            let store = TranscriptStore(container: container)
            let t = store.add(fileURL: URL(fileURLWithPath: "/tmp/Interrupted.mp4"), wantsCleanup: false)
            t.segments = [seg(0, 4, "partial")]
            t.status = .transcribing
            store.add(fileURL: URL(fileURLWithPath: "/tmp/Queued.mp4"), wantsCleanup: false)
            store.save()
        }

        let tool = makeTool()
        tool.start()
        let store = try #require(tool.store)
        let interrupted = try #require(store.all().first { $0.title == "Interrupted" })
        #expect(interrupted.status == .incomplete)
        #expect(interrupted.stoppedAt == 4)
        #expect(store.all().first { $0.title == "Queued" }?.status == .stopped)

        // A second start (tool turned off and on) must not recover again.
        let later = store.add(fileURL: URL(fileURLWithPath: "/tmp/Later.mp4"), wantsCleanup: false)
        later.status = .transcribing
        store.save()
        tool.start()
        #expect(tool.store === store)
        #expect(later.status == .transcribing)
        #expect(!(tool.queue?.isRunning ?? true))
    }

    @Test func startRemovesLeftoverAudioOnce() throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }
        let leftover = tempDirectory.appendingPathComponent("\(AudioExtractor.tempPrefix)\(UUID().uuidString).caf")
        try Data([1]).write(to: leftover)
        let tool = makeTool()
        tool.start()
        #expect(!FileManager.default.fileExists(atPath: leftover.path))

        // Turning the tool off and on must not touch a file a running job may own.
        try Data([1]).write(to: leftover)
        tool.stop()
        tool.start()
        #expect(FileManager.default.fileExists(atPath: leftover.path))
        tool.stop()
    }
}
