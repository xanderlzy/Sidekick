import SwiftUI

struct TryItStep: View {
    let key: HotkeyKey
    let next: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        StepLayout(title: "Try it here",
                   message: "Hold \(key.shortName) and say something like: “um so this is my first, no, my very first dictation.”") {
            TextEditor(text: $text)
                .font(.system(size: 15))
                .scrollContentBackground(.hidden)
                .focused($focused)
                .padding(14)
                .frame(maxWidth: 520, minHeight: 110, maxHeight: 140)
                .background(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder(Theme.fg(focused ? 0.4 : 0.15), lineWidth: 1))
                .animation(Motion.snappy, value: focused)
        } actions: {
            PrimaryButton(title: text.isEmpty ? "Skip" : "Continue", action: next)
        }
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true } }
    }
}
