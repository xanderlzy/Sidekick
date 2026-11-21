import AppKit
import KeyboardShortcuts

enum WindowAction: String, CaseIterable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case firstThird, centerThird, lastThird
    case firstTwoThirds, centerTwoThirds, lastTwoThirds
    case maximize, almostMaximize, maximizeHeight
    case larger, smaller, center, restore
    case nextDisplay, previousDisplay

    enum Group: String, CaseIterable {
        case halves = "Halves", corners = "Corners", thirds = "Thirds", size = "Size", displays = "Displays"
    }

    var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .firstThird: "First Third"
        case .centerThird: "Center Third"
        case .lastThird: "Last Third"
        case .firstTwoThirds: "First Two Thirds"
        case .centerTwoThirds: "Center Two Thirds"
        case .lastTwoThirds: "Last Two Thirds"
        case .maximize: "Maximize"
        case .almostMaximize: "Almost Maximize"
        case .maximizeHeight: "Maximize Height"
        case .larger: "Make Larger"
        case .smaller: "Make Smaller"
        case .center: "Center"
        case .restore: "Restore"
        case .nextDisplay: "Next Display"
        case .previousDisplay: "Previous Display"
        }
    }

    var group: Group {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: .halves
        case .topLeft, .topRight, .bottomLeft, .bottomRight: .corners
        case .firstThird, .centerThird, .lastThird, .firstTwoThirds, .centerTwoThirds, .lastTwoThirds: .thirds
        case .maximize, .almostMaximize, .maximizeHeight, .larger, .smaller, .center, .restore: .size
        case .nextDisplay, .previousDisplay: .displays
        }
    }

    /// Rectangle's default keys. Almost Maximize has none, as in Rectangle.
    var defaultShortcut: KeyboardShortcuts.Shortcut? {
        let co: NSEvent.ModifierFlags = [.control, .option]
        switch self {
        case .leftHalf: return .init(.leftArrow, modifiers: co)
        case .rightHalf: return .init(.rightArrow, modifiers: co)
        case .topHalf: return .init(.upArrow, modifiers: co)
        case .bottomHalf: return .init(.downArrow, modifiers: co)
        case .topLeft: return .init(.u, modifiers: co)
        case .topRight: return .init(.i, modifiers: co)
        case .bottomLeft: return .init(.j, modifiers: co)
        case .bottomRight: return .init(.k, modifiers: co)
        case .firstThird: return .init(.d, modifiers: co)
        case .centerThird: return .init(.f, modifiers: co)
        case .lastThird: return .init(.g, modifiers: co)
        case .firstTwoThirds: return .init(.e, modifiers: co)
        case .centerTwoThirds: return .init(.r, modifiers: co)
        case .lastTwoThirds: return .init(.t, modifiers: co)
        case .maximize: return .init(.return, modifiers: co)
        case .almostMaximize: return nil
        case .maximizeHeight: return .init(.upArrow, modifiers: co.union(.shift))
        case .larger: return .init(.equal, modifiers: co)
        case .smaller: return .init(.minus, modifiers: co)
        case .center: return .init(.c, modifiers: co)
        case .restore: return .init(.delete, modifiers: co)
        case .nextDisplay: return .init(.rightArrow, modifiers: co.union(.command))
        case .previousDisplay: return .init(.leftArrow, modifiers: co.union(.command))
        }
    }

    /// Each `Name` registers its default on creation, so build every one exactly once.
    private static let names: [WindowAction: KeyboardShortcuts.Name] = Dictionary(
        uniqueKeysWithValues: allCases.map {
            ($0, KeyboardShortcuts.Name("wm.\($0.rawValue)", default: $0.defaultShortcut))
        }
    )

    var shortcutName: KeyboardShortcuts.Name { Self.names[self]! }
}
