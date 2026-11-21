import Testing
import AppKit
import KeyboardShortcuts
@testable import Sidekick

struct WindowActionTests {
    @Test func defaultsMatchRectangle() {
        let co: NSEvent.ModifierFlags = [.control, .option]
        let expected: [WindowAction: KeyboardShortcuts.Shortcut?] = [
            .leftHalf: .init(.leftArrow, modifiers: co),
            .rightHalf: .init(.rightArrow, modifiers: co),
            .topHalf: .init(.upArrow, modifiers: co),
            .bottomHalf: .init(.downArrow, modifiers: co),
            .topLeft: .init(.u, modifiers: co),
            .topRight: .init(.i, modifiers: co),
            .bottomLeft: .init(.j, modifiers: co),
            .bottomRight: .init(.k, modifiers: co),
            .firstThird: .init(.d, modifiers: co),
            .centerThird: .init(.f, modifiers: co),
            .lastThird: .init(.g, modifiers: co),
            .firstTwoThirds: .init(.e, modifiers: co),
            .centerTwoThirds: .init(.r, modifiers: co),
            .lastTwoThirds: .init(.t, modifiers: co),
            .maximize: .init(.return, modifiers: co),
            .almostMaximize: nil,
            .maximizeHeight: .init(.upArrow, modifiers: [.control, .option, .shift]),
            .larger: .init(.equal, modifiers: co),
            .smaller: .init(.minus, modifiers: co),
            .center: .init(.c, modifiers: co),
            .restore: .init(.delete, modifiers: co),
            .nextDisplay: .init(.rightArrow, modifiers: [.control, .option, .command]),
            .previousDisplay: .init(.leftArrow, modifiers: [.control, .option, .command]),
        ]
        #expect(expected.count == 23)
        for action in WindowAction.allCases {
            #expect(action.defaultShortcut == expected[action]!, "\(action)")
        }
    }

    @Test func caseCountAndDistinctDefaults() {
        #expect(WindowAction.allCases.count == 23)
        let shortcuts = WindowAction.allCases.compactMap(\.defaultShortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
    }

    @Test func groupsAndTitles() {
        #expect(WindowAction.centerTwoThirds.group == .thirds)
        #expect(WindowAction.restore.group == .size)
        #expect(WindowAction.nextDisplay.group == .displays)
        #expect(WindowAction.larger.title == "Make Larger")
        #expect(WindowAction.centerTwoThirds.title == "Center Two Thirds")
    }

    @Test func shortcutNamesStable() {
        #expect(WindowAction.leftHalf.shortcutName.rawValue == "wm.leftHalf")
        #expect(WindowAction.leftHalf.shortcutName == WindowAction.leftHalf.shortcutName)
    }
}
