import AVFoundation

/// Speech → raw text. One session at a time: `begin`, many `append`s, then `finish` or `cancel`.
protocol Transcriber: AnyObject, Sendable {
    /// Installs or downloads whatever the engine needs. Safe to call repeatedly.
    func prepare() async throws
    var isReady: Bool { get async }
    func begin() async throws
    /// Called from the audio thread with microphone-format buffers.
    func append(_ buffer: AVAudioPCMBuffer)
    /// Final transcript of the whole session, trimmed.
    func finish() async throws -> String
    func cancel() async
}

enum TranscriberKind: String, CaseIterable, Identifiable, Sendable {
    case apple, whisper
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .apple: "Apple (built in)"
        case .whisper: "Whisper (local download)"
        }
    }
}

enum TranscriberError: Error { case unavailable, notStarted }
