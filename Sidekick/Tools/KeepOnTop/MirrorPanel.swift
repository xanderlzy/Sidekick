import AppKit
import SwiftUI

/// A floating, always-on-top live copy of one window. Lifts off the source, springs to a corner,
/// snaps to the nearest corner after a drag, and animates out when the source closes.
final class MirrorPanel: NSPanel, MirrorPresenting {
    private static let opacities: [CGFloat] = [1, 0.75, 0.5]

    private let source: WindowInfo
    private let onClose: () -> Void
    private let stream: MirrorStream
    private let status = MirrorStatus()
    private var opacityIndex = 0
    private var frameAnimations = 0
    private var dismissed = false
    private var poll: Timer?
    private var dragWatch: Timer?
    private var observers: [NSObjectProtocol] = []

    init(window: WindowInfo, onClose: @escaping () -> Void) {
        source = window
        self.onClose = onClose
        stream = MirrorStream(windowID: window.id, size: window.frame.size,
                              scale: Self.screen(for: window.frame)?.backingScaleFactor ?? 2, onStop: onClose)
        super.init(contentRect: window.frame, styleMask: [.borderless, .nonactivatingPanel, .resizable],
                   backing: .buffered, defer: false)
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        contentAspectRatio = window.frame.size
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = makeContent(size: window.frame.size)
    }

    // MARK: MirrorPresenting

    func present() {
        alphaValue = 0
        setFrame(source.frame, display: false)
        orderFrontRegardless()
        stream.start()
        startMonitoring()

        let visible = (Self.screen(for: source.frame) ?? NSScreen.main)?.visibleFrame ?? source.frame
        let target = PiPLayout.clamped(PiPLayout.pipFrame(source: source.frame, screen: visible), into: visible)
        NSAnimationContext.animate(Motion.snappy) { animator().alphaValue = 1 }
        // A short beat so the copy visibly lifts off the source before it travels.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.dismissed else { return }
                self.spring(to: target)
            }
        }
    }

    func dismiss() {
        guard !dismissed else { return }
        dismissed = true
        stopMonitoring()
        let shrunk = frame.insetBy(dx: frame.width * 0.1, dy: frame.height * 0.1)
        NSAnimationContext.animate(Motion.snappy) {
            animator().setFrame(shrunk, display: true)
            animator().alphaValue = 0
        } completion: {
            // Strong on purpose: PinController has already dropped the panel, so this one-shot
            // completion is what keeps it alive until it has animated out and stopped its stream.
            MainActor.assumeIsolated {
                self.stream.stop()
                self.close()
            }
        }
    }

    // MARK: Content

    private func makeContent(size: CGSize) -> NSView {
        let bounds = NSRect(origin: .zero, size: size)
        let container = NSView(frame: bounds)
        container.wantsLayer = true
        container.layer?.cornerRadius = Theme.corner
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor(Theme.bg()).cgColor

        let mirror = NSView(frame: bounds)
        mirror.layer = stream.layer
        mirror.wantsLayer = true
        mirror.autoresizingMask = [.width, .height]
        container.addSubview(mirror)

        let controls = MirrorControls(
            status: status,
            unpin: { [weak self] in self?.onClose() },
            activate: { [weak self] in
                guard let self else { return }
                NSRunningApplication(processIdentifier: self.source.pid)?.activate()
            },
            cycleOpacity: { [weak self] in self?.cycleOpacity() })
        let host = ClickThroughHostingView(rootView: controls)
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        return container
    }

    private func cycleOpacity() {
        opacityIndex = (opacityIndex + 1) % Self.opacities.count
        let alpha = Self.opacities[opacityIndex]
        NSAnimationContext.animate(Motion.snappy) { animator().alphaValue = alpha }
    }

    // MARK: Motion

    /// Window frames follow the SwiftUI spring through the `animator()` proxy (verified on macOS 26).
    private func spring(to target: NSRect) {
        guard target != frame else { return }
        frameAnimations += 1
        NSAnimationContext.animate(Motion.fluid) {
            animator().setFrame(target, display: true)
        } completion: { [weak self] in
            MainActor.assumeIsolated { self?.frameAnimations -= 1 }
        }
    }

    private var currentVisibleFrame: NSRect? { (screen ?? NSScreen.main)?.visibleFrame }

    private func snapToCorner() {
        guard !dismissed, let visible = currentVisibleFrame else { return }
        spring(to: PiPLayout.snapped(PiPLayout.clamped(frame, into: visible), screen: visible))
    }

    private func clampToScreen() {
        guard !dismissed, let visible = currentVisibleFrame else { return }
        spring(to: PiPLayout.clamped(frame, into: visible))
    }

    /// The user is dragging (or resizing) the panel: wait for the mouse to come up, then snap.
    private func windowMoved() {
        guard frameAnimations == 0, dragWatch == nil, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        dragWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
                self.dragWatch?.invalidate()
                self.dragWatch = nil
                self.snapToCorner()
            }
        }
    }

    // MARK: Source monitoring

    private func startMonitoring() {
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSource() }
        }
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clampToScreen() }
            },
            center.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowMoved() }
            },
        ]
    }

    private func stopMonitoring() {
        poll?.invalidate(); poll = nil
        dragWatch?.invalidate(); dragWatch = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    private func checkSource() {
        guard WindowFinder.exists(source.id) else { onClose(); return }
        status.paused = !WindowFinder.isOnScreen(source.id)
    }

    /// The screen showing most of `rect`.
    private static func screen(for rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { area($0.frame.intersection(rect)) < area($1.frame.intersection(rect)) }
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}

/// Lets the first click on a control land even though the panel never becomes key.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
