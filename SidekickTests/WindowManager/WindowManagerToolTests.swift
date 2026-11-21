import Foundation
import Testing
@testable import Sidekick

@MainActor
private final class FakeSnap: SnapController {
    var starts = 0, stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

@MainActor
struct WindowManagerToolTests {
    private let defaults = UserDefaults(suiteName: "WindowManagerToolTests-\(UUID())")!

    @Test func identity() {
        let tool = WindowManagerTool(defaults: defaults)
        #expect(tool.id == "windowManager")
        #expect(tool.name == "Window Manager")
        #expect(tool.permissions == [.accessibility])
        #expect(tool.setupSteps == [.accessibility])
        #expect(tool.menuTitle == "Window Manager")
        #expect(tool.pages.map(\.id) == ["settings"])
    }

    @Test func menuHasAllActionsWithFourInCheatSheet() {
        let items = WindowManagerTool(defaults: defaults).menuItems
        #expect(items.count == 23)
        #expect(items.filter(\.inCheatSheet).map(\.id) == WindowAction.allCases.filter {
            [.leftHalf, .rightHalf, .topHalf, .bottomHalf].contains($0)
        }.map(\.rawValue))
    }

    @Test func startStopIdempotent() {
        let snap = FakeSnap()
        let tool = WindowManagerTool(defaults: defaults, snapping: snap)
        tool.start(); tool.start()
        #expect(tool.isRunning)
        #expect(snap.starts == 1)
        tool.stop()
        #expect(!tool.isRunning)
        #expect(snap.stops == 1)
    }

    @Test func snapToggleOffSkipsSnapping() {
        defaults.set(false, forKey: WindowManagerTool.snapEnabledKey)
        let snap = FakeSnap()
        let tool = WindowManagerTool(defaults: defaults, snapping: snap)
        tool.start()
        #expect(snap.starts == 0)
        tool.setSnapping(true)
        #expect(snap.starts == 1)
    }

    @Test func accessibilityGrantedRestartsWhenRunning() {
        let snap = FakeSnap()
        let tool = WindowManagerTool(defaults: defaults, snapping: snap)
        tool.accessibilityGranted()
        #expect(snap.starts == 0)
        tool.start()
        tool.accessibilityGranted()
        #expect(snap.stops == 1 && snap.starts == 2)
    }

    @Test func notEnabledByDefault() {
        let sandbox = UserDefaults(suiteName: UUID().uuidString)!
        let dictation = DictationTool(defaults: sandbox, startServices: false,
                                      storeDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let registry = ToolRegistry(tools: [dictation, WindowManagerTool(defaults: sandbox)], defaults: sandbox)
        #expect(registry.enabled.map(\.id) == ["dictation"])
    }
}
