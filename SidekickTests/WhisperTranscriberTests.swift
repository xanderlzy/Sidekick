import Testing
import Foundation
@testable import Sidekick

struct WhisperTranscriberTests {
    @Test func cleanStripsWhisperArtifacts() {
        #expect(WhisperTranscriber.clean(" [BLANK_AUDIO] Hello there.  (music) ") == "Hello there.")
        #expect(WhisperTranscriber.clean("<|startoftranscript|> Hi <|endoftext|>") == "Hi")
        #expect(WhisperTranscriber.clean("[BLANK_AUDIO]") == "")
    }

    @Test func engineFallsBackToAppleUntilDownloaded() {
        #expect(TranscriberKind.effective(selected: .whisper, whisperReady: false) == .apple)
        #expect(TranscriberKind.effective(selected: .whisper, whisperReady: true) == .whisper)
        #expect(TranscriberKind.effective(selected: .apple, whisperReady: true) == .apple)
    }

    /// Real model run with the tiny English model (~40 MB, cached between runs).
    @Test(.timeLimit(.minutes(10)))
    func transcribesSynthesizedSpeechWithTinyModel() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sidekick-whisper-test")
        let folder = try await WhisperModelStore.download(variant: "openai_whisper-tiny.en", into: base) { _ in }
        let t = WhisperTranscriber(modelFolder: folder)
        try await t.prepare()
        try await t.begin()
        let url = try SpeechFixture.make("Testing one two three. Sidekick turns speech into text.")
        for b in try SpeechFixture.buffers(from: url) { t.append(b) }
        let text = try await t.finish().lowercased()
        print("WHISPER ►", text)
        #expect(text.contains("testing"))
    }
}
