import CoreAudio
import Foundation

struct MixerRow: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let isPlaying: Bool
    let setting: AppVolume
    let playsElsewhere: Bool
}

/// Which apps get a row, and which processes get tapped. Pure; no Core Audio calls.
enum MixerRules {
    static let webContentName = "Web content"

    static func rows(
        groups: [String: [AudioProcess]],
        apps: [RunningApp],
        settings: [String: AppVolume],
        defaultOutput: AudioObjectID?
    ) -> [MixerRow] {
        var rows: [MixerRow] = []
        for (key, processes) in groups where !processes.isEmpty {
            let setting = settings[key] ?? .standard
            let playing = processes.contains { $0.isRunningOutput }
            guard playing || !setting.isStandard else { continue }
            let name: String
            if key == AppGrouping.webContentKey {
                name = webContentName
            } else if let app = apps.first(where: { $0.bundleID == key }) {
                name = app.name
            } else {
                continue
            }
            rows.append(MixerRow(id: key, name: name, isPlaying: playing, setting: setting,
                                 playsElsewhere: playsElsewhere(processes, defaultOutput: defaultOutput)))
        }
        return rows.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    static func tapTargets(
        groups: [String: [AudioProcess]],
        settings: [String: AppVolume],
        defaultOutput: AudioObjectID?
    ) -> [String: [AudioObjectID]] {
        guard defaultOutput != nil else { return [:] }
        var targets: [String: [AudioObjectID]] = [:]
        for (key, processes) in groups where !processes.isEmpty {
            guard !(settings[key] ?? .standard).isStandard,
                  !playsElsewhere(processes, defaultOutput: defaultOutput) else { continue }
            targets[key] = processes.map(\.objectID)
        }
        return targets
    }

    /// Tapping a process pulls its audio onto the default output, so any process that reports
    /// a device other than exactly `[defaultOutput]` keeps the whole app out of the tap.
    /// With no default output we can't say "elsewhere", so rows are not flagged (targets are empty anyway).
    private static func playsElsewhere(_ processes: [AudioProcess], defaultOutput: AudioObjectID?) -> Bool {
        guard let defaultOutput else { return false }
        return processes.contains { !$0.outputDevices.isEmpty && $0.outputDevices != [defaultOutput] }
    }
}
