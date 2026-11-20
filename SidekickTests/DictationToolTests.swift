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

    @Test func stopTearsDown() {
        let tool = makeTool()
        tool.start()
        tool.stop()
        #expect(tool.env?.hotkeys.isRunning == false)
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
