import AVFoundation
import CoreAudio

enum AudioCaptureError: Error { case noInput }

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Microphone capture. Forwards raw buffers (native format) to a consumer and publishes
/// a smoothed 0…1 voice level for the waveform.
final class AudioCapture: @unchecked Sendable {
    /// UID of the chosen input device; nil = system default.
    var deviceUID: String?
    let levels: AsyncStream<Float>
    private let levelContinuation: AsyncStream<Float>.Continuation
    private var engine: AVAudioEngine?
    private var startedAt: Date?

    init() {
        (levels, levelContinuation) = AsyncStream.makeStream(of: Float.self, bufferingPolicy: .bufferingNewest(1))
    }

    func start(onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        stopEngine()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = deviceUID, let device = Self.inputDevices().first(where: { $0.uid == uid }),
           let unit = input.audioUnit {
            var id = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        let format = input.outputFormat(forBus: 0)
        // No microphone (or one that vanished) reports 0 Hz / 0 channels; installTap would crash.
        guard Self.isUsable(sampleRate: format.sampleRate, channels: format.channelCount) else {
            throw AudioCaptureError.noInput
        }
        let continuation = levelContinuation
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            if let data = buffer.floatChannelData {
                let samples = UnsafeBufferPointer(start: data[0], count: Int(buffer.frameLength))
                continuation.yield(LevelMeter.level(samples: samples))
            }
            onBuffer(buffer)
        }
        engine.prepare()
        try engine.start()
        self.engine = engine
        startedAt = Date()
    }

    /// Stops capture and returns how long it ran.
    @discardableResult
    func stop() -> TimeInterval {
        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        stopEngine()
        levelContinuation.yield(0)
        return duration
    }

    private func stopEngine() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        startedAt = nil
    }

    static func isUsable(sampleRate: Double, channels: UInt32) -> Bool { sampleRate > 0 && channels > 0 }

    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
