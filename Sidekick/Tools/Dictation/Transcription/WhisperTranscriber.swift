import AVFoundation
import Foundation
import Observation
import WhisperKit
import os

extension TranscriberKind {
    /// Whisper is used only once its model is on disk; until then Apple's engine stands in.
    static func effective(selected: TranscriberKind, whisperReady: Bool) -> TranscriberKind {
        selected == .whisper && !whisperReady ? .apple : selected
    }
    static let storageKey = "transcriber"
}

/// Local Whisper transcription via WhisperKit. Buffers the session's audio at 16 kHz mono and
/// transcribes it in one pass when the key is released.
final class WhisperTranscriber: Transcriber, @unchecked Sendable {
    private let modelFolder: URL
    private let pipe = OSAllocatedUnfairLock<WhisperKit?>(uncheckedState: nil)
    private let samples = OSAllocatedUnfairLock<[Float]?>(initialState: nil)

    init(modelFolder: URL) { self.modelFolder = modelFolder }

    func prepare() async throws {
        if pipe.withLockUnchecked({ $0 }) != nil { return }
        let config = WhisperKitConfig(modelFolder: modelFolder.path, verbose: false, logLevel: .error,
                                      prewarm: true, load: true, download: false)
        let kit = try await WhisperKit(config)
        pipe.withLockUnchecked { $0 = kit }
    }

    var isReady: Bool { get async { FileManager.default.fileExists(atPath: modelFolder.path) } }

    func begin() async throws {
        try await prepare()
        samples.withLock { $0 = [] }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let mono = AudioProcessor.resampleAudio(fromBuffer: buffer, toSampleRate: 16_000, channelCount: 1)
        else { return }
        let chunk = AudioProcessor.convertBufferToArray(buffer: mono)
        samples.withLock { $0?.append(contentsOf: chunk) }
    }

    func finish() async throws -> String {
        guard let audio = samples.withLock({ s -> [Float]? in defer { s = nil }; return s }) else {
            throw TranscriberError.notStarted
        }
        guard let kit = pipe.withLockUnchecked({ $0 }) else { throw TranscriberError.unavailable }
        guard audio.count > 1_600 else { return "" }   // under 0.1 s
        let options = DecodingOptions(language: "en", skipSpecialTokens: true, withoutTimestamps: true)
        let results = try await kit.transcribe(audioArray: audio, decodeOptions: options)
        return Self.clean(results.map(\.text).joined(separator: " "))
    }

    func cancel() async { samples.withLock { $0 = nil } }

    /// Removes Whisper's non-speech markers ("[BLANK_AUDIO]", "(music)", special tokens).
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>|\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

/// Downloads, locates and removes the Whisper model, and reports progress to Settings.
@MainActor @Observable
final class WhisperModelStore {
    enum State: Equatable { case notDownloaded, downloading(Double), ready, failed(String) }

    static let variant = "openai_whisper-small.en"
    static let pathKey = "whisperModelPath"
    static var baseDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Sidekick/Models", directoryHint: .isDirectory)
    }

    private(set) var state: State = .notDownloaded
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var task: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = modelFolder == nil ? .notDownloaded : .ready
    }

    var modelFolder: URL? {
        guard let path = defaults.string(forKey: Self.pathKey), FileManager.default.fileExists(atPath: path)
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    var isReady: Bool { modelFolder != nil }

    func download() {
        guard task == nil else { return }
        state = .downloading(0)
        task = Task {
            do {
                let folder = try await Self.download(variant: Self.variant, into: Self.baseDirectory) { fraction in
                    Task { @MainActor in self.state = .downloading(fraction) }
                }
                defaults.set(folder.path, forKey: Self.pathKey)
                state = .ready
            } catch {
                state = .failed("Download failed. Check your connection and try again.")
            }
            task = nil
        }
    }

    func remove() {
        if let folder = modelFolder { try? FileManager.default.removeItem(at: folder) }
        defaults.removeObject(forKey: Self.pathKey)
        state = .notDownloaded
    }

    nonisolated static func download(variant: String, into base: URL,
                                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return try await WhisperKit.download(variant: variant, downloadBase: base) { p in
            progress(p.fractionCompleted)
        }
    }
}
