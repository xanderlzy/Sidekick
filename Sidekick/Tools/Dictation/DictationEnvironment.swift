import AppKit
import SwiftUI
import SwiftData

/// Builds and owns Dictation's long-lived objects.
@MainActor
final class DictationEnvironment {
    static let defaultStoreDirectory = URL.applicationSupportDirectory.appending(path: "Sidekick", directoryHint: .isDirectory)

    let audio = AudioCapture()
    let appleTranscriber = AppleTranscriber()
    let inserter = TextInserter()
    let hotkeys: HotkeyMonitor
    let controller: DictationController
    let stats: StatsStore
    let history: HistoryStore
    private var pruneTimer: Timer?
    var isPruning: Bool { pruneTimer != nil }
    private(set) var pill: PillPresenter?
    let polishClient = SystemModelClient()
    let whisperModel: WhisperModelStore
    private var whisper: WhisperTranscriber?
    /// While set (onboarding practice), hotkey actions go here instead of starting dictation.
    var hotkeyInterceptor: ((HotkeyAction) -> Void)?
    var keyStateObserver: ((Bool) -> Void)?
    var polishAvailable: Bool { polishClient.isAvailable }
    private var trustPoll: Timer?
    private let defaults: UserDefaults
    private var settingsObserver: NSObjectProtocol?
    /// True between `startAll()` and `stopAll()`.
    private(set) var isRunning = false

    init(storeDirectory: URL = DictationEnvironment.defaultStoreDirectory, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        stats = StatsStore(defaults: defaults)
        whisperModel = WhisperModelStore(defaults: defaults)
        hotkeys = HotkeyMonitor(key: HotkeyKey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .fn)
        let container = (try? HistoryStore.makeContainer(in: storeDirectory))
            ?? (try! ModelContainer(for: DictationRecord.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        history = HistoryStore(container: container, stats: stats, policy: { RetentionPolicy.current(defaults) })
        let apple = appleTranscriber
        weak var weakSelf: DictationEnvironment?
        controller = DictationController(
            audio: audio,
            transcriber: { weakSelf?.currentTranscriber() ?? apple },
            polisher: FoundationPolisher(client: polishClient),
            inserter: inserter,
            sink: history,
            sounds: SystemSounds(defaults: defaults))
        audio.deviceUID = defaults.string(forKey: "inputDeviceUID")
        let controller = controller
        hotkeys.onAction = { action in
            if let intercept = weakSelf?.hotkeyInterceptor { intercept(action) } else { controller.enqueue(action) }
        }
        hotkeys.onKeyState = { down in weakSelf?.keyStateObserver?(down) }
        weakSelf = self
    }

    /// Starts everything Dictation runs while it's on (what Parrot's launch did).
    func startAll() {
        guard !isRunning else { return }
        isRunning = true
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .sidekickOpenDictationSettings, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppEnvironment.shared.window.show(.page(tool: "dictation", page: "settings")) }
        }
        prepareSpeech()
        showPill()
        startPruning()
        startHotkeys()
    }

    /// Stops listening, removes the pill, stops timers and cancels any dictation in progress.
    /// Safe to call when nothing was started.
    func stopAll() {
        isRunning = false
        hotkeys.stop()
        trustPoll?.invalidate(); trustPoll = nil
        pruneTimer?.invalidate(); pruneTimer = nil
        // Queued after any pending start, so a press that raced the stop can't leave the mic on.
        controller.enqueue(.cancel)
        pill?.close(); pill = nil
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
    }

    var selectedEngine: TranscriberKind {
        TranscriberKind(rawValue: defaults.string(forKey: TranscriberKind.storageKey) ?? "") ?? .apple
    }

    var effectiveEngine: TranscriberKind {
        .effective(selected: selectedEngine, whisperReady: whisperModel.isReady)
    }

    func currentTranscriber() -> Transcriber {
        guard effectiveEngine == .whisper, let folder = whisperModel.modelFolder else { return appleTranscriber }
        if let whisper { return whisper }
        let w = WhisperTranscriber(modelFolder: folder)
        whisper = w
        return w
    }

    /// Loads the selected engine's model in the background so the first dictation is quick.
    func warmUpEngine() {
        if effectiveEngine != .whisper { whisper = nil }
        let t = currentTranscriber()
        Task.detached { try? await t.prepare() }
    }

    func setHotkey(_ key: HotkeyKey) {
        hotkeys.key = key
    }

    /// Applies the retention setting now and once a day.
    func startPruning() {
        history.prune()
        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.history.prune() }
        }
    }

    func showPill() { if pill == nil { pill = PillPresenter(controller: controller) } }

    /// Starts listening for the hotkey once Accessibility is granted.
    func startHotkeys() {
        if (try? hotkeys.start()) != nil { return }
        trustPoll?.invalidate()
        trustPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, (try? self.hotkeys.start()) != nil else { return }
                self.trustPoll?.invalidate()
                self.trustPoll = nil
            }
        }
    }

    func prepareSpeech() {
        let t = appleTranscriber
        Task.detached { try? await t.prepare() }
        if effectiveEngine == .whisper { warmUpEngine() }
    }
}
