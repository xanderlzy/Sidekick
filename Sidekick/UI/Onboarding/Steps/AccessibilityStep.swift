import Combine
import SwiftUI

struct AccessibilityStep: View {
    let next: @MainActor @Sendable () -> Void
    @State private var granted = Permissions.accessibility
    @State private var auto = AutoAdvance()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        StepLayout(title: "Allow Accessibility",
                   message: "Accessibility lets Sidekick notice your shortcuts, paste dictated text and move windows. Turn on Sidekick in the list that opens.") {
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
            AppEnvironment.shared.registry.tools.forEach { $0.accessibilityGranted() }
            withAnimation(Motion.fluid) { granted = true }
            // Bring Sidekick back to the front after the user flips the switch in System Settings.
            AppEnvironment.shared.window.show()
            auto.schedule(next)
        }
        .onDisappear { auto.cancel() }
    }
}
