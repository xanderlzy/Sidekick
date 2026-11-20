import AVFoundation
import Speech
import os

/// On-device transcription with Apple's SpeechAnalyzer + SpeechTranscriber (English).
final class AppleTranscriber: Transcriber, @unchecked Sendable {
    static let locale = Locale(identifier: "en-US")

    /// Download progress while `prepare()` installs the speech model (for onboarding UI).
    private(set) var installProgress: Progress?

    private struct Session {
        var analyzer: SpeechAnalyzer
        var input: AsyncStream<AnalyzerInput>.Continuation
        var format: AVAudioFormat
        var converter: AVAudioConverter?
        var collector: Task<String, Error>
    }
    private let lock = OSAllocatedUnfairLock<Session?>(initialState: nil)

    private func makeModule() async throws -> SpeechTranscriber {
        guard SpeechTranscriber.isAvailable else { throw TranscriberError.unavailable }
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Self.locale) ?? Self.locale
        return SpeechTranscriber(locale: locale, preset: .transcription)
    }

    func prepare() async throws {
        let module = try await makeModule()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            installProgress = request.progress
            try await request.downloadAndInstall()
        }
    }

    var isReady: Bool {
        get async {
            guard SpeechTranscriber.isAvailable else { return false }
            let installed = await SpeechTranscriber.installedLocales
            return installed.contains { $0.language.languageCode == Self.locale.language.languageCode }
        }
    }

    func begin() async throws {
        await cancel()
        let module = try await makeModule()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw TranscriberError.unavailable
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: format)
        let collector = Task<String, Error> {
            var parts: [String] = []
            for try await result in module.results where result.isFinal {
                parts.append(String(result.text.characters))
            }
            return parts.joined(separator: " ")
        }
        try await analyzer.start(inputSequence: stream)
        lock.withLock { $0 = Session(analyzer: analyzer, input: continuation, format: format, converter: nil, collector: collector) }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLockUnchecked { session in
            guard var s = session else { return }
            if s.converter == nil || s.converter?.inputFormat != buffer.format {
                s.converter = AVAudioConverter(from: buffer.format, to: s.format)
            }
            if let converted = Self.convert(buffer, with: s.converter, to: s.format) {
                s.input.yield(AnalyzerInput(buffer: converted))
            }
            session = s
        }
    }

    func finish() async throws -> String {
        guard let s = lock.withLock({ state -> Session? in defer { state = nil }; return state }) else {
            throw TranscriberError.notStarted
        }
        s.input.finish()
        try await s.analyzer.finalizeAndFinishThroughEndOfInput()
        let text = try await s.collector.value
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "  ", with: " ")
    }

    func cancel() async {
        guard let s = lock.withLock({ state -> Session? in defer { state = nil }; return state }) else { return }
        s.input.finish()
        await s.analyzer.cancelAndFinishNow()
        s.collector.cancel()
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter?,
                                to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var consumed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}
