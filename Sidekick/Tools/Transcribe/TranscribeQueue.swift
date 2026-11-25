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
         cleanerClient: LanguageModelClient, makeTranscriber: @escaping (TranscriberKind, URL?) -> FileTranscriber) {
        self.store = store
        self.engines = engines
        self.defaults = defaults
        self.notifier = notifier
        self.cleanerClient = cleanerClient
        self.makeTranscriber = makeTranscriber
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

    /// Clears any earlier result and puts the item at the end of the queue.
    func retry(_ t: Transcript) {
        if let job = current, job.id == t.id, !job.ended { return }
        t.segments = []
        t.cleanedData = nil
        t.stoppedAt = nil
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
                item.status = .incomplete
                item.stoppedAt = item.segments.last?.end ?? 0
            case .cleaning:
                item.status = .done
                item.cleanedData = nil
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
        runner = Task { @MainActor in
            while let next = self.nextWaiting() {
                await self.run(next)
            }
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
            fail(job, reason: (error as? ExtractError)?.message ?? ExtractError.unsupported.message)
            return
        }
        defer { try? FileManager.default.removeItem(at: audio.url) }
        guard !job.ended else { return }

        let selected = TranscriberKind(rawValue: defaults.string(forKey: Self.engineKey) ?? "") ?? .whisper
        let kind = TranscriberKind.effective(selected: selected, whisperReady: engines.whisperModel.isReady)
        item.duration = audio.duration
        item.engine = kind.rawValue
        store.save()
        let transcriber = makeTranscriber(kind, kind == .whisper ? engines.whisperModel.modelFolder : nil)
        if kind == .whisper {
            engines.whisperBusy = true
            job.holdsWhisper = true
        }

        let scale = item.wantsCleanup ? 0.9 : 1.0
        let engineError = await transcribe(job, audio: audio, with: transcriber, progressScale: scale)
        guard !job.ended else { return }
        if let engineError {
            if engineError is CancellationError { return }
            let reason = engineError.localizedDescription
            if let last = item.segments.last {
                item.status = .incomplete
                item.stoppedAt = last.end
                item.failureReason = reason
                store.save()
                notifier.failed(title: job.title)
            } else {
                fail(job, reason: reason)
            }
            return
        }

        if item.wantsCleanup, !item.segments.isEmpty, cleanerClient.isAvailable {
            job.phase = .cleaning
            let paragraphs = TranscriptFormatter.paragraphs(item.segments)
            let cleaner = TranscriptCleaner(client: cleanerClient)
            let cleaned = await cleaner.clean(paragraphs) { fraction in
                Task { @MainActor in self.report(job, 0.9 + 0.1 * fraction) }
            }
            guard !job.ended else { return }
            item.cleaned = cleaned
        }

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
                    job.item.segments += batch
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

    private func report(_ job: Job, _ fraction: Double) {
        guard current === job, !job.ended else { return }
        progress[job.id] = max(progress[job.id] ?? 0, min(fraction, 1))
    }

    private func fail(_ job: Job, reason: String) {
        job.item.status = .failed
        job.item.failureReason = reason
        store.save()
        log.error("Transcription failed: \(reason, privacy: .public)")
        notifier.failed(title: job.title)
    }
}
