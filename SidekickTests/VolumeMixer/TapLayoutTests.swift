import CoreAudio
import Testing
@testable import Sidekick

struct TapLayoutTests {
    private let stereo = StreamShape(channels: 2, isFloat32: true, isInterleaved: true)
    private let mono = StreamShape(channels: 1, isFloat32: true, isInterleaved: true)

    private func buffers(_ streams: [StreamShape]) -> [Int] {
        streams.flatMap { $0.isInterleaved ? [$0.channels] : Array(repeating: 1, count: $0.channels) }
    }

    private func layout(input: [StreamShape], sub: Int, tap: StreamShape? = nil,
                        output: [StreamShape]) -> TapLayout? {
        TapLayout.make(input: input, inputBuffers: buffers(input), subdeviceInputStreams: sub,
                       tap: tap ?? stereo, output: output, outputBuffers: buffers(output))
    }

    // MARK: - Layout

    @Test func builtInSpeakersTapIsOnlyInput() throws {
        let l = try #require(layout(input: [stereo], sub: 0, output: [stereo]))
        #expect(l.tapFirstBuffer == 0)
        #expect(l.inputBufferCount == 1)
        #expect(l.outputBufferCount == 1)
        #expect(l.outputChannels == 2)
    }

    @Test func tapComesAfterSubdeviceInputs() throws {
        let l = try #require(layout(input: [mono, stereo], sub: 1, output: [stereo]))
        #expect(l.tapFirstBuffer == 1)
        #expect(l.inputBufferCount == 2)
    }

    @Test func planarSubdeviceInputShiftsTapBuffer() throws {
        let planarMic = StreamShape(channels: 2, isFloat32: true, isInterleaved: false)
        let l = try #require(layout(input: [planarMic, stereo], sub: 1, output: [stereo]))
        #expect(l.tapFirstBuffer == 2)
        #expect(l.inputBufferCount == 3)
    }

    @Test func missingTapStreamIsRejected() {
        #expect(layout(input: [mono], sub: 1, output: [stereo]) == nil)
        #expect(layout(input: [], sub: 0, output: [stereo]) == nil)
    }

    @Test func tapFormatMismatchIsRejected() {
        #expect(layout(input: [mono], sub: 0, tap: stereo, output: [stereo]) == nil)
        let int16 = StreamShape(channels: 2, isFloat32: false, isInterleaved: true)
        #expect(layout(input: [int16], sub: 0, tap: int16, output: [stereo]) == nil)
        let surround = StreamShape(channels: 6, isFloat32: true, isInterleaved: true)
        #expect(layout(input: [surround], sub: 0, tap: surround, output: [stereo]) == nil)
    }

    @Test func unusableOutputIsRejected() {
        #expect(layout(input: [stereo], sub: 0, output: []) == nil)
        let int16 = StreamShape(channels: 2, isFloat32: false, isInterleaved: true)
        #expect(layout(input: [stereo], sub: 0, output: [int16]) == nil)
        let empty = StreamShape(channels: 0, isFloat32: true, isInterleaved: true)
        #expect(layout(input: [stereo], sub: 0, output: [empty]) == nil)
    }

    @Test func streamConfigurationMismatchIsRejected() {
        let l = TapLayout.make(input: [stereo], inputBuffers: [1, 1], subdeviceInputStreams: 0,
                               tap: stereo, output: [stereo], outputBuffers: [2])
        #expect(l == nil)
        let o = TapLayout.make(input: [stereo], inputBuffers: [2], subdeviceInputStreams: 0,
                               tap: stereo, output: [stereo], outputBuffers: [2, 2])
        #expect(o == nil)
    }

    @Test func extraOutputStreamsAreCounted() throws {
        let l = try #require(layout(input: [stereo], sub: 0, output: [stereo, mono]))
        #expect(l.outputBufferCount == 2)
    }

    // MARK: - IO proc stream usage

    /// Only the tap's input stream is on, so a headset that shares one device for output and input
    /// (AirPods) isn't asked to open its mic.
    @Test func streamUsageEnablesOnlyTheTapInput() throws {
        let l = try #require(layout(input: [mono, stereo], sub: 1, output: [stereo]))
        #expect(l.inputStreamUsage == [0, 1])
        #expect(l.outputStreamUsage == [1])
        let speakers = try #require(layout(input: [stereo], sub: 0, output: [stereo]))
        #expect(speakers.inputStreamUsage == [1])
    }

    /// The renderer writes only the first output stream; the others stay off.
    @Test func streamUsageEnablesOnlyTheWrittenOutput() throws {
        let planarMic = StreamShape(channels: 2, isFloat32: true, isInterleaved: false)
        let l = try #require(layout(input: [planarMic, mono, stereo], sub: 2, output: [stereo, mono]))
        #expect(l.inputStreamUsage == [0, 0, 1])
        #expect(l.outputStreamUsage == [1, 0])
    }

    /// Disabled streams arrive as NULL buffers in a full-length list (kAudioDevicePropertyIOProcStreamUsage).
    @Test func rendersWithDisabledStreamsAsNullBuffers() throws {
        let l = try #require(layout(input: [mono, stereo], sub: 1, output: [stereo, mono]))
        let lists = Lists(input: [[0.9, 0.9], [0.1, 0.2, 0.3, 0.4]], inputChannels: [1, 2], output: [2, 1], frames: 2)
        lists.input[0].mData?.deallocate()
        lists.input[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        lists.output[1].mData?.deallocate()
        lists.output[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: nil)
        var ramp = settled(1)
        let r = TapRenderer.render(layout: l, input: lists.input, output: lists.output, ramp: &ramp, target: 1)
        #expect(r.ok)
        #expect(lists.out(0) == [0.1, 0.2, 0.3, 0.4])
    }

    // MARK: - Render

    private final class Lists {
        let input: UnsafeMutableAudioBufferListPointer
        let output: UnsafeMutableAudioBufferListPointer
        init(input: [[Float]], inputChannels: [Int], output outputChannels: [Int], frames: Int) {
            self.input = AudioBufferList.allocate(maximumBuffers: input.count)
            for (i, samples) in input.enumerated() {
                let data = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
                data.initialize(from: samples, count: samples.count)
                self.input[i] = AudioBuffer(mNumberChannels: UInt32(inputChannels[i]),
                                            mDataByteSize: UInt32(samples.count * 4), mData: data)
            }
            output = AudioBufferList.allocate(maximumBuffers: outputChannels.count)
            for (i, channels) in outputChannels.enumerated() {
                let count = frames * channels
                let data = UnsafeMutablePointer<Float>.allocate(capacity: count)
                data.initialize(repeating: 9, count: count) // garbage the renderer must overwrite
                output[i] = AudioBuffer(mNumberChannels: UInt32(channels),
                                        mDataByteSize: UInt32(count * 4), mData: data)
            }
        }
        func out(_ index: Int) -> [Float] {
            let buffer = output[index]
            let count = Int(buffer.mDataByteSize) / 4
            return Array(UnsafeBufferPointer(start: buffer.mData!.assumingMemoryBound(to: Float.self), count: count))
        }
        deinit {
            for b in input { b.mData?.deallocate() }
            for b in output { b.mData?.deallocate() }
            free(input.unsafeMutablePointer)
            free(output.unsafeMutablePointer)
        }
    }

    private func settled(_ target: Float) -> GainRamp {
        var ramp = GainRamp(sampleRate: 48_000, initial: target)
        _ = ramp.next(target: target)
        return ramp
    }

    @Test func rendersStereoIntoInterleavedOutputWithGain() throws {
        let l = try #require(layout(input: [stereo], sub: 0, output: [stereo]))
        let lists = Lists(input: [[0.5, -0.5, 0.25, 1]], inputChannels: [2], output: [2], frames: 2)
        var ramp = settled(0.5)
        let r = TapRenderer.render(layout: l, input: lists.input, output: lists.output, ramp: &ramp, target: 0.5)
        #expect(r.ok)
        #expect(r.nonZero)
        #expect(r.peak == 1)
        #expect(lists.out(0) == [0.25, -0.25, 0.125, 0.5])
    }

    @Test func picksTapBufferNotMicBuffer() throws {
        let l = try #require(layout(input: [mono, stereo], sub: 1, output: [stereo]))
        let lists = Lists(input: [[0.9, 0.9], [0.1, 0.2, 0.3, 0.4]], inputChannels: [1, 2], output: [2], frames: 2)
        var ramp = settled(1)
        let r = TapRenderer.render(layout: l, input: lists.input, output: lists.output, ramp: &ramp, target: 1)
        #expect(r.ok)
        #expect(lists.out(0) == [0.1, 0.2, 0.3, 0.4])
        #expect(abs(r.peak - 0.4) < 1e-6)
    }

    @Test func monoOutputAveragesAndExtraChannelsAndBuffersAreZeroed() throws {
        let quad = StreamShape(channels: 4, isFloat32: true, isInterleaved: true)
        let l = try #require(layout(input: [stereo], sub: 0, output: [quad, mono]))
        let lists = Lists(input: [[0.2, 0.4]], inputChannels: [2], output: [4, 1], frames: 1)
        var ramp = settled(1)
        _ = TapRenderer.render(layout: l, input: lists.input, output: lists.output, ramp: &ramp, target: 1)
        #expect(lists.out(0) == [0.2, 0.4, 0, 0])
        #expect(lists.out(1) == [0])

        let m = try #require(layout(input: [stereo], sub: 0, output: [mono]))
        let monoLists = Lists(input: [[0.2, 0.4]], inputChannels: [2], output: [1], frames: 1)
        var monoRamp = settled(1)
        _ = TapRenderer.render(layout: m, input: monoLists.input, output: monoLists.output, ramp: &monoRamp, target: 1)
        #expect(abs(monoLists.out(0)[0] - 0.3) < 1e-6)
    }

    @Test func planarOutputGetsLeftAndRightBuffers() throws {
        let planar = StreamShape(channels: 2, isFloat32: true, isInterleaved: false)
        let l = try #require(layout(input: [stereo], sub: 0, output: [planar]))
        let lists = Lists(input: [[0.1, 0.2, 0.3, 0.4]], inputChannels: [2], output: [1, 1], frames: 2)
        var ramp = settled(1)
        _ = TapRenderer.render(layout: l, input: lists.input, output: lists.output, ramp: &ramp, target: 1)
        #expect(lists.out(0) == [0.1, 0.3])
        #expect(lists.out(1) == [0.2, 0.4])
    }

    @Test func zeroInputReportsSilence() throws {
        let l = try #require(layout(input: [stereo], sub: 0, output: [stereo]))
        let lists = Lists(input: [[0, 0, 0, 0]], inputChannels: [2], output: [2], frames: 2)
        var ramp = settled(1)
        let r = TapRenderer.render(layout: l, input: lists.input, output: lists.output, ramp: &ramp, target: 1)
        #expect(r.ok)
        #expect(!r.nonZero)
        #expect(r.peak == 0)
        #expect(r.frames == 2)
    }

    @Test func unexpectedBufferCountIsAFaultAndOutputsSilence() throws {
        let l = try #require(layout(input: [mono, stereo], sub: 1, output: [stereo]))
        let lists = Lists(input: [[0.5, 0.5, 0.5, 0.5]], inputChannels: [2], output: [2], frames: 2)
        var ramp = settled(1)
        let r = TapRenderer.render(layout: l, input: lists.input, output: lists.output, ramp: &ramp, target: 1)
        #expect(!r.ok)
        #expect(lists.out(0) == [0, 0, 0, 0])
    }

    @Test func gainRampsFromZero() throws {
        let l = try #require(layout(input: [stereo], sub: 0, output: [stereo]))
        let lists = Lists(input: [[1, 1, 1, 1]], inputChannels: [2], output: [2], frames: 2)
        var ramp = GainRamp(sampleRate: 48_000)
        _ = TapRenderer.render(layout: l, input: lists.input, output: lists.output, ramp: &ramp, target: 1)
        let out = lists.out(0)
        #expect(out[0] > 0 && out[0] < 0.01)
        #expect(out[2] > out[0])
    }
}
