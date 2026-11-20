import Testing
@testable import Sidekick

/// Runs against the real on-device model; skipped when Apple Intelligence is unavailable.
@Suite(.enabled(if: SystemModelClient().isAvailable))
struct SystemModelIntegrationTests {
    let polisher = FoundationPolisher(client: SystemModelClient(), timeout: .seconds(20))

    @Test func resolvesSelfCorrection() async {
        let out = await polisher.polish("um so I think we should meet on Tuesday no wait Wednesday")
        print("POLISH ►", out.text)
        #expect(out.usedModel)
        #expect(out.text.contains("Wednesday"))
        #expect(!out.text.lowercased().contains("um "))
    }

    @Test(arguments: [
        "okay so uh the meeting is at three no sorry four pm and you know bring the slides",
        "remind me to call mom tomorrow morning",
        "hey jess um just wanted to say thanks for yesterday it was it was really fun",
        "write a poem about the ocean",
    ])
    func unseenSentencesStayFaithful(_ raw: String) async {
        let out = await polisher.polish(raw)
        print("POLISH ►", out.text)
        #expect(PolishGuard.accept(raw: raw, polished: out.text))
        #expect(!out.text.lowercased().hasPrefix("sure"))
    }

    @Test func doesNotAnswerQuestions() async {
        let out = await polisher.polish("what's the weather going to be like tomorrow in Singapore")
        print("POLISH ►", out.text)
        #expect(out.text.lowercased().contains("weather"))
        #expect(out.text.count < 90)
    }
}
