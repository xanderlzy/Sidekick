import AppKit
import AVFoundation
import Observation
import os

protocol AudioSource: AnyObject {
    var levels: AsyncStream<Float> { get }
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws
    @discardableResult func stop() -> TimeInterval
}
extension AudioCapture: AudioSource {}

struct PolishOutcome: Equatable, Sendable {
    var text: String
    var usedModel: Bool
    var modelUnavailable: Bool
}

protocol Polishing: Sendable {
    func polish(_ raw: String) async -> PolishOutcome
}

@MainActor protocol DictationSink: AnyObject {
    func record(raw: String, final: String, duration: TimeInterval, appName: String?)
}

enum Sound: Sendable { case start, stop }
protocol SoundPlaying { func play(_ s: Sound) }

extension Notification.Name {
    static let sidekickOpenDictationSettings = Notification.Name("SidekickOpenDictationSettings")
}

/// Orchestrates one dictation: hotkey → microphone → transcriber → polisher → paste → history.
@MainActor @Observable
final class DictationController {
    private(set) var pill: PillState = .hidden
    private(set) var level: Float = 0
    private(set) var aiUnavailableNudge = false

    static let copiedMessage = "Copied — press ⌘V"
    static let emptyMessage = "Didn't catch that"
    static let micMessage = "Dictation needs microphone access"

    @ObservationIgnored private let audio: AudioSource
    @ObservationIgnored private let makeTranscriber: () -> Transcriber
    @ObservationIgnored private let polisher: Polishing
    @ObservationIgnored private let inserter: TextInserter
    @ObservationIgnored private let sink: DictationSink
    @ObservationIgnored private let sounds: SoundPlaying
    @ObservationIgnored private let frontmostAppName: () -> String?
    @ObservationIgnored private let frontmostPID: () -> Int32?
    @ObservationIgnored private let ensureMicrophone: () async -> Bool
    /// Start cue waits this long, so a shortcut (Fn+Delete) cancels before anything shows.
    @ObservationIgnored private let uiDelay: Duration
    /// A transcriber that hasn't answered by then (plus half the recording length) is abandoned.
    @ObservationIgnored private let finishTimeout: Duration
    /// Claims the engine for one dictation, if it needs claiming (Whisper, so Transcribe waits for it).
    @ObservationIgnored private let holdEngine: (Transcriber) -> EngineHold?
    /// Less voiced audio than this is treated as silence (engines hallucinate on silence).
    static let minimumVoicedSeconds = 0.15

    private struct Session {
        let id = UUID()
        let transcriber: Transcriber
        let appName: String?
        let feed: BufferFeed
        let hold: EngineHold?
    }
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var queueTail: Task<Void, Never>?

    init(audio: AudioSource, transcriber: @escaping () -> Transcriber, polisher: Polishing,
         inserter: TextInserter, sink: DictationSink, sounds: SoundPlaying,
         frontmostAppName: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.localizedName },
         frontmostPID: @escaping () -> Int32? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
         ensureMicrophone: @escaping () async -> Bool = DictationController.defaultEnsureMicrophone,
         uiDelay: Duration = .milliseconds(120), finishTimeout: Duration = .seconds(10),
         holdEngine: @escaping (Transcriber) -> EngineHold? = { _ in nil }) {
        self.audio = audio
        self.makeTranscriber = transcriber
        self.polisher = polisher
        self.inserter = inserter
        self.sink = sink
        self.sounds = sounds
        self.frontmostAppName = frontmostAppName
        self.frontmostPID = frontmostPID
        self.ensureMicrophone = ensureMicrophone
        self.uiDelay = uiDelay
        self.finishTimeout = finishTimeout
        self.holdEngine = holdEngine
        let levels = audio.levels
        Task { [weak self] in
            for await value in levels { self?.level = value }
        }
    }

    var isRecording: Bool { session != nil }

    /// Serializes hotkey actions so a quick release can't overtake a slow start.
    func enqueue(_ action: HotkeyAction) {
        let previous = queueTail
        queueTail = Task { [weak self] in
            await previous?.value
            await self?.handle(action)
        }
    }

    func handle(_ action: HotkeyAction) async {
        switch action {
        case .start: await start()
        case .lock: if session != nil { pill = .listening(locked: true) }
        case .commit: await commit()
        case .cancel: await cancel()
        }
    }

    private func start() async {
        guard session == nil else { return }
        guard await ensureMicrophone() else {
            show(Self.micMessage)
            NotificationCenter.default.post(name: .sidekickOpenDictationSettings, object: nil)
            return
        }
        let transcriber = makeTranscriber()
        let feed = BufferFeed()
        let s = Session(transcriber: transcriber, appName: frontmostAppName(), feed: feed,
                        hold: holdEngine(transcriber))
        session = s
        messageTask?.cancel()
        if uiDelay == .zero {
            showListening()
        } else {
            Task { [weak self, uiDelay] in
                try? await Task.sleep(for: uiDelay)
                guard let self, self.session?.id == s.id else { return }
                self.showListening()
            }
        }
        do {
            // Capture immediately so the first word isn't lost while the engine spins up.
            try audio.start { buffer in feed.push(buffer) }
            try await transcriber.begin()
            feed.attach(transcriber)
        } catch {
            if session?.id == s.id {
                session = nil
                audio.stop()
                await transcriber.cancel()
                s.hold?.release()
                show("Couldn't start listening")
            }
        }
    }

    private func showListening() {
        sounds.play(.start)
        if case .listening = pill { return }   // already locked hands-free
        pill = .listening(locked: false)
    }

    private func commit() async {
        guard let s = session else { return }
        session = nil
        let target = frontmostPID()
        let duration = audio.stop()
        sounds.play(.stop)
        pill = .polishing
        guard s.feed.voicedSeconds >= Self.minimumVoicedSeconds else {
            await s.transcriber.cancel()
            s.hold?.release()
            show(Self.emptyMessage); return
        }
        let transcriber = s.transcriber
        // Long hands-free takes need longer to finalize (Whisper decodes the whole take at the end).
        let limit = finishTimeout + .seconds(duration * 0.5)
        let finished = await withTimeout(limit) { try await transcriber.finish() }
        if finished == nil { await transcriber.cancel() }
        s.hold?.release()
        let raw = (finished ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { show(Self.emptyMessage); return }
        let outcome = await polisher.polish(raw)
        aiUnavailableNudge = outcome.modelUnavailable
        // If the user switched apps while we were working, don't paste into the wrong one.
        let result: InsertResult
        if frontmostPID() == target {
            result = await inserter.insert(outcome.text)
        } else {
            inserter.copy(outcome.text); result = .copiedOnly
        }
        sink.record(raw: raw, final: outcome.text, duration: duration, appName: s.appName)
        if result == .copiedOnly { show(Self.copiedMessage) } else { pill = .hidden }
    }

    private func cancel() async {
        guard let s = session else { pill = .hidden; return }
        session = nil
        audio.stop()
        await s.transcriber.cancel()
        s.hold?.release()
        pill = .hidden
    }

    private func show(_ message: String) {
        pill = .message(message)
        messageTask?.cancel()
        messageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled, let self, self.pill == .message(message) else { return }
            self.pill = .hidden
        }
    }

    nonisolated static func defaultEnsureMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            return false   // this press is spent on the prompt; the next one records
        default: return false
        }
    }
}

/// Holds microphone buffers until the transcriber is ready, then streams straight through.
final class BufferFeed: @unchecked Sendable {
    private struct State { var backlog: [AVAudioPCMBuffer] = []; var target: Transcriber?; var voiced = 0.0 }
    private let lock = OSAllocatedUnfairLock(uncheckedState: State())
    /// Level (0…1, see LevelMeter) above which a buffer counts as voice: about −40 dBFS.
    static let voiceLevel: Float = 0.2

    /// Seconds of audio loud enough to be speech.
    var voicedSeconds: Double { lock.withLockUnchecked { $0.voiced } }

    func push(_ buffer: AVAudioPCMBuffer) {
        var voiced = 0.0
        if let data = buffer.floatChannelData, buffer.format.sampleRate > 0,
           LevelMeter.level(samples: UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))) > Self.voiceLevel {
            voiced = Double(buffer.frameLength) / buffer.format.sampleRate
        }
        lock.withLockUnchecked { state in
            state.voiced += voiced
            if let target = state.target { target.append(buffer) } else { state.backlog.append(buffer) }
        }
    }

    func attach(_ transcriber: Transcriber) {
        lock.withLockUnchecked { state in
            state.backlog.forEach(transcriber.append)
            state.backlog.removeAll()
            state.target = transcriber
        }
    }
}
