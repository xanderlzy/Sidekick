import AVFoundation
import Foundation

enum ExtractError: Error, Equatable {
    case notFound, unsupported, noAudio

    var message: String {
        switch self {
        case .notFound: "File not found."
        case .unsupported: "This format isn't supported."
        case .noAudio: "This file has no audio."
        }
    }
}

/// A temporary 16 kHz mono Float32 .caf. The caller deletes it.
struct ExtractedAudio: Sendable {
    let url: URL
    let duration: Double
}

enum AudioExtractor {
    static let sampleRate: Double = 16_000

    /// Cheap drop-time check: exists, not a folder, readable as media, has an audio track.
    static func validate(_ url: URL) async -> ExtractError? {
        do { _ = try await openAudioTrack(url); return nil }
        catch let e as ExtractError { return e }
        catch { return .unsupported }
    }

    static func extract(_ url: URL) async throws -> ExtractedAudio {
        let (asset, track) = try await openAudioTrack(url)
        try Task.checkCancellation()

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard let reader = try? AVAssetReader(asset: asset) else { throw ExtractError.unsupported }
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: settings)
        guard reader.canAdd(output) else { throw ExtractError.unsupported }
        reader.add(output)
        guard reader.startReading() else { throw ExtractError.unsupported }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidekick-transcribe-\(UUID().uuidString).caf")
        var succeeded = false
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if !succeeded { try? FileManager.default.removeItem(at: outURL) }
        }

        var frames: AVAudioFramePosition = 0
        do {
            let file = try AVAudioFile(forWriting: outURL, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: true)
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                guard let buffer = pcmBuffer(from: sample, format: file.processingFormat) else { throw ExtractError.unsupported }
                try file.write(from: buffer)
                frames += AVAudioFramePosition(buffer.frameLength)
            }
            try Task.checkCancellation()
            if reader.status == .failed { throw reader.error ?? ExtractError.unsupported }
        }
        succeeded = true
        return ExtractedAudio(url: outURL, duration: Double(frames) / sampleRate)
    }

    private static func openAudioTrack(_ url: URL) async throws -> (AVURLAsset, AVAssetTrack) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { throw ExtractError.notFound }
        guard !isDir.boolValue else { throw ExtractError.unsupported }
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            guard try await asset.load(.isReadable) else { throw ExtractError.unsupported }
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch let e as ExtractError {
            throw e
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ExtractError.unsupported
        }
        guard let track = tracks.first else { throw ExtractError.noAudio }
        return (asset, track)
    }

    private static func pcmBuffer(from sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let n = AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))
        guard n > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return nil }
        buffer.frameLength = n
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sample, at: 0, frameCount: Int32(n), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}
