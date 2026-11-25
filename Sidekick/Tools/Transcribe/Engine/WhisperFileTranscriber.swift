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

        _ = try await kit.transcribe(
            audioArray: samples,
            decodeOptions: options,
            callback: { _ in
                if Task.isCancelled { cancelled.set(); return false }
                return nil
            },
            segmentCallback: { found in
                let segments = found.compactMap { s -> Segment? in
                    let text = WhisperTranscriber.clean(s.text)
                    return text.isEmpty ? nil : Segment(start: Double(s.start), end: Double(s.end), text: text)
                }
                if !segments.isEmpty { onSegments(segments) }
                if let end = found.map({ Double($0.end) }).max() { meter.update(seconds: end) }
            })

        // WhisperKit returns normally when the callback stops it; surface that as cancellation.
        if cancelled.isSet { throw CancellationError() }
        try Task.checkCancellation()
        onProgress(1)
    }
}

final class OSAllocatedFlag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    func set() { state.withLock { $0 = true } }
    var isSet: Bool { state.withLock { $0 } }
}
