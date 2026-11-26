import Testing
import AppKit
import AVFoundation
@testable import Sidekick

// MARK: - Fakes

final class FakeAudio: AudioSource {
    let levels: AsyncStream<Float>
    /// Buffers delivered as soon as capture starts.
    var buffers: [AVAudioPCMBuffer]
    init(buffers: [AVAudioPCMBuffer] = FakeAudio.speech) { levels = AsyncStream { _ in }; self.buffers = buffers }
    var started = false
    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws { started = true; buffers.forEach(onBuffer) }

    /// 0.5 s of loud tone (stands in for a voice) and 0.5 s of near-silence.
    static var speech: [AVAudioPCMBuffer] { [tone(amplitude: 0.3, seconds: 0.5)] }
    static var silence: [AVAudioPCMBuffer] { [tone(amplitude: 0.0005, seconds: 0.5)] }
    static func tone(amplitude: Float, seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames = AVAudioFrameCount(48_000 * seconds)
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        b.frameLength = frames
        for i in 0..<Int(frames) { b.floatChannelData![0][i] = amplitude * sin(Float(i) * 0.06) }
        return b
    }
    func stop() -> TimeInterval { started = false; return 2.5 }
}

final class FakeTranscriber: Transcriber, @unchecked Sendable {
    var transcript: String
    var cancelled = false
    var finishDelay: Duration = .zero
    var beginError: (any Error)?
    init(_ transcript: String) { self.transcript = transcript }
    func prepare() async throws {}
    var isReady: Bool { get async { true } }
    func begin() async throws { if let beginError { throw beginError } }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func finish() async throws -> String {
        if finishDelay > .zero { try await Task.sleep(for: finishDelay) }
        return transcript
    }
    func cancel() async { cancelled = true }
}

struct UppercasePolisher: Polishing {
    func polish(_ raw: String) async -> PolishOutcome {
        PolishOutcome(text: raw.uppercased(), usedModel: true, modelUnavailable: false)
    }
}

final class FakeSink: DictationSink {
    var records: [(raw: String, final: String, duration: TimeInterval, app: String?)] = []
    func record(raw: String, final: String, duration: TimeInterval, appName: String?) {
        records.append((raw, final, duration, appName))
    }
}

final class FakeSounds: SoundPlaying {
    var played: [Sound] = []
    func play(_ s: Sound) { played.append(s) }
}

// MARK: - Tests

@MainActor
struct DictationControllerTests {
    struct Rig {
        let controller: DictationController
        let transcriber: FakeTranscriber
        let sink: FakeSink
        let sounds: FakeSounds
        let pasted: () -> [String]
    }

    func rig(transcript: String = "hello there", canPaste: Bool = true, audio: FakeAudio = FakeAudio(),
             frontmost: @escaping () -> Int32? = { 42 }, finishTimeout: Duration = .seconds(10),
             engines: SpeechEngines? = nil) -> Rig {
        let pb = NSPasteboard(name: .init("sidekick.test.\(UUID())"))
        final class Box { var pasted: [String] = [] }
        let box = Box()
        let inserter = TextInserter(pasteboard: pb, canPaste: { canPaste },
                                    postPaste: { box.pasted.append(pb.string(forType: .string) ?? "") },
                                    restoreDelay: .zero)
        let t = FakeTranscriber(transcript)
        let sink = FakeSink(), sounds = FakeSounds()
        let c = DictationController(audio: audio, transcriber: { t }, polisher: UppercasePolisher(),
                                    inserter: inserter, sink: sink, sounds: sounds,
                                    frontmostAppName: { "TextEdit" }, frontmostPID: frontmost,
                                    ensureMicrophone: { true }, uiDelay: .zero, finishTimeout: finishTimeout,
                                    holdEngine: { _ in engines?.holdWhisperForDictation() })
        return Rig(controller: c, transcriber: t, sink: sink, sounds: sounds, pasted: { box.pasted })
    }

    @Test func holdFlowInsertsPolishedText() async {
        let r = rig()
        await r.controller.handle(.start)
        #expect(r.controller.pill == .listening(locked: false))
        await r.controller.handle(.commit)
        #expect(r.pasted() == ["HELLO THERE"])
        #expect(r.sink.records.count == 1)
        #expect(r.sink.records.first?.raw == "hello there")
        #expect(r.sink.records.first?.final == "HELLO THERE")
        #expect(r.sink.records.first?.app == "TextEdit")
        #expect(r.sounds.played == [.start, .stop])
        #expect(r.controller.pill == .hidden)
    }

    @Test func emptyTranscriptDoesNothing() async {
        let r = rig(transcript: "  ")
        await r.controller.handle(.start)
        await r.controller.handle(.commit)
        #expect(r.pasted().isEmpty)
        #expect(r.sink.records.isEmpty)
        #expect(r.controller.pill == .message("Didn't catch that"))
    }

    @Test func cancelDiscards() async {
        let r = rig()
        await r.controller.handle(.start)
        await r.controller.handle(.cancel)
        #expect(r.transcriber.cancelled)
        #expect(r.pasted().isEmpty)
        #expect(r.sink.records.isEmpty)
        #expect(r.controller.pill == .hidden)
        await r.controller.handle(.commit)   // stray commit after cancel is ignored
        #expect(r.pasted().isEmpty)
    }

    @Test func lockUpdatesPill() async {
        let r = rig()
        await r.controller.handle(.start)
        await r.controller.handle(.lock)
        #expect(r.controller.pill == .listening(locked: true))
    }

    @Test func secureInputCopiesOnly() async {
        let r = rig(canPaste: false)
        await r.controller.handle(.start)
        await r.controller.handle(.commit)
        #expect(r.pasted().isEmpty)
        #expect(r.controller.pill == .message("Copied — press ⌘V"))
        #expect(r.sink.records.count == 1)
    }

    @Test func missingMicrophoneShowsMessage() async {
        let pb = NSPasteboard(name: .init("sidekick.test.\(UUID())"))
        let t = FakeTranscriber("hi")
        let c = DictationController(audio: FakeAudio(), transcriber: { t }, polisher: UppercasePolisher(),
                                    inserter: TextInserter(pasteboard: pb, canPaste: { true }, postPaste: {}, restoreDelay: .zero),
                                    sink: FakeSink(), sounds: FakeSounds(),
                                    frontmostAppName: { nil }, ensureMicrophone: { false })
        await c.handle(.start)
        #expect(c.pill == .message("Dictation needs microphone access"))
    }

    @Test func silenceIsTreatedAsEmptyEvenIfTheEngineHallucinates() async {
        let r = rig(transcript: "Thank you.", audio: FakeAudio(buffers: FakeAudio.silence))
        await r.controller.handle(.start)
        await r.controller.handle(.commit)
        #expect(r.pasted().isEmpty)
        #expect(r.sink.records.isEmpty)
        #expect(r.controller.pill == .message("Didn't catch that"))
    }

    @Test func switchingAppsBeforePasteCopiesInstead() async {
        final class Seq { var values: [Int32] = [42, 99] }
        let seq = Seq()
        let r = rig(frontmost: { seq.values.isEmpty ? 99 : seq.values.removeFirst() })
        await r.controller.handle(.start)
        await r.controller.handle(.commit)
        #expect(r.pasted().isEmpty)
        #expect(r.controller.pill == .message("Copied — press ⌘V"))
        #expect(r.sink.records.count == 1)
    }

    @Test func hungTranscriberTimesOutAndDictationRecovers() async {
        let r = rig(finishTimeout: .milliseconds(100))
        r.transcriber.finishDelay = .seconds(30)
        let start = ContinuousClock.now
        await r.controller.handle(.start)
        await r.controller.handle(.commit)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(r.controller.pill == .message("Didn't catch that"))
        r.transcriber.finishDelay = .zero
        await r.controller.handle(.start)
        await r.controller.handle(.commit)
        #expect(r.pasted() == ["HELLO THERE"])
    }

    @Test func chordCancelBeforeUIDelayIsSilent() async {
        let pb = NSPasteboard(name: .init("sidekick.test.\(UUID())"))
        let sounds = FakeSounds()
        let c = DictationController(audio: FakeAudio(), transcriber: { FakeTranscriber("x") }, polisher: UppercasePolisher(),
                                    inserter: TextInserter(pasteboard: pb, canPaste: { true }, postPaste: {}, restoreDelay: .zero),
                                    sink: FakeSink(), sounds: sounds, frontmostAppName: { nil }, frontmostPID: { 1 },
                                    ensureMicrophone: { true }, uiDelay: .milliseconds(150))
        await c.handle(.start)
        await c.handle(.cancel)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(sounds.played.isEmpty)
        #expect(c.pill == .hidden)
    }

    // MARK: - Whisper in use (Transcribe waits for these before loading its own model)

    @Test func holdsEngineFromStartUntilFinishReturns() async {
        let engines = SpeechEngines(defaults: UserDefaults(suiteName: "ctl-\(UUID())")!)
        let r = rig(engines: engines)
        await r.controller.handle(.start)
        #expect(engines.whisperDictations == 1)
        await r.controller.handle(.commit)
        #expect(engines.whisperDictations == 0)
        #expect(r.pasted() == ["HELLO THERE"])
    }

    @Test func releasesEngineOnCancelSilenceTimeoutAndFailedStart() async {
        let engines = SpeechEngines(defaults: UserDefaults(suiteName: "ctl-\(UUID())")!)
        let r = rig(engines: engines)
        await r.controller.handle(.start)
        await r.controller.handle(.cancel)
        #expect(engines.whisperDictations == 0)

        let quiet = rig(audio: FakeAudio(buffers: FakeAudio.silence), engines: engines)
        await quiet.controller.handle(.start)
        await quiet.controller.handle(.commit)
        #expect(engines.whisperDictations == 0)

        let hung = rig(finishTimeout: .milliseconds(50), engines: engines)
        hung.transcriber.finishDelay = .seconds(30)
        await hung.controller.handle(.start)
        await hung.controller.handle(.commit)
        #expect(engines.whisperDictations == 0)

        let broken = rig(engines: engines)
        broken.transcriber.beginError = TranscriberError.unavailable
        await broken.controller.handle(.start)
        #expect(broken.controller.pill == .message("Couldn't start listening"))
        #expect(engines.whisperDictations == 0)
    }
}
