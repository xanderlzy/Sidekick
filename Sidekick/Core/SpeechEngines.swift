import Foundation
import Observation

/// App-wide speech resources shared by every tool that transcribes (Dictation, Transcribe).
@MainActor @Observable
final class SpeechEngines {
    static let shared = SpeechEngines(defaults: .standard)

    let whisperModel: WhisperModelStore
    /// True while a long transcription holds Whisper; Dictation uses Apple's engine meanwhile.
    var whisperBusy = false {
        didSet {
            guard whisperBusy != oldValue else { return }
            busyObservers.forEach { $0(whisperBusy) }
        }
    }
    /// Dictations currently running on Whisper (from begin until finish or cancel returns).
    /// A Transcribe job waits for this to reach 0 before loading its own Whisper model.
    private(set) var whisperDictations = 0

    @ObservationIgnored private var busyObservers: [@MainActor (Bool) -> Void] = []

    init(defaults: UserDefaults = .standard) {
        whisperModel = WhisperModelStore(defaults: defaults)
    }

    /// Calls `handler` synchronously each time `whisperBusy` changes.
    func observeWhisperBusy(_ handler: @escaping @MainActor (Bool) -> Void) {
        busyObservers.append(handler)
    }

    /// Counts a Whisper dictation as running until the hold is released.
    func holdWhisperForDictation() -> EngineHold {
        whisperDictations += 1
        return EngineHold { [weak self] in self?.whisperDictations -= 1 }
    }
}

/// A claim on an engine, released exactly once (later calls do nothing).
@MainActor
final class EngineHold {
    private var onRelease: (() -> Void)?
    init(onRelease: @escaping () -> Void) { self.onRelease = onRelease }
    func release() {
        onRelease?()
        onRelease = nil
    }
}
