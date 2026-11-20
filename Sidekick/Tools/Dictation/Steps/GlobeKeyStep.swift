import SwiftUI

struct GlobeKeyStep: View {
    let next: () -> Void
    var body: some View {
        StepLayout(title: "One quick setting",
                   message: "So the Fn key starts dictation instead of opening the emoji picker, set it to do nothing in Keyboard settings.") {
            HStack(spacing: 8) {
                ForEach(Array(["System Settings", "Keyboard", "Press 🌐 key to", "Do Nothing"].enumerated()), id: \.offset) { i, part in
                    if i > 0 { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.fg(0.35)) }
                    label(part)
                        .lineLimit(1).fixedSize()
                        .font(.system(size: 12, weight: i == 3 ? .semibold : .regular))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().strokeBorder(Theme.fg(i == 3 ? 0.6 : 0.15), lineWidth: 1))
                }
            }
        } actions: {
            Button("Open Keyboard Settings") { Permissions.openSettings(.keyboard) }
                .buttonStyle(MonoButtonStyle())
            PrimaryButton(title: "Done", action: next)
        }
    }

    /// The globe must be interpolated into a Text (not a String) to render as an icon.
    private func label(_ part: String) -> Text {
        part == "Press 🌐 key to" ? Text("Press \(Image(systemName: "globe")) key to") : Text(part)
    }
}
