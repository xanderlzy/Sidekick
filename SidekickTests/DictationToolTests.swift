import Foundation
import Testing
@testable import Sidekick

@MainActor
struct DictationToolTests {
    let defaults: UserDefaults
    let storeDirectory: URL
    let engines: SpeechEngines

    init() {
        defaults = UserDefaults(suiteName: "DictationToolTests-\(UUID())")!
        storeDirectory = FileManager.default.temporaryDirectory.appending(path: "DictationToolTests-\(UUID())")
        engines = SpeechEngines(defaults: defaults)
    }

    func makeTool() -> DictationTool {
        DictationTool(defaults: defaults, startServices: false, storeDirectory: storeDirectory, engines: engines)
    }

    @Test func stepsDependOnHotkey() {
        defaults.set("fn", forKey: "hotkey")
        #expect(makeTool().setupSteps.contains(.globeKey))
        defaults.set("rightOption", forKey: "hotkey")
        #expect(!makeTool().setupSteps.contains(.globeKey))
        #expect(makeTool().setupSteps == [.microphone, .accessibility, .speechModel, .appleIntelligence, .practice, .tryIt])
    }

    @Test func accessibilityGrantedWithoutEnvDoesNotStart() {
        let tool = makeTool()
        tool.accessibilityGranted()
        #expect(tool.env == nil)
    }

    @Test func accessibilityGrantedWhileStoppedDoesNotStartHotkeys() {
        var calls = 0
        let tool = DictationTool(defaults: defaults, startServices: false, storeDirectory: storeDirectory, engines: engines,
                                 startHotkeys: { _ in calls += 1 })
        tool.start()
        tool.stop()
        #expect(tool.env != nil)
        tool.accessibilityGranted()
        #expect(calls == 0)
    }

    @Test func envCreatedOnlyOnStart() {
        let tool = makeTool()
        #expect(tool.env == nil)
        tool.start()
        #expect(tool.env != nil)
    }

    @Test func startIsIdempotent() {
        let tool = makeTool()
        tool.start()
        let env = tool.env
        tool.start()
        #expect(tool.env === env)
    }

    /// Runs the services that are safe in tests (pill, pruning timer); the event tap and mic stay untouched.
    @Test func stopTearsDown() throws {
        let tool = makeTool()
        tool.start()
        let env = try #require(tool.env)
        env.showPill()
        env.startPruning()
        #expect(env.pill != nil)
        #expect(env.isPruning)
        tool.stop()
        #expect(env.pill == nil)
        #expect(!env.isPruning)
        #expect(!env.hotkeys.isRunning)
    }

    @Test func metadata() {
        let tool = makeTool()
        #expect(tool.id == "dictation")
        #expect(tool.name == "Dictation")
        #expect(tool.symbol == "waveform")
        #expect(tool.permissions == [.microphone, .accessibility, .speech])
        #expect(tool.pages.map(\.id) == ["home", "history", "settings"])
        #expect(tool.menuItems.isEmpty)
    }

    @Test func historyStoreLivesInStoreDirectory() throws {
        _ = try HistoryStore.makeContainer(in: storeDirectory)
        #expect(FileManager.default.fileExists(atPath: storeDirectory.appending(path: "History.store").path))
    }

    @Test func dictationUsesAppleWhileTranscribeBusy() throws {
        let model = FileManager.default.temporaryDirectory.appending(path: "DictationToolTests-model-\(UUID())")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: model) }
        defaults.set(model.path, forKey: WhisperModelStore.pathKey)
        defaults.set(TranscriberKind.whisper.rawValue, forKey: TranscriberKind.storageKey)
        let engines = SpeechEngines(defaults: defaults)
        let env = DictationEnvironment(storeDirectory: storeDirectory, defaults: defaults, engines: engines)
        #expect(env.effectiveEngine == .whisper)
        engines.whisperBusy = true
        #expect(env.effectiveEngine == .apple)
        engines.whisperBusy = false
        #expect(env.effectiveEngine == .whisper)
    }

    private func whisperSelected() throws -> URL {
        let model = FileManager.default.temporaryDirectory.appending(path: "DictationToolTests-model-\(UUID())")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        defaults.set(model.path, forKey: WhisperModelStore.pathKey)
        defaults.set(TranscriberKind.whisper.rawValue, forKey: TranscriberKind.storageKey)
        return model
    }

    @Test func dictationReleasesAndRewarmsWhisperAroundBusyPeriod() throws {
        let model = try whisperSelected()
        defer { try? FileManager.default.removeItem(at: model) }
        let engines = SpeechEngines(defaults: defaults)
        var prepared: [Transcriber] = []
        let env = DictationEnvironment(storeDirectory: storeDirectory, defaults: defaults, engines: engines,
                                       prepareTranscriber: { prepared.append($0) })
        env.warmUpEngine()
        #expect(env.hasWhisperInstance)
        #expect(prepared.last is WhisperTranscriber)

        engines.whisperBusy = true
        #expect(!env.hasWhisperInstance)

        engines.whisperBusy = false
        #expect(env.hasWhisperInstance)
        #expect(prepared.count == 2)
        #expect(prepared.last is WhisperTranscriber)
    }

    @Test func dictationDoesNotRewarmWhisperWhenSwitchedToApple() throws {
        let model = try whisperSelected()
        defer { try? FileManager.default.removeItem(at: model) }
        let engines = SpeechEngines(defaults: defaults)
        var prepared: [Transcriber] = []
        let env = DictationEnvironment(storeDirectory: storeDirectory, defaults: defaults, engines: engines,
                                       prepareTranscriber: { prepared.append($0) })
        env.warmUpEngine()
        engines.whisperBusy = true
        defaults.set(TranscriberKind.apple.rawValue, forKey: TranscriberKind.storageKey)
        engines.whisperBusy = false
        #expect(!env.hasWhisperInstance)
        #expect(prepared.count == 1)
    }

    @Test func onlyWhisperDictationsHoldTheEngine() throws {
        let model = try whisperSelected()
        defer { try? FileManager.default.removeItem(at: model) }
        let engines = SpeechEngines(defaults: defaults)
        let env = DictationEnvironment(storeDirectory: storeDirectory, defaults: defaults, engines: engines,
                                       prepareTranscriber: { _ in })
        #expect(env.holdIfWhisper(env.appleTranscriber) == nil)
        let hold = env.holdIfWhisper(env.currentTranscriber())
        #expect(hold != nil)
        #expect(engines.whisperDictations == 1)
        hold?.release()
        hold?.release()
        #expect(engines.whisperDictations == 0)
    }
}
