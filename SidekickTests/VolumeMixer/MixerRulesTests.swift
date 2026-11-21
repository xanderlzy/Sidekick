import CoreAudio
import Foundation
import Testing
@testable import Sidekick

struct MixerRulesTests {
    private let music = RunningApp(pid: 200, bundleID: "com.apple.Music", name: "Music")
    private let chrome = RunningApp(pid: 100, bundleID: "com.google.Chrome", name: "Chrome")
    private let quiet = AppVolume(volume: 0.5, muted: false)
    private let speakers: AudioObjectID = 81
    private let other: AudioObjectID = 57

    private func proc(_ id: AudioObjectID, playing: Bool = true,
                      devices: [AudioObjectID] = []) -> AudioProcess {
        AudioProcess(objectID: id, pid: pid_t(id), bundleID: nil, isRunningOutput: playing,
                     outputDevices: devices)
    }

    private func rows(_ groups: [String: [AudioProcess]], apps: [RunningApp]? = nil,
                      settings: [String: AppVolume] = [:]) -> [MixerRow] {
        MixerRules.rows(groups: groups, apps: apps ?? [music, chrome], settings: settings,
                        defaultOutput: speakers)
    }

    private func targets(_ groups: [String: [AudioProcess]], settings: [String: AppVolume],
                         defaultOutput: AudioObjectID? = 81) -> [String: [AudioObjectID]] {
        MixerRules.tapTargets(groups: groups, settings: settings, defaultOutput: defaultOutput)
    }

    @Test func playingAppShows() {
        let r = rows(["com.apple.Music": [proc(1)]])
        #expect(r.map(\.id) == ["com.apple.Music"])
        #expect(r[0].isPlaying)
        #expect(r[0].name == "Music")
        #expect(r[0].setting == .standard)
    }

    @Test func changedRunningAppShowsWhenSilent() {
        let r = rows(["com.apple.Music": [proc(1, playing: false)]],
                     settings: ["com.apple.Music": quiet])
        #expect(r.map(\.id) == ["com.apple.Music"])
        #expect(!r[0].isPlaying)
        #expect(r[0].setting == quiet)
    }

    @Test func standardSilentAppHidden() {
        #expect(rows(["com.apple.Music": [proc(1, playing: false)]]).isEmpty)
    }

    @Test func rowsSortedByName() {
        let apps = [RunningApp(pid: 1, bundleID: "a", name: "App 10"),
                    RunningApp(pid: 2, bundleID: "b", name: "App 2"),
                    RunningApp(pid: 3, bundleID: "c", name: "app 1")]
        let allPlaying = ["a": [proc(1)], "b": [proc(2)], "c": [proc(3)]]
        #expect(rows(allPlaying, apps: apps).map(\.name) == ["app 1", "App 2", "App 10"])
        let someSilent = ["a": [proc(1, playing: false)], "b": [proc(2)], "c": [proc(3, playing: false)]]
        let s = ["a": quiet, "c": quiet]
        #expect(rows(someSilent, apps: apps, settings: s).map(\.name) == ["app 1", "App 2", "App 10"])
    }

    @Test func webContentRowTitled() {
        let r = rows([AppGrouping.webContentKey: [proc(1)]])
        #expect(r.map(\.name) == ["Web content"])
    }

    @Test func tapTargetsOnlyNonStandard() {
        let g = ["com.apple.Music": [proc(1)], "com.google.Chrome": [proc(2)]]
        #expect(targets(g, settings: ["com.google.Chrome": quiet]) == ["com.google.Chrome": [2]])
    }

    @Test func tapTargetsIncludeAllProcessesOfGroup() {
        let g = ["com.apple.Music": [proc(1), proc(2, playing: false)]]
        #expect(targets(g, settings: ["com.apple.Music": quiet])["com.apple.Music"] == [1, 2])
    }

    @Test func nonStandardButNoProcessesNoTarget() {
        #expect(targets(["com.apple.Music": []], settings: ["com.apple.Music": quiet]).isEmpty)
        #expect(targets([:], settings: ["com.apple.Music": quiet]).isEmpty)
    }

    @Test func otherDeviceAppNotTapped() {
        let g = ["com.apple.Music": [proc(1, devices: [other])]]
        let s = ["com.apple.Music": quiet]
        #expect(targets(g, settings: s).isEmpty)
        let r = MixerRules.rows(groups: g, apps: [music], settings: s, defaultOutput: speakers)
        #expect(r[0].playsElsewhere)
    }

    @Test func defaultPlusOtherDeviceNotTapped() {
        let g = ["com.apple.Music": [proc(1, devices: [speakers, other])]]
        #expect(targets(g, settings: ["com.apple.Music": quiet]).isEmpty)
    }

    @Test func emptyDevicesStillTapped() {
        let g = ["com.apple.Music": [proc(1, devices: [speakers]), proc(2, playing: false, devices: [])]]
        let t = targets(g, settings: ["com.apple.Music": quiet])
        #expect(t["com.apple.Music"] == [1, 2])
        let r = rows(g, settings: ["com.apple.Music": quiet])
        #expect(!r[0].playsElsewhere)
    }

    @Test func noDefaultOutputNoTargets() {
        let g = ["com.apple.Music": [proc(1)]]
        #expect(targets(g, settings: ["com.apple.Music": quiet], defaultOutput: nil).isEmpty)
    }
}
