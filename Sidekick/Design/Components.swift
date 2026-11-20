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
                Capsule(style: .circular).fill(prominent ? Theme.fg() : Color.clear)
                    .overlay(Capsule(style: .circular).strokeBorder(Theme.fg(prominent ? 0 : 0.2), lineWidth: 1))
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

/// A small outlined label, always on one line. Lay several out with `FlowLayout` so they wrap whole.
struct Chip: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.fg(0.55))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .overlay(Capsule(style: .circular).strokeBorder(Theme.fg(0.12), lineWidth: 1))
    }
}

/// A page's title with an optional line of copy under it, and optional controls on the right.
struct PageHeader<Accessory: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Text(title).font(Theme.Font.title)
                if let subtitle {
                    Text(subtitle).font(Theme.Font.body).foregroundStyle(Theme.fg(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
    }
}

extension PageHeader where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}
