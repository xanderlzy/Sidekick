import Testing
import CoreGraphics
@testable import Sidekick

struct HotkeyKeyTests {
    @Test func fnDetectedFromSecondaryFnFlag() {
        #expect(HotkeyKey.fn.isDown(flags: .maskSecondaryFn))
        #expect(!HotkeyKey.fn.isDown(flags: []))
    }

    @Test func rightOptionNotTriggeredByLeftOption() {
        let leftAlt = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x20)
        let rightAlt = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
        #expect(!HotkeyKey.rightOption.isDown(flags: leftAlt))
        #expect(HotkeyKey.rightOption.isDown(flags: rightAlt))
    }

    @Test func rightCommandAndControlUseDeviceMasks() {
        #expect(HotkeyKey.rightCommand.isDown(flags: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)))
        #expect(!HotkeyKey.rightCommand.isDown(flags: CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)))
        #expect(HotkeyKey.rightControl.isDown(flags: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000)))
    }

    @Test func keyCodesMatch() {
        #expect(HotkeyKey.fn.keyCode == 63)
        #expect(HotkeyKey.rightOption.keyCode == 61)
        #expect(HotkeyKey.rightCommand.keyCode == 54)
        #expect(HotkeyKey.rightControl.keyCode == 62)
    }
}

struct HotkeyKeyDownTests {
    /// Releasing Globe/Fn also posts keyDown 179 (observed on hardware); it is part of the
    /// trigger, not a shortcut, so it must not cancel a double-tap.
    @Test func globeKeyDownIsNotAChord() {
        #expect(HotkeyMonitor.event(forKeyDown: 179) == nil)
        #expect(HotkeyMonitor.event(forKeyDown: 53) == .escape)
        #expect(HotkeyMonitor.event(forKeyDown: 51) == .otherKey)   // Delete
        #expect(HotkeyMonitor.event(forKeyDown: 123) == .otherKey)  // ←
    }
}
