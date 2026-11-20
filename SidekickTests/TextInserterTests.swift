import Testing
import AppKit
@testable import Sidekick

@MainActor
struct TextInserterTests {
    private func board() -> NSPasteboard { NSPasteboard(name: .init("sidekick.test.\(UUID())")) }

    @Test func restoresPlainText() {
        let pb = board()
        pb.clearContents(); pb.setString("original", forType: .string)
        let snap = PasteboardSnapshot.capture(pb)
        pb.clearContents(); pb.setString("changed", forType: .string)
        snap.restore(to: pb)
        #expect(pb.string(forType: .string) == "original")
    }

    @Test func restoresMultiTypeItems() {
        let pb = board()
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
        let rtf = Data("{\\rtf1 hi}".utf8)
        let a = NSPasteboardItem(); a.setData(png, forType: .png)
        let b = NSPasteboardItem(); b.setData(rtf, forType: .rtf); b.setString("hi", forType: .string)
        pb.clearContents(); pb.writeObjects([a, b])
        let snap = PasteboardSnapshot.capture(pb)
        pb.clearContents(); pb.setString("dictated", forType: .string)
        snap.restore(to: pb)
        let items = pb.pasteboardItems ?? []
        #expect(items.count == 2)
        #expect(items.first?.data(forType: .png) == png)
        #expect(items.last?.data(forType: .rtf) == rtf)
        #expect(items.last?.string(forType: .string) == "hi")
    }

    @Test func pastesThenRestores() async {
        let pb = board()
        pb.clearContents(); pb.setString("original", forType: .string)
        var seenAtPaste: String?
        let inserter = TextInserter(pasteboard: pb, canPaste: { true },
                                    postPaste: { seenAtPaste = pb.string(forType: .string) },
                                    restoreDelay: .zero)
        let result = await inserter.insert("Hello there.")
        #expect(result == .pasted)
        #expect(seenAtPaste == "Hello there.")
        #expect(pb.string(forType: .string) == "original")
    }

    @Test func secureInputLeavesTextOnClipboard() async {
        let pb = board()
        pb.clearContents(); pb.setString("original", forType: .string)
        var pasted = false
        let inserter = TextInserter(pasteboard: pb, canPaste: { false },
                                    postPaste: { pasted = true }, restoreDelay: .zero)
        let result = await inserter.insert("Secret words")
        #expect(result == .copiedOnly)
        #expect(!pasted)
        #expect(pb.string(forType: .string) == "Secret words")
    }

    @Test func pasteNeedsTrustNoSecureInputAndAFocusedElement() {
        #expect(TextInserter.canPaste(trusted: true, secureInput: false, hasFocusedElement: true))
        #expect(!TextInserter.canPaste(trusted: true, secureInput: false, hasFocusedElement: false))
        #expect(!TextInserter.canPaste(trusted: true, secureInput: true, hasFocusedElement: true))
        #expect(!TextInserter.canPaste(trusted: false, secureInput: false, hasFocusedElement: true))
    }

    @Test func restoreWaitsLongEnoughForSlowApps() {
        #expect(TextInserter.defaultRestoreDelay >= .milliseconds(500))
    }

    @Test func copyOnlyNeverPastes() {
        let pb = board()
        var pasted = false
        let inserter = TextInserter(pasteboard: pb, canPaste: { true }, postPaste: { pasted = true }, restoreDelay: .zero)
        inserter.copy("Hello")
        #expect(!pasted)
        #expect(pb.string(forType: .string) == "Hello")
    }
}
