import AVFoundation
import Foundation
import Speech

enum AppleFileError: Error { case unavailable, assetsUnavailable }

/// Whole-file transcription with Apple's SpeechAnalyzer (English).
struct AppleFileTranscriber: FileTranscriber {
    func transcribe(_ audio: ExtractedAudio,
                    onSegments: @escaping @Sendable ([Segment]) -> Void,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try Task.checkCancellation()
        guard SpeechTranscriber.isAvailable else { throw AppleFileError.unavailable }
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: AppleTranscriber.locale)
            ?? AppleTranscriber.locale
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        } catch { throw AppleFileError.assetsUnavailable }
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.language.languageCode == locale.language.languageCode }) else {
            throw AppleFileError.assetsUnavailable
        }
        try Task.checkCancellation()

        let file = try AVAudioFile(forReading: audio.url)
        let analyzer = SpeechAnalyzer(modules: [module])
        let meter = ProgressMeter(duration: audio.duration, report: onProgress)

        try await withTaskCancellationHandler {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            for try await result in module.results where result.isFinal {
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                let start = result.range.start.seconds, end = result.range.end.seconds
                if !text.isEmpty, start.isFinite, end.isFinite {
                    onSegments([Segment(start: max(start, 0), end: max(end, start, 0), text: text)])
                }
                if end.isFinite { meter.update(seconds: end) }
            }
            // The results stream also ends when the analyzer is cancelled.
            try Task.checkCancellation()
            onProgress(1)
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
