import Testing
import Foundation
import Speech
import os
@testable import Sidekick

/// Integration tests: synthesized speech goes through `AudioExtractor`, then a whole-file transcriber.
struct FileTranscriberTests {
    private static let sentence = "Testing one two three. Sidekick turns speech into text."

    private final class Collector: Sendable {
        let segments = OSAllocatedUnfairLock<[Segment]>(initialState: [])
        let progress = OSAllocatedUnfairLock<[Double]>(initialState: [])
    }

    private static func extracted() async throws -> ExtractedAudio {
        try await AudioExtractor.extract(SpeechFixture.make(sentence))
    }

    private static func run(_ t: some FileTranscriber, on audio: ExtractedAudio) async throws -> Collector {
        let c = Collector()
        try await t.transcribe(audio,
                               onSegments: { s in c.segments.withLock { $0.append(contentsOf: s) } },
                               onProgress: { p in c.progress.withLock { $0.append(p) } })
        return c
    }

    private static func check(_ c: Collector) {
        let segments = c.segments.withLock { $0 }
        let text = segments.map(\.text).joined(separator: " ").lowercased()
        print("FILE ►", text, segments.map { "\($0.start)-\($0.end)" })
        #expect(text.contains("testing"))
        #expect((segments.first?.start ?? -1) >= 0)
        #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.end <= $1.end })
        let progress = c.progress.withLock { $0 }
        #expect((progress.last ?? 0) >= 0.9)
        #expect(progress.allSatisfy { (0...1).contains($0) })
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 })
    }

    private static func tinyModel() async throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-whisper-test")
        return try await WhisperModelStore.download(variant: "openai_whisper-tiny.en", into: base) { _ in }
    }

    @Test(.timeLimit(.minutes(10)))
    func whisperTinyReturnsTimedSegments() async throws {
        let folder = try await Self.tinyModel()
        let audio = try await Self.extracted()
        defer { try? FileManager.default.removeItem(at: audio.url) }
        Self.check(try await Self.run(WhisperFileTranscriber(modelFolder: folder), on: audio))
    }

    @Test(.timeLimit(.minutes(5)))
    func appleReturnsTimedSegments() async throws {
        let audio = try await Self.extracted()
        defer { try? FileManager.default.removeItem(at: audio.url) }
        print("SFSpeechRecognizer authorization:", SFSpeechRecognizer.authorizationStatus().rawValue)
        Self.check(try await Self.run(AppleFileTranscriber(), on: audio))
    }

    @Test(.timeLimit(.minutes(10)))
    func whisperCancelStops() async throws {
        let folder = try await Self.tinyModel()
        let audio = try await Self.extracted()
        defer { try? FileManager.default.removeItem(at: audio.url) }
        let t = WhisperFileTranscriber(modelFolder: folder)
        let task = Task { try await Self.run(t, on: audio) }
        task.cancel()
        let start = ContinuousClock.now
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test(.timeLimit(.minutes(5)))
    func appleCancelStops() async throws {
        let audio = try await Self.extracted()
        defer { try? FileManager.default.removeItem(at: audio.url) }
        let task = Task { try await Self.run(AppleFileTranscriber(), on: audio) }
        task.cancel()
        let start = ContinuousClock.now
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
    }
}
