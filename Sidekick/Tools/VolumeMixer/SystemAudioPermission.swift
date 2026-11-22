import AVFoundation
import CoreAudio
import Foundation
import os
import Synchronization

/// System Audio Recording, as far as Volume Mixer can tell. There is no public status API, so the
/// answer comes from a self-tap probe (spike §3).
///
/// - `notPrompted`: the user has never pressed Grant; nothing has been probed. Not granted.
/// - `denied`: a probe saw only zeros. Not granted.
/// - `unknown`: no verdict yet (probe still running, timed out, or failed). **Not granted for
///   muting, but never treat it as denied**: callers retry; only `denied`/`notPrompted` tear down.
enum SystemAudioState: Equatable, Sendable {
    case notPrompted, granted, denied, unknown

    var isGranted: Bool { self == .granted }
}

/// The app-wide permission state. Thin facade over one `SystemAudioPermissionCore` using the real probe.
@MainActor
enum SystemAudioPermission {
    static let shared = SystemAudioPermissionCore(
        defaults: .standard,
        prober: { SelfTapProbe.run() },
        recentTapAudio: { AppTap.latestAudioEvidence })

    /// The last definite result (or `.notPrompted` / `.unknown`). Never touches Core Audio.
    static var cached: SystemAudioState { shared.cached }
    /// A probe returned GRANTED (or a tap heard real audio) within the last 30 s.
    static var isGrantedRecently: Bool { shared.isGrantedRecently }
    /// The Grant button: sets `volumeMixer.permissionPrompted`, then probes. May show the system prompt.
    static func request() async -> SystemAudioState { await shared.request() }
    /// No prompt. Before Grant was ever pressed this answers `.notPrompted` without probing.
    static func check(maxAge: TimeInterval = PermissionLedger.freshWindow) async -> SystemAudioState {
        await shared.check(maxAge: maxAge)
    }
    /// The gate before any muting tap (spike §3 "Gate").
    static func ensureGranted() async -> SystemAudioState { await shared.ensureGranted() }
}

/// What the probes have said so far. Pure.
struct PermissionLedger: Sendable {
    static let freshWindow: TimeInterval = 30

    private(set) var definite: SystemAudioState?
    private(set) var checkedAt: Date?
    private(set) var grantedAt: Date?

    /// `.unknown` never replaces a definite answer and doesn't count as a check.
    mutating func record(_ state: SystemAudioState, at date: Date) {
        switch state {
        case .granted:
            definite = .granted
            checkedAt = date
            grantedAt = date
        case .denied:
            definite = .denied
            checkedAt = date
            grantedAt = nil
        case .unknown, .notPrompted:
            break
        }
    }

    /// A tap heard non-zero input at `date`: that proves GRANTED at that moment. Recorded at the
    /// evidence time, never overrides a later denial, and isn't a probe (doesn't refresh `checkedAt`).
    mutating func noteEvidence(at date: Date) {
        if definite == .denied, let checkedAt, checkedAt >= date { return }
        definite = .granted
        if grantedAt.map({ $0 < date }) ?? true { grantedAt = date }
    }

    func state(prompted: Bool) -> SystemAudioState {
        prompted ? (definite ?? .unknown) : .notPrompted
    }

    func isFreshGrant(now: Date) -> Bool {
        guard let grantedAt else { return false }
        return now.timeIntervalSince(grantedAt) <= Self.freshWindow
    }

    func isStale(now: Date, maxAge: TimeInterval) -> Bool {
        guard let checkedAt else { return true }
        return now.timeIntervalSince(checkedAt) >= maxAge
    }
}

/// Which probe a request should wait on. A probe stuck inside Core Audio past `stuckAfter` is
/// abandoned for a fresh one, but at most `maxLive` probes (stuck threads) exist at once. Pure.
struct ProbeTracker: Sendable {
    enum Decision: Equatable, Sendable { case join(Int), start(Int), refuse }

    private struct Live: Sendable {
        let id: Int
        let startedAt: Date
        let stuckAfter: TimeInterval
    }

    let maxLive: Int
    private var live: [Live] = []
    private var lastID = 0

    init(maxLive: Int = 3) { self.maxLive = maxLive }

    mutating func request(now: Date, stuckAfter: TimeInterval) -> Decision {
        if let newest = live.last, now.timeIntervalSince(newest.startedAt) < newest.stuckAfter {
            return .join(newest.id)
        }
        guard live.count < maxLive else { return .refuse }
        lastID += 1
        live.append(Live(id: lastID, startedAt: now, stuckAfter: stuckAfter))
        return .start(lastID)
    }

    mutating func finished(_ id: Int) {
        live.removeAll { $0.id == id }
    }
}

/// Probe scheduling, timeouts and caching. The prober is injected so tests never touch Core Audio.
@MainActor
final class SystemAudioPermissionCore {
    static let promptedKey = "volumeMixer.permissionPrompted"
    typealias Prober = @Sendable () -> SystemAudioState

    private let defaults: UserDefaults
    private let prober: Prober
    private let recentTapAudio: @MainActor () -> Date?
    private let now: () -> Date
    private let automaticWait: Duration
    private let grantWait: Duration
    private let automaticStuckAfter: TimeInterval
    private let grantStuckAfter: TimeInterval

    private var ledger = PermissionLedger()
    private var tracker = ProbeTracker()
    private var waiters: [Int: [Int: CheckedContinuation<SystemAudioState, Never>]] = [:]
    private var nextWaiter = 0

    init(
        defaults: UserDefaults,
        prober: @escaping Prober,
        recentTapAudio: @escaping @MainActor () -> Date?,
        now: @escaping () -> Date = Date.init,
        automaticWait: Duration = .seconds(2),
        grantWait: Duration = .seconds(60),
        automaticStuckAfter: TimeInterval = 10,
        grantStuckAfter: TimeInterval = 90
    ) {
        self.defaults = defaults
        self.prober = prober
        self.recentTapAudio = recentTapAudio
        self.now = now
        self.automaticWait = automaticWait
        self.grantWait = grantWait
        self.automaticStuckAfter = automaticStuckAfter
        self.grantStuckAfter = grantStuckAfter
    }

    var hasPrompted: Bool { defaults.bool(forKey: Self.promptedKey) }

    var cached: SystemAudioState { ledger.state(prompted: hasPrompted) }

    var isGrantedRecently: Bool { hasPrompted && ledger.isFreshGrant(now: now()) }

    func request() async -> SystemAudioState {
        defaults.set(true, forKey: Self.promptedKey)
        return await probe(wait: grantWait, stuckAfter: grantStuckAfter)
    }

    func check(maxAge: TimeInterval = PermissionLedger.freshWindow) async -> SystemAudioState {
        guard hasPrompted else { return .notPrompted }
        if !ledger.isStale(now: now(), maxAge: maxAge) { return cached }
        return await probe(wait: automaticWait, stuckAfter: automaticStuckAfter)
    }

    func ensureGranted() async -> SystemAudioState {
        guard hasPrompted else { return .notPrompted }
        if ledger.isFreshGrant(now: now()) { return .granted }
        if let evidence = recentTapAudio() {
            ledger.noteEvidence(at: evidence)
            if ledger.isFreshGrant(now: now()) { return .granted }
        }
        // The first TCC lookup of a session can exceed the 2 s wait, so give `unknown` one more
        // wait (this joins the same running probe) before reporting it.
        let first = await probe(wait: automaticWait, stuckAfter: automaticStuckAfter)
        guard first == .unknown else { return first }
        return await probe(wait: automaticWait, stuckAfter: automaticStuckAfter)
    }

    // MARK: - Probing

    private func probe(wait: Duration, stuckAfter: TimeInterval) async -> SystemAudioState {
        let id: Int
        switch tracker.request(now: now(), stuckAfter: stuckAfter) {
        case .refuse:
            return .unknown
        case .join(let running):
            id = running
        case .start(let started):
            id = started
            launch(started)
        }
        return await self.wait(for: id, timeout: wait)
    }

    private func launch(_ id: Int) {
        let prober = prober
        // Each probe gets its own serial queue, so a probe stuck inside Core Audio can't block the next.
        DispatchQueue(label: "com.sidekick.volumeMixer.probe.\(id)", qos: .userInitiated).async {
            let result = prober()
            Task { @MainActor in self.finish(id, result) }
        }
    }

    private func finish(_ id: Int, _ result: SystemAudioState) {
        tracker.finished(id)
        ledger.record(result, at: now())
        let pending = waiters.removeValue(forKey: id) ?? [:]
        for continuation in pending.values { continuation.resume(returning: result) }
    }

    private func wait(for id: Int, timeout: Duration) async -> SystemAudioState {
        nextWaiter += 1
        let key = nextWaiter
        return await withCheckedContinuation { continuation in
            waiters[id, default: [:]][key] = continuation
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                // Abandon, don't cancel: the probe keeps running and its late result is still cached.
                self.waiters[id]?.removeValue(forKey: key)?.resume(returning: .unknown)
            }
        }
    }
}

/// The self-tap probe (spike §3). Blocking; runs on a probe queue, never the main actor.
/// Plays a −100 dBFS 1 kHz sine from Sidekick, taps Sidekick's own process **unmuted**, and looks
/// for non-zero input. If the state is undetermined, creating the IO proc shows the system prompt
/// and blocks until the user answers.
enum SelfTapProbe {
    private static let log = Logger(subsystem: "com.sidekick.app", category: "VolumeMixer")

    static func run() -> SystemAudioState {
        let tone = InaudibleTone()
        guard tone.start() else { return .unknown }
        defer { tone.stop() }

        guard let processObject = waitForOwnProcessObject(),
              let device = CoreAudioProperties.defaultOutputDevice() else { return .unknown }
        let session: TapSession
        do {
            session = try TapSession.start(processes: [processObject], device: device, name: "Sidekick probe")
        } catch {
            log.error("Permission probe couldn't start a tap: \(String(describing: error), privacy: .public)")
            return .unknown
        }
        defer { session.destroy() }

        // Granted: the first callback has a non-zero sample (~50 ms). Denied: 20 all-zero callbacks.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if session.io.nonZeroCallbacks.load(ordering: .relaxed) > 0 { return .granted }
            if session.io.callbacks.load(ordering: .relaxed) >= 20 { return .denied }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return .unknown
    }

    private static func waitForOwnProcessObject() -> AudioObjectID? {
        for _ in 0..<50 {
            if let id = CoreAudioProperties.processObject(for: getpid()) { return id }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return nil
    }
}

/// A private AVAudioEngine playing a 1 kHz sine at 1e-5 amplitude. Inaudible, but non-zero.
private final class InaudibleTone: @unchecked Sendable {
    private let engine = AVAudioEngine()

    func start() -> Bool {
        let format = engine.mainMixerNode.outputFormat(forBus: 0)
        let rate = format.sampleRate > 0 ? format.sampleRate : 48_000
        let mono = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)
        guard let mono else { return false }
        let phase = PhaseBox(step: 2 * .pi * 1_000 / rate)
        let source = AVAudioSourceNode(format: mono) { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                var p = phase.value
                for frame in 0..<Int(frameCount) {
                    data[frame] = Float(sin(p)) * 1e-5
                    p += phase.step
                    if p > 2 * .pi { p -= 2 * .pi }
                }
            }
            phase.value += phase.step * Double(frameCount)
            phase.value = phase.value.truncatingRemainder(dividingBy: 2 * .pi)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: mono)
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    func stop() {
        engine.stop()
    }

    /// Render-thread state; only the render block touches `value`.
    private final class PhaseBox: @unchecked Sendable {
        let step: Double
        var value: Double = 0
        init(step: Double) { self.step = step }
    }
}
