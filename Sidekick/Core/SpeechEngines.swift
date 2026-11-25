import Foundation
import Observation

/// App-wide speech resources shared by every tool that transcribes (Dictation, Transcribe).
@MainActor @Observable
final class SpeechEngines {
    static let shared = SpeechEngines(defaults: .standard)

    let whisperModel: WhisperModelStore
    /// True while a long transcription holds Whisper; Dictation uses Apple's engine meanwhile.
    var whisperBusy = false

    init(defaults: UserDefaults = .standard) {
        whisperModel = WhisperModelStore(defaults: defaults)
    }
}
