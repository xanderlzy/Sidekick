import Foundation
import Testing
@testable import Sidekick

@MainActor
struct MixerSettingsStoreTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MixerSettingsStoreTests-\(UUID())")!
    }

    @Test func unknownAppIsStandard() {
        let store = MixerSettingsStore(defaults: makeDefaults())
        #expect(store.setting(for: "x") == .standard)
    }

    @Test func setPersistsAcrossInstances() {
        let defaults = makeDefaults()
        MixerSettingsStore(defaults: defaults).set(AppVolume(volume: 0.4, muted: true), for: "x")
        let reloaded = MixerSettingsStore(defaults: defaults)
        #expect(reloaded.setting(for: "x") == AppVolume(volume: 0.4, muted: true))
    }

    @Test func settingStandardRemovesEntry() {
        let store = MixerSettingsStore(defaults: makeDefaults())
        store.set(AppVolume(volume: 0.4, muted: false), for: "x")
        store.set(.standard, for: "x")
        #expect(store.all["x"] == nil)
    }

    /// NaN would otherwise survive min/max (or become a full-volume gain) and be persisted.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteVolumeIsTreatedAsFull(_ volume: Double) {
        let store = MixerSettingsStore(defaults: makeDefaults())
        store.set(AppVolume(volume: 0.4, muted: false), for: "x")
        store.set(AppVolume(volume: volume, muted: false), for: "x")
        #expect(store.all["x"] == nil) // back to standard: untapped, normal sound
        store.set(AppVolume(volume: volume, muted: true), for: "y")
        #expect(store.setting(for: "y") == AppVolume(volume: 1, muted: true))
    }

    @Test func resetAndResetAll() {
        let store = MixerSettingsStore(defaults: makeDefaults())
        store.set(AppVolume(volume: 0.4, muted: false), for: "x")
        store.set(AppVolume(volume: 0.2, muted: true), for: "y")
        store.reset("x")
        #expect(store.all["x"] == nil)
        #expect(store.setting(for: "x") == .standard)
        #expect(store.all["y"] != nil)
        store.resetAll()
        #expect(store.all.isEmpty)
        #expect(store.setting(for: "y") == .standard)
    }

    @Test func gainCurve() {
        #expect(AppVolume(volume: 0.5, muted: false).gain == 0.25)
        #expect(AppVolume(volume: 1, muted: false).gain == 1)
        #expect(AppVolume(volume: 0, muted: false).gain == 0)
        #expect(AppVolume(volume: 0.8, muted: true).gain == 0)
    }

    @Test func volumeIsClamped() {
        let store = MixerSettingsStore(defaults: makeDefaults())
        store.set(AppVolume(volume: 1.4, muted: true), for: "hi")
        store.set(AppVolume(volume: -0.2, muted: false), for: "lo")
        #expect(store.setting(for: "hi").volume == 1.0)
        #expect(store.setting(for: "lo").volume == 0)
    }
}
