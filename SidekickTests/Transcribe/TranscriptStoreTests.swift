import Foundation
import SwiftData
import Testing
@testable import Sidekick

@MainActor
struct TranscriptStoreTests {
    private func makeStore() throws -> TranscriptStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        return TranscriptStore(container: try ModelContainer(for: Transcript.self, configurations: config))
    }

    @Test func addUsesFileNameAsTitle() throws {
        let store = try makeStore()
        let t = store.add(fileURL: URL(fileURLWithPath: "/tmp/Lecture 4 - Entropy.mp4"), wantsCleanup: true)
        #expect(t.title == "Lecture 4 - Entropy")
        #expect(t.status == .waiting)
        #expect(t.wantsCleanup)
        #expect(t.duration == 0)
    }

    @Test func segmentsRoundTrip() throws {
        let store = try makeStore()
        let t = store.add(fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), wantsCleanup: false)
        let segs = [Segment(start: 0, end: 1.5, text: "Hello"), Segment(start: 1.5, end: 3, text: "world")]
        t.segments = segs
        t.cleaned = [Paragraph(start: 0, text: "Hello world")]
        store.save()
        #expect(t.segments == segs)
        #expect(t.cleaned == [Paragraph(start: 0, text: "Hello world")])
    }

    @Test func recoverMarksTranscribingIncompleteAndWaitingStopped() throws {
        let store = try makeStore()
        let a = store.add(fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), wantsCleanup: false)
        a.status = .transcribing
        a.segments = [Segment(start: 0, end: 2, text: "x"), Segment(start: 2, end: 7.5, text: "y")]
        let b = store.add(fileURL: URL(fileURLWithPath: "/tmp/b.m4a"), wantsCleanup: false)
        let c = store.add(fileURL: URL(fileURLWithPath: "/tmp/c.m4a"), wantsCleanup: false)
        c.status = .transcribing
        store.recoverAfterLaunch()
        #expect(a.status == .incomplete)
        #expect(a.stoppedAt == 7.5)
        #expect(b.status == .stopped)
        #expect(c.status == .incomplete)
        #expect(c.stoppedAt == 0)
    }

    @Test func deleteRemoves() throws {
        let store = try makeStore()
        let t = store.add(fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), wantsCleanup: false)
        #expect(store.all().count == 1)
        store.delete(t)
        #expect(store.all().isEmpty)
    }
}
