import Foundation
import Testing
@testable import Sidekick

/// A blocking stand-in for the self-tap probe. Each call takes the next scripted result;
/// when `holding` is set, calls block until `release()`.
private final class StubProber: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [SystemAudioState]
    private var _calls = 0
    private let gate = DispatchSemaphore(value: 0)
    private var blocked = 0
    let holding: Bool

    init(_ results: [SystemAudioState], holding: Bool = false) {
        self.results = results
        self.holding = holding
    }

    var calls: Int { lock.withLock { _calls } }

    func run() -> SystemAudioState {
        let result: SystemAudioState = lock.withLock {
            _calls += 1
            if holding { blocked += 1 }
            return results.isEmpty ? .granted : results.removeFirst()
        }
        if holding { gate.wait() }
        return result
    }

    func releaseAll() {
        let count = lock.withLock { () -> Int in let c = blocked; blocked = 0; return c }
        for _ in 0..<count { gate.signal() }
    }
}

private final class Clock: @unchecked Sendable {
    var now = Date(timeIntervalSinceReferenceDate: 1_000_000)
    func advance(_ seconds: TimeInterval) { now += seconds }
}

@MainActor
struct SystemAudioPermissionTests {
    private func makeDefaults(prompted: Bool = false) -> UserDefaults {
        let d = UserDefaults(suiteName: "SystemAudioPermissionTests-\(UUID())")!
        if prompted { d.set(true, forKey: SystemAudioPermissionCore.promptedKey) }
        return d
    }

    private func makeCore(
        _ prober: StubProber, prompted: Bool = false, clock: Clock = Clock(),
        tapAudio: @escaping @MainActor () -> Date? = { nil }, defaults: UserDefaults? = nil
    ) -> SystemAudioPermissionCore {
        SystemAudioPermissionCore(
            defaults: defaults ?? makeDefaults(prompted: prompted),
            prober: { prober.run() },
            recentTapAudio: tapAudio,
            now: { clock.now },
            automaticWait: .milliseconds(100),
            grantWait: .seconds(5),
            automaticStuckAfter: 10,
            grantStuckAfter: 90)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: - Prompted flag

    @Test func neverProbesBeforePrompted() async {
        let prober = StubProber([.granted])
        let core = makeCore(prober, tapAudio: { Date() })
        #expect(core.cached == .notPrompted)
        #expect(await core.check() == .notPrompted)
        #expect(await core.ensureGranted() == .notPrompted)
        #expect(!core.isGrantedRecently)
        #expect(prober.calls == 0)
    }

    @Test func requestSetsFlagThenProbes() async {
        let prober = StubProber([.granted])
        let defaults = makeDefaults()
        let core = makeCore(prober, defaults: defaults)
        #expect(await core.request() == .granted)
        #expect(defaults.bool(forKey: SystemAudioPermissionCore.promptedKey))
        #expect(core.hasPrompted)
        #expect(core.cached == .granted)
        #expect(core.isGrantedRecently)
        #expect(prober.calls == 1)
    }

    @Test func promptedFlagPersistsAcrossInstances() async {
        let defaults = makeDefaults()
        _ = await makeCore(StubProber([.denied]), defaults: defaults).request()
        let prober = StubProber([.granted])
        let later = makeCore(prober, defaults: defaults)
        #expect(later.cached == .unknown)
        #expect(await later.check() == .granted)
        #expect(prober.calls == 1)
    }

    // MARK: - Cache and the 30 s window

    @Test func checkUsesFreshCacheAndReprobesWhenStale() async {
        let prober = StubProber([.granted, .granted])
        let clock = Clock()
        let core = makeCore(prober, prompted: true, clock: clock)
        #expect(await core.check() == .granted)
        clock.advance(29)
        #expect(await core.check() == .granted)
        #expect(prober.calls == 1)
        clock.advance(2)
        #expect(await core.check() == .granted)
        #expect(prober.calls == 2)
    }

    @Test func grantExpiresAfterThirtySeconds() async {
        let clock = Clock()
        let core = makeCore(StubProber([.granted]), prompted: true, clock: clock)
        _ = await core.check()
        clock.advance(30)
        #expect(core.isGrantedRecently)
        clock.advance(0.5)
        #expect(!core.isGrantedRecently)
    }

    @Test func deniedClearsGrant() async {
        let clock = Clock()
        let core = makeCore(StubProber([.granted, .denied]), prompted: true, clock: clock)
        _ = await core.check()
        #expect(await core.check(maxAge: 0) == .denied)
        #expect(core.cached == .denied)
        #expect(!core.isGrantedRecently)
    }

    @Test func unknownNeverOverwritesADefiniteResult() async {
        let core = makeCore(StubProber([.granted, .unknown]), prompted: true)
        _ = await core.check()
        #expect(await core.check(maxAge: 0) == .unknown)
        #expect(core.cached == .granted)
    }

    // MARK: - Gate

    @Test func gateUsesRecentGrantWithoutProbing() async {
        let prober = StubProber([.granted])
        let core = makeCore(prober, prompted: true)
        _ = await core.check()
        #expect(await core.ensureGranted() == .granted)
        #expect(prober.calls == 1)
    }

    @Test func gateCountsTapAudioAsGrant() async {
        let prober = StubProber([.denied])
        let clock = Clock()
        let core = makeCore(prober, prompted: true, clock: clock, tapAudio: { clock.now - 10 })
        #expect(await core.ensureGranted() == .granted)
        #expect(prober.calls == 0)
    }

    @Test func tapEvidenceIsRecordedAtEvidenceTimeWithoutCountingAsACheck() async {
        let prober = StubProber([.granted])
        let clock = Clock()
        var evidence: Date? = clock.now - 25
        let core = makeCore(prober, prompted: true, clock: clock, tapAudio: { evidence })
        #expect(await core.ensureGranted() == .granted)
        evidence = nil
        clock.advance(6) // evidence is now 31 s old
        #expect(!core.isGrantedRecently)
        // Evidence didn't refresh the probe cache: check() still probes.
        #expect(await core.check() == .granted)
        #expect(prober.calls == 1)
    }

    @Test func staleTapEvidenceDoesNotPassTheGate() async {
        let prober = StubProber([.denied])
        let clock = Clock()
        let core = makeCore(prober, prompted: true, clock: clock, tapAudio: { clock.now - 31 })
        #expect(await core.ensureGranted() == .denied)
        #expect(prober.calls == 1)
    }

    @Test func ledgerEvidenceNeverOverridesALaterDenial() {
        var ledger = PermissionLedger()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        ledger.record(.denied, at: t0 + 10)
        ledger.noteEvidence(at: t0 + 5)
        #expect(ledger.state(prompted: true) == .denied)
        #expect(!ledger.isFreshGrant(now: t0 + 10))
        ledger.noteEvidence(at: t0 + 11)
        #expect(ledger.state(prompted: true) == .granted)
        #expect(ledger.isFreshGrant(now: t0 + 41))
        #expect(ledger.isStale(now: t0 + 41, maxAge: 30)) // evidence isn't a check
    }

    @Test func gateProbesWhenGrantIsStale() async {
        let prober = StubProber([.granted, .denied])
        let clock = Clock()
        let core = makeCore(prober, prompted: true, clock: clock)
        _ = await core.check()
        clock.advance(31)
        #expect(await core.ensureGranted() == .denied)
        #expect(prober.calls == 2)
    }

    // MARK: - Timeouts, joining, abandonment

    @Test func timeoutGivesUnknownAndLateResultIsStored() async {
        let prober = StubProber([.granted], holding: true)
        let core = makeCore(prober, prompted: true)
        #expect(await core.check() == .unknown)
        #expect(core.cached == .unknown)
        prober.releaseAll()
        #expect(await eventually { core.cached == .granted })
        #expect(core.isGrantedRecently)
    }

    @Test func gateRetriesOnceOnUnknown() async {
        // First wait times out; the retry joins the same probe, which then finishes.
        let prober = StubProber([.granted], holding: true)
        let core = makeCore(prober, prompted: true)
        Task { try? await Task.sleep(for: .milliseconds(150)); prober.releaseAll() }
        #expect(await core.ensureGranted() == .granted)
        #expect(prober.calls == 1)
    }

    @Test func concurrentChecksJoinOneProbe() async {
        let prober = StubProber([.granted], holding: true)
        let core = makeCore(prober, prompted: true)
        async let a = core.check()
        async let b = core.check()
        _ = await (a, b)
        #expect(prober.calls == 1)
        prober.releaseAll()
        #expect(await eventually { core.cached == .granted })
    }

    @Test func stuckProbeIsReplacedUpToACap() async {
        let prober = StubProber([.granted, .granted, .granted, .granted], holding: true)
        let clock = Clock()
        let core = makeCore(prober, prompted: true, clock: clock)
        _ = await core.check(maxAge: 0)
        #expect(prober.calls == 1)
        clock.advance(5)
        _ = await core.check(maxAge: 0)
        #expect(prober.calls == 1) // still within the stuck bound: joined
        clock.advance(6)
        _ = await core.check(maxAge: 0)
        #expect(await eventually { prober.calls == 2 })
        clock.advance(11)
        _ = await core.check(maxAge: 0)
        #expect(await eventually { prober.calls == 3 })
        clock.advance(11)
        #expect(await core.check(maxAge: 0) == .unknown)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(prober.calls == 3) // cap reached: no fourth stuck thread
        prober.releaseAll()
        #expect(await eventually { core.cached == .granted })
        // Once the stuck ones finish, probing works again.
        _ = await core.check(maxAge: 0)
        #expect(await eventually { prober.calls == 4 })
        prober.releaseAll()
    }

    // MARK: - Pure pieces

    @Test func trackerJoinsThenStartsThenRefuses() {
        var tracker = ProbeTracker(maxLive: 2)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        #expect(tracker.request(now: t0, stuckAfter: 10) == .start(1))
        #expect(tracker.request(now: t0 + 9, stuckAfter: 10) == .join(1))
        #expect(tracker.request(now: t0 + 10, stuckAfter: 10) == .start(2))
        #expect(tracker.request(now: t0 + 15, stuckAfter: 10) == .join(2))
        #expect(tracker.request(now: t0 + 25, stuckAfter: 10) == .refuse)
        tracker.finished(1)
        #expect(tracker.request(now: t0 + 25, stuckAfter: 10) == .start(3))
    }

    @Test func ledgerStates() {
        var ledger = PermissionLedger()
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        #expect(ledger.state(prompted: false) == .notPrompted)
        #expect(ledger.state(prompted: true) == .unknown)
        #expect(ledger.isStale(now: t0, maxAge: 30))
        ledger.record(.granted, at: t0)
        #expect(ledger.state(prompted: true) == .granted)
        #expect(ledger.state(prompted: false) == .notPrompted)
        #expect(ledger.isFreshGrant(now: t0 + 30))
        #expect(!ledger.isFreshGrant(now: t0 + 31))
        ledger.record(.unknown, at: t0 + 40)
        #expect(ledger.state(prompted: true) == .granted)
        #expect(ledger.isStale(now: t0 + 40, maxAge: 30))
        ledger.record(.denied, at: t0 + 41)
        #expect(!ledger.isFreshGrant(now: t0 + 41))
        #expect(ledger.state(prompted: true) == .denied)
    }
}
