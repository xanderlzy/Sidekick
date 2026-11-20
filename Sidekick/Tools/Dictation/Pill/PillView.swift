import SwiftUI

/// The floating dictation indicator: a black capsule that breathes with your voice,
/// morphs into a spinner while polishing, and widens to show short messages.
struct PillView: View {
    let state: PillState
    let level: Float

    static let height: CGFloat = 36

    var body: some View {
        ZStack(alignment: .bottom) {
            if state != .hidden {
                capsule
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity),
                        removal: .scale(scale: 0.8, anchor: .bottom).combined(with: .opacity)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 14)
        .animation(Motion.fluid, value: state)
    }

    private var capsule: some View {
        content
            .frame(height: Self.height)
            .frame(minWidth: Self.height)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.black)
                    .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
            }
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .hidden:
            EmptyView()
        case .listening(let locked):
            HStack(spacing: 8) {
                if locked {
                    LockDot().transition(.scale.combined(with: .opacity))
                }
                Waveform(level: level)
            }
            .padding(.horizontal, 16)
            .transition(.opacity)
        case .polishing:
            Spinner().frame(width: Self.height).transition(.opacity)
        case .message(let text):
            Text(text)
                .font(Theme.Font.caption)
                .foregroundStyle(.white)
                .fixedSize()
                .padding(.horizontal, 16)
                .transition(.opacity)
        }
    }
}

/// Nine bars whose heights follow the voice level, each with its own phase so it feels alive.
private struct Waveform: View {
    let level: Float
    @State private var smoother = Smoother()

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let l = smoother.step(toward: CGFloat(level))
            HStack(spacing: 3) {
                ForEach(0..<9, id: \.self) { i in
                    Capsule().fill(Color.white)
                        .frame(width: 3, height: Self.height(bar: i, level: l, time: t))
                }
            }
            .frame(width: 9 * 3 + 8 * 3, height: 22)
        }
    }

    static func height(bar i: Int, level: CGFloat, time t: Double) -> CGFloat {
        let center = abs(CGFloat(i) - 4) / 4               // 0 at middle, 1 at edges
        let envelope = 1 - 0.55 * center
        let wobble = 0.6 + 0.4 * sin(t * 9 + Double(i) * 0.85)
        let idle = 3 + 1.5 * (0.5 + 0.5 * sin(t * 2.4 + Double(i) * 0.6))
        return idle + level * 19 * envelope * wobble
    }
}

/// Eases the displayed level toward the live one each frame.
private final class Smoother {
    private var value: CGFloat = 0
    func step(toward target: CGFloat) -> CGFloat {
        let rate: CGFloat = target > value ? 0.35 : 0.12   // quick attack, soft release
        value += (target - value) * rate
        return value
    }
}

private struct LockDot: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle().fill(Color.white)
                .frame(width: 6, height: 6)
                .opacity(0.55 + 0.45 * sin(t * 3.2))
        }
    }
}

private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .frame(width: 14, height: 14)
                .rotationEffect(.radians(t * 2 * .pi * 1.1))
        }
    }
}

#Preview("Listening") { PillView(state: .listening(locked: false), level: 0.6).frame(width: 360, height: 80) }
#Preview("Locked") { PillView(state: .listening(locked: true), level: 0.3).frame(width: 360, height: 80) }
#Preview("Polishing") { PillView(state: .polishing, level: 0).frame(width: 360, height: 80) }
#Preview("Message") { PillView(state: .message("Copied — press ⌘V"), level: 0).frame(width: 360, height: 80) }
