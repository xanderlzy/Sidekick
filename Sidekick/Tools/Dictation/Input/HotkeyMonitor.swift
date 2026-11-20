import AppKit
import CoreGraphics

/// Listens to the global keyboard stream for the chosen trigger key (and Escape),
/// feeds a `HotkeyStateMachine`, and reports its actions on the main actor.
@MainActor
final class HotkeyMonitor {
    var key: HotkeyKey { didSet { keyIsDown = false } }
    var onAction: (HotkeyAction) -> Void = { _ in }
    /// Raw press state of the trigger key, for UI such as onboarding practice.
    var onKeyState: (Bool) -> Void = { _ in }

    private var machine = HotkeyStateMachine()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private var keyIsDown = false
    private let clock = ProcessInfo.processInfo

    init(key: HotkeyKey) { self.key = key }

    var isRunning: Bool { tap != nil }

    func start() throws {
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { throw PermissionError.accessibility }
        let mask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(mask), callback: hotkeyTapCallback, userInfo: refcon
        ) else { throw PermissionError.accessibility }
        tap = port
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.emit(self?.machine.tick(now: self?.now ?? 0) ?? []) }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tap = nil; source = nil
        machine = HotkeyStateMachine(); keyIsDown = false
    }

    private var now: TimeInterval { clock.systemUptime }

    fileprivate func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            guard UInt16(keyCode) == key.keyCode else { return }
            let down = key.isDown(flags: flags)
            guard down != keyIsDown else { return }
            keyIsDown = down
            onKeyState(down)
            emit(machine.handle(down ? .down : .up, at: now))
        case .keyDown:
            guard machine.isActive else { return }
            guard let event = Self.event(forKeyDown: keyCode) else { return }
            emit(machine.handle(event, at: now))
        default:
            break
        }
    }

    /// Escape cancels; the Globe key's own keyDown (179, posted on release) is part of the
    /// trigger; any other key is a shortcut chord.
    nonisolated static func event(forKeyDown keyCode: Int64) -> HotkeyEvent? {
        switch keyCode {
        case 53: .escape
        case 179: nil
        default: .otherKey
        }
    }

    private func emit(_ actions: [HotkeyAction]) {
        actions.forEach(onAction)
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let refcon {
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        MainActor.assumeIsolated { monitor.handle(type: type, keyCode: keyCode, flags: flags) }
    }
    return Unmanaged.passUnretained(event)
}
