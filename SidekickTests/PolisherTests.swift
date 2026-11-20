import Testing
@testable import Sidekick

struct FakeModel: LanguageModelClient {
    var isAvailable = true
    var delay: Duration = .zero
    var reply: @Sendable (String) -> String
    func respond(instructions: String, prompt: String) async throws -> String {
        if delay > .zero { try await Task.sleep(for: delay) }
        return reply(prompt)
    }
}

struct PolisherTests {
    @Test func normalCleanupAccepted() async {
        let p = FoundationPolisher(client: FakeModel { _ in "I think we should meet." })
        let out = await p.polish("um so I think we should uh meet")
        #expect(out == PolishOutcome(text: "I think we should meet.", usedModel: true, modelUnavailable: false))
    }

    @Test func answerLikeOutputFallsBackToRaw() async {
        let raw = "what's the weather tomorrow"
        let p = FoundationPolisher(client: FakeModel { _ in String(repeating: "Tomorrow looks sunny and warm. ", count: 7) })
        let out = await p.polish(raw)
        #expect(out.text == raw)
        #expect(!out.usedModel)
    }

    @Test func unavailableModelReturnsRaw() async {
        let p = FoundationPolisher(client: FakeModel(isAvailable: false) { _ in "nope" })
        let out = await p.polish("hello")
        #expect(out == PolishOutcome(text: "hello", usedModel: false, modelUnavailable: true))
    }

    @Test func timeoutReturnsRaw() async {
        let p = FoundationPolisher(client: FakeModel(delay: .seconds(5)) { _ in "Hello." }, timeout: .milliseconds(100))
        let start = ContinuousClock.now
        let out = await p.polish("hello")
        #expect(out.text == "hello")
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    @Test func promptCarriesOnlyTheChunk() async {
        let p = FoundationPolisher(client: FakeModel { prompt in
            prompt.replacingOccurrences(of: "Dictated text:\n", with: "")
        })
        let out = await p.polish("keep me")
        #expect(out.text == "keep me")
        #expect(out.usedModel)
    }

    @Test func totalBudgetPassesRemainingChunksThroughRaw() async {
        final class Counter: @unchecked Sendable { var n = 0 }
        let calls = Counter()
        let model = FakeModel(delay: .milliseconds(200)) { prompt in
            calls.n += 1
            return prompt.replacingOccurrences(of: "Dictated text:\n", with: "")
        }
        let p = FoundationPolisher(client: model, timeout: .seconds(5), totalBudget: .milliseconds(300))
        let raw = (0..<3).map { _ in Array(repeating: "word", count: 240).joined(separator: " ") + "." }.joined(separator: " ")
        let start = ContinuousClock.now
        let out = await p.polish(raw)
        #expect(calls.n < 3)
        #expect(out.text.split(separator: " ").count == 720)
        #expect(ContinuousClock.now - start < .seconds(1))
    }
}
