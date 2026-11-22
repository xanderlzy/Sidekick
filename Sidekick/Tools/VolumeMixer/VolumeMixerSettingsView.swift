import AppKit
import SwiftUI

/// Name and icon for a remembered key: the installed app, else the bundle ID itself.
enum RememberedVolume {
    static func name(for key: String) -> String {
        if key == AppGrouping.webContentKey { return MixerRules.webContentName }
        guard let url = appURL(key) else { return key }
        let bundle = Bundle(url: url)
        return (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }

    static func icon(for key: String) -> NSImage? {
        guard key != AppGrouping.webContentKey, let url = appURL(key) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func appURL(_ bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }
}

struct VolumeMixerSettingsView: View {
    let store: MixerSettingsStore
    let controller: TapController

    var body: some View {
        // `store` is observable, so the list follows Reset and the panel's sliders.
        let remembered = store.all.map { (key: $0.key, name: RememberedVolume.name(for: $0.key), setting: $0.value) }
            .sorted { ($0.name.lowercased(), $0.key) < ($1.name.lowercased(), $1.key) }
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.section) {
                PageHeader("Volume Mixer")

                SettingsSection("Remembered volumes") {
                    if remembered.isEmpty {
                        Text("No remembered volumes yet.")
                            .font(Theme.Font.caption).foregroundStyle(Theme.fg(0.45))
                            .padding(.vertical, 11)
                    } else {
                        ForEach(remembered, id: \.key) { item in
                            row(item.key, item.name, item.setting)
                        }
                    }
                }

                if !remembered.isEmpty {
                    Button("Reset all") { controller.resetAll() }
                        .buttonStyle(MonoButtonStyle())
                        .padding(.bottom, 24)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private func row(_ key: String, _ name: String, _ setting: AppVolume) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                icon(key).frame(width: 22, height: 22)
                Text(name).font(Theme.Font.body).lineLimit(1)
                Spacer(minLength: 16)
                Text(percent(setting)).font(Theme.Font.caption)
                    .foregroundStyle(Theme.fg(0.6)).monospacedDigit()
                Button("Reset") { controller.reset(key) }.buttonStyle(MonoButtonStyle())
            }
            .padding(.vertical, 8)
            Hairline()
        }
    }

    @ViewBuilder private func icon(_ key: String) -> some View {
        if key == AppGrouping.webContentKey {
            Image(systemName: "globe").font(.system(size: 15)).foregroundStyle(Theme.fg(0.7))
        } else if let image = RememberedVolume.icon(for: key) {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 15)).foregroundStyle(Theme.fg(0.45))
        }
    }

    private func percent(_ setting: AppVolume) -> String {
        setting.muted ? "Muted" : "\(Int((setting.volume * 100).rounded()))%"
    }
}
