import SwiftUI
import KeyboardShortcuts

/// Keep on Top's settings page: the shortcut and the list of pinned windows.
struct KeepOnTopPage: View {
    let pins: PinController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Keep on Top").font(Theme.Font.title)

                SettingsRow(title: "Shortcut") {
                    KeyboardShortcuts.Recorder(for: .pinWindow)
                }

                SettingsSection("Pinned") {
                    if pins.pins.isEmpty {
                        Text("Nothing pinned. Press ⌃⌥T on any window.")
                            .font(Theme.Font.body).foregroundStyle(Theme.fg(0.45))
                            .padding(.vertical, 11)
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                    ForEach(pins.pins, id: \.id) { window in
                        SettingsRow(title: window.appName, detail: window.title.isEmpty ? nil : window.title) {
                            Button("Unpin") { pins.unpin(window.id) }.buttonStyle(MonoButtonStyle())
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .scrollIndicators(.never)
        .animation(Motion.snappy, value: pins.pins.map(\.id))
    }
}
