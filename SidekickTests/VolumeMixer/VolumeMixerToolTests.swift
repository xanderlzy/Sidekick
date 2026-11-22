import CoreAudio
import Foundation
import Testing
@testable import Sidekick

@MainActor
private final class FakeMenuBar: MixerMenuBar {
    private(set) var installs = 0, removes = 0
    private(set) var isInstalled = false
    func install() { installs += 1; isInstalled = true }
    func remove() { removes += 1; isInstalled = false }
}

@MainActor
struct VolumeMixerToolTests {
    private let defaults = UserDefaults(suiteName: "VolumeMixerToolTests-\(UUID())")!
    private let music = "com.apple.Music"

    private struct Rig {
        let tool: VolumeMixerTool
        let system: FakeAudioSystem
        let bar: FakeMenuBar
    }

    private func makeRig(stored: [String: AppVolume] = [:]) -> Rig {
        let store = MixerSettingsStore(defaults: defaults)
        for (key, value) in stored { store.set(value, for: key) }
        let system = FakeAudioSystem()
        system.processList = [AudioProcess(objectID: 108, pid: 2108, bundleID: music, isRunningOutput: true,
                                           outputDevices: [81])]
        system.apps = [RunningApp(pid: 2108, bundleID: music, name: "Music")]
        let bar = FakeMenuBar()
        let tool = VolumeMixerTool(defaults: defaults, system: system,
                                   permission: { [system] in await system.checkPermission() },
                                   menuBar: { _, _ in bar })
        return Rig(tool: tool, system: system, bar: bar)
    }

    @Test func identity() {
        let tool = makeRig().tool
        #expect(tool.id == "volumeMixer")
        #expect(tool.name == "Volume Mixer")
        #expect(tool.symbol == "speaker.wave.2")
        #expect(tool.summary == "Set each app's volume from the menu bar. Sidekick remembers it for next time.")
        #expect(tool.permissions == [.systemAudio])
        #expect(tool.setupSteps == [.systemAudio])
        #expect(tool.menuItems.isEmpty)
        #expect(tool.pages.map(\.id) == ["settings"])
        #expect(tool.pages.map(\.title) == ["Settings"])
    }

    @Test func startInstallsMenuBarAndStartsController() async {
        let rig = makeRig(stored: [music: AppVolume(volume: 0.5, muted: false)])
        defer { rig.tool.stop() }
        rig.tool.start()
        await rig.tool.controller.settle()
        #expect(rig.tool.isRunning)
        #expect(rig.bar.isInstalled)
        #expect(rig.system.listening)
        #expect(rig.system.liveTaps.count == 1)
    }

    @Test func stopLeavesNothingBehind() async {
        let rig = makeRig(stored: [music: AppVolume(volume: 0.5, muted: false)])
        rig.tool.start()
        await rig.tool.controller.settle()
        rig.tool.stop()
        #expect(!rig.tool.isRunning)
        #expect(!rig.bar.isInstalled)
        #expect(rig.system.liveTaps.isEmpty)
        #expect(!rig.system.listening)
        #expect(!rig.tool.controller.isPolling)
        #expect(MixerSettingsStore(defaults: defaults).all == [music: AppVolume(volume: 0.5, muted: false)])
    }

    @Test func startStopIdempotent() async {
        let rig = makeRig()
        rig.tool.start(); rig.tool.start()
        await rig.tool.controller.settle()
        #expect(rig.bar.installs == 1)
        rig.tool.stop(); rig.tool.stop()
        #expect(rig.bar.removes == 1)
        #expect(rig.system.stopListeningCount == 1)
    }

    @Test func stopBeforeStartIsHarmless() {
        let rig = makeRig()
        rig.tool.stop()
        #expect(rig.bar.removes == 0)
    }

    @Test func offByDefault() {
        let registry = ToolRegistry(tools: [makeRig().tool], defaults: defaults)
        #expect(!registry.isEnabled("volumeMixer"))
        #expect(registry.enabled.isEmpty)
    }

    @Test func resetThroughToolReleasesTapAndUpdatesStore() async {
        let rig = makeRig(stored: [music: AppVolume(volume: 0.5, muted: false)])
        defer { rig.tool.stop() }
        rig.tool.start()
        await rig.tool.controller.settle()
        rig.tool.controller.reset(music)
        await rig.tool.controller.settle()
        #expect(rig.system.liveTaps.isEmpty)
        #expect(rig.tool.store.all.isEmpty)
    }

    @Test func rememberedNames() {
        let rig = makeRig()
        #expect(RememberedVolume.name(for: AppGrouping.webContentKey) == "Web content")
        #expect(RememberedVolume.name(for: "no.such.bundle.id.zzz") == "no.such.bundle.id.zzz")
        #expect(RememberedVolume.name(for: "com.apple.finder") == "Finder")
        _ = rig
    }
}
