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
    @ObservationIgnored private let ownBundleID: String
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let log = Logger(subsystem: "com.sidekick.app", category: "VolumeMixer")

    /// Polls between the backup permission checks (Task 4 contract: every 30 s while taps exist).
    static let periodicCheckPolls = 30

    private struct ActiveTap {
        let handle: any TapHandle
        var processes: [AudioObjectID]
        let device: AudioDeviceID
    }

    /// A create/rebuild that failed twice; not retried until the device or the processes change.
    private struct FailedAttempt: Equatable {
        let device: AudioDeviceID
        let processes: Set<AudioObjectID>
    }

    private enum UnknownRetry { case none, scheduled, spent }

    // Snapshot of the world, re-read by `refresh()` and the listeners.
    @ObservationIgnored private var running = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var apps: [RunningApp] = []
    @ObservationIgnored private var groups: [String: [AudioProcess]] = [:]
    @ObservationIgnored private var defaultOutput: AudioDeviceID?

    // Taps and their bookkeeping. Only the worker (and `stop()`) changes `taps`.
    @ObservationIgnored private var taps: [String: ActiveTap] = [:]
    @ObservationIgnored private var failed: [String: FailedAttempt] = [:]
    @ObservationIgnored private var rebuildKeys: Set<String> = []
    @ObservationIgnored private var acknowledged: Set<String> = []
    /// Keys whose tap faulted on this device already; a second fault releases instead of rebuilding.
    @ObservationIgnored private var faultedOn: [String: AudioDeviceID] = [:]
    @ObservationIgnored private var unknownRetry = UnknownRetry.none
    @ObservationIgnored private var polls = 0

    // The serialized worker.
    @ObservationIgnored private var reconcileRequested = false
    @ObservationIgnored private var watchdogRequested = false
    @ObservationIgnored private var probeRequested = false
    @ObservationIgnored private var recheckPermission = false
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var retired: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var poller: Task<Void, Never>?

    init(system: any AudioSystem,
         store: MixerSettingsStore,
         permission: @escaping PermissionCheck = { await SystemAudioPermission.check(maxAge: 0) },
         ownBundleID: String = Bundle.main.bundleIdentifier ?? "com.sidekick.app",
         pollInterval: Duration = .seconds(1)) {
        self.system = system
        self.store = store
        self.permission = permission
        self.ownBundleID = ownBundleID
        self.pollInterval = pollInterval
    }

    // MARK: - Lifecycle

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        system.startListening(
            onProcessesChanged: { [weak self] in self?.processesChanged() },
            onDefaultDeviceChanged: { [weak self] in self?.worldChanged() })
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
        unknownRetry = .none
        reconcileRequested = false
        watchdogRequested = false
        probeRequested = false
        recheckPermission = false
        polls = 0
        notices.removeAll()
        needsPermission = false
        rows = []
        updatePolling()
    }

    /// Re-reads processes, apps and the default device, recomputes rows and reconciles taps.
    /// Also re-checks the permission when it was missing (e.g. the panel opened after Grant).
    func refresh() {
        guard running else { return }
        if needsPermission { recheckPermission = true }
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
        while generation == gen {
            if watchdogRequested {
                watchdogRequested = false
                await watchdog(gen)
            } else if reconcileRequested {
                reconcileRequested = false
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
        if needsPermission {
            // Only an explicit refresh re-asks; listener events would just hammer the probe.
            guard recheckPermission else { return }
            recheckPermission = false
            let state = await permission()
            guard generation == gen, state == .granted else { return }
            needsPermission = false
            failed.removeAll()
        }
        recheckPermission = false

        let wanted = targets()
        for key in taps.keys where wanted[key] == nil { release(key) }
        for key in Set(failed.keys).union(notices.keys).union(faultedOn.keys) where wanted[key] == nil {
            failed[key] = nil
            notices[key] = nil
            faultedOn[key] = nil
        }
        for key in wanted.keys.sorted() {
            // Each step can await; re-read what's wanted so a change made meanwhile wins.
            guard generation == gen, !needsPermission else { return }
            guard let ids = targets()[key], let device = defaultOutput else { continue }
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
    /// seconds) — a burst. Doubling can't happen: the new copy is at 0 until the original is muted,
    /// and the two copies go to different devices.
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
                    return
                }
                handle.setGain(store.setting(for: key).gain)
                old?.handle.invalidate()
                taps[key] = ActiveTap(handle: handle, processes: ids, device: device)
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
            old.handle.invalidate()
            taps[key] = nil
            acknowledged.remove(key)
        }
        failed[key] = FailedAttempt(device: device, processes: Set(ids))
        notices[key] = "Couldn't keep \(name(for: key))'s volume on this device"
        updatePolling()
    }

    private func watchdog(_ gen: Int) async {
        if unknownRetry == .scheduled {
            unknownRetry = .spent
            reconcileRequested = true
        }
        guard !taps.isEmpty else { probeRequested = false; return }
        polls += 1
        for (key, tap) in taps {
            if tap.handle.level > 0 { acknowledged.remove(key) }
            guard tap.handle.hasFault else { continue }
            if faultedOn[key] == tap.device {
                // Faulted again right after a rebuild: a faulted tap is silent, so release it.
                release(key)
                failed[key] = FailedAttempt(device: tap.device, processes: Set(tap.processes))
                notices[key] = "Couldn't keep \(name(for: key))'s volume on this device"
            } else {
                faultedOn[key] = tap.device
                rebuildKeys.insert(key)
            }
        }
        if !rebuildKeys.isEmpty { reconcileRequested = true }

        let revoked = taps.filter { $0.value.handle.looksRevoked }.map { ($0.key, $0.value.handle) }
        let periodic = polls % Self.periodicCheckPolls == 0
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

    /// Permission is definitely missing: release everything, keep settings.
    private func revoke() {
        log.error("System Audio Recording not granted; releasing every tap")
        for tap in taps.values { tap.handle.invalidate() }
        taps.removeAll()
        rebuildKeys.removeAll()
        acknowledged.removeAll()
        notices.removeAll()
        unknownRetry = .none
        needsPermission = true
        updatePolling()
    }

    private func release(_ key: String) {
        taps[key]?.handle.invalidate()
        taps[key] = nil
        rebuildKeys.remove(key)
        acknowledged.remove(key)
        updatePolling()
    }

    private func targets() -> [String: [AudioObjectID]] {
        MixerRules.tapTargets(groups: effectiveGroups(), settings: store.all, defaultOutput: defaultOutput)
    }

    /// Right after a default-device change, a tapped process can still report the device its tap was
    /// built on. Treat that as "following the default" so the app is rebuilt, not released to full
    /// volume. Once rebuilt, a process that really stays on the old device is released as usual.
    private func effectiveGroups() -> [String: [AudioProcess]] {
        var result = groups
        for (key, tap) in taps where tap.device != defaultOutput {
            result[key] = result[key]?.map { process in
                guard process.outputDevices == [tap.device] else { return process }
                return AudioProcess(objectID: process.objectID, pid: process.pid, bundleID: process.bundleID,
                                    isRunningOutput: process.isRunningOutput, outputDevices: [])
            }
        }
        return result
    }

    private func updateRows() {
        let new = MixerRules.rows(groups: effectiveGroups(), apps: apps, settings: store.all,
                                  defaultOutput: defaultOutput)
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
