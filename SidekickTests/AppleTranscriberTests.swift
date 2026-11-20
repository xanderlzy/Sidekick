import Testing
import AVFoundation
import Foundation
@testable import Sidekick

/// Integration test: synthesizes speech with `say`, streams it through the on-device
/// transcriber in mic-sized buffers, and checks the words come back.
struct AppleTranscriberTests {
    @Test(.timeLimit(.minutes(5)))
    func transcribesSynthesizedSpeech() async throws {
        let url = try SpeechFixture.make("Testing one two three. Sidekick turns speech into text.")
        let t = AppleTranscriber()
        try await t.prepare()
        try await t.begin()
        for buffer in try SpeechFixture.buffers(from: url) { t.append(buffer) }
        let text = try await t.finish().lowercased()
        #expect(text.contains("testing"))
        #expect(text.contains("sidekick") || text.contains("speech"))
    }

    @Test(.timeLimit(.minutes(2)))
    func cancelReturnsCleanly() async throws {
        let t = AppleTranscriber()
        try await t.prepare()
        try await t.begin()
        await t.cancel()
    }
}

enum SpeechFixture {
    static func make(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-\(UUID()).aiff")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", url.path, text]
        try p.run(); p.waitUntilExit()
        return url
    }

    /// Splits the file into 1024-frame float buffers, like the microphone tap delivers.
    static func buffers(from url: URL) throws -> [AVAudioPCMBuffer] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        var out: [AVAudioPCMBuffer] = []
        while file.framePosition < file.length {
            let b = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024)!
            try file.read(into: b, frameCount: 1024)
            if b.frameLength == 0 { break }
            out.append(b)
        }
        return out
    }
}
