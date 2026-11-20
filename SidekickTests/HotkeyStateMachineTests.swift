import Testing
@testable import Sidekick

struct HotkeyStateMachineTests {
    @Test func holdAndRelease() {
        var m = HotkeyStateMachine()
        #expect(m.handle(.down, at: 0) == [.start])
        #expect(m.isActive)
        #expect(m.handle(.up, at: 1.0) == [.commit])
        #expect(!m.isActive)
    }

    @Test func doubleTapLocks() {
        var m = HotkeyStateMachine()
        #expect(m.handle(.down, at: 0) == [.start])
        #expect(m.handle(.up, at: 0.1) == [])
        #expect(m.handle(.down, at: 0.25) == [.lock])
        #expect(m.handle(.up, at: 0.3) == [])
        #expect(m.tick(now: 2) == [])
        #expect(m.isActive)
        #expect(m.handle(.down, at: 5) == [.commit])
        #expect(m.handle(.up, at: 5.1) == [])
        #expect(!m.isActive)
    }

    @Test func singleShortTapCancelsAfterWindow() {
        var m = HotkeyStateMachine()
        _ = m.handle(.down, at: 0)
        _ = m.handle(.up, at: 0.1)
        #expect(m.tick(now: 0.2) == [])
        #expect(m.tick(now: 0.45) == [.cancel])
        #expect(!m.isActive)
    }

    @Test func secondTapTooLateIsNewHold() {
        var m = HotkeyStateMachine()
        _ = m.handle(.down, at: 0)
        _ = m.handle(.up, at: 0.1)
        #expect(m.tick(now: 0.5) == [.cancel])
        #expect(m.handle(.down, at: 0.6) == [.start])
    }

    @Test func escapeCancelsWhileHolding() {
        var m = HotkeyStateMachine()
        _ = m.handle(.down, at: 0)
        #expect(m.handle(.escape, at: 0.5) == [.cancel])
        #expect(m.handle(.up, at: 0.8) == [])
        #expect(!m.isActive)
    }

    @Test func escapeCancelsWhileLocked() {
        var m = HotkeyStateMachine()
        _ = m.handle(.down, at: 0); _ = m.handle(.up, at: 0.1)
        _ = m.handle(.down, at: 0.2); _ = m.handle(.up, at: 0.3)
        #expect(m.handle(.escape, at: 3) == [.cancel])
        #expect(!m.isActive)
    }

    @Test func escapeWhenIdleDoesNothing() {
        var m = HotkeyStateMachine()
        #expect(m.handle(.escape, at: 0) == [])
    }

    @Test func repeatedDownWhileHoldingIgnored() {
        var m = HotkeyStateMachine()
        _ = m.handle(.down, at: 0)
        #expect(m.handle(.down, at: 0.5) == [])
        #expect(m.handle(.up, at: 1) == [.commit])
    }

    @Test func otherKeyWhileHoldingCancelsQuietly() {
        var m = HotkeyStateMachine()
        #expect(m.handle(.down, at: 0) == [.start])
        #expect(m.handle(.otherKey, at: 0.05) == [.cancel])     // e.g. Fn+Delete
        #expect(m.handle(.otherKey, at: 0.1) == [])
        #expect(m.handle(.up, at: 0.6) == [])
        #expect(!m.isActive)
        #expect(m.handle(.down, at: 1) == [.start])
    }

    @Test func otherKeyDuringPendingTapCancels() {
        var m = HotkeyStateMachine()
        _ = m.handle(.down, at: 0); _ = m.handle(.up, at: 0.1)
        #expect(m.handle(.otherKey, at: 0.15) == [.cancel])
        #expect(m.tick(now: 1) == [])
        #expect(!m.isActive)
    }

    @Test func typingWhileLockedKeepsListening() {
        var m = HotkeyStateMachine()
        _ = m.handle(.down, at: 0); _ = m.handle(.up, at: 0.1)
        _ = m.handle(.down, at: 0.2); _ = m.handle(.up, at: 0.3)
        #expect(m.handle(.otherKey, at: 1) == [])
        #expect(m.isActive)
    }
}
