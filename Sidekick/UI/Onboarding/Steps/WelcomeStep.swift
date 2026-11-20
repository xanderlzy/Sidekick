import SwiftUI

struct WelcomeStep: View {
    let next: () -> Void
    var body: some View {
        StepLayout(title: "Small tools for your Mac.",
                   message: "Turn on only what you need. Everything runs on this Mac.") {
            EmptyView()
        } actions: {
            PrimaryButton(title: "Get started", action: next)
        }
    }
}
