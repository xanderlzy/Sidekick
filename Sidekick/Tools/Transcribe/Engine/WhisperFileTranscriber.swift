import Foundation
import WhisperKit
import os

/// Whole-file Whisper transcription with timestamps. Loads its own WhisperKit for each call and
/// releases it afterwards, so it never shares memory with Dictation's instance.
struct WhisperFileTranscriber: FileTranscriber {
    let modelFolder: URL

    func transcribe(_ audio: ExtractedAudio,
                    onSegments: @escaping @Sendable ([Segment]) -> Void,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.url.path)
        try Task.checkCancellation()

        let config = WhisperKitConfig(modelFolder: modelFolder.path, verbose: false, logLevel: .error,
                                      prewarm: true, load: true, download: false)
        let kit = try await WhisperKit(config)
        try Task.checkCancellation()

        // One worker keeps VAD chunks (and so segments) in time order.
        let options = DecodingOptions(language: "en", skipSpecialTokens: true, withoutTimestamps: false,
                                      concurrentWorkerCount: 1, chunkingStrategy: .vad)
        let meter = ProgressMeter(duration: audio.duration, report: onProgress)
        let cancelled = OSAllocatedFlag()

        // In the chunked (VAD) path WhisperKit ignores the per-call segment callback and uses this
        // instance property; its timings are already shifted to absolute file time.
        kit.segmentDiscoveryCallback = { found in
            let segments = Self.segments(found.map { ($0.start, $0.end, $0.text) })
            if !segments.isEmpty { onSegments(segments) }
            if let end = found.map({ Double($0.end) }).filter(\.isFinite).max() { meter.update(seconds: end) }
        }

        // WhisperKit calls `callback` from a detached task, so Task.isCancelled is false there;
        // the cancellation handler sets a flag it can read instead.
        _ = try await withTaskCancellationHandler {
            try await kit.transcribe(
                audioArray: samples,
                decodeOptions: options,
                callback: { _ in cancelled.isSet ? false : nil })
        } onCancel: {
            cancelled.set()
        }

        // WhisperKit returns normally when the callback stops it; surface that as cancellation.
        if cancelled.isSet { throw CancellationError() }
        try Task.checkCancellation()
        onProgress(1)
    }

    /// Cleaned segments; blank text and non-finite times are dropped (a NaN can't be saved as JSON,
    /// which would lose the whole batch).
    static func segments(_ found: [(start: Float, end: Float, text: String)]) -> [Segment] {
        found.compactMap { s in
            let text = WhisperTranscriber.clean(s.text)
            guard !text.isEmpty, s.start.isFinite, s.end.isFinite else { return nil }
            return Segment(start: Double(s.start), end: Double(s.end), text: text)
        }
    }
}

final class OSAllocatedFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    func set() { state.withLock { $0 = true } }
    var isSet: Bool { state.withLock { $0 } }
}
