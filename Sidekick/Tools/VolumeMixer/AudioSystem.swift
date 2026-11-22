import AppKit
import CoreAudio
import Darwin
import Foundation

/// Everything Volume Mixer needs from Core Audio and the workspace. Mocked in tests.
@MainActor
protocol AudioSystem: AnyObject {
    func processes() -> [AudioProcess]
    func runningApps() -> [RunningApp]
    func parent(of pid: pid_t) -> pid_t?
    func defaultOutputDevice() -> AudioDeviceID?
    func deviceName(_ id: AudioDeviceID) -> String
    /// Callbacks run on the main actor. Calling again replaces the previous listeners.
    func startListening(onProcessesChanged: @escaping @MainActor () -> Void,
                        onDefaultDeviceChanged: @escaping @MainActor () -> Void)
    /// Removes every listener. No callback runs after this returns.
    func stopListening()
    /// Gate → tap unmuted → verify → mute → ramp from 0 to `gain()`, read when setup completes so a
    /// change made meanwhile wins. Slow work runs off the main actor.
    /// On any failure nothing is left behind and the app plays normally.
    func makeTap(processes: [AudioObjectID], device: AudioDeviceID,
                 gain: @escaping @MainActor () -> Float) async throws -> any TapHandle
}

/// One live tap. Call `invalidate()` to release the app to normal sound; `deinit` is only a backstop.
@MainActor
protocol TapHandle: AnyObject {
    func setGain(_ gain: Float)
    /// The latest input peak, 0...1 (0 when the app isn't outputting).
    var level: Float { get }
    func setProcesses(_ ids: [AudioObjectID]) throws
    /// Stops IO, destroys the aggregate, then the tap. Idempotent.
    func invalidate()
    /// IO is running and the input has been all zeros for 1 s (see `SilenceWatchdog`). Either silent
    /// content or a revoked permission: run `SystemAudioPermission.check(maxAge: 0)`.
    var looksRevoked: Bool { get }
    /// Call when that probe said GRANTED (silent content). Within the same silent run the watchdog
    /// then waits 5 s, then 30 s (cap) of further zeros before firing again; real audio re-arms it at 1 s.
    /// So a stream held open but silent costs at most one probe per 30 s in steady state.
    ///
    /// Worst-case silent window after revocation: ≈2.5 s (≈4 s if the probe times out) when the app was
    /// audible at the time. If revocation lands during an already-acknowledged silent run and the app
    /// then starts playing, it can stay silent up to the current backoff (≤30 s), bounded by Task 5's
    /// 30 s periodic probe — ≈30 s + probe time in the worst case.
    func acknowledgeSilence()
    /// The IO buffers stopped matching the layout read at setup; output is silent. Rebuild or release.
    var hasFault: Bool { get }
    /// Seconds since the IO proc last ran (infinity if never). IO runs only while a tapped process
    /// outputs, so this says how long the app has been quiet.
    var secondsSinceIO: TimeInterval { get }
    /// Sidekick's private aggregate device for this tap. It must never count as "another device"
    /// when it shows up in a process's `outputDevices`.
    var aggregateID: AudioObjectID { get }
}

enum MixerTapError: Error, Equatable {
    /// The gate didn't see GRANTED. `.unknown` means retry later, not "denied".
    case permission(SystemAudioState)
    case invalidProcesses
    case noDevice
    /// The aggregate's streams didn't match anything we recognise; no IO was started.
    case unsupportedLayout
    case invalidated
    case coreAudio(String, OSStatus)
}

// MARK: - Live implementation

@MainActor
final class CoreAudioSystem: AudioSystem {
    private let listenerQueue = DispatchQueue(label: "com.sidekick.volumeMixer.listeners")
    private var listening = false
    private var generation = 0
    private var systemBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?
    private var processBlock: AudioObjectPropertyListenerBlock?
    private var watched: Set<AudioObjectID> = []
    private var onProcessesChanged: (@MainActor () -> Void)?
    private var onDefaultDeviceChanged: (@MainActor () -> Void)?
    private var processesChangePending = false

    private static let processListAddress = CoreAudioProperties.address(kAudioHardwarePropertyProcessObjectList)
    private static let defaultOutputAddress = CoreAudioProperties.address(kAudioHardwarePropertyDefaultOutputDevice)
    private static let perProcessAddresses = [
        CoreAudioProperties.address(kAudioProcessPropertyIsRunning),
        CoreAudioProperties.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput),
    ]

    func processes() -> [AudioProcess] {
        CoreAudioProperties.processObjectList().compactMap(CoreAudioProperties.process)
    }

    func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let bundleID = app.bundleIdentifier else { return nil }
            return RunningApp(pid: app.processIdentifier, bundleID: bundleID, name: app.localizedName ?? bundleID)
        }
    }

    func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = pid_t(info.pbi_ppid)
        return parent > 0 ? parent : nil
    }

    func defaultOutputDevice() -> AudioDeviceID? {
        CoreAudioProperties.defaultOutputDevice()
    }

    func deviceName(_ id: AudioDeviceID) -> String {
        CoreAudioProperties.string(id, CoreAudioProperties.address(kAudioObjectPropertyName)) ?? ""
    }

    func makeTap(processes: [AudioObjectID], device: AudioDeviceID,
                 gain: @escaping @MainActor () -> Float) async throws -> any TapHandle {
        try await AppTap.make(processes: processes, device: device, gain: gain)
    }

    // MARK: Listeners

    func startListening(onProcessesChanged: @escaping @MainActor () -> Void,
                        onDefaultDeviceChanged: @escaping @MainActor () -> Void) {
        stopListening()
        listening = true
        self.onProcessesChanged = onProcessesChanged
        self.onDefaultDeviceChanged = onDefaultDeviceChanged
        let system = Self.makeBlock(owner: self, generation: generation, event: .processList)
        let defaultDevice = Self.makeBlock(owner: self, generation: generation, event: .defaultDevice)
        processBlock = Self.makeBlock(owner: self, generation: generation, event: .process)
        systemBlock = system
        defaultDeviceBlock = defaultDevice
        var listAddress = Self.processListAddress
        var defaultAddress = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &listAddress, listenerQueue, system)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddress,
                                            listenerQueue, defaultDevice)
        syncProcessListeners()
    }

    func stopListening() {
        generation += 1
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        if let systemBlock {
            var address = Self.processListAddress
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, listenerQueue, systemBlock)
        }
        if let defaultDeviceBlock {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, listenerQueue, defaultDeviceBlock)
        }
        if let processBlock {
            for id in watched { removeProcessListeners(id, processBlock) }
        }
        watched = []
        systemBlock = nil
        defaultDeviceBlock = nil
        processBlock = nil
        onProcessesChanged = nil
        onDefaultDeviceChanged = nil
        processesChangePending = false
        listening = false
    }

    private enum Event: Sendable { case processList, process, defaultDevice }

    /// Built outside the main actor so the block isn't main-actor-isolated (it runs on `listenerQueue`).
    private nonisolated static func makeBlock(
        owner: CoreAudioSystem, generation: Int, event: Event
    ) -> AudioObjectPropertyListenerBlock {
        { [weak owner] _, _ in
            Task { @MainActor in owner?.handle(event, generation: generation) }
        }
    }

    private func handle(_ event: Event, generation: Int) {
        guard listening, generation == self.generation else { return }
        switch event {
        case .processList:
            syncProcessListeners()
            scheduleProcessesChanged()
        case .process:
            scheduleProcessesChanged()
        case .defaultDevice:
            onDefaultDeviceChanged?()
        }
    }

    /// `ProcessObjectList` fires twice per change and per-process events come in bursts; coalesce.
    private func scheduleProcessesChanged() {
        guard !processesChangePending else { return }
        processesChangePending = true
        let generation = generation
        Task { @MainActor in
            guard self.listening, generation == self.generation else { return }
            self.processesChangePending = false
            self.onProcessesChanged?()
        }
    }

    /// Per-process `IsRunning` and output `Devices` listeners (not `IsRunningOutput`: it never fires).
    private func syncProcessListeners() {
        guard let processBlock else { return }
        let current = Set(CoreAudioProperties.processObjectList())
        for id in current.subtracting(watched) {
            for address in Self.perProcessAddresses {
                var address = address
                AudioObjectAddPropertyListenerBlock(id, &address, listenerQueue, processBlock)
            }
        }
        for id in watched.subtracting(current) {
            removeProcessListeners(id, processBlock) // the object is gone; failure is fine
        }
        watched = current
    }

    private func removeProcessListeners(_ id: AudioObjectID, _ block: @escaping AudioObjectPropertyListenerBlock) {
        for address in Self.perProcessAddresses {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, listenerQueue, block)
        }
    }
}

// MARK: - Property helpers

/// Thin, thread-safe wrappers over `AudioObjectGetPropertyData`. Safe to call from any thread.
enum CoreAudioProperties {
    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, as: T.Type) -> T? {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size,
                                                       alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer) == noErr,
              Int(size) == MemoryLayout<T>.size else { return nil }
        return pointer.load(as: T.self)
    }

    static func array<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, of: T.Type,
                         qualifier: UnsafeRawPointer? = nil, qualifierSize: UInt32 = 0) -> [T] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, qualifierSize, qualifier, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.stride
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(object, &address, qualifierSize, qualifier, &size, pointer) == noErr
        else { return [] }
        let filled = min(count, Int(size) / MemoryLayout<T>.stride)
        return Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: T.self), count: filled))
    }

    static func string(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func processObjectList() -> [AudioObjectID] {
        array(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyProcessObjectList),
              of: AudioObjectID.self)
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func process(_ id: AudioObjectID) -> AudioProcess? {
        guard let pid = value(id, address(kAudioProcessPropertyPID), as: pid_t.self) else { return nil }
        let bundle = string(id, address(kAudioProcessPropertyBundleID))
        let running = value(id, address(kAudioProcessPropertyIsRunningOutput), as: UInt32.self) ?? 0
        let devices = array(id, address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput),
                            of: AudioObjectID.self)
        return AudioProcess(objectID: id, pid: pid, bundleID: bundle?.isEmpty == true ? nil : bundle,
                            isRunningOutput: running != 0, outputDevices: devices)
    }

    static func defaultOutputDevice() -> AudioDeviceID? {
        let id = value(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice),
                       as: AudioDeviceID.self)
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func deviceUID(_ id: AudioDeviceID) -> String? {
        string(id, address(kAudioDevicePropertyDeviceUID))
    }

    /// Channels per buffer, as `kAudioDevicePropertyStreamConfiguration` reports for one scope.
    static func streamConfiguration(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [Int]? {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return nil }
        guard size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.map { Int($0.mNumberChannels) }
    }

    /// The device's streams for one scope, in order, from each stream's virtual format.
    static func streamShapes(_ device: AudioDeviceID, scope: AudioObjectPropertyScope) -> [StreamShape]? {
        let streams = array(device, address(kAudioDevicePropertyStreams, scope: scope), of: AudioStreamID.self)
        var shapes: [StreamShape] = []
        for stream in streams {
            guard let format = value(stream, address(kAudioStreamPropertyVirtualFormat),
                                     as: AudioStreamBasicDescription.self) else { return nil }
            shapes.append(shape(of: format))
        }
        return shapes
    }

    static func shape(of format: AudioStreamBasicDescription) -> StreamShape {
        let flags = format.mFormatFlags
        let isFloat32 = format.mFormatID == kAudioFormatLinearPCM && flags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
        return StreamShape(channels: Int(format.mChannelsPerFrame), isFloat32: isFloat32,
                           isInterleaved: flags & kAudioFormatFlagIsNonInterleaved == 0)
    }
}
