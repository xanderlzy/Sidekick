import Combine
import SwiftUI

struct SpeechModelStep: View {
    let env: DictationEnvironment
    let next: () -> Void
    enum Phase: Equatable { case working(Double), ready, failed }
    @State private var phase: Phase = .working(0)
    private let poll = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        StepLayout(title: "Getting the speech engine ready",
                   message: "Apple's on-device speech model turns your voice into text. It's a one-time download if it isn't on your Mac already.") {
            switch phase {
            case .working(let fraction):
                HStack(spacing: 12) {
                    ProgressBar(fraction: fraction).frame(width: 240)
                    Text(fraction > 0 ? "\(Int(fraction * 100))%" : "Checking…")
                        .font(Theme.Font.caption).monospacedDigit().foregroundStyle(Theme.fg(0.5))
                }
            case .ready:
                DoneBadge(text: "Speech engine ready")
            case .failed:
                Text("Couldn't get the speech model. Check your internet connection.")
                    .font(Theme.Font.body).foregroundStyle(Theme.fg(0.6))
            }
        } actions: {
            switch phase {
            case .ready: PrimaryButton(title: "Continue", action: next)
            case .failed: PrimaryButton(title: "Try again") { prepare() }
            case .working: EmptyView()
            }
        }
        .task { prepare() }
        .onReceive(poll) { _ in
            if case .working = phase, let p = env.appleTranscriber.installProgress {
                withAnimation(Motion.snappy) { phase = .working(p.fractionCompleted) }
            }
        }
    }

    private func prepare() {
        phase = .working(0)
        let t = env.appleTranscriber
        Task {
            do {
                try await t.prepare()
                withAnimation(Motion.fluid) { phase = .ready }
            } catch {
                withAnimation(Motion.fluid) { phase = .failed }
            }
        }
    }
}
