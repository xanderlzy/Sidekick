import CoreAudio
import Foundation
import Observation

/// Which elements of a device carry a control (volume or mute). Pure.
enum SystemVolumeElements {
    static let channels: [AudioObjectPropertyElement] = [1, 2]

    /// The main element when it's settable, else whichever of channels 1 and 2 are.
    /// Empty means the device hides the control (HDMI, AirPlay and most aggregates).
    static func select(settable: (AudioObjectPropertyElement) -> Bool) -> [AudioObjectPropertyElement] {
        if settable(kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        return channels.filter(settable)
    }

    static func average(_ values: [Float32]) -> Double? {
        guard !values.isEmpty else { return nil }
        return Double(values.reduce(0, +)) / Double(values.count)
    }
}

/// The default output device's volume and mute, kept live while started.
/// `volume` is nil when the device has no software volume ("This device controls its own volume").
@MainActor @Observable
final class SystemVolume {
    private(set) var deviceName = ""
    private(set) var volume: Double?
    private(set) var muted = false
    /// False when the device has no settable mute either; the glyph is then inert.
    private(set) var canMute = false

    /// The device and elements the listeners are bound to, so removal mirrors the add exactly.
    private struct Binding {
        let device: AudioDeviceID
        let volumeElements: [AudioObjectPropertyElement]
        let muteElements: [AudioObjectPropertyElement]
        let block: AudioObjectPropertyListenerBlock
    }

    @ObservationIgnored private let queue = DispatchQueue(label: "com.sidekick.volumeMixer.systemVolume")
    @ObservationIgnored private var running = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var defaultDeviceBlock: AudioObjectPropertyListenerBlock?
    @ObservationIgnored private var binding: Binding?
    @ObservationIgnored private var readPending = false

    private static let defaultOutputAddress = CoreAudioProperties.address(kAudioHardwarePropertyDefaultOutputDevice)

    init() {}

    // MARK: Lifecycle

    /// Starts listening to the default device, its volume and its mute. Idempotent.
    func start() {
        guard !running else { return }
        running = true
        generation += 1
        let block = Self.makeBlock(owner: self, generation: generation, rebind: true)
        defaultDeviceBlock = block
        var address = Self.defaultOutputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        rebind()
    }

    /// Removes every listener. No update runs after this returns. Idempotent.
    func stop() {
        guard running else { return }
        running = false
        generation += 1
        if let defaultDeviceBlock {
            var address = Self.defaultOutputAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, queue,
                                                   defaultDeviceBlock)
        }
        defaultDeviceBlock = nil
        unbind()
        readPending = false
    }

    // MARK: Controls

    /// Sets the device volume (0...1). Channel-only devices get both channels set.
    func setVolume(_ value: Double) {
        guard let binding, !binding.volumeElements.isEmpty else { return }
        var scalar = Float32(min(1, max(0, value)))
        for element in binding.volumeElements {
            var address = Self.volumeAddress(element)
            AudioObjectSetPropertyData(binding.device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &scalar)
        }
        volume = Double(scalar)
    }

    func toggleMute() {
        guard let binding, !binding.muteElements.isEmpty else { return }
        var flag: UInt32 = muted ? 0 : 1
        for element in binding.muteElements {
            var address = Self.muteAddress(element)
            AudioObjectSetPropertyData(binding.device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &flag)
        }
        muted = flag != 0
    }

    // MARK: Binding

    /// Moves the volume and mute listeners onto the current default device and reads it.
    private func rebind() {
        unbind()
        guard running, let device = CoreAudioProperties.defaultOutputDevice() else {
            deviceName = ""
            volume = nil
            muted = false
            canMute = false
            return
        }
        let volumeElements = SystemVolumeElements.select { Self.isSettable(device, Self.volumeAddress($0)) }
        let muteElements = SystemVolumeElements.select { Self.isSettable(device, Self.muteAddress($0)) }
        let block = Self.makeBlock(owner: self, generation: generation, rebind: false)
        for address in volumeElements.map(Self.volumeAddress) + muteElements.map(Self.muteAddress) {
            var address = address
            AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        }
        binding = Binding(device: device, volumeElements: volumeElements, muteElements: muteElements, block: block)
        read()
    }

    private func unbind() {
        guard let binding else { return }
        for address in binding.volumeElements.map(Self.volumeAddress) + binding.muteElements.map(Self.muteAddress) {
            var address = address
            AudioObjectRemovePropertyListenerBlock(binding.device, &address, queue, binding.block)
        }
        self.binding = nil
    }

    private func read() {
        guard let binding else { return }
        let name = CoreAudioProperties.string(binding.device, CoreAudioProperties.address(kAudioObjectPropertyName)) ?? ""
        let volumes = binding.volumeElements.compactMap {
            CoreAudioProperties.value(binding.device, Self.volumeAddress($0), as: Float32.self)
        }
        let mutes = binding.muteElements.compactMap {
            CoreAudioProperties.value(binding.device, Self.muteAddress($0), as: UInt32.self)
        }
        let newVolume = SystemVolumeElements.average(volumes)
        let newMuted = !mutes.isEmpty && mutes.allSatisfy { $0 != 0 }
        if deviceName != name { deviceName = name }
        if volume != newVolume { volume = newVolume }
        if muted != newMuted { muted = newMuted }
        if canMute != !binding.muteElements.isEmpty { canMute = !binding.muteElements.isEmpty }
    }

    private func handle(rebind shouldRebind: Bool, generation: Int) {
        guard running, generation == self.generation else { return }
        if shouldRebind {
            rebind()
            return
        }
        // Volume keys fire a burst (both channels, repeats); read once per main-actor turn.
        guard !readPending else { return }
        readPending = true
        Task { @MainActor in
            guard self.running, generation == self.generation else { return }
            self.readPending = false
            self.read()
        }
    }

    /// Built outside the main actor so the block isn't main-actor-isolated (it runs on `queue`).
    private nonisolated static func makeBlock(owner: SystemVolume, generation: Int,
                                              rebind: Bool) -> AudioObjectPropertyListenerBlock {
        { [weak owner] _, _ in
            Task { @MainActor in owner?.handle(rebind: rebind, generation: generation) }
        }
    }

    // MARK: Addresses

    private static func volumeAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        CoreAudioProperties.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput,
                                    element: element)
    }

    private static func muteAddress(_ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        CoreAudioProperties.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput,
                                    element: element)
    }

    private static func isSettable(_ device: AudioDeviceID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }
}
