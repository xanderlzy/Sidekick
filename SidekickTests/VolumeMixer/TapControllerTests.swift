import CoreAudio
import Foundation
import Testing
@testable import Sidekick

@MainActor
struct TapControllerTests {
    private let music = "com.apple.Music"
    private let chrome = "com.google.Chrome"
    private let speakers: AudioDeviceID = 81
    private let headphones: AudioDeviceID = 90

    private func musicProcess(_ id: AudioObjectID = 108, bundle: String = "com.apple.Music",
                              playing: Bool = true, devices: [AudioObjectID] = [81]) -> AudioProcess {
        AudioProcess(objectID: id, pid: pid_t(id + 2000), bundleID: bundle, isRunningOutput: playing,
                     outputDevices: devices)
    }

    private func chromeProcess() -> AudioProcess {
        AudioProcess(objectID: 120, pid: 3100, bundleID: "com.google.Chrome.helper", isRunningOutput: true,
                     outputDevices: [81])
    }

    private struct Rig {
        let controller: TapController
        let system: FakeAudioSystem
        let store: MixerSettingsStore
        let defaults: UserDefaults
    }

    /// Music is playing on the speakers (81). Polling is effectively manual (`pollWatchdog()`).
    private func makeRig(stored: [String: AppVolume] = [:], start: Bool = true) async -> Rig {
        let defaults = UserDefaults(suiteName: "TapControllerTests-\(UUID())")!
        let store = MixerSettingsStore(defaults: defaults)
        for (key, value) in stored { store.set(value, for: key) }
        let system = FakeAudioSystem()
        system.processList = [musicProcess()]
        system.apps = [RunningApp(pid: 2108, bundleID: music, name: "Music"),
                       RunningApp(pid: 3000, bundleID: chrome, name: "Chrome")]
        let controller = TapController(system: system, store: store,
                                       permission: { [system] in await system.checkPermission() },
                                       pollInterval: .seconds(3600))
        if start {
            controller.start()
            await controller.settle()
        }
        return Rig(controller: controller, system: system, store: store, defaults: defaults)
    }

    private func lowered(_ rig: Rig, to volume: Double = 0.5) async -> FakeTap {
        rig.controller.setVolume(volume, for: music)
        await rig.controller.settle()
        return rig.system.liveTaps[0]
    }

    // MARK: Brief

    @Test func startTapsStoredNonStandardApps() async {
        let rig = await makeRig(stored: [music: AppVolume(volume: 0.5, muted: false)])
        #expect(rig.system.listening)
        #expect(rig.system.makeCalls == [.init(processes: [108], device: speakers, gain: 0.25)])
        #expect(rig.controller.activeTapKeys == [music])
    }

    @Test func untouchedAppNeverTapped() async {
        let rig = await makeRig()
        #expect(rig.system.makeCalls.isEmpty)
        #expect(rig.controller.rows.map(\.id) == [music])
        #expect(rig.controller.activeTapKeys.isEmpty)
    }

    @Test func lowerCreatesTapAtTargetGain() async {
        let rig = await makeRig()
        let tap = await lowered(rig)
        #expect(rig.system.makeCalls.count == 1)
        #expect(rig.system.makeCalls[0].gain == 0.25)
        #expect(tap.gain == 0.25)
        #expect(rig.controller.activeTapKeys == [music])
    }

    @Test func furtherChangesUpdateGainWithoutNewTap() async {
        let rig = await makeRig()
        let tap = await lowered(rig)
        rig.controller.setVolume(0.2, for: music)
        #expect(abs(tap.gain - 0.04) < 0.0001) // applied at once, not after a reconcile
        await rig.controller.settle()
        rig.controller.setVolume(0.8, for: music)
        await rig.controller.settle()
        #expect(abs(tap.gain - 0.64) < 0.0001)
        #expect(rig.system.makeCalls.count == 1)
    }

    @Test func backToDefaultReleasesTap() async {
        let rig = await makeRig()
        let tap = await lowered(rig)
        rig.controller.setVolume(1, for: music)
        await rig.controller.settle()
        #expect(tap.invalidated)
        #expect(rig.controller.activeTapKeys.isEmpty)
        #expect(rig.store.all.isEmpty)
        #expect(!rig.controller.isPolling)
    }

    @Test func muteTapsAtZeroAndUnmuteRestores() async {
        let rig = await makeRig()
        let tap = await lowered(rig)
        rig.controller.toggleMute(music)
        await rig.controller.settle()
        #expect(tap.gain == 0)
        #expect(rig.store.setting(for: music).muted)
        rig.controller.toggleMute(music)
        await rig.controller.settle()
        #expect(tap.gain == 0.25)
        #expect(!tap.invalidated)
        #expect(rig.system.makeCalls.count == 1)

        // Muting an untouched app taps it at 0; unmuting it releases it.
        rig.controller.setVolume(1, for: music)
        await rig.controller.settle()
        rig.controller.toggleMute(music)
        await rig.controller.settle()
        #expect(rig.system.liveTaps.map(\.gain) == [0])
        rig.controller.toggleMute(music)
        await rig.controller.settle()
        #expect(rig.system.liveTaps.isEmpty)
    }

    @Test func newHelperProcessJoinsTap() async {
        let rig = await makeRig()
        let tap = await lowered(rig)
        rig.system.processList.append(musicProcess(300, bundle: "com.apple.Music.helper"))
        rig.system.fireProcessesChanged()
        await rig.controller.settle()
        #expect(tap.setProcessesCalls == [[108, 300]])
        #expect(rig.system.makeCalls.count == 1)
        #expect(!tap.invalidated)
    }

    @Test func appQuitReleasesTap() async {
        let rig = await makeRig()
        let tap = await lowered(rig)
        rig.system.processList = []
        rig.system.apps.removeAll { $0.bundleID == music }
        rig.system.fireProcessesChanged()
        await rig.controller.settle()
        #expect(tap.invalidated)
        #expect(rig.controller.activeTapKeys.isEmpty)
        #expect(rig.controller.rows.isEmpty) // no processes, so the rules drop the row
        #expect(rig.store.setting(for: music).volume == 0.5)
    }

    @Test func deviceChangeRebuildsWithSameGain() async {
        let rig = await makeRig()
        let old = await lowered(rig)
        // The process can still report the old device when the default-device notification lands.
        rig.system.defaultDevice = headphones
        rig.system.fireDefaultDeviceChanged()
        await rig.controller.settle()
        let live = rig.system.liveTaps
        #expect(old.invalidated)
        #expect(live.count == 1)
        #expect(live.first?.device == headphones)
        #expect(live.first?.gain == 0.25)
        #expect(rig.system.makeCalls.last == .init(processes: [108], device: headphones, gain: 0.25))
        // New before old: the old (muting) tap holds the original silent until the new one is muted.
        #expect(rig.system.events == ["make 81", "make 90", "invalidate 1"])

        // The process catching up to the new device changes nothing.
        rig.system.processList = [musicProcess(devices: [headphones])]
        rig.system.fireProcessesChanged()
        await rig.controller.settle()
        #expect(rig.system.makeCalls.count == 2)
        #expect(rig.system.liveTaps.count == 1)
    }

    @Test func rebuildFailureReleasesAfterOneRetry() async {
        let rig = await makeRig()
        let old = await lowered(rig)
        rig.system.makeErrors = [MixerTapError.coreAudio("create tap", -1), MixerTapError.coreAudio("create tap", -1)]
        rig.system.defaultDevice = headphones
        rig.system.fireDefaultDeviceChanged()
        await rig.controller.settle()
        #expect(rig.system.makeCalls.map(\.device) == [speakers, headphones, headphones])
        #expect(old.invalidated)
        #expect(rig.system.liveTaps.isEmpty)
        #expect(rig.controller.activeTapKeys.isEmpty)
        #expect(rig.controller.notice == "Couldn't keep Music's volume on this device")

        // No retry storm on later events for the same device and processes.
        rig.system.fireProcessesChanged()
        await rig.controller.settle()
        #expect(rig.system.makeCalls.count == 3)

        // The notice clears once the key no longer wants a tap.
        rig.controller.setVolume(1, for: music)
        await rig.controller.settle()
        #expect(rig.controller.notice == nil)
    }

    @Test func noticeClearsOnNextSuccess() async {
        let rig = await makeRig()
        _ = await lowered(rig)
        rig.system.makeErrors = [MixerTapError.unsupportedLayout, MixerTapError.unsupportedLayout]
        rig.system.defaultDevice = headphones
        rig.system.fireDefaultDeviceChanged()
        await rig.controller.settle()
        #expect(rig.controller.notice != nil)
        rig.system.defaultDevice = speakers
        rig.system.fireDefaultDeviceChanged()
        await rig.controller.settle()
        #expect(rig.controller.activeTapKeys == [music])
        #expect(rig.controller.notice == nil)
    }

    @Test(arguments: [SystemAudioState.denied, .notPrompted])
    func tapCreationFailureMarksPermission(_ state: SystemAudioState) async {
        let rig = await makeRig()
        rig.system.processList.append(chromeProcess())
        rig.system.fireProcessesChanged()
        let musicTap = await lowered(rig)
        rig.system.makeErrors = [MixerTapError.permission(state)]
        rig.controller.setVolume(0.3, for: chrome)
        await rig.controller.settle()
        #expect(rig.controller.needsPermission)
        #expect(musicTap.invalidated)
        #expect(rig.system.liveTaps.isEmpty)
        #expect(rig.store.setting(for: chrome).volume == 0.3)
        #expect(rig.store.setting(for: music).volume == 0.5)
        #expect(rig.system.makeCalls.count == 2) // no retry against a definite answer
        #expect(!rig.controller.isPolling)

        // Listener events don't hammer the gate while permission is missing.
        rig.system.fireProcessesChanged()
        await rig.controller.settle()
        #expect(rig.system.makeCalls.count == 2)
    }

    @Test func permissionRecoveredOnRefresh() async {
        let rig = await makeRig()
        rig.system.makeErrors = [MixerTapError.permission(.denied)]
        rig.controller.setVolume(0.5, for: music)
        await rig.controller.settle()
        #expect(rig.controller.needsPermission)
        rig.system.permissionState = .denied
        rig.controller.refresh()
        await rig.controller.settle()
        #expect(rig.controller.needsPermission)
        #expect(rig.system.makeCalls.count == 1)
        rig.system.permissionState = .granted
        rig.controller.refresh()
        await rig.controller.settle()
        #expect(!rig.controller.needsPermission)
        #expect(rig.controller.activeTapKeys == [music])
    }

    @Test func stopReleasesEverything() async {
        let rig = await makeRig(stored: [music: AppVolume(volume: 0.5, muted: false),
                                         chrome: AppVolume(volume: 0.2, muted: true)])
        rig.system.processList.append(chromeProcess())
        rig.system.fireProcessesChanged()
        await rig.controller.settle()
        #expect(rig.system.liveTaps.count == 2)
        rig.controller.stop()
        #expect(rig.system.liveTaps.isEmpty)
        #expect(!rig.system.listening)
        #expect(rig.controller.activeTapKeys.isEmpty)
        #expect(!rig.controller.isPolling)
        #expect(rig.store.all.count == 2)
        rig.controller.stop() // idempotent
        #expect(rig.system.stopListeningCount == 1)
    }

    @Test func settingsPersistThroughController() async {
        let rig = await makeRig()
        rig.controller.setVolume(0.3, for: music)
        rig.controller.toggleMute(music)
        let reloaded = MixerSettingsStore(defaults: rig.defaults)
        #expect(reloaded.setting(for: music) == AppVolume(volume: 0.3, muted: true))
    }

    @Test func otherDeviceAppNotTapped() async {
        let rig = await makeRig()
        rig.system.processList = [musicProcess(devices: [57])]
        rig.system.fireProcessesChanged()
        rig.controller.setVolume(0.5, for: music)
        await rig.controller.settle()
        #expect(rig.system.makeCalls.isEmpty)
        #expect(rig.controller.rows.first?.playsElsewhere == true)
    }

    @Test func otherDeviceReleasesExistingTap() async {
        let rig = await makeRig()
        let tap = await lowered(rig)
        rig.system.processList = [musicProcess(devices: [57])]
        rig.system.fireProcessesChanged()
        await rig.controller.settle()
        #expect(tap.invalidated)
        #expect(rig.controller.rows.first?.playsElsewhere == true)
    }

    // MARK: Controller rulings

    @Test func noDefaultOutputNoTaps() async {
        let rig = await makeRig(stored: [music: AppVolume(volume: 0.5, muted: false)], start: false)
        rig.system.defaultDevice = nil
        rig.controller.start()
        await rig.controller.settle()
        #expect(rig.system.makeCalls.isEmpty)
        #expect(rig.controller.rows.map(\.id) == [music])
        rig.system.defaultDevice = speakers
        rig.system.fireDefaultDeviceChanged()
        await rig.controller.settle()
        #expect(rig.controller.activeTapKeys == [music])
    }

    @Test func requestsDuringCreateCoalesceIntoOneTap() async {
        let rig = await makeRig()
        rig.system.holdCreates = true
        rig.controller.setVolume(0.5, for: music)
        await rig.system.waitForHeldCreate()
        #expect(rig.system.heldCount == 1)
        rig.controller.setVolume(0.3, for: music)
        rig.system.fireProcessesChanged()
        rig.controller.setVolume(0.2, for: music)
        rig.system.releaseHeld()
        await rig.controller.settle()
        #expect(rig.system.makeCalls.count == 1)
        #expect(rig.system.liveTaps.count == 1)
        #expect(abs(rig.system.liveTaps[0].gain - 0.04) < 0.0001)
    }

    @Test func backToDefaultDuringCreateReleasesArrival() async {
        let rig = await makeRig()
        rig.system.holdCreates = true
        rig.controller.setVolume(0.5, for: music)
        await rig.system.waitForHeldCreate()
        rig.controller.setVolume(1, for: music)
        rig.system.releaseHeld()
        await rig.controller.settle()
        #expect(rig.system.taps.count == 1)
        #expect(rig.system.liveTaps.isEmpty)
        #expect(rig.controller.activeTapKeys.isEmpty)
    }

    @Test func stopDuringCreateInvalidatesArrival() async {
        let rig = await makeRig()
        rig.system.holdCreates = true
        rig.controller.setVolume(0.5, for: music)
        await rig.system.waitForHeldCreate()
        rig.controller.stop()
        rig.system.releaseHeld()
        await rig.controller.settle()
        #expect(rig.system.taps.count == 1)
        #expect(rig.system.liveTaps.isEmpty)
        #expect(rig.controller.activeTapKeys.isEmpty)
    }

    @Test func unknownPermissionOnCreateRetriesOnceOnNextPoll() async {
        let rig = await makeRig()
        rig.system.makeErrors = [MixerTapError.permission(.unknown), MixerTapError.permission(.unknown)]
        rig.controller.setVolume(0.5, for: music)
        await rig.controller.settle()
        #expect(!rig.controller.needsPermission)
        #expect(rig.system.makeCalls.count == 1)
        #expect(rig.controller.isPolling)
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        #expect(rig.system.makeCalls.count == 2)
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        #expect(rig.system.makeCalls.count == 2) // once only
        #expect(!rig.controller.isPolling)
        // The next real event tries again.
        rig.system.fireProcessesChanged()
        await rig.controller.settle()
        #expect(rig.controller.activeTapKeys == [music])
        #expect(!rig.controller.needsPermission)
    }

    @Test func unknownPermissionDuringRebuildCountsAsAFailedAttempt() async {
        let rig = await makeRig()
        let old = await lowered(rig)
        rig.system.makeErrors = [MixerTapError.permission(.unknown), nil]
        rig.system.defaultDevice = headphones
        rig.system.fireDefaultDeviceChanged()
        await rig.controller.settle()
        #expect(!rig.controller.needsPermission)
        #expect(old.invalidated)
        #expect(rig.system.liveTaps.map(\.device) == [headphones])
    }

    @Test func watchdogGrantedAcknowledgesSilence() async {
        let rig = await makeRig()
        let tap = await lowered(rig)
        tap.looksRevoked = true
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        #expect(rig.system.permissionChecks == 1)
        #expect(tap.acknowledgeCount == 1)
        #expect(!tap.invalidated)
    }

    @Test(arguments: [SystemAudioState.denied, .notPrompted])
    func watchdogNotGrantedTearsDown(_ state: SystemAudioState) async {
        let rig = await makeRig()
        let tap = await lowered(rig)
        tap.looksRevoked = true
        rig.system.permissionState = state
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        #expect(tap.invalidated)
        #expect(rig.controller.needsPermission)
        #expect(rig.store.setting(for: music).volume == 0.5)
        #expect(!rig.controller.isPolling)
    }

    @Test func watchdogUnknownKeepsTapsAndRetries() async {
        let rig = await makeRig()
        let tap = await lowered(rig)
        tap.looksRevoked = true
        rig.system.permissionState = .unknown
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        #expect(!tap.invalidated)
        #expect(!rig.controller.needsPermission)
        #expect(tap.acknowledgeCount == 0)
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        #expect(rig.system.permissionChecks == 2)
        rig.system.permissionState = .granted
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        #expect(tap.acknowledgeCount == 1)
    }

    @Test func periodicPermissionCheckEvery30Polls() async {
        let rig = await makeRig()
        _ = await lowered(rig)
        for _ in 0..<29 { rig.controller.pollWatchdog(); await rig.controller.settle() }
        #expect(rig.system.permissionChecks == 0)
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        #expect(rig.system.permissionChecks == 1)
    }

    @Test func processChangeAfterAcknowledgedSilenceProbes() async {
        let rig = await makeRig()
        let tap = await lowered(rig)
        tap.looksRevoked = true
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        #expect(rig.system.permissionChecks == 1)
        // Music's state changes (e.g. playback resumes) while its tap sits in acknowledged silence.
        rig.system.processList = [musicProcess(playing: false, devices: [])]
        rig.system.permissionState = .denied
        rig.system.fireProcessesChanged()
        await rig.controller.settle()
        #expect(rig.system.permissionChecks == 2)
        #expect(tap.invalidated)
        #expect(rig.controller.needsPermission)
    }

    @Test func audioHeardEndsAcknowledgedSilence() async {
        let rig = await makeRig()
        let tap = await lowered(rig)
        tap.looksRevoked = true
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        tap.level = 0.4
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        rig.system.processList = [musicProcess(playing: false, devices: [])]
        rig.system.fireProcessesChanged()
        await rig.controller.settle()
        #expect(rig.system.permissionChecks == 1)
    }

    @Test func faultedTapIsRebuilt() async {
        let rig = await makeRig()
        let old = await lowered(rig)
        old.hasFault = true
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        #expect(old.invalidated)
        #expect(rig.system.liveTaps.map(\.gain) == [0.25])
        #expect(rig.system.events == ["make 81", "make 81", "invalidate 1"])
    }

    @Test func repeatedFaultReleasesWithNotice() async {
        let rig = await makeRig()
        let first = await lowered(rig)
        first.hasFault = true
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        let second = rig.system.liveTaps[0]
        second.hasFault = true
        rig.controller.pollWatchdog()
        await rig.controller.settle()
        #expect(second.invalidated)
        #expect(rig.system.liveTaps.isEmpty)
        #expect(rig.system.makeCalls.count == 2)
        #expect(rig.controller.notice == "Couldn't keep Music's volume on this device")
    }

    @Test func setProcessesFailureRebuilds() async {
        let rig = await makeRig()
        let old = await lowered(rig)
        old.setProcessesError = MixerTapError.coreAudio("update tap", -1)
        rig.system.processList.append(musicProcess(300, bundle: "com.apple.Music.helper"))
        rig.system.fireProcessesChanged()
        await rig.controller.settle()
        #expect(old.invalidated)
        #expect(rig.system.liveTaps.map(\.processes) == [[108, 300]])
    }

    @Test func levelIsScaledByGain() async {
        let rig = await makeRig()
        #expect(rig.controller.level(for: music) == nil)
        let tap = await lowered(rig)
        tap.level = 0.8
        #expect(abs((rig.controller.level(for: music) ?? -1) - 0.2) < 0.0001)
        rig.controller.toggleMute(music)
        #expect(rig.controller.level(for: music) == 0)
    }

    @Test func pollsOnlyWhileTapsExist() async {
        let rig = await makeRig()
        #expect(!rig.controller.isPolling)
        _ = await lowered(rig)
        #expect(rig.controller.isPolling)
        rig.controller.setVolume(1, for: music)
        await rig.controller.settle()
        #expect(!rig.controller.isPolling)
    }
}
