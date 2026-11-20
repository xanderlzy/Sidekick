import Testing
import CoreGraphics
@testable import Sidekick

@MainActor
final class FakeMirror: MirrorPresenting {
    var presented = 0
    var dismissed = 0
    func present() { presented += 1 }
    func dismiss() { dismissed += 1 }
}

@MainActor
struct PinControllerTests {
    func info(_ id: CGWindowID) -> WindowInfo {
        WindowInfo(id: id, pid: 1, frame: CGRect(x: 0, y: 0, width: 400, height: 300), title: "t", appName: "a")
    }

    @Test func togglePinsThenUnpins() {
        var made: [FakeMirror] = []
        let c = PinController(makeMirror: { _ in let m = FakeMirror(); made.append(m); return m })
        c.toggle(info(1))
        #expect(made[0].presented == 1)
        #expect(c.pins.count == 1)
        c.toggle(info(1))
        #expect(made[0].dismissed == 1)
        #expect(c.pins.isEmpty)
    }

    @Test func multiplePins() {
        let c = PinController(makeMirror: { _ in FakeMirror() })
        c.toggle(info(1)); c.toggle(info(2))
        #expect(c.pins.map(\.id) == [1, 2])
    }

    @Test func unpinAllDismissesEveryMirror() {
        var made: [FakeMirror] = []
        let c = PinController(makeMirror: { _ in let m = FakeMirror(); made.append(m); return m })
        c.toggle(info(1)); c.toggle(info(2))
        c.unpinAll()
        #expect(made.allSatisfy { $0.dismissed == 1 })
        #expect(c.pins.isEmpty)
    }

    @Test func unpinUnknownIsNoop() {
        let c = PinController(makeMirror: { _ in FakeMirror() })
        c.toggle(info(1))
        c.unpin(42)
        #expect(c.pins.count == 1)
    }
}
