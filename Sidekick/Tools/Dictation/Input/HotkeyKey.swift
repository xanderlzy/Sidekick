import CoreGraphics

/// Keys Dictation can use as the dictation trigger. Modifier-only keys, so holding them
/// never types a character into the focused app.
enum HotkeyKey: String, CaseIterable, Identifiable, Sendable {
    case fn, rightOption, rightCommand, rightControl

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .fn: 63
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        }
    }

    var displayName: String {
        switch self {
        case .fn: "Fn / Globe"
        case .rightOption: "Right ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .rightControl: "Right ⌃ Control"
        }
    }

    var shortName: String {
        switch self {
        case .fn: "Fn"
        case .rightOption: "right ⌥"
        case .rightCommand: "right ⌘"
        case .rightControl: "right ⌃"
        }
    }

    /// Device-dependent masks from IOKit's NX_DEVICER*KEYMASK, which distinguish left/right.
    private static let rightAlt: UInt64 = 0x40
    private static let rightCmd: UInt64 = 0x10
    private static let rightCtl: UInt64 = 0x2000

    func isDown(flags: CGEventFlags) -> Bool {
        switch self {
        case .fn: flags.contains(.maskSecondaryFn)
        case .rightOption: flags.rawValue & Self.rightAlt != 0
        case .rightCommand: flags.rawValue & Self.rightCmd != 0
        case .rightControl: flags.rawValue & Self.rightCtl != 0
        }
    }
}
