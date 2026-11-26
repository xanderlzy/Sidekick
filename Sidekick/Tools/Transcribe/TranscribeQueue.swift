import Foundation
import Observation
import os

/// Transcribes dropped files one at a time, oldest first, saving text as it arrives.
///
/// The queue lives on the main actor, but extraction, transcription and cleanup are nonisolated
/// async calls, so they run off it and Dictation never waits behind a lecture.
@MainActor @Observable
final class TranscribeQueue {
    static let engineKey = "transcribeEngine"
    static let cleanupKey = "transcribeCleanup"

    /// 0...1 per item while it runs; for the UI only, never saved.
    private(set) var progress: [UUID: Double] = [:]
    /// The last drop's rejected files, for the UI.
    private(set) var rejected: [(name: String, reason: String)] = []
    var isRunning: Bool { runner != nil }

    private var runner: Task<Void, Never>?

    @ObservationIgnored private let store: TranscriptStore
    @ObservationIgnored private let engines: SpeechEngines
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let notifier: TranscribeNotifier
    @ObservationIgnored private let cleanerClient: LanguageModelClient
    @ObservationIgnored private let makeTranscriber: (TranscriberKind, URL?) -> FileTranscriber
    /// Longest a Whisper job waits for a Whisper dictation already running to finish.
    @ObservationIgnored private let dictationWaitLimit: Duration
    /// Starts keeping the Mac awake (and Sidekick out of App Nap); returns the function that ends it.
    @ObservationIgnored private let holdActivity: @MainActor () -> @MainActor () -> Void
    @ObservationIgnored private var current: Job?
    @ObservationIgnored private var askedPermission = false
    @ObservationIgnored private var lastQueuedAt = Date.distantPast
    @ObservationIgnored private let log = Logger(subsystem: "com.sidekick.app", category: "Transcribe")

    /// The item being worked on. Once `ended` is set (by cancel or stop), its final state has been
    /// written and the runner must not touch the item again.
    @MainActor private final class Job {
        enum Phase { case transcribing, cleaning }
        let item: Transcript
        let id: UUID
        let title: String
        var task: Task<Void, Never>?
        var phase = Phase.transcribing
        var ended = false
        var holdsWhisper = false
        /// The item already had text when the job started: this run writes to `retrySegments`
        /// and the old text stays until the run finishes.
        var isRetry = false

        init(item: Transcript) {
            self.item = item
            id = item.id
            title = item.title
        }
    }

    private enum EngineEvent: Sendable {
        case segments([Segment])
        case progress(Double)
    }

    init(store: TranscriptStore, engines: SpeechEngines, defaults: UserDefaults, notifier: TranscribeNotifier,
         cleanerClient: LanguageModelClient, makeTranscriber: @escaping (TranscriberKind, URL?) -> FileTranscriber,
         dictationWaitLimit: Duration = .seconds(120),
         holdActivity: @escaping @MainActor () -> @MainActor () -> Void = TranscribeQueue.systemActivity) {
        self.store = store
        self.engines = engines
        self.defaults = defaults
        self.notifier = notifier
        self.cleanerClient = cleanerClient
        self.makeTranscriber = makeTranscriber
        self.dictationWaitLimit = dictationWaitLimit
        self.holdActivity = holdActivity
    }

    /// Hours of queued lectures must not be cut short by idle sleep or App Nap (Sidekick is a
    /// menu bar app, so with its window closed it's an App Nap candidate).
    static func systemActivity() -> @MainActor () -> Void {
        let token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled], reason: "Transcribing")
        return { ProcessInfo.processInfo.endActivity(token) }
    }

    // MARK: - Commands

    func enqueue(_ urls: [URL]) async {
        var rejections: [(name: String, reason: String)] = []
        var valid: [URL] = []
        for url in urls {
            if let error = await AudioExtractor.validate(url) {
                rejections.append((url.lastPathComponent, error.message))
            } else {
                valid.append(url)
            }
        }
        rejected = rejections
        guard !valid.isEmpty else { return }

        let wantsCleanup = defaults.bool(forKey: Self.cleanupKey)
        for url in valid {
            let item = store.add(fileURL: url, wantsCleanup: wantsCleanup)
            item.queuedAt = nextQueuedAt()
        }
        store.save()
        startIfIdle()

        if !askedPermission {
            askedPermission = true
            await notifier.requestPermissionIfNeeded()
        }
    }

    /// Deletes the item, stopping it first if it's the one running.
    func cancel(_ t: Transcript) {
        let id = t.id
        if let job = current, job.id == id {
            job.ended = true
            job.task?.cancel()
        }
        progress[id] = nil
        store.delete(t)
    }

    /// Puts the item at the end of the queue. Any earlier text stays until the new run finishes.
    func retry(_ t: Transcript) {
        if let job = current, job.id == t.id, !job.ended { return }
        t.failureReason = nil
        t.status = .waiting
        t.queuedAt = nextQueuedAt()
        store.save()
        startIfIdle()
    }

    /// Stops the running item (keeping its text) and everything waiting.
    func stopAll() {
        if let job = current, !job.ended {
            job.ended = true
            job.task?.cancel()
            let item = job.item
            switch job.phase {
            case .transcribing:
                endUnfinished(job, reason: nil)
            case .cleaning:
                // The text is all there; only the cleanup is dropped.
                if job.isRetry { item.commitRetry(cleaned: nil) } else { item.cleanedData = nil }
                item.status = .done
                item.stoppedAt = nil
            }
            progress[job.id] = nil
        }
        for t in store.all() where t.status == .waiting {
            t.status = .stopped
        }
        store.save()
    }

    /// Returns once nothing is queued or running.
    func waitUntilIdle() async {
        while let runner { await runner.value }
    }

    // MARK: - Runner

    private func nextQueuedAt() -> Date {
        // Strictly increasing, so items dropped together keep their order.
        let now = Date.now
        lastQueuedAt = now > lastQueuedAt ? now : lastQueuedAt.addingTimeInterval(0.001)
        return lastQueuedAt
    }

    private func startIfIdle() {
        guard runner == nil else { return }
        let endActivity = holdActivity()
        runner = Task { @MainActor in
            while let next = self.nextWaiting() {
                await self.run(next)
            }
            endActivity()
            self.runner = nil
        }
    }

    private func nextWaiting() -> Transcript? {
        store.all().filter { $0.status == .waiting }.min { $0.queuedAt < $1.queuedAt }
    }

    private func run(_ item: Transcript) async {
        let job = Job(item: item)
        current = job
        item.status = .transcribing
        store.save()
        progress[job.id] = 0

        let task = Task { @MainActor in await self.work(job) }
        job.task = task
        await task.value

        if job.holdsWhisper { engines.whisperBusy = false }
        current = nil
        progress[job.id] = nil
    }

    private func work(_ job: Job) async {
        let item = job.item
        let audio: ExtractedAudio
        do {
            audio = try await AudioExtractor.extract(item.fileURL)
        } catch {
            guard !job.ended, !(error is CancellationError) else { return }
            endUnfinished(job, reason: (error as? ExtractError)?.message ?? ExtractError.unsupported.message)
            return
        }
        defer { try? FileManager.default.removeItem(at: audio.url) }
        guard !job.ended else { return }

        let selected = TranscriberKind(rawValue: defaults.string(forKey: Self.engineKey) ?? "") ?? .whisper
        let kind = TranscriberKind.effective(selected: selected, whisperReady: engines.whisperModel.isReady)
        item.duration = audio.duration
        item.engine = kind.rawValue
        if TranscribeTool.hasStoredText(item) {
            job.isRetry = true
            item.retrySegments = []
        }
        store.save()
        if kind == .whisper {
            // New dictations switch to Apple now; one already on Whisper gets to finish first,
            // so two Whisper workloads never run at once.
            engines.whisperBusy = true
            job.holdsWhisper = true
            await waitForWhisperDictations(job)
            guard !job.ended else { return }
        }
        let transcriber = makeTranscriber(kind, kind == .whisper ? engines.whisperModel.modelFolder : nil)

        let scale = item.wantsCleanup ? 0.9 : 1.0
        let engineError = await transcribe(job, audio: audio, with: transcriber, progressScale: scale)
        guard !job.ended else { return }
        if let engineError {
            if engineError is CancellationError { return }
            endUnfinished(job, reason: engineError.localizedDescription)
            return
        }

        let runSegments = job.isRetry ? item.retrySegments ?? [] : item.segments
        var cleaned: [Paragraph]?
        if item.wantsCleanup, !runSegments.isEmpty, cleanerClient.isAvailable {
            job.phase = .cleaning
            let paragraphs = TranscriptFormatter.paragraphs(runSegments)
            let cleaner = TranscriptCleaner(client: cleanerClient)
            cleaned = await cleaner.clean(paragraphs) { fraction in
                Task { @MainActor in self.report(job, 0.9 + 0.1 * fraction) }
            }
            guard !job.ended else { return }
        }

        if job.isRetry { item.commitRetry(cleaned: cleaned) } else { item.cleaned = cleaned }
        item.stoppedAt = nil
        item.failureReason = nil
        item.status = .done
        store.save()
        notifier.finished(title: job.title)
    }

    /// Runs the engine, appending each batch to the item in arrival order. Returns the engine's error, if any,
    /// after every batch it sent has been saved.
    private func transcribe(_ job: Job, audio: ExtractedAudio, with transcriber: FileTranscriber,
                            progressScale: Double) async -> Error? {
        let (events, sink) = AsyncStream.makeStream(of: EngineEvent.self)
        let consumer = Task { @MainActor in
            for await event in events {
                guard !job.ended else { continue }
                switch event {
                case .segments(let batch):
                    if job.isRetry {
                        job.item.retrySegments = (job.item.retrySegments ?? []) + batch
                    } else {
                        job.item.segments += batch
                    }
                    store.save()
                case .progress(let fraction):
                    report(job, fraction * progressScale)
                }
            }
        }
        var engineError: Error?
        do {
            try await transcriber.transcribe(audio,
                                             onSegments: { sink.yield(.segments($0)) },
                                             onProgress: { sink.yield(.progress($0)) })
        } catch {
            engineError = error
        }
        sink.finish()
        await consumer.value
        return engineError
    }

    /// Polls until no dictation is using Whisper, the job ends, or `dictationWaitLimit` passes.
    private func waitForWhisperDictations(_ job: Job) async {
        let deadline = ContinuousClock.now + dictationWaitLimit
        while engines.whisperDictations > 0, !job.ended, !Task.isCancelled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if engines.whisperDictations > 0, !job.ended {
            log.error("A Whisper dictation is still running; starting the transcription anyway")
        }
    }

    private func report(_ job: Job, _ fraction: Double) {
        guard current === job, !job.ended else { return }
        progress[job.id] = max(progress[job.id] ?? 0, min(fraction, 1))
    }

    /// Ends a run that didn't finish. A cut-short retry keeps whichever run reaches further. With text,
    /// the item is incomplete at its last segment; without, it fails (or, when stopped, is incomplete at 0).
    /// `reason` is nil when the user stopped it.
    private func endUnfinished(_ job: Job, reason: String?) {
        let item = job.item
        item.settleRetry()
        if let last = item.segments.last {
            item.status = .incomplete
            item.stoppedAt = last.end
            item.failureReason = reason
        } else if let reason {
            item.status = .failed
            item.failureReason = reason
        } else {
            item.status = .incomplete
            item.stoppedAt = 0
        }
        store.save()
        guard let reason else { return }
        log.error("Transcription failed: \(reason, privacy: .public)")
        notifier.failed(title: job.title)
    }
}
