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
        #expect(tool.summary == "Snap windows to halves, thirds and corners with shortcuts or by dragging to the screen's edges.")
        #expect(tool.permissions == [.accessibility])
        #expect(tool.setupSteps == [.accessibility])
        #expect(tool.menuTitle == "Window Manager")
        #expect(tool.pages.map(\.id) == ["settings"])
    }

    @Test func menuHasAllActionsWithFourInCheatSheet() {
        let items = WindowManagerTool(defaults: defaults).menuItems
        #expect(items.count == 23)
        #expect(items.allSatisfy { $0.id.hasPrefix("wm.") })
        #expect(items.filter(\.inCheatSheet).map(\.id) == ["wm.leftHalf", "wm.rightHalf", "wm.topHalf", "wm.bottomHalf"])
    }

    @Test func startStopIdempotent() {
        let snap = FakeSnap()
        let tool = WindowManagerTool(defaults: defaults, snapping: snap)
        defer { tool.stop() }
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
        defer { tool.stop() }
        tool.start()
        #expect(snap.starts == 0)
        tool.setSnapping(true)
        #expect(snap.starts == 1)
    }

    @Test func accessibilityGrantedRestartsWhenRunning() {
        let snap = FakeSnap()
        let tool = WindowManagerTool(defaults: defaults, snapping: snap)
        defer { tool.stop() }
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

    @Test func systemEdgeTilingIsReadFromProvider() {
        #expect(WindowManagerTool(defaults: defaults, systemEdgeTiling: { true }).systemEdgeTilingOn)
        #expect(!WindowManagerTool(defaults: defaults, systemEdgeTiling: { false }).systemEdgeTilingOn)
    }
}

struct SystemTilingTests {
    private func suite(_ values: [String: Bool]) -> UserDefaults {
        let d = UserDefaults(suiteName: "SystemTilingTests-\(UUID())")!
        for (k, v) in values { d.set(v, forKey: k) }
        return d
    }

    @Test func missingKeysMeanOn() {
        #expect(SystemTiling.edgeTilingEnabled(suite([:])))
        #expect(SystemTiling.edgeTilingEnabled(nil))
    }

    @Test func bothOffMeansOff() {
        #expect(!SystemTiling.edgeTilingEnabled(suite([SystemTiling.edgeKey: false, SystemTiling.topEdgeKey: false])))
    }

    @Test func mixedMeansOn() {
        #expect(SystemTiling.edgeTilingEnabled(suite([SystemTiling.edgeKey: false, SystemTiling.topEdgeKey: true])))
        #expect(SystemTiling.edgeTilingEnabled(suite([SystemTiling.edgeKey: true, SystemTiling.topEdgeKey: false])))
        #expect(SystemTiling.edgeTilingEnabled(suite([SystemTiling.edgeKey: false])))
    }

    @Test func settingsURLOpensDesktopAndDock() {
        #expect(Permissions.Pane.desktopAndDock.url.absoluteString == "x-apple.systempreferences:com.apple.Desktop-Settings.extension")
    }
}
