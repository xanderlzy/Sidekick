import Foundation

enum HotkeyEvent { case down, up, escape, otherKey }
enum HotkeyAction: Equatable, Sendable { case start, lock, commit, cancel }

/// Pure model of the dictation key.
/// - Hold, then release: `start` … `commit`.
/// - Quick tap then press again within `doubleTapWindow`: `start` … `lock` (hands-free);
///   the next press `commit`s.
/// - A lone quick tap expires into `cancel`. Escape cancels any active session.
/// - Another key pressed while the hotkey is held (Fn+Delete, Fn+→, right-⌘+C) is a
///   shortcut, not dictation: `cancel` quietly. Typing while locked hands-free is fine.
struct HotkeyStateMachine {
    var tapMaxDuration: TimeInterval = 0.25
    var doubleTapWindow: TimeInterval = 0.30

    private enum State: Equatable {
        case idle
        case holding(since: TimeInterval)
        case pendingTap(until: TimeInterval)
        case lockedAwaitingUp
        case locked
        case ignoringUp
    }
    private var state: State = .idle

    var isActive: Bool {
        switch state {
        case .holding, .pendingTap, .lockedAwaitingUp, .locked: true
        case .idle, .ignoringUp: false
        }
    }

    var isLocked: Bool { state == .locked || state == .lockedAwaitingUp }

    mutating func handle(_ e: HotkeyEvent, at t: TimeInterval) -> [HotkeyAction] {
        switch (state, e) {
        case (.idle, .down):
            state = .holding(since: t); return [.start]
        case (.holding(let since), .up):
            if t - since < tapMaxDuration {
                state = .pendingTap(until: t + doubleTapWindow); return []
            }
            state = .idle; return [.commit]
        case (.holding, .escape), (.lockedAwaitingUp, .escape),
             (.holding, .otherKey), (.lockedAwaitingUp, .otherKey):
            state = .ignoringUp; return [.cancel]
        case (.pendingTap(let until), .down):
            if t <= until { state = .lockedAwaitingUp; return [.lock] }
            state = .holding(since: t); return [.cancel, .start]
        case (.pendingTap, .escape), (.locked, .escape), (.pendingTap, .otherKey):
            state = .idle; return [.cancel]
        case (.lockedAwaitingUp, .up):
            state = .locked; return []
        case (.locked, .down):
            state = .ignoringUp; return [.commit]
        case (.ignoringUp, .up):
            state = .idle; return []
        default:
            return []
        }
    }

    mutating func tick(now t: TimeInterval) -> [HotkeyAction] {
        if case .pendingTap(let until) = state, t > until {
            state = .idle; return [.cancel]
        }
        return []
    }
}
