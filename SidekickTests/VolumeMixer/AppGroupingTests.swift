import CoreAudio
import Foundation
import Testing
@testable import Sidekick

struct AppGroupingTests {
    private let chrome = RunningApp(pid: 100, bundleID: "com.google.Chrome", name: "Chrome")
    private let music = RunningApp(pid: 200, bundleID: "com.apple.Music", name: "Music")
    private let own = "com.sidekick.app"

    private func proc(_ id: AudioObjectID, pid: pid_t, _ bundle: String?) -> AudioProcess {
        AudioProcess(objectID: id, pid: pid, bundleID: bundle, isRunningOutput: true)
    }

    private func group(_ procs: [AudioProcess], apps: [RunningApp]? = nil,
                       parents: [pid_t: pid_t] = [:]) -> [String: [AudioProcess]] {
        AppGrouping.group(processes: procs, apps: apps ?? [chrome, music], ownBundleID: own,
                          parentOf: { parents[$0] })
    }

    @Test func exactBundleMatch() {
        let p = proc(1, pid: 200, "com.apple.Music")
        #expect(group([p]) == ["com.apple.Music": [p]])
    }

    @Test func helperPrefixMatch() {
        let helper = proc(1, pid: 150, "com.google.Chrome.helper")
        let cast = proc(2, pid: 151, "com.google.Chromecast")
        let result = group([helper, cast])
        #expect(result == ["com.google.Chrome": [helper]])
    }

    /// Chrome's audio service ("Google Chrome Helper (Aperitif)", com.google.Chrome.helper) is itself
    /// listed as a running app; it must still fold into Chrome, not get its own row.
    @Test func helperListedAsARunningAppFoldsIntoItsParent() {
        let aperitif = RunningApp(pid: 150, bundleID: "com.google.Chrome.helper",
                                  name: "Google Chrome Helper (Aperitif)", isRegular: false)
        let helper = proc(1, pid: 150, "com.google.Chrome.helper")
        #expect(group([helper], apps: [chrome, aperitif, music]) == ["com.google.Chrome": [helper]])
    }

    @Test func regularAppExtendingAnotherKeepsItsOwnRow() {
        let canary = RunningApp(pid: 160, bundleID: "com.google.Chrome.canary", name: "Chrome Canary")
        let a = proc(1, pid: 100, "com.google.Chrome")
        let b = proc(2, pid: 160, "com.google.Chrome.canary")
        #expect(group([a, b], apps: [chrome, canary])
                == ["com.google.Chrome": [a], "com.google.Chrome.canary": [b]])
    }

    @Test func chromecastDoesNotFoldIntoChrome() {
        let cast = RunningApp(pid: 170, bundleID: "com.google.Chromecast", name: "Chromecast")
        let a = proc(1, pid: 100, "com.google.Chrome")
        let b = proc(2, pid: 170, "com.google.Chromecast")
        #expect(group([a, b], apps: [chrome, cast])
                == ["com.google.Chrome": [a], "com.google.Chromecast": [b]])
    }

    @Test func descendantByParentPID() {
        let p = proc(1, pid: 300, nil)
        let result = group([p], parents: [300: 250, 250: 100])
        #expect(result == ["com.google.Chrome": [p]])
    }

    @Test func ownProcessesExcluded() {
        let me = proc(1, pid: 5, own)
        let helper = proc(2, pid: 6, own + ".helper")
        let ownApp = RunningApp(pid: 5, bundleID: own, name: "Sidekick")
        #expect(group([me, helper], apps: [ownApp, chrome]).isEmpty)
    }

    @Test func unattributedWebContentGetsSyntheticKey() {
        let p = proc(1, pid: 400, "com.apple.WebKit.WebContent")
        #expect(group([p], parents: [400: 1]) == [AppGrouping.webContentKey: [p]])
    }

    /// Observed in the spike: Safari's audio comes from a GPU process whose parent is launchd.
    @Test func webKitGPUProcessGoesToWebContent() {
        let gpu = proc(1, pid: 49770, "com.apple.WebKit.GPU")
        let safari = RunningApp(pid: 49756, bundleID: "com.apple.Safari", name: "Safari")
        let result = group([gpu], apps: [safari], parents: [49770: 1])
        #expect(result == [AppGrouping.webContentKey: [gpu]])
    }

    @Test func unknownDaemonDropped() {
        let p = proc(1, pid: 500, "com.apple.systemsoundserverd")
        #expect(group([p], parents: [500: 1]).isEmpty)
    }

    @Test func parentLoopTerminates() {
        let p = proc(1, pid: 600, nil)
        #expect(group([p], parents: [600: 601, 601: 602, 602: 600]).isEmpty)
    }
}
