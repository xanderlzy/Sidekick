import Foundation
import Testing
@testable import Sidekick

@MainActor
struct DictationToolTests {
    let defaults: UserDefaults
    let storeDirectory: URL

    init() {
        defaults = UserDefaults(suiteName: "DictationToolTests-\(UUID())")!
        storeDirectory = FileManager.default.temporaryDirectory.appending(path: "DictationToolTests-\(UUID())")
    }

    func makeTool() -> DictationTool {
        DictationTool(defaults: defaults, startServices: false, storeDirectory: storeDirectory)
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
        let tool = makeTool()
        tool.start()
        tool.stop()
        tool.accessibilityGranted()
        #expect(tool.env?.isRunning == false)
        #expect(tool.env?.trustPoll == nil)
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
}
