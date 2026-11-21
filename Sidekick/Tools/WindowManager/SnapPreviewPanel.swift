import AppKit
import SwiftUI

/// The translucent footprint shown while a window is dragged into a snap area.
/// One click-through panel covers the target display; only the footprint inside it moves.
@MainActor
final class SnapPreviewPanel {
    static let inset: CGFloat = 6
    static let seedSize: CGFloat = 40

    private let panel: NSPanel
    private let model = SnapPreviewModel()
    /// The display the panel currently covers, in AX coordinates.
    private var display: Display?
    /// The last requested target, in AX coordinates. Nil while hidden or fading out.
    private var target: CGRect?
    /// Bumped on every show/hide so stale animation completions do nothing.
    private var generation = 0

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        let host = NSHostingView(rootView: SnapPreviewView(model: model))
        host.sizingOptions = []
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    /// Shows the footprint for `axRect` on `display`. Repeating the current target does nothing,
    /// so a steady drag never restarts the spring.
    func show(_ axRect: CGRect, on display: Display) {
        if axRect == target, display == self.display { return }
        let local = Self.local(axRect, in: display).insetBy(dx: Self.inset, dy: Self.inset)

        if display == self.display, panel.isVisible {
            // Retarget, or come back while fading out: glide there.
            generation += 1
            target = axRect
            withAnimation(Motion.fluid) {
                model.rect = local
                model.opacity = 1
            }
            return
        }

        // First show on this display: seed a small rect at the cursor, then spring out to the target.
        generation += 1
        let token = generation
        target = axRect
        self.display = display
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        panel.setFrame(ScreenGeometry.flip(display.frame, primaryHeight: primaryHeight), display: false)
        let cursor = Self.local(ScreenGeometry.flip(NSEvent.mouseLocation, primaryHeight: primaryHeight), in: display)
        var seed = Transaction()
        seed.disablesAnimations = true
        withTransaction(seed) {
            model.rect = CGRect(x: cursor.x - Self.seedSize / 2, y: cursor.y - Self.seedSize / 2,
                                width: Self.seedSize, height: Self.seedSize)
            model.opacity = 0
        }
        panel.orderFrontRegardless()
        // Let the seed render once so the spring has somewhere to start from.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            withAnimation(Motion.snappy) {
                self.model.rect = local
                self.model.opacity = 1
            }
        }
    }

    /// Fades the footprint out, then orders the panel out.
    func hide() {
        guard target != nil else { return }
        generation += 1
        let token = generation
        target = nil
        withAnimation(Motion.snappy, completionCriteria: .logicallyComplete) {
            model.opacity = 0
        } completion: { [weak self] in
            self?.finishHide(token)
        }
        // Backstop in case SwiftUI has nothing to animate and skips the completion.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.finishHide(token)
        }
    }

    private func finishHide(_ token: Int) {
        guard generation == token else { return }
        panel.orderOut(nil)
        display = nil
    }

    /// Removes the panel at once, without animation.
    func close() {
        generation += 1
        target = nil
        display = nil
        panel.orderOut(nil)
        model.opacity = 0
    }

    private static func local(_ r: CGRect, in display: Display) -> CGRect {
        r.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }

    private static func local(_ p: CGPoint, in display: Display) -> CGPoint {
        CGPoint(x: p.x - display.frame.minX, y: p.y - display.frame.minY)
    }
}

@MainActor @Observable
private final class SnapPreviewModel {
    /// In the panel's top-left, y-down space (matches AX relative to the display).
    var rect: CGRect = .zero
    var opacity: Double = 0
}

private struct SnapPreviewView: View {
    let model: SnapPreviewModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
        shape
            .fill(Theme.fg(0.08))
            .overlay(shape.strokeBorder(Theme.fg(0.5), lineWidth: 1.5))
            .frame(width: model.rect.width, height: model.rect.height)
            .offset(x: model.rect.minX, y: model.rect.minY)
            .opacity(model.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .ignoresSafeArea()
    }
}
