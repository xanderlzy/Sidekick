import CoreAudio
import Darwin
import Foundation
import os
import Synchronization

/// The live `TapHandle`: one process tap, a private aggregate device and an IO proc that plays the
/// tapped audio back at `gain` (spike §2/§3).
@MainActor
final class AppTap: TapHandle {
    private static let log = Logger(subsystem: "com.sidekick.app", category: "VolumeMixer")
    private static var registry: [WeakTap] = []

    private let session: TapSession
    private var invalidated = false
    private var watchdog = SilenceWatchdog()

    private init(session: TapSession) {
        self.session = session
        Self.registry.removeAll { $0.tap == nil }
        Self.registry.append(WeakTap(tap: self))
    }

    deinit {
        // Backstop only; owners call invalidate(). `destroy()` is idempotent and thread-safe.
        session.destroy()
    }

    /// Gate → create unmuted with output gain 0 → verify → flip to `.mutedWhenTapped` → ramp to `gain`.
    static func make(processes: [AudioObjectID], device: AudioDeviceID, gain: Float) async throws -> AppTap {
        guard !processes.isEmpty, !processes.contains(kAudioObjectUnknown) else {
            throw MixerTapError.invalidProcesses
        }
        // 1. Gate: GRANTED within 30 s, or probe now. Never create a muting tap without it.
        let state = await SystemAudioPermission.ensureGranted()
        guard state == .granted else { throw MixerTapError.permission(state) }

        // 2. Create the tap unmuted; IO starts at gain 0, so nothing changes audibly yet.
        let name = "Sidekick mixer \(processes.map(String.init).joined(separator: ","))"
        let session = try await offMain {
            try TapSession.start(processes: processes, device: device, name: name)
        }
        let tap = AppTap(session: session)
        do {
            // 3. Verify audio flows (or that the app is simply silent).
            try await tap.verify()
            // Creation can be slow; re-run the gate if the grant has gone stale meanwhile.
            if !tap.heardAudio(within: PermissionLedger.freshWindow) {
                let again = await SystemAudioPermission.ensureGranted()
                guard again == .granted else { throw MixerTapError.permission(again) }
            }
            // A cancelled make must release, never mute.
            try Task.checkCancellation()
            // 4. Mute the original. Only after this returns do we raise the copy's gain, so the copy
            // never plays on top of the not-yet-muted original.
            try await offMain { try session.setMuted(true) }
            // 5. Ramp from 0 to the target (~20 ms).
            tap.setGain(gain)
            return tap
        } catch {
            tap.invalidate()
            log.error("Tap setup failed: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    /// Waits up to ~200 ms. Non-zero input: fine. Only zeros while callbacks run: could be silent
    /// content or a revoked permission, so ask a fresh probe. No callbacks: the app is silent; the
    /// IO proc will start by itself when it plays.
    private func verify() async throws {
        let io = session.io
        for _ in 0..<20 {
            if io.fault.load(ordering: .relaxed) { throw MixerTapError.unsupportedLayout }
            if io.nonZeroCallbacks.load(ordering: .relaxed) > 0 { return }
            if io.callbacks.load(ordering: .relaxed) >= 10 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        if io.nonZeroCallbacks.load(ordering: .relaxed) > 0 { return }
        guard io.callbacks.load(ordering: .relaxed) > 0 else { return }
        let state = await SystemAudioPermission.check(maxAge: 0)
        guard state == .granted else { throw MixerTapError.permission(state) }
    }

    // MARK: TapHandle

    func setGain(_ gain: Float) {
        let clamped = gain.isFinite ? min(max(gain, 0), 1) : 0
        session.io.gain.store(clamped.bitPattern, ordering: .relaxed)
    }

    var level: Float {
        guard !invalidated, HostClock.seconds(since: session.io.lastCallback.load(ordering: .relaxed)) < 0.25
        else { return 0 }
        return Float(bitPattern: session.io.level.load(ordering: .relaxed))
    }

    func setProcesses(_ ids: [AudioObjectID]) throws {
        guard !invalidated else { throw MixerTapError.invalidated }
        guard !ids.isEmpty, !ids.contains(kAudioObjectUnknown) else { throw MixerTapError.invalidProcesses }
        try session.setProcesses(ids)
    }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        session.destroy()
        Self.registry.removeAll { $0.tap == nil || $0.tap === self }
    }

    var looksRevoked: Bool {
        guard !invalidated else { return false }
        let io = session.io
        // IO only runs while a tapped process outputs; no recent callback means nothing is playing.
        guard HostClock.seconds(since: io.lastCallback.load(ordering: .relaxed)) < 0.5 else { return false }
        return watchdog.looksRevoked(nonZero: io.nonZeroCallbacks.load(ordering: .relaxed),
                                     zeroFrames: io.zeroFrames.load(ordering: .relaxed),
                                     sampleRate: session.sampleRate)
    }

    func acknowledgeSilence() {
        watchdog.acknowledge(nonZero: session.io.nonZeroCallbacks.load(ordering: .relaxed),
                             zeroFrames: session.io.zeroFrames.load(ordering: .relaxed))
    }

    var hasFault: Bool { !invalidated && session.io.fault.load(ordering: .relaxed) }

    var aggregateID: AudioObjectID { session.aggregateID }

    // MARK: Permission evidence

    /// When this tap last delivered non-zero input: proof of the permission (spike §3 fast path).
    var lastAudioEvidence: Date? {
        let stamp = session.io.lastNonZero.load(ordering: .relaxed)
        guard !invalidated, stamp != 0 else { return nil }
        return Date(timeIntervalSinceNow: -HostClock.seconds(since: stamp))
    }

    func heardAudio(within seconds: TimeInterval) -> Bool {
        guard let evidence = lastAudioEvidence else { return false }
        return -evidence.timeIntervalSinceNow <= seconds
    }

    /// The newest non-zero input across all live taps.
    static var latestAudioEvidence: Date? {
        registry.compactMap { $0.tap?.lastAudioEvidence }.max()
    }

    private struct WeakTap {
        weak var tap: AppTap?
    }

    private nonisolated static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }
}

// MARK: - Shared IO state

/// Crosses between the IO thread and everything else. Atomics only; Float values as bit patterns.
final class TapIOState: Sendable {
    let gain = Atomic<UInt32>(Float(0).bitPattern)
    let level = Atomic<UInt32>(Float(0).bitPattern)
    let callbacks = Atomic<UInt64>(0)
    let nonZeroCallbacks = Atomic<UInt64>(0)
    /// Consecutive all-zero input frames; reset to 0 by any non-zero callback.
    let zeroFrames = Atomic<UInt64>(0)
    /// `mach_absolute_time()` of the last callback / the last non-zero callback (0 = never).
    let lastCallback = Atomic<UInt64>(0)
    let lastNonZero = Atomic<UInt64>(0)
    let fault = Atomic<Bool>(false)

    /// Called from the IO proc. Real-time safe.
    func record(_ result: TapRenderer.Result) {
        let now = mach_absolute_time()
        callbacks.wrappingAdd(1, ordering: .relaxed)
        lastCallback.store(now, ordering: .relaxed)
        level.store(min(result.peak, 1).bitPattern, ordering: .relaxed)
        if !result.ok { fault.store(true, ordering: .relaxed) }
        if result.nonZero {
            nonZeroCallbacks.wrappingAdd(1, ordering: .relaxed)
            zeroFrames.store(0, ordering: .relaxed)
            lastNonZero.store(now, ordering: .relaxed)
        } else {
            zeroFrames.wrappingAdd(UInt64(result.frames), ordering: .relaxed)
        }
    }
}

/// Ramp state owned by the IO proc. Only the IO thread (one serial queue) touches `ramp`. Held
/// behind a pointer so the IO proc's `inout` access has no runtime exclusivity check. Freed when the
/// IO block is released, which is after the IO proc is destroyed.
private final class IORenderState: @unchecked Sendable {
    let ramp: UnsafeMutablePointer<GainRamp>
    init(sampleRate: Double) {
        ramp = .allocate(capacity: 1)
        ramp.initialize(to: GainRamp(sampleRate: sampleRate, initial: 0))
    }
    deinit {
        ramp.deinitialize(count: 1)
        ramp.deallocate()
    }
}

enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Seconds since a `mach_absolute_time()` stamp; infinity for 0 (never).
    static func seconds(since stamp: UInt64) -> TimeInterval {
        guard stamp != 0 else { return .infinity }
        let now = mach_absolute_time()
        guard now > stamp else { return 0 }
        let nanos = Double(now - stamp) * Double(timebase.numer) / Double(timebase.denom)
        return nanos / 1e9
    }
}

// MARK: - Core Audio objects

/// Owns the tap, aggregate and IO proc. Not actor-bound: setup is blocking and runs off the main
/// actor; `destroy()` is idempotent and safe from any thread (including `deinit`).
final class TapSession: Sendable {
    let io: TapIOState
    let sampleRate: Double
    /// The private aggregate device. Fixed for the session's lifetime.
    let aggregateID: AudioObjectID

    private struct Objects {
        var tap = AudioObjectID(kAudioObjectUnknown)
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        var procID: AudioDeviceIOProcID?
        var description: CATapDescription?
        var destroyed = false
    }

    private let objects: Mutex<Objects>

    private init(objects: sending Objects, sampleRate: Double, io: TapIOState) {
        self.aggregateID = objects.aggregate
        self.objects = Mutex(objects)
        self.sampleRate = sampleRate
        self.io = io
    }

    deinit { destroy() }

    /// Creates an **unmuted** private tap, its aggregate and a running IO proc at gain 0.
    /// Blocking (can take seconds the first time). On failure, destroys whatever it created.
    static func start(processes: [AudioObjectID], device: AudioDeviceID, name: String) throws -> TapSession {
        guard !processes.isEmpty, !processes.contains(kAudioObjectUnknown) else {
            throw MixerTapError.invalidProcesses
        }
        guard let deviceUID = CoreAudioProperties.deviceUID(device) else { throw MixerTapError.noDevice }

        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = name

        var objects = Objects()
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create tap")
        objects.tap = tap
        objects.description = description

        do {
            let aggregateInfo: [String: Any] = [
                kAudioAggregateDeviceNameKey: name,
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            var aggregate = AudioObjectID(kAudioObjectUnknown)
            try check(AudioHardwareCreateAggregateDevice(aggregateInfo as CFDictionary, &aggregate), "create aggregate")
            objects.aggregate = aggregate

            let layout = try readLayout(aggregate: aggregate, tap: tap, device: device)
            let rate = CoreAudioProperties.value(aggregate, CoreAudioProperties.address(kAudioDevicePropertyNominalSampleRate),
                                                 as: Float64.self) ?? 48_000
            let sampleRate = rate > 0 ? rate : 48_000

            let io = TapIOState()
            let render = IORenderState(sampleRate: sampleRate)
            let queue = DispatchQueue(label: "com.sidekick.volumeMixer.io", qos: .userInteractive)
            var procID: AudioDeviceIOProcID?
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, queue,
                                                         makeIOBlock(layout: layout, io: io, render: render)),
                      "create IO proc")
            guard let procID else { throw MixerTapError.coreAudio("create IO proc", -1) }
            objects.procID = procID
            try check(AudioDeviceStart(aggregate, procID), "start IO")

            return TapSession(objects: objects, sampleRate: sampleRate, io: io)
        } catch {
            teardown(objects.aggregate, objects.procID, objects.tap)
            throw error
        }
    }

    func setMuted(_ muted: Bool) throws {
        try updateDescription { $0.muteBehavior = muted ? .mutedWhenTapped : .unmuted }
    }

    func setProcesses(_ ids: [AudioObjectID]) throws {
        try updateDescription { $0.processes = ids }
    }

    /// Stop IO → destroy IO proc → destroy aggregate → destroy tap. Idempotent.
    func destroy() {
        let ids = objects.withLock { objects -> (AudioObjectID, AudioDeviceIOProcID?, AudioObjectID)? in
            guard !objects.destroyed else { return nil }
            objects.destroyed = true
            objects.description = nil
            return (objects.aggregate, objects.procID, objects.tap)
        }
        guard let ids else { return }
        Self.teardown(ids.0, ids.1, ids.2)
    }

    // MARK: Private

    private func updateDescription(_ change: (CATapDescription) -> Void) throws {
        try objects.withLock { objects in
            guard !objects.destroyed, let description = objects.description else { throw MixerTapError.invalidated }
            let previousProcesses = description.processes
            let previousMute = description.muteBehavior
            change(description)
            var address = CoreAudioProperties.address(kAudioTapPropertyDescription)
            var value: CATapDescription? = description
            let status = withUnsafeMutablePointer(to: &value) {
                AudioObjectSetPropertyData(objects.tap, &address, 0, nil,
                                           UInt32(MemoryLayout<CATapDescription?>.size), $0)
            }
            if status != noErr {
                description.processes = previousProcesses
                description.muteBehavior = previousMute
                throw MixerTapError.coreAudio("update tap", status)
            }
        }
    }

    private static func teardown(_ aggregate: AudioObjectID, _ procID: AudioDeviceIOProcID?, _ tap: AudioObjectID) {
        if aggregate != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregate, procID)
                AudioDeviceDestroyIOProcID(aggregate, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    private static func readLayout(aggregate: AudioDeviceID, tap: AudioObjectID, device: AudioDeviceID) throws -> TapLayout {
        guard let tapFormat = CoreAudioProperties.value(tap, CoreAudioProperties.address(kAudioTapPropertyFormat),
                                                        as: AudioStreamBasicDescription.self),
              let input = CoreAudioProperties.streamShapes(aggregate, scope: kAudioObjectPropertyScopeInput),
              let output = CoreAudioProperties.streamShapes(aggregate, scope: kAudioObjectPropertyScopeOutput),
              let inputBuffers = CoreAudioProperties.streamConfiguration(aggregate, scope: kAudioObjectPropertyScopeInput),
              let outputBuffers = CoreAudioProperties.streamConfiguration(aggregate, scope: kAudioObjectPropertyScopeOutput),
              let deviceInputs = CoreAudioProperties.streamShapes(device, scope: kAudioObjectPropertyScopeInput)
        else { throw MixerTapError.unsupportedLayout }
        guard let layout = TapLayout.make(
            input: input, inputBuffers: inputBuffers, subdeviceInputStreams: deviceInputs.count,
            tap: CoreAudioProperties.shape(of: tapFormat), output: output, outputBuffers: outputBuffers)
        else {
            Logger(subsystem: "com.sidekick.app", category: "VolumeMixer").error(
                "Unrecognised tap layout: in \(String(describing: input), privacy: .public) \(inputBuffers, privacy: .public) out \(String(describing: output), privacy: .public) \(outputBuffers, privacy: .public) subIn \(deviceInputs.count, privacy: .public)")
            throw MixerTapError.unsupportedLayout
        }
        return layout
    }

    /// Built in a nonisolated static context so the block carries no actor isolation.
    private static func makeIOBlock(layout: TapLayout, io: TapIOState, render: IORenderState) -> AudioDeviceIOBlock {
        { _, inputData, _, outputData, _ in
            let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            let output = UnsafeMutableAudioBufferListPointer(outputData)
            let target = Float(bitPattern: io.gain.load(ordering: .relaxed))
            let result = TapRenderer.render(layout: layout, input: input, output: output,
                                            ramp: &render.ramp.pointee, target: target)
            io.record(result)
        }
    }

    private static func check(_ status: OSStatus, _ operation: String) throws {
        guard status == noErr else { throw MixerTapError.coreAudio(operation, status) }
    }
}
