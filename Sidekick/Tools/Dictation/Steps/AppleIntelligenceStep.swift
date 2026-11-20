import Combine
import SwiftUI

struct AppleIntelligenceStep: View {
    let env: DictationEnvironment
    let next: () -> Void
    @State private var available = false
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        StepLayout(title: available ? "Polishing is on" : "Turn on Apple Intelligence",
                   message: available
                   ? "Apple's on-device model will tidy each dictation: no ums, proper punctuation, and your corrections applied. Your words stay yours."
                   : "Dictation uses Apple's on-device model to tidy what you say. Without it, Dictation still works, but it inserts exactly what it hears.") {
            if available { DoneBadge(text: "Apple Intelligence available") }
        } actions: {
            if !available {
                Button("Open Settings") { Permissions.openSettings(.appleIntelligence) }
                    .buttonStyle(MonoButtonStyle())
            }
            PrimaryButton(title: available ? "Continue" : "Continue without it", action: next)
        }
        .onAppear { available = env.polishAvailable }
        .onReceive(poll) { _ in
            let now = env.polishAvailable
            if now != available { withAnimation(Motion.fluid) { available = now } }
        }
    }
}
