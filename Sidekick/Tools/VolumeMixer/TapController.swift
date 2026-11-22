import CoreAudio
import Foundation
import Observation
import os

/// Keeps one tap per app that needs one, in step with settings, processes, the default output
/// device and the permission. All Core Audio goes through `AudioSystem`; tests use fakes.
///
/// Tap work is asynchronous (`makeTap` is async), so it runs in one serialized worker: at most one
/// reconcile is in flight, and requests made meanwhile coalesce into a single re-run. Results that
/// arrive after `stop()` (or a `start()` since) are invalidated on arrival.
@MainActor @Observable
final class TapController {
    typealias PermissionCheck = @MainActor () async -> SystemAudioState

    private(set) var rows: [MixerRow] = []
    /// Definitely not granted (`.denied` / `.notPrompted`). Every tap is down; settings are kept.
    private(set) var needsPermission = false
    /// One line about a failure, e.g. "Couldn't keep Music's volume on this device".
    var notice: String? { notices.keys.sorted().first.flatMap { notices[$0] } }
    private var notices: [String: String] = [:]

    var activeTapKeys: Set<String> { Set(taps.keys) }
    /// True while the ~1 Hz watchdog runs (only while taps exist, or one `unknown` retry is due).
    var isPolling: Bool { poller != nil }

    @ObservationIgnored private let system: any AudioSystem
    @ObservationIgnored private let store: MixerSettingsStore
    @ObservationIgnored private let permission: PermissionCheck
    @ObservationIgnored private let isGrantedRecently: @MainActor () -> Bool
    @ObservationIgnored private let ownBundleID: String
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let log = Logger(subsystem: "com.sidekick.app", category: "VolumeMixer")

    /// Polls between the backup permission checks (Task 4 contract: every 30 s while taps exist).
    static let periodicCheckPolls = 30
    /// Only polls while some tap has had IO this recently count toward `periodicCheckPolls`: the
    /// probe opens the default output (waking Bluetooth/USB devices), and an idle tap mutes nothing
    /// audible. Revocation while idle is still caught: a resumed app's zero input trips the watchdog.
    static let activeIOWindow: TimeInterval = 30
    /// A tap released for "plays to another device" this soon after creation counts as a flap.
    static let flapWindow: TimeInterval = 10
    /// The second flap within the window stops the key being tapped on that device.
    static let flapLimit = 2
    /// How long a rebuilt process may keep reporting the previous device before it counts as
    /// really playing there.
    static let lagWindow: TimeInterval = 5
    /// A tap that stays healthy this long forgets an earlier fault.
    static let healthyAfter: TimeInterval = 30

    private struct ActiveTap {
        let handle: any TapHandle
        var processes: [AudioObjectID]
        let device: AudioDeviceID
        let createdAt: Date
    }

    /// A create/rebuild that failed twice (or flapped); not retried until the device or the
    /// processes change, or the key stops wanting a tap.
    private struct FailedAttempt: Equatable {
        let device: AudioDeviceID
        let processes: Set<AudioObjectID>
    }

    /// Processes of a rebuilt key that may still report the device the old tap was on. Only time
    /// spent outputting counts toward `lagWindow`: a paused app can keep its old `Devices` until it
    /// restarts IO, and releasing it then would make it play at full volume when resumed.
    private struct Lag {
        let device: AudioDeviceID
        var processes: Set<AudioObjectID>
        var runningSince: [AudioObjectID: Date] = [:]
    }

    /// What a reconcile decides from. An identical input after a completed reconcile is a no-op.
    private struct ReconcileInput: Equatable {
        let groups: [String: [AudioProcess]]
        let defaultOutput: AudioDeviceID?
        let settings: [String: AppVolume]
        let elsewhere: Set<String>
    }

    private enum UnknownRetry { case none, scheduled, spent }

    // Snapshot of the world, re-read by `refresh()` and the listeners.
    @ObservationIgnored private var running = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var apps: [RunningApp] = []
    @ObservationIgnored private var groups: [String: [AudioProcess]] = [:]
    @ObservationIgnored private var defaultOutput: AudioDeviceID?
    /// Keys seen playing to another device this session (spike §4). Not tapped until one of their
    /// processes reports exactly the default output, so a stopped app (empty `Devices`) isn't
    /// pre-tapped and pulled to the default on its next start. Kept across stop/start.
    @ObservationIgnored private var elsewhere: Set<String> = []

    // Taps and their bookkeeping. Only the worker (and `stop()`) changes `taps`.
    @ObservationIgnored private var taps: [String: ActiveTap] = [:]
    @ObservationIgnored private var failed: [String: FailedAttempt] = [:]
    @ObservationIgnored private var rebuildKeys: Set<String> = []
    @ObservationIgnored private var acknowledged: Set<String> = []
    /// Keys whose tap faulted on this device already; a second fault releases instead of rebuilding.
    @ObservationIgnored private var faultedOn: [String: AudioDeviceID] = [:]
    @ObservationIgnored private var flaps: [String: Int] = [:]
    @ObservationIgnored private var lagging: [String: Lag] = [:]
    /// Keys whose lag just expired; their "plays elsewhere" release isn't a flap.
    @ObservationIgnored private var lagExpired: Set<String> = []
    @ObservationIgnored private var unknownRetry = UnknownRetry.none
    @ObservationIgnored private var polls = 0

    // The serialized worker.
    @ObservationIgnored private var reconcileRequested = false
    @ObservationIgnored private var forceReconcile = false
    @ObservationIgnored private var lastInput: ReconcileInput?
    @ObservationIgnored private var watchdogRequested = false
    @ObservationIgnored private var probeRequested = false
    /// Ask the (non-prompting) permission check before the next reconcile: on start, and on a
    /// refresh without a fresh grant. Answers `.notPrompted` without Core Audio before Grant.
    @ObservationIgnored private var permissionCheckRequested = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var retired: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var poller: Task<Void, Never>?

    init(system: any AudioSystem,
         store: MixerSettingsStore,
         permission: @escaping PermissionCheck = { await SystemAudioPermission.check(maxAge: 0) },
         isGrantedRecently: @escaping @MainActor () -> Bool = { SystemAudioPermission.isGrantedRecently },
         ownBundleID: String = Bundle.main.bundleIdentifier ?? "com.sidekick.app",
         pollInterval: Duration = .seconds(1),
         now: @escaping () -> Date = Date.init) {
        self.system = system
        self.store = store
        self.permission = permission
        self.isGrantedRecently = isGrantedRecently
        self.ownBundleID = ownBundleID
        self.pollInterval = pollInterval
        self.now = now
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        system.startListening(
            onProcessesChanged: { [weak self] in self?.processesChanged() },
            onDefaultDeviceChanged: { [weak self] in self?.worldChanged() })
        // The permission verdict lives in memory only, so after a relaunch nothing knows it until a
        // check runs (spike §3: probe on tool start). Without it, a not-granted user would see
        // working-looking sliders instead of the "needs System Audio Recording" line.
        permissionCheckRequested = true
        refresh()
    }

    /// Releases every tap (apps return to normal sound), removes the listeners and drops any
    /// in-flight work. Stored settings are kept.
    func stop() {
        guard running else { return }
        running = false
        generation += 1
        system.stopListening()
        if let worker {
            worker.cancel()
            retired[generation - 1] = worker
        }
        worker = nil
        for tap in taps.values { tap.handle.invalidate() }
        taps.removeAll()
        failed.removeAll()
        rebuildKeys.removeAll()
        acknowledged.removeAll()
        faultedOn.removeAll()
        flaps.removeAll()
        lagging.removeAll()
        lagExpired.removeAll()
        unknownRetry = .none
        reconcileRequested = false
        forceReconcile = false
        lastInput = nil
        watchdogRequested = false
        probeRequested = false
        permissionCheckRequested = false
        polls = 0
        notices.removeAll()
        needsPermission = false
        rows = []
        updatePolling()
    }

    /// Re-reads processes, apps and the default device, recomputes rows and reconciles taps.
    /// Also re-checks the permission when it was missing (e.g. the panel opened after Grant) or
    /// isn't freshly confirmed (e.g. switched off in System Settings since).
    func refresh() {
        guard running else { return }
        if needsPermission || !isGrantedRecently() { permissionCheckRequested = true }
        forceReconcile = true
        worldChanged()
    }

    /// Waits until no tap work is in flight. For tests and callers that need a settled state.
    func settle() async {
        while true {
            let pending = Array(retired.values) + (worker.map { [$0] } ?? [])
            if pending.isEmpty { return }
            for task in pending { await task.value }
        }
    }

    // MARK: - Settings

    func setVolume(_ volume: Double, for key: String) {
        var setting = store.setting(for: key)
        setting.volume = volume
        apply(setting, for: key)
    }

    func toggleMute(_ key: String) {
        var setting = store.setting(for: key)
        setting.muted.toggle()
        apply(setting, for: key)
    }

    /// Forgets one app's remembered volume; a live tap is released by the reconcile.
    func reset(_ key: String) {
        store.reset(key)
        settingsChanged()
    }

    func resetAll() {
        store.resetAll()
        settingsChanged()
    }

    private func settingsChanged() {
        guard running else { return }
        updateRows()
        requestReconcile()
    }

    /// The tap's input peak scaled by the current gain, so it shows what's heard. Nil when untapped.
    func level(for key: String) -> Float? {
        guard let tap = taps[key] else { return nil }
        return tap.handle.level * store.setting(for: key).gain
    }

    private func apply(_ setting: AppVolume, for key: String) {
        store.set(setting, for: key)
        // A live tap follows at once (the IO ramps it); a reconcile creates or releases taps.
        taps[key]?.handle.setGain(store.setting(for: key).gain)
        guard running else { return }
        updateRows()
        requestReconcile()
    }

    // MARK: - Events

    private func worldChanged() {
        guard running else { return }
        snapshot()
        requestReconcile()
    }

    private func processesChanged() {
        guard running else { return }
        let before = groups
        snapshot()
        // A tap in acknowledged silence can't see a revocation (input stays zero), so when that
        // app's processes change (it starts/stops playing, switches device) probe right away instead
        // of waiting out the watchdog backoff (≤ 30 s).
        if acknowledged.contains(where: { before[$0] != groups[$0] }) {
            probeRequested = true
            watchdogRequested = true
        }
        requestReconcile()
    }

    private func snapshot() {
        defaultOutput = system.defaultOutputDevice()
        apps = system.runningApps()
        let system = self.system
        groups = AppGrouping.group(processes: system.processes(), apps: apps, ownBundleID: ownBundleID,
                                   parentOf: { system.parent(of: $0) })
        pruneLagging()
        updateElsewhere()
        updateRows()
    }

    private func requestReconcile() {
        reconcileRequested = true
        // A real event earns a fresh `unknown` retry.
        if unknownRetry != .scheduled { unknownRetry = .none }
        schedule()
    }

    /// One watchdog round: faults, revocation, the periodic permission check, the `unknown` retry.
    func pollWatchdog() {
        guard running else { return }
        watchdogRequested = true
        schedule()
    }

    // MARK: - Worker

    private func schedule() {
        guard running, worker == nil else { return }
        let gen = generation
        worker = Task { [weak self] in await self?.drain(gen) }
    }

    private func drain(_ gen: Int) async {
        var lastWasWatchdog = false
        while generation == gen {
            if permissionCheckRequested {
                permissionCheckRequested = false
                await checkPermission(gen)
                continue
            }
            // Alternate when both are pending, so a slow probe plus the 1 Hz poller can't starve
            // a reconcile (e.g. a device-change rebuild).
            if watchdogRequested, !(lastWasWatchdog && reconcileRequested) {
                watchdogRequested = false
                lastWasWatchdog = true
                await watchdog(gen)
            } else if reconcileRequested {
                reconcileRequested = false
                lastWasWatchdog = false
                await reconcile(gen)
            } else {
                break
            }
        }
        if generation == gen {
            worker = nil
            updateRows()
            updatePolling()
        } else {
            retired[gen] = nil
        }
    }

    private func reconcile(_ gen: Int) async {
        let input = ReconcileInput(groups: groups, defaultOutput: defaultOutput, settings: store.all,
                                   elsewhere: elsewhere)
        // Core Audio fires duplicate notifications; an unchanged world needs no second pass.
        guard forceReconcile || !rebuildKeys.isEmpty || input != lastInput else { return }
        forceReconcile = false
        lastInput = input
        // Only an explicit refresh (or start) re-asks; listener events would just hammer the probe.
        // A granted answer forces the next reconcile.
        guard !needsPermission else { return }

        let wanted = targets()
        for key in taps.keys where wanted[key] == nil { release(key, reason: .unwanted) }
        // Forget failures once the key stops wanting a tap in the user's sense (back to 100%, or
        // the app is gone) — not merely while it plays elsewhere, or the flap breaker would reset.
        for key in Set(failed.keys).union(notices.keys).union(faultedOn.keys).union(flaps.keys)
        where store.setting(for: key).isStandard || groups[key] == nil {
            failed[key] = nil
            notices[key] = nil
            faultedOn[key] = nil
            flaps[key] = nil
        }
        for key in wanted.keys.sorted() {
            // Each step can await; re-read what's wanted so a change made meanwhile wins. A skipped
            // or aborted step means this pass didn't fully apply `input`, so don't dedupe against it.
            guard generation == gen, !needsPermission else { lastInput = nil; return }
            guard let ids = targets()[key], let device = defaultOutput else { lastInput = nil; continue }
            await reconcile(key, processes: ids, device: device, gen: gen)
        }
    }

    private func reconcile(_ key: String, processes ids: [AudioObjectID], device: AudioDeviceID, gen: Int) async {
        guard let tap = taps[key] else {
            if failed[key] == FailedAttempt(device: device, processes: Set(ids)) { return }
            await build(key, processes: ids, device: device, replacing: nil, gen: gen)
            return
        }
        if tap.device == device, !rebuildKeys.contains(key) {
            if Set(tap.processes) != Set(ids) {
                do {
                    try tap.handle.setProcesses(ids)
                    taps[key]?.processes = ids
                } catch {
                    log.error("Tap process update failed: \(String(describing: error), privacy: .public)")
                    rebuildKeys.insert(key)
                }
            }
            if !rebuildKeys.contains(key) {
                tap.handle.setGain(store.setting(for: key).gain)
                failed[key] = nil
                notices[key] = nil
                return
            }
        }
        await build(key, processes: ids, device: device, replacing: tap, gen: gen)
    }

    /// Creates a tap, retrying once. When replacing, the new tap is created **before** the old one is
    /// invalidated: the old tap keeps the original muted (its copy plays at the same gain on the old
    /// device), and the new one starts unmuted at gain 0, mutes, then ramps up. Invalidating first
    /// would play the app at full volume on the new device for the whole setup (≥ 50 ms, up to
    /// seconds) — a burst. The two copies overlap only briefly (until the old tap is invalidated
    /// right after the new one is live), and on a device change they go to different devices.
    private func build(_ key: String, processes ids: [AudioObjectID], device: AudioDeviceID,
                       replacing old: ActiveTap?, gen: Int) async {
        rebuildKeys.remove(key)
        for attempt in 1...2 {
            do {
                let handle = try await system.makeTap(processes: ids, device: device,
                                                      gain: store.setting(for: key).gain)
                guard generation == gen else { handle.invalidate(); return }
                guard targets()[key] != nil else {
                    // No longer wanted (e.g. back to 100%); the queued re-run releases the old one.
                    handle.invalidate()
                    lastInput = nil
                    return
                }
                handle.setGain(store.setting(for: key).gain)
                old?.handle.invalidate()
                taps[key] = ActiveTap(handle: handle, processes: ids, device: device, createdAt: now())
                lagExpired.remove(key)
                if let old, old.device != device {
                    lagging[key] = Lag(device: old.device, processes: Set(ids))
                    pruneLagging()
                }
                acknowledged.remove(key)
                failed[key] = nil
                notices[key] = nil
                updatePolling()
                return
            } catch {
                guard generation == gen else { return }
                log.error("Tap for \(key, privacy: .public) failed (attempt \(attempt)): \(String(describing: error), privacy: .public)")
                if error is CancellationError { return }
                if case MixerTapError.permission(let state) = error {
                    if state == .denied || state == .notPrompted {
                        revoke()
                        return
                    }
                    // `.unknown` never tears down. A fresh create just leaves the app at normal
                    // sound and retries once on the next poll; a rebuild counts it as a failed
                    // attempt, since the old tap is on a device the app no longer plays to.
                    if state == .unknown, old == nil {
                        if unknownRetry == .none { unknownRetry = .scheduled }
                        updatePolling()
                        return
                    }
                }
            }
        }
        // Both attempts failed: release to normal sound, say so, and don't retry on this device.
        if let old, let current = taps[key], current.handle === old.handle {
            release(key, reason: .failed)
        }
        markFailed(key, device: device, processes: ids)
    }

    /// The start / refresh check. Definitely not granted: release everything and show the line.
    private func checkPermission(_ gen: Int) async {
        let state = await permission()
        guard generation == gen else { return }
        switch state {
        case .granted:
            guard needsPermission else { return }
            needsPermission = false
            failed.removeAll()
            requestForcedReconcile()
        case .denied, .notPrompted:
            revoke()
        case .unknown:
            break // the gate before each muting tap decides; never tear down on unknown
        }
    }

    private func watchdog(_ gen: Int) async {
        if unknownRetry == .scheduled {
            unknownRetry = .spent
            requestForcedReconcile()
        }
        guard !taps.isEmpty else { probeRequested = false; return }
        let ioActive = taps.values.contains { $0.handle.secondsSinceIO < Self.activeIOWindow }
        if ioActive { polls += 1 }
        let date = now()
        for (key, tap) in taps {
            if tap.handle.level > 0 { acknowledged.remove(key) }
            if date.timeIntervalSince(tap.createdAt) >= Self.flapWindow { flaps[key] = nil }
            guard tap.handle.hasFault else {
                if date.timeIntervalSince(tap.createdAt) >= Self.healthyAfter { faultedOn[key] = nil }
                continue
            }
            if faultedOn[key] == tap.device {
                // Faulted again soon after a rebuild: a faulted tap is silent, so release it.
                release(key, reason: .failed)
                markFailed(key, device: tap.device, processes: tap.processes)
            } else {
                faultedOn[key] = tap.device
                rebuildKeys.insert(key)
            }
        }
        if !rebuildKeys.isEmpty { requestForcedReconcile() }
        if !lagging.isEmpty {
            // IsRunningOutput changes fire no listener (spike §1), and an app keeping other IO open
            // (a call app with the mic) can pause or resume without any notification. Re-read the
            // processes so the lag clock counts real output only; `snapshot()` prunes and expires
            // lags. A changed world (an expiry marks the key elsewhere) fails the reconcile dedupe.
            snapshot()
            reconcileRequested = true
        }

        let revoked = taps.filter { $0.value.handle.looksRevoked }.map { ($0.key, $0.value.handle) }
        let periodic = ioActive && polls % Self.periodicCheckPolls == 0
        let probe = probeRequested
        probeRequested = false
        guard !revoked.isEmpty || periodic || probe else { return }

        let state = await permission()
        guard generation == gen else { return }
        switch state {
        case .granted:
            for (key, handle) in revoked where taps[key]?.handle === handle {
                handle.acknowledgeSilence()
                acknowledged.insert(key)
            }
        case .denied, .notPrompted:
            revoke()
        case .unknown:
            break // retried on the next poll; never tear down on unknown
        }
    }

    // MARK: - Helpers

    private func requestForcedReconcile() {
        reconcileRequested = true
        forceReconcile = true
    }

    /// Permission is definitely missing: release everything, keep settings.
    private func revoke() {
        if !taps.isEmpty { log.error("System Audio Recording not granted; releasing every tap") }
        for tap in taps.values { tap.handle.invalidate() }
        taps.removeAll()
        rebuildKeys.removeAll()
        acknowledged.removeAll()
        lagging.removeAll()
        notices.removeAll()
        unknownRetry = .none
        needsPermission = true
        updatePolling()
    }

    private enum ReleaseReason { case unwanted, failed }

    private func release(_ key: String, reason: ReleaseReason) {
        guard let tap = taps[key] else { return }
        tap.handle.invalidate()
        taps[key] = nil
        rebuildKeys.remove(key)
        acknowledged.remove(key)
        lagging[key] = nil
        let afterLagExpiry = lagExpired.remove(key) != nil
        // Flap breaker: released for "plays elsewhere" right after it was created, more than once
        // (e.g. a device report that includes our own aggregate in some form we don't strip).
        // A release because a lag ran out is a real "pinned to the old device", not a flap.
        if reason == .unwanted, elsewhere.contains(key), !afterLagExpiry,
           now().timeIntervalSince(tap.createdAt) < Self.flapWindow {
            flaps[key, default: 0] += 1
            if flaps[key, default: 0] >= Self.flapLimit {
                flaps[key] = nil
                markFailed(key, device: tap.device, processes: tap.processes)
            }
        }
        updatePolling()
    }

    private func markFailed(_ key: String, device: AudioDeviceID, processes: [AudioObjectID]) {
        failed[key] = FailedAttempt(device: device, processes: Set(processes))
        notices[key] = "Couldn't keep \(name(for: key))'s volume on this device"
        log.error("Released \(key, privacy: .public): couldn't keep its volume on device \(device)")
        updatePolling()
    }

    private func targets() -> [String: [AudioObjectID]] {
        var result = MixerRules.tapTargets(groups: effectiveGroups(), settings: store.all,
                                           defaultOutput: defaultOutput)
        for key in elsewhere { result[key] = nil }
        return result
    }

    /// The process view the rules see:
    /// - Sidekick's own aggregate devices never count as "another device".
    /// - Right after a default-device change, a tapped process can still report the device its tap
    ///   was built on (before the rebuild) or the previous device (after it, see `Lag`). Treat that
    ///   as "following the default" so the app is rebuilt or kept, not released to full volume.
    private func effectiveGroups() -> [String: [AudioProcess]] {
        let own = ownAggregates()
        var result: [String: [AudioProcess]] = [:]
        for (key, processes) in groups {
            let tap = taps[key]
            let lag = lagging[key]
            result[key] = processes.map { process in
                var devices = process.outputDevices.filter { !own.contains($0) }
                if let tap, tap.device != defaultOutput, devices == [tap.device] { devices = [] }
                if let lag, lag.processes.contains(process.objectID), devices == [lag.device] { devices = [] }
                guard devices != process.outputDevices else { return process }
                return AudioProcess(objectID: process.objectID, pid: process.pid, bundleID: process.bundleID,
                                    isRunningOutput: process.isRunningOutput, outputDevices: devices)
            }
        }
        return result
    }

    private func ownAggregates() -> Set<AudioObjectID> {
        Set(taps.values.map(\.handle.aggregateID)).subtracting([kAudioObjectUnknown])
    }

    /// A lagging process stops lagging once it reports anything other than the previous device, or
    /// once it has been outputting to it for `lagWindow` (then it's taken at its word: pinned there).
    private func pruneLagging() {
        let own = ownAggregates()
        let date = now()
        for (key, original) in lagging {
            var lag = original
            let current = groups[key] ?? []
            for id in original.processes {
                guard let process = current.first(where: { $0.objectID == id }),
                      process.outputDevices.filter({ !own.contains($0) }) == [lag.device] else {
                    lag.processes.remove(id)
                    lag.runningSince[id] = nil
                    continue
                }
                guard process.isRunningOutput else {
                    lag.runningSince[id] = nil
                    continue
                }
                let since = lag.runningSince[id] ?? date
                lag.runningSince[id] = since
                if date.timeIntervalSince(since) >= Self.lagWindow {
                    lag.processes.remove(id)
                    lag.runningSince[id] = nil
                    lagExpired.insert(key)
                }
            }
            lagging[key] = lag.processes.isEmpty ? nil : lag
        }
    }

    private func updateElsewhere() {
        guard let defaultOutput else { return }
        for (key, processes) in effectiveGroups() {
            if processes.contains(where: { !$0.outputDevices.isEmpty && $0.outputDevices != [defaultOutput] }) {
                elsewhere.insert(key)
            } else if processes.contains(where: { $0.outputDevices == [defaultOutput] }) {
                elsewhere.remove(key)
            }
        }
    }

    private func updateRows() {
        let new = MixerRules.rows(groups: effectiveGroups(), apps: apps, settings: store.all,
                                  defaultOutput: defaultOutput)
            .map { row in
                guard elsewhere.contains(row.id), !row.playsElsewhere else { return row }
                return MixerRow(id: row.id, name: row.name, isPlaying: row.isPlaying, setting: row.setting,
                                playsElsewhere: true)
            }
        if new != rows { rows = new }
    }

    private func name(for key: String) -> String {
        if key == AppGrouping.webContentKey { return MixerRules.webContentName }
        return apps.first { $0.bundleID == key }?.name ?? key
    }

    private func updatePolling() {
        let wanted = running && (!taps.isEmpty || unknownRetry == .scheduled)
        if wanted, poller == nil {
            let interval = pollInterval
            poller = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: interval)
                    guard !Task.isCancelled, let self else { return }
                    self.pollWatchdog()
                }
            }
        } else if !wanted, let poller {
            poller.cancel()
            self.poller = nil
        }
    }
}
