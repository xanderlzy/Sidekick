import Testing
import AppKit
@testable import Sidekick

struct WindowFinderTests {
    private func win(id: Int, pid: Int, layer: Int = 0, x: CGFloat = 0, y: CGFloat = 0,
                     w: CGFloat = 800, h: CGFloat = 600, title: String? = "Doc", app: String? = "App") -> [String: Any] {
        var d: [String: Any] = [
            kCGWindowNumber as String: id,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: ["X": x, "Y": y, "Width": w, "Height": h] as [String: CGFloat],
        ]
        if let title { d[kCGWindowName as String] = title }
        if let app { d[kCGWindowOwnerName as String] = app }
        return d
    }

    private func pick(_ list: [[String: Any]], front: pid_t = 10, own: pid_t = 99) -> WindowInfo? {
        WindowFinder.pick(from: list, frontmostPID: front, ownPID: own, primaryScreenHeight: 1080)
    }

    @Test func picksTopNormalWindowOfFrontmostApp() {
        let list = [win(id: 1, pid: 20), win(id: 2, pid: 10, title: "Top", app: "Safari"), win(id: 3, pid: 10)]
        let w = pick(list)
        #expect(w?.id == 2)
        #expect(w?.pid == 10)
        #expect(w?.title == "Top")
        #expect(w?.appName == "Safari")
    }

    @Test func skipsFullyTransparentWindows() {
        var invisible = win(id: 1, pid: 10)
        invisible[kCGWindowAlpha as String] = 0.0
        #expect(pick([invisible, win(id: 2, pid: 10)])?.id == 2)
    }

    @Test func skipsOwnProcess() {
        #expect(pick([win(id: 1, pid: 99)], front: 99, own: 99) == nil)
    }

    @Test func skipsNonZeroLayer() {
        let w = pick([win(id: 1, pid: 10, layer: 25), win(id: 2, pid: 10)])
        #expect(w?.id == 2)
    }

    @Test func skipsTinyWindows() {
        #expect(pick([win(id: 1, pid: 10, w: 90, h: 400)]) == nil)
    }

    @Test func nilWhenFrontmostHasNoWindow() {
        #expect(pick([win(id: 1, pid: 20)]) == nil)
    }

    @Test func convertsToAppKitCoordinates() {
        let w = pick([win(id: 1, pid: 10, x: 0, y: 0, w: 800, h: 600)])
        #expect(w?.frame == CGRect(x: 0, y: 480, width: 800, height: 600))
    }

    @Test func missingTitleAndAppNameBecomeEmpty() {
        let w = pick([win(id: 1, pid: 10, title: nil, app: nil)])
        #expect(w?.title == "")
        #expect(w?.appName == "")
    }

    @Test func acceptsCFDictionaryBounds() {
        var d = win(id: 1, pid: 10)
        d[kCGWindowBounds as String] = CGRect(x: 0, y: 0, width: 800, height: 600).dictionaryRepresentation
        #expect(pick([d])?.frame.origin.y == 480)
    }
}
