import Combine
import SwiftUI

struct AccessibilityStep: View {
    let env: DictationEnvironment
    let next: () -> Void
    @State private var granted = Permissions.accessibility
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        StepLayout(title: "Let Sidekick type for you",
                   message: "Accessibility access lets Sidekick notice the dictation key and paste your words where the cursor is. Turn on Sidekick in the list that opens.") {
            if granted { DoneBadge(text: "Accessibility allowed") }
        } actions: {
            if granted {
                PrimaryButton(title: "Continue", action: next)
            } else {
                PrimaryButton(title: "Open Accessibility Settings") {
                    Permissions.promptAccessibility()
                    Permissions.openSettings(.accessibility)
                }
            }
        }
        .onReceive(poll) { _ in
            guard Permissions.accessibility, !granted else { return }
            env.startHotkeys()
            withAnimation(Motion.fluid) { granted = true }
            // Bring Sidekick back to the front after the user flips the switch in System Settings.
            AppEnvironment.shared.window.show()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.9))
                next()
            }
        }
    }
}
