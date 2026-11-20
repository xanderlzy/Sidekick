import Combine
import Speech
import SwiftUI

struct GeneralSettingsView: View {
    let env: AppEnvironment
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var granted: [Permission: Bool] = [:]
    private let permissionPoll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Every permission any enabled tool needs, once each.
    private var permissions: [Permission] {
        var seen = Set<Permission>()
        return env.registry.enabled.flatMap(\.permissions).filter { seen.insert($0).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("General").font(Theme.Font.title)

                SettingsSection("Startup") {
                    SettingsRow(title: "Launch at login") {
                        Toggle("", isOn: $launchAtLogin).toggleStyle(MonoToggleStyle()).labelsHidden()
                    }
                    SettingsRow(title: "Updates", detail: "Version \(Bundle.main.shortVersion)") {
                        Button("Check for updates") { env.updater?.checkForUpdates() }
                            .buttonStyle(MonoButtonStyle())
                            .disabled(env.updater == nil)
                    }
                }

                SettingsSection("Permissions") {
                    if permissions.isEmpty {
                        SettingsRow(title: "No permissions needed", detail: "Turn on a tool that needs one.") {
                            EmptyView()
                        }
                    }
                    ForEach(permissions, id: \.self) { p in
                        SettingsRow(title: p.title) {
                            PermissionControl(granted: granted[p] ?? p.isGranted) { grant(p) }
                        }
                    }
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .scrollIndicators(.never)
        .animation(Motion.snappy, value: granted)
        .onChange(of: launchAtLogin) { _, on in
            do { try LoginItem.set(on) } catch { launchAtLogin = LoginItem.isEnabled }
        }
        .onReceive(permissionPoll) { _ in
            for p in permissions { granted[p] = p.isGranted }
        }
    }

    private func grant(_ p: Permission) {
        switch p {
        case .microphone:
            Task { if await !Permissions.requestMicrophone() { Permissions.openSettings(.microphone) } }
        case .accessibility:
            Permissions.promptAccessibility()
            Permissions.openSettings(.accessibility)
        case .screenRecording:
            Permissions.requestScreenRecording()
            Permissions.openSettings(.screenRecording)
        case .speech:
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
    }
}
