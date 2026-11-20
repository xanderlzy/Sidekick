import SwiftUI

/// Black/white switch: ink track when on, faint track when off, paper-colored knob.
struct MonoToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 12)
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Theme.fg() : Theme.fg(0.15))
                    .frame(width: 34, height: 20)
                Circle().fill(Theme.bg())
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                    .frame(width: 16, height: 16)
                    .padding(2)
            }
            .animation(Motion.snappy, value: configuration.isOn)
            .contentShape(Capsule())
            .onTapGesture { configuration.isOn.toggle() }
            .accessibilityAddTraits(.isButton)
        }
    }
}

/// Bordered pill button in ink; `prominent` fills it.
struct MonoButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(prominent ? Theme.bg() : Theme.fg())
            .background {
                Capsule().fill(prominent ? Theme.fg() : Color.clear)
                    .overlay(Capsule().strokeBorder(Theme.fg(prominent ? 0 : 0.2), lineWidth: 1))
            }
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.snappy, value: configuration.isPressed)
    }
}

/// Hairline in ink.
struct Hairline: View {
    var body: some View { Rectangle().fill(Theme.fg(0.08)).frame(height: 1) }
}

/// Small uppercase section label.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Theme.fg(0.4))
    }
}
