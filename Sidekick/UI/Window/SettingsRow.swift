import SwiftUI

/// One settings line: title and optional detail on the left, a control on the right, a hairline below.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    let control: Control

    init(title: String, detail: String? = nil, control: Control) {
        self.title = title; self.detail = detail; self.control = control
    }

    init(title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.init(title: title, detail: detail, control: control())
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.Font.body)
                    if let detail {
                        Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.fg(0.45))
                    }
                }
                Spacer()
                control
            }
            .padding(.vertical, 11)
            Hairline()
        }
    }
}

/// A titled group of settings rows.
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title; self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: title).padding(.bottom, 6)
            content()
        }
    }
}

/// "Allowed ✓" when granted, otherwise a prominent Allow button.
struct PermissionControl: View {
    let granted: Bool
    let grant: () -> Void

    var body: some View {
        if granted {
            Label("Allowed", systemImage: "checkmark")
                .font(Theme.Font.caption).foregroundStyle(Theme.fg(0.5))
                .transition(.scale.combined(with: .opacity))
        } else {
            Button("Allow", action: grant).buttonStyle(MonoButtonStyle(prominent: true))
        }
    }
}
