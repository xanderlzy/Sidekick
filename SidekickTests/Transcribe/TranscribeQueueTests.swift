import Foundation
import os
import SwiftData
import Testing
@testable import Sidekick

// MARK: - Fakes

/// Opens once; waiters poll it and throw CancellationError if their task is cancelled first.
final class Gate: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    func open() { state.withLock { $0 = true } }
    var isOpen: Bool { state.withLock { $0 } }
    func wait() async throws {
        while !isOpen { try await Task.sleep(for: .milliseconds(2)) }
    }
}

/// Scripted transcriber: sends `batches` in order, optionally pausing on `gate` after `pauseAfter`
/// batches, then optionally throws.
final class FakeFileTranscriber: FileTranscriber, Sendable {
    let batches: [[Segment]]
    let pauseAfter: Int?
    let gate: Gate?
    let error: (any Error & Sendable)?
    private let state = OSAllocatedUnfairLock(initialState: (started: false, audio: URL?.none))

    init(_ batches: [[Segment]] = [], pauseAfter: Int? = nil, gate: Gate? = nil, error: (any Error & Sendable)? = nil) {
        self.batches = batches
        self.pauseAfter = pauseAfter
        self.gate = gate
        self.error = error
    }

    var started: Bool { state.withLock { $0.started } }
    var audioURL: URL? { state.withLock { $0.audio } }

    func transcribe(_ audio: ExtractedAudio,
                    onSegments: @escaping @Sendable ([Segment]) -> Void,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws {
        state.withLock { $0 = (true, audio.url) }
        #expect(FileManager.default.fileExists(atPath: audio.url.path))
        for (i, batch) in batches.enumerated() {
            if i == pauseAfter, let gate { try await gate.wait() }
            try Task.checkCancellation()
            onSegments(batch)
            onProgress(Double(i + 1) / Double(batches.count))
        }
        if batches.count == pauseAfter, let gate { try await gate.wait() }
        try Task.checkCancellation()
        if let error { throw error }
    }
}

struct EngineFailure: Error, LocalizedError, Sendable {
    var errorDescription: String? { "The engine stopped." }
}

/// Hands out transcribers in order and records each request.
@MainActor
final class TranscriberScript {
    var queue: [FakeFileTranscriber]
    private(set) var requests: [(kind: TranscriberKind, folder: URL?)] = []
    private(set) var made: [FakeFileTranscriber] = []
    init(_ queue: [FakeFileTranscriber]) { self.queue = queue }

    func make(_ kind: TranscriberKind, _ folder: URL?) -> FileTranscriber {
        requests.append((kind, folder))
        let t = queue.isEmpty ? FakeFileTranscriber() : queue.removeFirst()
        made.append(t)
        return t
    }
}

/// Records notifications instead of posting them.
final class RecordingNotifier: TranscribeNotifier {
    private let state = OSAllocatedUnfairLock(initialState: (asks: 0, finished: [String](), failed: [String]()))
    var asks: Int { state.withLock { $0.asks } }
    var finishedTitles: [String] { state.withLock { $0.finished } }
    var failedTitles: [String] { state.withLock { $0.failed } }
    func requestPermissionIfNeeded() async { state.withLock { $0.asks += 1 } }
    func finished(title: String) { state.withLock { $0.finished.append(title) } }
    func failed(title: String) { state.withLock { $0.failed.append(title) } }
}

/// A model that signals when asked and answers only once its gate opens.
final class GatedModel: LanguageModelClient {
    let gate = Gate()
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    var callCount: Int { calls.withLock { $0 } }
    var isAvailable: Bool { true }
    func respond(instructions: String, prompt: String) async throws -> String {
        calls.withLock { $0 += 1 }
        try await gate.wait()
        return prompt.replacingOccurrences(of: "Dictated text:\n", with: "")
    }
}

/// Counts keep-awake activities begun and ended.
@MainActor
final class ActivityRecorder {
    private(set) var begun = 0
    private(set) var ended = 0
    var held: Int { begun - ended }
    func begin() -> @MainActor () -> Void {
        begun += 1
        var done = false
        return { [self] in
            guard !done else { return }
            done = true
            ended += 1
        }
    }
}

// MARK: - Fixtures

enum QueueFixture {
    /// One short synthesized clip, copied per test so files can be deleted freely.
    static let source: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-queue-fixture-\(UUID()).aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", url.path, "Hello."]
        try? p.run(); p.waitUntilExit()
        return url
    }()

    static func file(_ name: String = "Lecture") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-queue-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).aiff")
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }
}

func seg(_ start: Double, _ end: Double, _ text: String) -> Segment { Segment(start: start, end: end, text: text) }

@MainActor
struct QueueHarness {
    let store: TranscriptStore
    let engines: SpeechEngines
    let defaults: UserDefaults
    let notifier = RecordingNotifier()
    let script: TranscriberScript
    let queue: TranscribeQueue
    let modelFolder: URL?

    init(_ transcribers: [FakeFileTranscriber] = [], whisperReady: Bool = false,
         cleaner: LanguageModelClient = FakeModel { $0.replacingOccurrences(of: "Dictated text:\n", with: "") },
         dictationWaitLimit: Duration = .seconds(120), activity: ActivityRecorder = ActivityRecorder()) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        store = TranscriptStore(container: try ModelContainer(for: Transcript.self, configurations: config))
        defaults = UserDefaults(suiteName: "sidekick-queue-tests-\(UUID())")!
        if whisperReady {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-fake-model-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defaults.set(folder.path, forKey: WhisperModelStore.pathKey)
            modelFolder = folder
        } else {
            modelFolder = nil
        }
        engines = SpeechEngines(defaults: defaults)
        let script = TranscriberScript(transcribers)
        self.script = script
        queue = TranscribeQueue(store: store, engines: engines, defaults: defaults, notifier: notifier,
                                cleanerClient: cleaner, makeTranscriber: { script.make($0, $1) },
                                dictationWaitLimit: dictationWaitLimit, holdActivity: activity.begin)
    }

    func item(_ title: String) -> Transcript? { store.all().first { $0.title == title } }
}

/// Polls `condition` until it holds; fails the test after `timeout`.
@MainActor
func until(_ what: String, timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline { Issue.record("Timed out waiting for \(what)"); return }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

// MARK: - Tests

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct TranscribeQueueTests {
    @Test func runsOneAtATimeInDropOrder() async throws {
        let gates = (0..<3).map { _ in Gate() }
        let fakes = (0..<3).map { i in FakeFileTranscriber([[seg(0, 1, "job \(i)")]], pauseAfter: 0, gate: gates[i]) }
        let h = try QueueHarness(fakes)
        await h.queue.enqueue([try QueueFixture.file("A"), try QueueFixture.file("B"), try QueueFixture.file("C")])
        #expect(h.store.all().count == 3)
        for i in 0..<3 {
            await until("job \(i) to start") { fakes[i].started }
            // Only the running job has started; later ones are still waiting.
            #expect(fakes.filter(\.started).count == i + 1)
            #expect(h.store.all().filter { $0.status == .transcribing }.count == 1)
            gates[i].open()
        }
        await h.queue.waitUntilIdle()
        #expect(h.item("A")?.segments.map(\.text) == ["job 0"])
        #expect(h.item("B")?.segments.map(\.text) == ["job 1"])
        #expect(h.item("C")?.segments.map(\.text) == ["job 2"])
        #expect(h.store.all().allSatisfy { $0.status == .done })
        #expect(h.notifier.finishedTitles == ["A", "B", "C"])
        #expect(!h.queue.isRunning)
    }

    @Test func sameFileTwiceMakesTwoItems() async throws {
        let h = try QueueHarness([FakeFileTranscriber([[seg(0, 1, "one")]]), FakeFileTranscriber([[seg(0, 1, "two")]])])
        let file = try QueueFixture.file("Twice")
        await h.queue.enqueue([file, file])
        await h.queue.waitUntilIdle()
        let items = h.store.all()
        #expect(items.count == 2)
        #expect(Set(items.map(\.id)).count == 2)
        #expect(items.allSatisfy { $0.status == .done })
        #expect(h.queue.rejected.isEmpty)
    }

    @Test func mixedDropQueuesValidAndRejectsOthers() async throws {
        let h = try QueueHarness([FakeFileTranscriber([[seg(0, 1, "x")]])])
        let audio = try QueueFixture.file("Good")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-queue-folder-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-queue-\(UUID())-notes.txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        await h.queue.enqueue([audio, folder, text])
        #expect(h.store.all().count == 1)
        #expect(h.queue.rejected.count == 2)
        #expect(h.queue.rejected.map(\.name) == [folder.lastPathComponent, text.lastPathComponent])
        #expect(h.queue.rejected.allSatisfy { $0.reason == "This format isn't supported." })
        await h.queue.waitUntilIdle()

        // The next drop replaces the rejection list.
        await h.queue.enqueue([try QueueFixture.file("Also good")])
        #expect(h.queue.rejected.isEmpty)
        await h.queue.waitUntilIdle()
    }

    @Test func segmentsSavedAsTheyArrive() async throws {
        let gate = Gate()
        let fake = FakeFileTranscriber([[seg(0, 2, "first")], [seg(2, 4, "second")]], pauseAfter: 1, gate: gate)
        let h = try QueueHarness([fake])
        await h.queue.enqueue([try QueueFixture.file("Live")])
        await until("first batch saved") {
            h.item("Live").map { $0.segments.count == 1 && h.queue.progress[$0.id] == 0.5 } ?? false
        }
        let item = try #require(h.item("Live"))
        #expect(item.status == .transcribing)
        #expect(item.segments == [seg(0, 2, "first")])
        #expect(!item.hasChanges)
        #expect(h.queue.progress[item.id] == 0.5)
        gate.open()
        await h.queue.waitUntilIdle()
        #expect(item.segments == [seg(0, 2, "first"), seg(2, 4, "second")])
        #expect(item.status == .done)
        #expect(item.engine == "apple")
        #expect(item.duration > 0)
        #expect(h.queue.progress[item.id] == nil)
    }

    @Test func cancelRemovesItem() async throws {
        let gate = Gate()
        let running = FakeFileTranscriber([[seg(0, 1, "a")]], pauseAfter: 1, gate: gate)
        let h = try QueueHarness([running, FakeFileTranscriber([[seg(0, 1, "c")]])], whisperReady: true)
        await h.queue.enqueue([try QueueFixture.file("Running"), try QueueFixture.file("Waiting"), try QueueFixture.file("Next")])
        await until("first batch saved") { h.item("Running")?.segments.count == 1 }
        #expect(h.engines.whisperBusy)

        // While waiting.
        h.queue.cancel(try #require(h.item("Waiting")))
        #expect(h.item("Waiting") == nil)

        // While running.
        h.queue.cancel(try #require(h.item("Running")))
        #expect(h.item("Running") == nil)

        await h.queue.waitUntilIdle()
        #expect(h.store.all().map(\.title) == ["Next"])
        #expect(h.item("Next")?.status == .done)
        #expect(h.script.made.count == 2)
        #expect(!h.engines.whisperBusy)
        #expect(h.notifier.failedTitles.isEmpty)
        #expect(h.notifier.finishedTitles == ["Next"])
        let tempAudio = try #require(running.audioURL)
        #expect(!FileManager.default.fileExists(atPath: tempAudio.path))
    }

    @Test func stopAllMarksIncompleteAndStopped() async throws {
        let gate = Gate()
        let fake = FakeFileTranscriber([[seg(0, 2, "one")], [seg(2, 7.5, "two")], [seg(7.5, 9, "three")]],
                                       pauseAfter: 2, gate: gate)
        let h = try QueueHarness([fake], whisperReady: true)
        await h.queue.enqueue([try QueueFixture.file("Running"), try QueueFixture.file("Waiting")])
        await until("two batches saved") { h.item("Running")?.segments.count == 2 }
        h.queue.stopAll()
        let running = try #require(h.item("Running"))
        #expect(running.status == .incomplete)
        #expect(running.stoppedAt == 7.5)
        #expect(h.item("Waiting")?.status == .stopped)
        await h.queue.waitUntilIdle()
        #expect(running.status == .incomplete)
        #expect(running.stoppedAt == 7.5)
        #expect(running.segments.count == 2)
        #expect(h.item("Waiting")?.status == .stopped)
        #expect(!h.engines.whisperBusy)
        #expect(h.notifier.finishedTitles.isEmpty)
        #expect(h.notifier.failedTitles.isEmpty)
        #expect(h.script.made.count == 1)
        let tempAudio = try #require(fake.audioURL)
        #expect(!FileManager.default.fileExists(atPath: tempAudio.path))
    }

    @Test func retryReplacesPartialText() async throws {
        let gate = Gate()
        let retryGate = Gate()
        let first = FakeFileTranscriber([[seg(0, 3, "partial")]], pauseAfter: 1, gate: gate)
        let second = FakeFileTranscriber([[seg(0, 2, "fresh")], [seg(2, 5, "text")]], pauseAfter: 1, gate: retryGate)
        let h = try QueueHarness([first, second])
        await h.queue.enqueue([try QueueFixture.file("Retry")])
        await until("partial saved") { h.item("Retry")?.segments.count == 1 }
        h.queue.stopAll()
        await h.queue.waitUntilIdle()
        let item = try #require(h.item("Retry"))
        #expect(item.status == .incomplete)
        let before = item.queuedAt

        h.queue.retry(item)
        #expect(item.queuedAt > before)
        // The old text stays until the new run finishes.
        #expect(item.segments == [seg(0, 3, "partial")])
        await until("new run's first batch saved") { item.retrySegments?.count == 1 }
        #expect(item.segments == [seg(0, 3, "partial")])
        #expect(!item.hasChanges)
        retryGate.open()
        await h.queue.waitUntilIdle()
        #expect(item.segments == [seg(0, 2, "fresh"), seg(2, 5, "text")])
        #expect(item.retrySegmentsData == nil)
        #expect(item.status == .done)
        #expect(item.stoppedAt == nil)
        #expect(item.failureReason == nil)
    }

    /// Runs one job that stops with `old` saved, then returns the harness and item, ready to retry.
    private func stoppedWithText(_ old: [[Segment]], then retryRun: FakeFileTranscriber,
                                 name: String = "Again") async throws -> (QueueHarness, Transcript, URL) {
        let gate = Gate()
        let first = FakeFileTranscriber(old, pauseAfter: old.count, gate: gate)
        let h = try QueueHarness([first, retryRun])
        let file = try QueueFixture.file(name)
        await h.queue.enqueue([file])
        await until("old text saved") { h.item(name)?.segments.count == old.joined().count }
        h.queue.stopAll()
        await h.queue.waitUntilIdle()
        return (h, try #require(h.item(name)), file)
    }

    @Test func retryOfMissingFileKeepsOldText() async throws {
        let (h, item, file) = try await stoppedWithText([[seg(0, 30, "old")]], then: FakeFileTranscriber())
        try FileManager.default.removeItem(at: file)
        h.queue.retry(item)
        await h.queue.waitUntilIdle()
        #expect(item.segments == [seg(0, 30, "old")])
        #expect(item.retrySegmentsData == nil)
        #expect(item.status == .incomplete)
        #expect(item.stoppedAt == 30)
        #expect(item.failureReason == "File not found.")
        #expect(h.notifier.failedTitles == ["Again"])
    }

    @Test func retryStoppedEarlyKeepsLongerOldText() async throws {
        let gate = Gate()
        let retryRun = FakeFileTranscriber([[seg(0, 5, "new")], [seg(5, 40, "more")]], pauseAfter: 1, gate: gate)
        let (h, item, _) = try await stoppedWithText([[seg(0, 30, "old")]], then: retryRun)
        h.queue.retry(item)
        await until("new run's first batch saved") { item.retrySegments?.count == 1 }
        h.queue.stopAll()
        #expect(item.segments == [seg(0, 30, "old")])
        #expect(item.retrySegmentsData == nil)
        #expect(item.status == .incomplete)
        #expect(item.stoppedAt == 30)
        await h.queue.waitUntilIdle()
        #expect(item.segments == [seg(0, 30, "old")])
        #expect(item.retrySegmentsData == nil)
    }

    @Test func retryStoppedAfterPassingOldKeepsNewText() async throws {
        let gate = Gate()
        let retryRun = FakeFileTranscriber([[seg(0, 20, "new")], [seg(20, 45, "more")], [seg(45, 60, "end")]],
                                           pauseAfter: 2, gate: gate)
        let (h, item, _) = try await stoppedWithText([[seg(0, 30, "old")]], then: retryRun)
        h.queue.retry(item)
        await until("new run passed the old one") { item.retrySegments?.count == 2 }
        h.queue.stopAll()
        #expect(item.segments == [seg(0, 20, "new"), seg(20, 45, "more")])
        #expect(item.retrySegmentsData == nil)
        #expect(item.status == .incomplete)
        #expect(item.stoppedAt == 45)
        await h.queue.waitUntilIdle()
        #expect(item.segments == [seg(0, 20, "new"), seg(20, 45, "more")])
    }

    @Test func retryEngineErrorEarlyKeepsOldText() async throws {
        let retryRun = FakeFileTranscriber([[seg(0, 5, "new")]], error: EngineFailure())
        let (h, item, _) = try await stoppedWithText([[seg(0, 30, "old")]], then: retryRun)
        h.queue.retry(item)
        await h.queue.waitUntilIdle()
        #expect(item.segments == [seg(0, 30, "old")])
        #expect(item.retrySegmentsData == nil)
        #expect(item.status == .incomplete)
        #expect(item.stoppedAt == 30)
        #expect(item.failureReason != nil)
    }

    @Test func retryGoesToTheEndOfTheQueue() async throws {
        let gate = Gate()
        let fakes = [FakeFileTranscriber(error: EngineFailure()),
                     FakeFileTranscriber([[seg(0, 1, "b")]], pauseAfter: 0, gate: gate),
                     FakeFileTranscriber([[seg(0, 1, "c")]]),
                     FakeFileTranscriber([[seg(0, 1, "a again")]])]
        let h = try QueueHarness(fakes)
        await h.queue.enqueue([try QueueFixture.file("A"), try QueueFixture.file("B"), try QueueFixture.file("C")])
        await until("B to start") { fakes[1].started }
        let a = try #require(h.item("A"))
        #expect(a.status == .failed)
        h.queue.retry(a)
        gate.open()
        await h.queue.waitUntilIdle()
        #expect(h.item("C")?.segments.map(\.text) == ["c"])
        #expect(a.segments.map(\.text) == ["a again"])
        #expect(h.notifier.finishedTitles == ["B", "C", "A"])
    }

    @Test func missingFileFails() async throws {
        let gate = Gate()
        let h = try QueueHarness([FakeFileTranscriber([[seg(0, 1, "x")]], pauseAfter: 0, gate: gate)])
        let gone = try QueueFixture.file("Gone")
        await h.queue.enqueue([try QueueFixture.file("First"), gone])
        try FileManager.default.removeItem(at: gone)
        gate.open()
        await h.queue.waitUntilIdle()
        let item = try #require(h.item("Gone"))
        #expect(item.status == .failed)
        #expect(item.failureReason == "File not found.")
        #expect(h.notifier.failedTitles == ["Gone"])
        #expect(h.script.made.count == 1)
    }

    @Test func silentFileFinishesDone() async throws {
        let h = try QueueHarness([FakeFileTranscriber([])])
        await h.queue.enqueue([try QueueFixture.file("Quiet")])
        await h.queue.waitUntilIdle()
        let item = try #require(h.item("Quiet"))
        #expect(item.status == .done)
        #expect(item.segments.isEmpty)
        #expect(h.notifier.finishedTitles == ["Quiet"])
    }

    @Test func engineErrorWithPartialTextIsIncomplete() async throws {
        let fake = FakeFileTranscriber([[seg(0, 2, "one")], [seg(2, 4.25, "two")]], error: EngineFailure())
        let h = try QueueHarness([fake], whisperReady: true)
        await h.queue.enqueue([try QueueFixture.file("Broken")])
        await h.queue.waitUntilIdle()
        let item = try #require(h.item("Broken"))
        #expect(item.status == .incomplete)
        #expect(item.stoppedAt == 4.25)
        #expect(item.segments.count == 2)
        #expect(item.failureReason == "The engine stopped.")
        #expect(h.notifier.failedTitles == ["Broken"])
        #expect(!h.engines.whisperBusy)
        let tempAudio = try #require(fake.audioURL)
        #expect(!FileManager.default.fileExists(atPath: tempAudio.path))
    }

    @Test func engineErrorWithoutTextFails() async throws {
        let h = try QueueHarness([FakeFileTranscriber(error: EngineFailure())])
        await h.queue.enqueue([try QueueFixture.file("Broken")])
        await h.queue.waitUntilIdle()
        let item = try #require(h.item("Broken"))
        #expect(item.status == .failed)
        #expect(item.failureReason == "The engine stopped.")
        #expect(h.notifier.failedTitles == ["Broken"])
    }

    @Test func cleanupSettingSnapshotAtQueueTime() async throws {
        let gate = Gate()
        let fake = FakeFileTranscriber([[seg(0, 1, "um hello there")]], pauseAfter: 0, gate: gate)
        let cleaner = FakeModel { $0.replacingOccurrences(of: "Dictated text:\n", with: "").replacingOccurrences(of: "um ", with: "").capitalized }
        let h = try QueueHarness([fake], cleaner: cleaner)
        h.defaults.set(true, forKey: "transcribeCleanup")
        await h.queue.enqueue([try QueueFixture.file("Clean")])
        h.defaults.set(false, forKey: "transcribeCleanup")
        gate.open()
        await h.queue.waitUntilIdle()
        let item = try #require(h.item("Clean"))
        #expect(item.wantsCleanup)
        #expect(item.status == .done)
        #expect(item.cleaned == [Paragraph(start: 0, text: "Hello There")])
        #expect(item.segments == [seg(0, 1, "um hello there")])
    }

    @Test func cleanupOffLeavesCleanedEmpty() async throws {
        let h = try QueueHarness([FakeFileTranscriber([[seg(0, 1, "um hello")]])])
        await h.queue.enqueue([try QueueFixture.file("Raw")])
        await h.queue.waitUntilIdle()
        let item = try #require(h.item("Raw"))
        #expect(!item.wantsCleanup)
        #expect(item.cleaned == nil)
    }

    @Test func unavailableCleanupModelFinishesUncleaned() async throws {
        let h = try QueueHarness([FakeFileTranscriber([[seg(0, 1, "um hello")]])],
                                 cleaner: FakeModel(isAvailable: false) { _ in "Hello." })
        h.defaults.set(true, forKey: "transcribeCleanup")
        await h.queue.enqueue([try QueueFixture.file("NoModel")])
        await h.queue.waitUntilIdle()
        let item = try #require(h.item("NoModel"))
        #expect(item.status == .done)
        #expect(item.cleaned == nil)
        #expect(h.notifier.finishedTitles == ["NoModel"])
    }

    @Test func stopDuringCleanupLeavesDoneUncleaned() async throws {
        let model = GatedModel()
        let fake = FakeFileTranscriber([[seg(0, 1, "um hello there")]])
        let h = try QueueHarness([fake], cleaner: model)
        h.defaults.set(true, forKey: "transcribeCleanup")
        await h.queue.enqueue([try QueueFixture.file("Cleaning")])
        await until("cleanup to start") { model.callCount > 0 }
        let item = try #require(h.item("Cleaning"))
        #expect((h.queue.progress[item.id] ?? 0) >= 0.9)
        h.queue.stopAll()
        #expect(item.status == .done)
        #expect(item.cleaned == nil)
        model.gate.open()
        await h.queue.waitUntilIdle()
        #expect(item.status == .done)
        #expect(item.cleaned == nil)
        #expect(item.segments == [seg(0, 1, "um hello there")])
        #expect(h.notifier.finishedTitles.isEmpty)
    }

    @Test func whisperBusyOnlyWhileWhisperJobRuns() async throws {
        let gate = Gate()
        let appleGate = Gate()
        let whisperJob = FakeFileTranscriber([[seg(0, 1, "w")]], pauseAfter: 1, gate: gate)
        let appleJob = FakeFileTranscriber([[seg(0, 1, "a")]], pauseAfter: 1, gate: appleGate)
        let h = try QueueHarness([whisperJob, appleJob], whisperReady: true)
        #expect(!h.engines.whisperBusy)
        await h.queue.enqueue([try QueueFixture.file("Whisper")])
        await until("whisper job to start") { whisperJob.started }
        #expect(h.engines.whisperBusy)
        #expect(h.script.requests.first?.kind == .whisper)
        #expect(h.script.requests.first?.folder?.path == h.modelFolder?.path)
        #expect(h.item("Whisper")?.engine == "whisper")
        gate.open()
        await h.queue.waitUntilIdle()
        #expect(!h.engines.whisperBusy)

        h.defaults.set("apple", forKey: "transcribeEngine")
        await h.queue.enqueue([try QueueFixture.file("Apple")])
        await until("apple job to start") { appleJob.started }
        #expect(!h.engines.whisperBusy)
        #expect(h.script.requests.last?.kind == .apple)
        #expect(h.script.requests.last?.folder == nil)
        appleGate.open()
        await h.queue.waitUntilIdle()
        #expect(!h.engines.whisperBusy)
    }

    @Test func whisperRemovedFallsBackToApple() async throws {
        let h = try QueueHarness([FakeFileTranscriber([[seg(0, 1, "x")]])], whisperReady: false)
        h.defaults.set("whisper", forKey: "transcribeEngine")
        await h.queue.enqueue([try QueueFixture.file("Fallback")])
        await h.queue.waitUntilIdle()
        #expect(h.script.requests.count == 1)
        #expect(h.script.requests.first?.kind == .apple)
        #expect(h.script.requests.first?.folder == nil)
        #expect(h.item("Fallback")?.engine == "apple")
        #expect(!h.engines.whisperBusy)
    }

    @Test func unsetEngineDefaultsToWhisper() async throws {
        let h = try QueueHarness([FakeFileTranscriber([[seg(0, 1, "x")]])], whisperReady: true)
        await h.queue.enqueue([try QueueFixture.file("Default")])
        await h.queue.waitUntilIdle()
        #expect(h.script.requests.first?.kind == .whisper)
    }

    @Test func permissionAskedOnceOnFirstQueuedFile() async throws {
        let h = try QueueHarness()
        let text = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-queue-\(UUID()).txt")
        try "hello".write(to: text, atomically: true, encoding: .utf8)
        await h.queue.enqueue([text])
        #expect(h.notifier.asks == 0)
        await h.queue.enqueue([try QueueFixture.file("One")])
        await h.queue.enqueue([try QueueFixture.file("Two")])
        await h.queue.waitUntilIdle()
        #expect(h.notifier.asks == 1)
    }

    @Test func whisperJobWaitsForDictationInProgress() async throws {
        let fake = FakeFileTranscriber([[seg(0, 1, "x")]])
        let h = try QueueHarness([fake], whisperReady: true)
        let hold = h.engines.holdWhisperForDictation()
        await h.queue.enqueue([try QueueFixture.file("Waits")])
        // New dictations go to Apple straight away, but the job doesn't load Whisper yet.
        await until("whisper marked busy") { h.engines.whisperBusy }
        try await Task.sleep(for: .milliseconds(150))
        #expect(h.script.made.isEmpty)
        #expect(!fake.started)
        hold.release()
        await h.queue.waitUntilIdle()
        #expect(fake.started)
        #expect(h.item("Waits")?.status == .done)
        #expect(!h.engines.whisperBusy)
    }

    @Test func whisperJobWaitIsBounded() async throws {
        let fake = FakeFileTranscriber([[seg(0, 1, "x")]])
        let h = try QueueHarness([fake], whisperReady: true, dictationWaitLimit: .milliseconds(100))
        let hold = h.engines.holdWhisperForDictation()
        await h.queue.enqueue([try QueueFixture.file("Stuck dictation")])
        await h.queue.waitUntilIdle()
        #expect(fake.started)
        #expect(h.item("Stuck dictation")?.status == .done)
        hold.release()
    }

    @Test func appleJobDoesNotWaitForDictation() async throws {
        let fake = FakeFileTranscriber([[seg(0, 1, "x")]])
        let h = try QueueHarness([fake], whisperReady: false)
        let hold = h.engines.holdWhisperForDictation()
        await h.queue.enqueue([try QueueFixture.file("Apple")])
        await h.queue.waitUntilIdle()
        #expect(fake.started)
        hold.release()
    }

    @Test func stopWhileWaitingForDictationEndsTheJob() async throws {
        let fake = FakeFileTranscriber([[seg(0, 1, "x")]])
        let h = try QueueHarness([fake], whisperReady: true)
        let hold = h.engines.holdWhisperForDictation()
        await h.queue.enqueue([try QueueFixture.file("Waiting on dictation")])
        await until("whisper marked busy") { h.engines.whisperBusy }
        h.queue.stopAll()
        await h.queue.waitUntilIdle()
        #expect(!fake.started)
        #expect(h.item("Waiting on dictation")?.status == .incomplete)
        #expect(!h.engines.whisperBusy)
        hold.release()
    }

    @Test func keepsTheMacAwakeOnlyWhileRunning() async throws {
        let activity = ActivityRecorder()
        let gate = Gate()
        let h = try QueueHarness([FakeFileTranscriber([[seg(0, 1, "a")]], pauseAfter: 0, gate: gate),
                                  FakeFileTranscriber([[seg(0, 1, "b")]])], activity: activity)
        #expect(activity.held == 0)
        await h.queue.enqueue([try QueueFixture.file("A"), try QueueFixture.file("B")])
        #expect(activity.held == 1)
        gate.open()
        await h.queue.waitUntilIdle()
        // One activity for the whole run of the queue, released when it empties.
        #expect(activity.begun == 1)
        #expect(activity.held == 0)

        await h.queue.enqueue([try QueueFixture.file("C")])
        await h.queue.waitUntilIdle()
        #expect(activity.begun == 2)
        #expect(activity.held == 0)
    }

    @Test func stopReleasesTheKeepAwakeActivity() async throws {
        let activity = ActivityRecorder()
        let gate = Gate()
        let h = try QueueHarness([FakeFileTranscriber([[seg(0, 1, "a")]], pauseAfter: 1, gate: gate)], activity: activity)
        await h.queue.enqueue([try QueueFixture.file("A"), try QueueFixture.file("B")])
        await until("first batch saved") { h.item("A")?.segments.count == 1 }
        #expect(activity.held == 1)
        h.queue.stopAll()
        await h.queue.waitUntilIdle()
        #expect(activity.held == 0)
    }
}
