import CoreAudio
import Foundation
@testable import Sidekick

/// A tap that records what the controller did to it. Never touches Core Audio.
@MainActor
final class FakeTap: TapHandle {
    let serial: Int
    let device: AudioDeviceID
    private(set) var processes: [AudioObjectID]
    private(set) var gain: Float
    /// The gain `makeTap` ramped to when it finished (read from the provider at that point).
    let initialGain: Float
    private(set) var setProcessesCalls: [[AudioObjectID]] = []
    private(set) var invalidated = false
    private(set) var acknowledgeCount = 0
    private(set) var setGainCount = 0
    /// A distinct fake aggregate per tap (1000 + serial).
    var aggregateID: AudioObjectID { AudioObjectID(1000 + serial) }
    private unowned let system: FakeAudioSystem

    var level: Float = 0
    var looksRevoked = false
    var hasFault = false
    /// Seconds since the IO proc last ran; recent by default (the app is playing).
    var secondsSinceIO: TimeInterval = 0
    var setProcessesError: (any Error)?

    init(serial: Int, processes: [AudioObjectID], device: AudioDeviceID, gain: Float, system: FakeAudioSystem) {
        self.serial = serial
        self.processes = processes
        self.device = device
        self.gain = gain
        self.initialGain = gain
        self.system = system
    }

    func setGain(_ gain: Float) {
        self.gain = gain
        setGainCount += 1
    }

    func setProcesses(_ ids: [AudioObjectID]) throws {
        if let setProcessesError { throw setProcessesError }
        setProcessesCalls.append(ids)
        processes = ids
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        system.events.append("invalidate \(serial)")
    }

    func acknowledgeSilence() {
        acknowledgeCount += 1
        looksRevoked = false
    }
}

/// An `AudioSystem` driven entirely by the test.
@MainActor
final class FakeAudioSystem: AudioSystem {
    struct MakeCall: Equatable {
        let processes: [AudioObjectID]
        let device: AudioDeviceID
        let gain: Float
    }

    var processList: [AudioProcess] = []
    var apps: [RunningApp] = []
    var parents: [pid_t: pid_t] = [:]
    var defaultDevice: AudioDeviceID? = 81
    /// Popped one per `makeTap` call; `nil` entries (or an empty queue) succeed.
    var makeErrors: [(any Error)?] = []
    /// While true, `makeTap` suspends until `releaseHeld()`.
    var holdCreates = false
    /// What the injected permission check answers.
    var permissionState: SystemAudioState = .granted
    /// What the injected "granted within 30 s" answers.
    var freshGrant = false

    private(set) var makeCalls: [MakeCall] = []
    private(set) var taps: [FakeTap] = []
    private(set) var permissionChecks = 0
    private(set) var listening = false
    private(set) var stopListeningCount = 0
    var events: [String] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var onProcessesChanged: (@MainActor () -> Void)?
    private var onDefaultDeviceChanged: (@MainActor () -> Void)?

    var liveTaps: [FakeTap] { taps.filter { !$0.invalidated } }
    var heldCount: Int { held.count }

    func processes() -> [AudioProcess] { processList }
    func runningApps() -> [RunningApp] { apps }
    func parent(of pid: pid_t) -> pid_t? { parents[pid] }
    func defaultOutputDevice() -> AudioDeviceID? { defaultDevice }
    func deviceName(_ id: AudioDeviceID) -> String { "Device \(id)" }

    func startListening(onProcessesChanged: @escaping @MainActor () -> Void,
                        onDefaultDeviceChanged: @escaping @MainActor () -> Void) {
        listening = true
        self.onProcessesChanged = onProcessesChanged
        self.onDefaultDeviceChanged = onDefaultDeviceChanged
    }

    func stopListening() {
        listening = false
        stopListeningCount += 1
        onProcessesChanged = nil
        onDefaultDeviceChanged = nil
    }

    func makeTap(processes: [AudioObjectID], device: AudioDeviceID,
                 gain: @escaping @MainActor () -> Float) async throws -> any TapHandle {
        makeCalls.append(MakeCall(processes: processes, device: device, gain: gain()))
        events.append("make \(device)")
        if holdCreates {
            await withCheckedContinuation { held.append($0) }
        }
        if !makeErrors.isEmpty, let error = makeErrors.removeFirst() {
            throw error
        }
        // Like AppTap.make: the final ramp reads the gain when setup completes.
        let tap = FakeTap(serial: taps.count + 1, processes: processes, device: device, gain: gain(), system: self)
        taps.append(tap)
        return tap
    }

    /// While true, the permission check suspends until `releaseHeldPermission()`.
    var holdPermission = false
    private var heldPermission: [CheckedContinuation<Void, Never>] = []

    func checkPermission() async -> SystemAudioState {
        permissionChecks += 1
        events.append("permission")
        if holdPermission {
            await withCheckedContinuation { heldPermission.append($0) }
        }
        return permissionState
    }

    func releaseHeldPermission() {
        holdPermission = false
        let waiting = heldPermission
        heldPermission.removeAll()
        waiting.forEach { $0.resume() }
    }

    func waitForHeldPermission() async {
        for _ in 0..<10_000 where heldPermission.isEmpty { await Task.yield() }
    }

    // MARK: Test drivers

    /// Forgets the permission checks and events so far (taps and make calls are kept).
    func clearRecords() {
        permissionChecks = 0
        events.removeAll()
    }

    func fireProcessesChanged() { onProcessesChanged?() }
    func fireDefaultDeviceChanged() { onDefaultDeviceChanged?() }

    func releaseHeld(keepHolding: Bool = false) {
        holdCreates = keepHolding
        let waiting = held
        held.removeAll()
        waiting.forEach { $0.resume() }
    }

    /// Lets the controller's worker run until it is suspended inside `makeTap`. No sleeping.
    func waitForHeldCreate() async {
        for _ in 0..<10_000 where held.isEmpty { await Task.yield() }
    }
}
