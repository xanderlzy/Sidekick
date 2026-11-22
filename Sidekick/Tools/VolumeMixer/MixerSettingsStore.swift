import Foundation
import Observation

/// One app's remembered volume. Gain is `volume²` (no boost); muted is silent.
struct AppVolume: Codable, Equatable, Sendable {
    var volume: Double
    var muted: Bool

    static let standard = AppVolume(volume: 1, muted: false)

    /// True when the app needs no tap (full volume, not muted).
    var isStandard: Bool { self == .standard }

    var gain: Float {
        muted ? 0 : Float(volume * volume)
    }
}

/// Remembered per-app volumes, keyed by bundle ID, stored as JSON in UserDefaults.
/// Standard entries are never stored, so `all` is exactly the remembered list.
@MainActor @Observable
final class MixerSettingsStore {
    static let key = "volumeMixer.settings"

    @ObservationIgnored private let defaults: UserDefaults
    private var entries: [String: AppVolume]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([String: AppVolume].self, from: data) {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    var all: [String: AppVolume] { entries }

    func setting(for key: String) -> AppVolume {
        entries[key] ?? .standard
    }

    func set(_ value: AppVolume, for key: String) {
        var clamped = value
        clamped.volume = min(max(value.volume, 0), 1)
        if clamped.isStandard {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = clamped
        }
        persist()
    }

    func reset(_ key: String) {
        entries.removeValue(forKey: key)
        persist()
    }

    func resetAll() {
        entries.removeAll()
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
