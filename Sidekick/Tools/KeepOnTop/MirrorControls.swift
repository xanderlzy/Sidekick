import SwiftUI

/// What the mirror's overlay shows: whether the source is paused (minimized or on another Space).
@MainActor @Observable
final class MirrorStatus {
    var paused = false
}

/// The mirror's hover overlay: unpin, bring the source forward, and cycle opacity.
struct MirrorControls: View {
    let status: MirrorStatus
    let unpin: () -> Void
    let activate: () -> Void
    let cycleOpacity: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            capsule
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(8)
            if status.paused {
                Circle().fill(Theme.fg(0.6)).frame(width: 6, height: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(10)
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(Motion.snappy, value: hovering)
        .animation(Motion.snappy, value: status.paused)
    }

    private var capsule: some View {
        HStack(spacing: 10) {
            icon("pin.slash", help: "Unpin", action: unpin)
            icon("arrow.up.forward.app", help: "Show Window", action: activate)
            icon("circle.lefthalf.filled", help: "Opacity", action: cycleOpacity)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background {
            Capsule().fill(Theme.bg(0.85))
                .overlay(Capsule().strokeBorder(Theme.fg(0.12), lineWidth: 1))
        }
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.fg())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
