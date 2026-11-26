import AVFoundation
import Foundation
import Testing
@testable import Sidekick

struct AudioExtractorTests {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-test-\(UUID()).\(ext)")
    }

    private func duration(of url: URL) throws -> Double {
        let f = try AVAudioFile(forReading: url)
        return Double(f.length) / f.processingFormat.sampleRate
    }

    @Test(.timeLimit(.minutes(1)))
    func extractsAiffTo16kMono() async throws {
        let src = try SpeechFixture.make("Testing one two three.")
        defer { try? FileManager.default.removeItem(at: src) }
        #expect(await AudioExtractor.validate(src) == nil)
        let out = try await AudioExtractor.extract(src)
        defer { try? FileManager.default.removeItem(at: out.url) }
        let f = try AVAudioFile(forReading: out.url)
        #expect(f.processingFormat.sampleRate == 16000)
        #expect(f.processingFormat.channelCount == 1)
        let srcDuration = try duration(of: src)
        #expect(abs(out.duration - srcDuration) < 0.2)
        #expect(abs(Double(f.length) / 16000 - srcDuration) < 0.2)
    }

    @Test(.timeLimit(.minutes(1)))
    func extractsAudioFromMovie() async throws {
        let src = try SpeechFixture.make("Testing one two three.")
        let mov = tempURL("mov")
        defer { try? FileManager.default.removeItem(at: src); try? FileManager.default.removeItem(at: mov) }
        let session = try #require(AVAssetExportSession(asset: AVURLAsset(url: src), presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: mov, as: .mov)
        #expect(await AudioExtractor.validate(mov) == nil)
        let out = try await AudioExtractor.extract(mov)
        defer { try? FileManager.default.removeItem(at: out.url) }
        #expect(abs(out.duration - (try duration(of: src))) < 0.2)
    }

    @Test func missingFileIsNotFound() async throws {
        let url = tempURL("mp4")
        #expect(await AudioExtractor.validate(url) == .notFound)
        await #expect(throws: ExtractError.notFound) { try await AudioExtractor.extract(url) }
    }

    @Test func textFileIsUnsupported() async throws {
        let url = tempURL("txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await AudioExtractor.validate(url) == .unsupported)
        await #expect(throws: ExtractError.unsupported) { try await AudioExtractor.extract(url) }
    }

    @Test func folderIsUnsupported() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await AudioExtractor.validate(url) == .unsupported)
        await #expect(throws: ExtractError.unsupported) { try await AudioExtractor.extract(url) }
    }

    @Test(.timeLimit(.minutes(1)))
    func videoWithoutAudioIsNoAudio() async throws {
        let url = tempURL("mov")
        defer { try? FileManager.default.removeItem(at: url) }
        try await writeBlackVideo(to: url)
        #expect(await AudioExtractor.validate(url) == .noAudio)
        await #expect(throws: ExtractError.noAudio) { try await AudioExtractor.extract(url) }
    }

    @Test func messagesMatchCopy() {
        #expect(ExtractError.notFound.message == "File not found.")
        #expect(ExtractError.unsupported.message == "This format isn't supported.")
        #expect(ExtractError.noAudio.message == "This file has no audio.")
    }

    private func writeBlackVideo(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                          kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
        let buffer = try #require(pb)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
        adaptor.append(buffer, withPresentationTime: .zero)
        input.markAsFinished()
        await writer.finishWriting()
        try #require(writer.status == .completed)
    }

    @Test func removesOnlyLeftoverExtractedAudio() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-leftovers-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let leftover = dir.appendingPathComponent("\(AudioExtractor.tempPrefix)\(UUID().uuidString).caf")
        let other = dir.appendingPathComponent("sidekick-other.caf")
        let notCaf = dir.appendingPathComponent("\(AudioExtractor.tempPrefix)notes.txt")
        for url in [leftover, other, notCaf] { try Data([1]).write(to: url) }
        AudioExtractor.removeLeftovers(in: dir)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: notCaf.path))
    }

    @Test(.timeLimit(.minutes(1)))
    func extractedFileUsesTheLeftoverPrefix() async throws {
        let src = try SpeechFixture.make("Hi.")
        defer { try? FileManager.default.removeItem(at: src) }
        let audio = try await AudioExtractor.extract(src)
        defer { try? FileManager.default.removeItem(at: audio.url) }
        #expect(audio.url.lastPathComponent.hasPrefix(AudioExtractor.tempPrefix))
        #expect(audio.url.pathExtension == "caf")
    }
}
