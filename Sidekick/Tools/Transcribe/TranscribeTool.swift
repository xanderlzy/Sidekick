import AppKit
import os
import SwiftData
import SwiftUI

/// Drop audio or video files and get timestamped transcripts, made on this Mac one file at a time.
@MainActor
final class TranscribeTool: Tool {
    static let showTimestampsKey = "transcribeShowTimestamps"

    let id = "transcribe"
    let name = "Transcribe"
    let symbol = "text.quote"
    let summary = "Drop audio or video files and get a transcript. Runs entirely on this Mac."
    /// File input to SpeechAnalyzer needs no Speech Recognition authorization, and Whisper needs none.
    let permissions: [Permission] = []
    let setupSteps: [OnboardingStep] = []
    let menuItems: [ToolMenuItem] = []

    /// Built on the first `start()` and kept afterwards, so turning the tool off and on reuses them.
    private(set) var store: TranscriptStore?
    private(set) var queue: TranscribeQueue?
    let engines: SpeechEngines

    private let defaults: UserDefaults
    private let storeDirectory: URL
    private let notifier: TranscribeNotifier
    private let cleanerClient: LanguageModelClient
    private let makeTranscriber: (TranscriberKind, URL?) -> FileTranscriber
    private var terminateObserver: NSObjectProtocol?
    /// Where extraction leaves temporary audio; leftovers are cleared on the first start.
    private let tempDirectory: URL
    private let log = Logger(subsystem: "com.sidekick.app", category: "Transcribe")

    init(defaults: UserDefaults = .standard, storeDirectory: URL = DictationEnvironment.defaultStoreDirectory,
         engines: SpeechEngines = .shared, notifier: TranscribeNotifier = UserNotificationsNotifier(),
         cleanerClient: LanguageModelClient = SystemModelClient(),
         makeTranscriber: @escaping (TranscriberKind, URL?) -> FileTranscriber = TranscribeTool.liveTranscriber,
         tempDirectory: URL = FileManager.default.temporaryDirectory) {
        self.tempDirectory = tempDirectory
        self.defaults = defaults
        self.storeDirectory = storeDirectory
        self.engines = engines
        self.notifier = notifier
        self.cleanerClient = cleanerClient
        self.makeTranscriber = makeTranscriber
    }

    nonisolated static func liveTranscriber(_ kind: TranscriberKind, _ modelFolder: URL?) -> FileTranscriber {
        if kind == .whisper, let modelFolder { return WhisperFileTranscriber(modelFolder: modelFolder) }
        return AppleFileTranscriber()
    }

    var pages: [ToolPage] {
        [
            ToolPage(id: "transcripts", title: "Transcripts") { [weak self] in
                guard let self, let store, let queue else { return AnyView(EmptyView()) }
                return AnyView(TranscribeView(tool: self, store: store, queue: queue)
                    .modelContainer(store.container))
            },
            ToolPage(id: "settings", title: "Settings") { [weak self] in
                guard let self else { return AnyView(EmptyView()) }
                return AnyView(TranscribeSettingsView(engines: engines))
            },
        ]
    }

    /// Idempotent. Nothing starts transcribing here: items a quit interrupted wait for Retry.
    func start() {
        if store == nil {
            // Nothing is running yet, so any extracted audio here is from a quit or crash.
            AudioExtractor.removeLeftovers(in: tempDirectory)
            let container: ModelContainer
            do {
                container = try TranscriptStore.makeContainer(in: storeDirectory)
            } catch {
                log.error("Couldn't open Transcripts.store, keeping transcripts in memory only: \(error, privacy: .public)")
                container = try! ModelContainer(for: Transcript.self,
                                                configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            }
            let store = TranscriptStore(container: container)
            store.recoverAfterLaunch()
            self.store = store
            queue = TranscribeQueue(store: store, engines: engines, defaults: defaults, notifier: notifier,
                                    cleanerClient: cleanerClient, makeTranscriber: makeTranscriber)
        }
        if terminateObserver == nil {
            terminateObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.queue?.stopAll() }
            }
        }
    }

    /// Stops the running file (keeping its text) and everything waiting.
    func stop() {
        queue?.stopAll()
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
    }

    /// Queues files without making the caller wait for validation or the notification prompt.
    func add(_ urls: [URL]) {
        guard let queue, !urls.isEmpty else { return }
        Task { await queue.enqueue(urls) }
    }

    /// Renames, or keeps the old title when the new one is blank. Returns the title now in effect.
    @discardableResult
    func rename(_ t: Transcript, to newTitle: String) -> String {
        // The view may commit on focus loss just after the item was deleted.
        guard t.modelContext != nil, !t.isDeleted else { return newTitle }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != t.title else { return t.title }
        t.title = trimmed
        store?.save()
        return trimmed
    }

    /// Waiting and running items are cancelled (which deletes them); others are deleted outright.
    func delete(_ t: Transcript) {
        // A confirmation may outlive the item (the queue can't delete it, but the user could twice).
        guard t.modelContext != nil, !t.isDeleted else { return }
        switch t.status {
        case .waiting, .transcribing: queue?.cancel(t)
        default: store?.delete(t)
        }
    }

    /// Finished or partly finished text is worth a second thought before it's gone.
    /// Asks before removing anything with text, finished or not. Cheap: never decodes the segments.
    static func deleteNeedsConfirmation(_ t: Transcript) -> Bool {
        t.status == .done || t.status == .incomplete || hasStoredText(t)
    }

    /// True when the item holds any segments or cleaned text, judged from the stored bytes without
    /// decoding them (an empty segment list encodes as `[]`).
    static func hasStoredText(_ t: Transcript) -> Bool {
        t.cleanedData != nil || t.segmentsData.count > emptySegmentsByteCount
    }

    private static let emptySegmentsByteCount = (try? JSONEncoder().encode([Segment]()))?.count ?? 2

    static func canRetry(_ t: Transcript) -> Bool {
        [.stopped, .incomplete, .failed].contains(t.status)
    }

    static func canCancel(_ t: Transcript) -> Bool {
        t.status == .waiting || t.status == .transcribing
    }

    // MARK: - Text shared by the pages, Copy and Export

    /// Cleaned paragraphs if there are any, else paragraphs grouped from the raw segments.
    static func paragraphs(for t: Transcript) -> [Paragraph] {
        t.cleaned ?? TranscriptFormatter.paragraphs(t.segments)
    }

    /// The exact text Copy puts on the pasteboard and Export writes.
    static func exportText(for t: Transcript, timestamps: Bool) -> String {
        TranscriptFormatter.text(paragraphs(for: t), timestamps: timestamps)
    }

    /// `mm:ss`, or `h:mm:ss` from one hour, without the transcript's brackets.
    static func clock(_ seconds: Double) -> String {
        TranscriptFormatter.timestamp(seconds).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// The status line under a transcript's title; nil when it's done.
    static func statusText(for t: Transcript) -> String? {
        switch t.status {
        case .waiting: "Waiting…"
        case .transcribing: "Transcribing…"
        case .done: nil
        case .incomplete: "Incomplete (stopped at \(clock(t.stoppedAt ?? 0)))"
        case .stopped: "Stopped"
        case .failed: t.failureReason ?? "Couldn't transcribe this file."
        }
    }
}
