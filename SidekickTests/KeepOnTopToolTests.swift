import Testing
import CoreGraphics
@testable import Sidekick

@MainActor
struct KeepOnTopToolTests {
    let window = WindowInfo(id: 7, pid: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                            title: "Video", appName: "Safari")

    func makeTool(hasPermission: Bool = true, frontmost: WindowInfo? = nil,
                  requestSetup: @escaping () -> Void = {}, beep: @escaping () -> Void = {}) -> KeepOnTopTool {
        KeepOnTopTool(pins: PinController(makeMirror: { _ in FakeMirror() }),
                      hasPermission: { hasPermission }, frontmost: { frontmost },
                      requestSetup: requestSetup, beep: beep)
    }

    @Test func shortcutWithoutPermissionRequestsSetup() {
        var setups = 0
        let tool = makeTool(hasPermission: false, frontmost: window, requestSetup: { setups += 1 })
        tool.handleShortcut()
        #expect(setups == 1)
        #expect(tool.pins.pins.isEmpty)
    }

    @Test func shortcutWithNoWindowBeeps() {
        var beeps = 0
        let tool = makeTool(frontmost: nil, beep: { beeps += 1 })
        tool.handleShortcut()
        #expect(beeps == 1)
    }

    @Test func shortcutTogglesPin() {
        let tool = makeTool(frontmost: window)
        tool.handleShortcut()
        #expect(tool.pins.pins.count == 1)
        tool.handleShortcut()
        #expect(tool.pins.pins.count == 0)
    }

    @Test func stopUnpinsAll() {
        let tool = makeTool(frontmost: window)
        tool.handleShortcut()
        tool.stop()
        #expect(tool.pins.pins.isEmpty)
    }

    @Test func metadata() {
        let tool = makeTool()
        #expect(tool.id == "keepOnTop")
        #expect(tool.setupSteps == [.screenRecording])
        #expect(tool.permissions == [.screenRecording])
        #expect(tool.pages.map(\.id) == ["main"])
    }

    @Test func unpinAllMenuItemOnlyWhenPinned() {
        let tool = makeTool(frontmost: window)
        #expect(tool.menuItems.map(\.id) == ["pin"])
        tool.handleShortcut()
        #expect(tool.menuItems.map(\.id) == ["pin", "unpinAll"])
    }
}
