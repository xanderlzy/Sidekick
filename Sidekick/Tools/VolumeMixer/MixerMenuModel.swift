import AppKit

/// One line of the mixer menu, top to bottom. Pure value; `MixerStatusItem` turns it into an `NSMenuItem`.
enum MixerMenuEntry: Equatable {
    case header(String)
    /// The output device's volume row.
    case system
    case deviceCaption(String)
    case separator
    case sectionHeader(String)
    case app(MixerRow)
    case caption(String)
    case action(String)
}

/// What the mixer menu shows for the controller's state. Pure.
enum MixerMenuModel {
    static let title = "Sound"
    static let appsTitle = "Apps"
    static let settingsTitle = "Volume Mixer Settings…"
    static let nothingPlaying = "Nothing's playing right now."
    static let needsPermission = "Volume Mixer needs System Audio Recording"
    static let openSettingsTitle = "Open Settings…"
    static let playsElsewhere = "Plays to another device"
    static let ownVolume = "This device controls its own volume"

    static func entries(rows: [MixerRow], needsPermission: Bool, notice: String?,
                        deviceName: String) -> [MixerMenuEntry] {
        var entries: [MixerMenuEntry] = [.header(title), .system]
        if !deviceName.isEmpty { entries.append(.deviceCaption(deviceName)) }
        entries += [.separator, .sectionHeader(appsTitle)]
        if needsPermission {
            entries += [.caption(Self.needsPermission), .action(openSettingsTitle)]
        } else {
            entries += rows.isEmpty ? [.caption(nothingPlaying)] : rows.map(MixerMenuEntry.app)
            if let notice { entries.append(.caption(notice)) }
        }
        entries += [.separator, .action(settingsTitle)]
        return entries
    }
}

enum MixerFormat {
    /// "70%". Clamped to 0–100%.
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "0%" }
        return "\(Int((min(1, max(0, value)) * 100).rounded()))%"
    }
}

enum SpeakerGlyph {
    static func name(volume: Double?, muted: Bool) -> String {
        if muted { return "speaker.slash.fill" }
        guard let volume else { return "speaker.wave.2.fill" }
        switch volume {
        case ..<0.005: return "speaker.fill"
        case ..<0.34: return "speaker.wave.1.fill"
        case ..<0.67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

enum MixerDisplay {
    /// The controller's rows, plus the row being dragged if it dropped out mid-drag (a silent app
    /// dragged back to 100% stops being listed); it stays put until the finger lifts.
    static func rows(_ rows: [MixerRow], holding held: MixerRow?) -> [MixerRow] {
        guard let held, !rows.contains(where: { $0.id == held.id }) else { return rows }
        return (rows + [held]).sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// The held copy of a row mid-drag: at the slider's value and unmuted (dragging unmutes).
    static func dragged(_ row: MixerRow, to value: Double) -> MixerRow {
        MixerRow(id: row.id, name: row.name, isPlaying: row.isPlaying,
                 setting: AppVolume(volume: min(1, max(0, value)), muted: false),
                 playsElsewhere: row.playsElsewhere)
    }
}

/// A row's icon: the owning app's own icon, read from its bundle on disk, or the globe for Web content.
///
/// Rows are keyed by the owning app's bundle ID (helpers such as Chrome's are already folded into it), so the
/// icon comes from that app's bundle: first the running copy's `bundleURL`, then the installed copy.
/// Never a helper's icon and never a generic placeholder.
enum MixerAppIcon {
    enum Source: Equatable {
        case globe
        case file(String)
        case none
    }

    static func source(for key: String, runningPath: (String) -> String?,
                       installedPath: (String) -> String?) -> Source {
        if key == AppGrouping.webContentKey { return .globe }
        if let path = runningPath(key) ?? installedPath(key) { return .file(path) }
        return .none
    }

    /// The icon for `key` at `size` points, or nil when the app can't be found.
    @MainActor
    static func image(for key: String, size: CGFloat) -> NSImage? {
        let source = source(
            for: key,
            runningPath: { id in
                NSRunningApplication.runningApplications(withBundleIdentifier: id)
                    .first { $0.bundleURL != nil }?.bundleURL?.path
            },
            installedPath: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path })
        switch source {
        case .globe:
            let image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size - 2, weight: .regular))
            image?.isTemplate = true
            return image
        case .file(let path):
            // A copy: `icon(forFile:)` may hand back a shared image, and we resize it.
            guard let image = NSWorkspace.shared.icon(forFile: path).copy() as? NSImage else { return nil }
            image.size = NSSize(width: size, height: size)
            return image
        case .none:
            return nil
        }
    }
}
