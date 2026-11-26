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
        let batches = OSAllocatedUnfairLock<Int>(initialState: 0)
    }

    private static func extracted() async throws -> ExtractedAudio {
        try await AudioExtractor.extract(SpeechFixture.make(sentence))
    }

    private static func run(_ t: some FileTranscriber, on audio: ExtractedAudio) async throws -> Collector {
        let c = Collector()
        try await t.transcribe(audio,
                               onSegments: { s in c.batches.withLock { $0 += 1 }; c.segments.withLock { $0.append(contentsOf: s) } },
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

    /// About 90 s of speech with 2 s gaps, so Whisper's VAD chunking and Apple's incremental results both kick in.
    private static func longExtracted() async throws -> ExtractedAudio {
        let sentences = [
            "Testing one two three, this is the first part of the lecture.",
            "Today we will talk about how computers turn speech into text.",
            "The microphone records pressure waves and stores them as numbers.",
            "Then a model looks at short windows of sound and guesses words.",
            "Longer recordings are split wherever there is a pause in speech.",
            "Each piece is transcribed on its own and then joined together.",
            "That keeps memory use low even for a ninety minute recording.",
            "Timestamps let you jump straight to the part you care about.",
            "Sidekick saves the text as it arrives, so nothing is lost.",
            "If you stop halfway, the finished part of the transcript stays.",
            "This is the second to last sentence of our small test lecture.",
            "And that is all for today, thank you very much for listening.",
        ]
        let url = try SpeechFixture.make(sentences.joined(separator: " [[slnc 2000]] "))
        defer { try? FileManager.default.removeItem(at: url) }
        let audio = try await AudioExtractor.extract(url)
        #expect(audio.duration > 40)
        return audio
    }

    private static func checkLong(_ c: Collector) {
        let segments = c.segments.withLock { $0 }
        let batches = c.batches.withLock { $0 }
        let progress = c.progress.withLock { $0 }
        print("LONG ►", batches, "batches,", segments.count, "segments, progress", progress.map { ($0 * 100).rounded() / 100 })
        #expect(batches > 1)
        #expect(zip(segments, segments.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(progress.contains { $0 < 1 })
        #expect(progress.last == 1 || (progress.last ?? 0) >= 0.9)
        #expect(zip(progress, progress.dropFirst()).allSatisfy { $0 <= $1 })
    }

    @Test(.timeLimit(.minutes(10)))
    func whisperLongFileStreamsSegments() async throws {
        let folder = try await Self.tinyModel()
        let audio = try await Self.longExtracted()
        defer { try? FileManager.default.removeItem(at: audio.url) }
        Self.checkLong(try await Self.run(WhisperFileTranscriber(modelFolder: folder), on: audio))
    }

    @Test(.timeLimit(.minutes(10)))
    func appleLongFileStreamsSegments() async throws {
        let audio = try await Self.longExtracted()
        defer { try? FileManager.default.removeItem(at: audio.url) }
        Self.checkLong(try await Self.run(AppleFileTranscriber(), on: audio))
    }

    /// Starts the run, waits for real work (first segment), cancels, and expects a prompt
    /// CancellationError with nothing delivered afterwards.
    private static func checkCancel(_ t: some FileTranscriber, audio: ExtractedAudio) async throws {
        let c = Collector()
        let (events, cont) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            try await t.transcribe(audio,
                                   onSegments: { s in c.segments.withLock { $0.append(contentsOf: s) }; cont.yield() },
                                   onProgress: { _ in })
        }
        var it = events.makeAsyncIterator()
        _ = await it.next()
        let before = c.segments.withLock { $0.count }
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(ContinuousClock.now - start < .seconds(5))
        let after = c.segments.withLock { $0.count }
        try await Task.sleep(for: .seconds(1))
        #expect(c.segments.withLock { $0.count } == after)
        print("CANCEL ►", before, "segments at cancel,", after, "after")
    }

    @Test(.timeLimit(.minutes(10)))
    func whisperCancelStops() async throws {
        let folder = try await Self.tinyModel()
        let audio = try await Self.longExtracted()
        defer { try? FileManager.default.removeItem(at: audio.url) }
        try await Self.checkCancel(WhisperFileTranscriber(modelFolder: folder), audio: audio)
    }

    @Test(.timeLimit(.minutes(10)))
    func appleCancelStops() async throws {
        let audio = try await Self.longExtracted()
        defer { try? FileManager.default.removeItem(at: audio.url) }
        try await Self.checkCancel(AppleFileTranscriber(), audio: audio)
    }

    @Test func whisperSegmentsDropNonFiniteTimesAndBlankText() {
        let found: [(start: Float, end: Float, text: String)] = [
            (0, 1.5, " Hello."), (1.5, .nan, "lost"), (.infinity, 3, "lost too"), (3, 4, "  "), (4, 5, "world"),
        ]
        let segments = WhisperFileTranscriber.segments(found)
        #expect(segments.map(\.text) == ["Hello.", "world"])
        #expect(segments.map(\.start) == [0, 4])
    }
}
