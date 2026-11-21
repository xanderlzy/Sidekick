import KeyboardShortcuts
import SwiftUI

struct WindowManagerSettingsView: View {
    let tool: WindowManagerTool
    @AppStorage(WindowManagerTool.snapEnabledKey) private var snapEnabled = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                PageHeader("Window Manager")

                SettingsSection("Snapping") {
                    SettingsRow(title: "Snap windows by dragging", detail: "Drag a window to an edge or corner of the screen.") {
                        Toggle("", isOn: $snapEnabled).toggleStyle(MonoToggleStyle()).labelsHidden()
                    }
                }

                ForEach(WindowAction.Group.allCases, id: \.self) { group in
                    SettingsSection(group.rawValue) {
                        ForEach(WindowAction.allCases.filter { $0.group == group }, id: \.self) { action in
                            SettingsRow(title: action.title) {
                                KeyboardShortcuts.Recorder(for: action.shortcutName)
                            }
                        }
                    }
                }

                Button("Restore default shortcuts") {
                    KeyboardShortcuts.reset(WindowAction.allCases.map(\.shortcutName))
                }
                .buttonStyle(MonoButtonStyle())
                .padding(.bottom, 24)
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .scrollIndicators(.never)
        .onChange(of: snapEnabled) { _, new in tool.setSnapping(new) }
    }
}
