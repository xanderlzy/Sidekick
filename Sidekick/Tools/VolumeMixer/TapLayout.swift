import CoreAudio
import Foundation

/// The parts of one stream's format the renderer cares about.
struct StreamShape: Equatable, Sendable {
    var channels: Int
    var isFloat32: Bool
    var isInterleaved: Bool

    /// Buffers this stream occupies in an IO `AudioBufferList`.
    var buffers: [Int] { isInterleaved ? [channels] : Array(repeating: 1, count: channels) }
}

/// Where the tap's audio sits in the aggregate's input, and where it goes in the output.
/// Computed once before IO starts; the IO proc only reads these constants. Pure.
struct TapLayout: Equatable, Sendable {
    let inputBufferCount: Int
    let tapFirstBuffer: Int
    let tapChannels: Int
    let tapInterleaved: Bool
    let outputBufferCount: Int
    let outputChannels: Int
    let outputInterleaved: Bool

    /// - Parameters:
    ///   - input/output: the aggregate's streams in order (`kAudioStreamPropertyVirtualFormat`).
    ///   - inputBuffers/outputBuffers: channels per buffer from `kAudioDevicePropertyStreamConfiguration`.
    ///   - subdeviceInputStreams: how many input streams the real subdevice contributes; the tap's
    ///     stream comes right after them.
    ///   - tap: the tap's own format (`kAudioTapPropertyFormat`).
    /// - Returns: nil for any layout we don't recognise. Never guess: a wrong guess is noise or silence.
    static func make(
        input: [StreamShape], inputBuffers: [Int], subdeviceInputStreams: Int, tap: StreamShape,
        output: [StreamShape], outputBuffers: [Int]
    ) -> TapLayout? {
        guard subdeviceInputStreams >= 0, input.count == subdeviceInputStreams + 1,
              input.flatMap(\.buffers) == inputBuffers,
              output.flatMap(\.buffers) == outputBuffers else { return nil }
        let tapStream = input[subdeviceInputStreams]
        guard tap.isFloat32, tapStream.isFloat32, (1...2).contains(tap.channels),
              tapStream.channels == tap.channels else { return nil }
        guard let first = output.first, first.isFloat32, first.channels >= 1 else { return nil }
        return TapLayout(
            inputBufferCount: inputBuffers.count,
            tapFirstBuffer: input[..<subdeviceInputStreams].reduce(0) { $0 + $1.buffers.count },
            tapChannels: tap.channels,
            tapInterleaved: tapStream.isInterleaved,
            outputBufferCount: outputBuffers.count,
            outputChannels: first.channels,
            outputInterleaved: first.isInterleaved)
    }
}

/// The IO proc's work, as a function over buffer lists so it can be tested without Core Audio.
/// Real-time safe: no allocation, locks, logging or actor state.
enum TapRenderer {
    struct Result {
        /// Input peak (before gain).
        var peak: Float = 0
        var nonZero = false
        var frames = 0
        /// False when the buffers don't match the layout; the output is then silence.
        var ok = true
    }

    static func render(
        layout: TapLayout,
        input: UnsafeMutableAudioBufferListPointer,
        output: UnsafeMutableAudioBufferListPointer,
        ramp: inout GainRamp,
        target: Float
    ) -> Result {
        for buffer in output {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }
        var result = Result()
        guard input.count == layout.inputBufferCount, output.count == layout.outputBufferCount else {
            result.ok = false
            return result
        }

        // Source pointers (left, right) and stride, in samples.
        let tapBuffer = input[layout.tapFirstBuffer]
        guard let left = tapBuffer.mData?.assumingMemoryBound(to: Float.self) else {
            result.ok = false
            return result
        }
        var right = left
        var inStride = 1
        var inFrames: Int
        if layout.tapInterleaved {
            guard Int(tapBuffer.mNumberChannels) == layout.tapChannels else { result.ok = false; return result }
            inStride = layout.tapChannels
            inFrames = Int(tapBuffer.mDataByteSize) / (4 * layout.tapChannels)
            if layout.tapChannels == 2 { right = left + 1 }
        } else {
            inFrames = Int(tapBuffer.mDataByteSize) / 4
            if layout.tapChannels == 2 {
                let r = input[layout.tapFirstBuffer + 1]
                guard let data = r.mData?.assumingMemoryBound(to: Float.self) else { result.ok = false; return result }
                right = data
                inFrames = min(inFrames, Int(r.mDataByteSize) / 4)
            }
        }

        // Destination pointers.
        let outBuffer = output[0]
        guard let outLeft = outBuffer.mData?.assumingMemoryBound(to: Float.self) else {
            result.ok = false
            return result
        }
        var outRight: UnsafeMutablePointer<Float>? = nil
        var outStride = 1
        var outFrames: Int
        if layout.outputInterleaved {
            guard Int(outBuffer.mNumberChannels) == layout.outputChannels else { result.ok = false; return result }
            outStride = layout.outputChannels
            outFrames = Int(outBuffer.mDataByteSize) / (4 * layout.outputChannels)
            if layout.outputChannels >= 2 { outRight = outLeft + 1 }
        } else {
            outFrames = Int(outBuffer.mDataByteSize) / 4
            if layout.outputChannels >= 2 {
                let r = output[1]
                guard let data = r.mData?.assumingMemoryBound(to: Float.self) else { result.ok = false; return result }
                outRight = data
                outFrames = min(outFrames, Int(r.mDataByteSize) / 4)
            }
        }

        let frames = min(inFrames, outFrames)
        var peak: Float = 0
        for frame in 0..<max(frames, 0) {
            let l = left[frame * inStride]
            let r = right[frame * inStride]
            peak = max(peak, abs(l), abs(r))
            let gain = ramp.next(target: target)
            if let outRight {
                outLeft[frame * outStride] = l * gain
                outRight[frame * outStride] = r * gain
            } else {
                outLeft[frame * outStride] = (l + r) * 0.5 * gain
            }
        }
        result.frames = max(frames, 0)
        result.peak = peak
        result.nonZero = peak > 0
        return result
    }
}

/// Zero-input watchdog decision (spike §3), with backoff for streams that stay open but silent.
/// Pure: fed the IO counters by `AppTap`.
///
/// Fires after 1 s of consecutive all-zero input. Each `acknowledge` (a probe said GRANTED, so it's
/// silent content) within the same silent run waits longer before firing again: 5 s, then 30 s
/// (cap). Any non-zero audio (the non-zero callback count changes) re-arms it at 1 s.
struct SilenceWatchdog: Sendable {
    static let intervals: [Double] = [1, 5, 30]

    private var ackNonZero: UInt64?
    private var ackZeroFrames: UInt64 = 0
    private var level = 0

    func looksRevoked(nonZero: UInt64, zeroFrames: UInt64, sampleRate: Double) -> Bool {
        if let ackNonZero, ackNonZero == nonZero {
            let wait = UInt64(Self.intervals[level] * sampleRate)
            return zeroFrames >= ackZeroFrames &+ wait
        }
        return zeroFrames >= UInt64(Self.intervals[0] * sampleRate)
    }

    mutating func acknowledge(nonZero: UInt64, zeroFrames: UInt64) {
        level = ackNonZero == nonZero ? min(level + 1, Self.intervals.count - 1) : 1
        ackNonZero = nonZero
        ackZeroFrames = zeroFrames
    }
}
