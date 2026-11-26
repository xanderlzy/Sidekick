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

    @Test func allIsNewestFirst() throws {
        let store = try makeStore()
        let old = store.add(fileURL: URL(fileURLWithPath: "/tmp/old.m4a"), wantsCleanup: false)
        old.dateAdded = Date(timeIntervalSince1970: 1000)
        let new = store.add(fileURL: URL(fileURLWithPath: "/tmp/new.m4a"), wantsCleanup: false)
        new.dateAdded = Date(timeIntervalSince1970: 2000)
        #expect(store.all().map(\.title) == ["new", "old"])
    }

    @Test func recoverLeavesDoneUntouched() throws {
        let store = try makeStore()
        let t = store.add(fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), wantsCleanup: false)
        t.status = .done
        store.recoverAfterLaunch()
        #expect(t.status == .done)
        #expect(t.stoppedAt == nil)
    }

    @Test func unreadableSegmentsAreNotOverwritten() throws {
        let store = try makeStore()
        let t = store.add(fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), wantsCleanup: false)
        let garbage = Data("not json".utf8)
        t.segmentsData = garbage
        t.segments = t.segments + [Segment(start: 0, end: 1, text: "x")]
        #expect(t.segmentsData == garbage)
    }

    @Test func recoverMidRetryKeepsWhicheverRunReachesFurther() throws {
        let store = try makeStore()
        // The old run reached further: the new run's text is dropped.
        let a = store.add(fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), wantsCleanup: false)
        a.segments = [Segment(start: 0, end: 30, text: "old")]
        a.retrySegments = [Segment(start: 0, end: 4, text: "new")]
        a.status = .transcribing
        // The new run passed the old one: it replaces the old text.
        let b = store.add(fileURL: URL(fileURLWithPath: "/tmp/b.m4a"), wantsCleanup: false)
        b.segments = [Segment(start: 0, end: 10, text: "old")]
        b.retrySegments = [Segment(start: 0, end: 12, text: "new"), Segment(start: 12, end: 20, text: "more")]
        b.status = .transcribing
        store.save()

        store.recoverAfterLaunch()
        #expect(a.status == .incomplete)
        #expect(a.segments == [Segment(start: 0, end: 30, text: "old")])
        #expect(a.retrySegmentsData == nil)
        #expect(a.stoppedAt == 30)
        #expect(b.status == .incomplete)
        #expect(b.segments == [Segment(start: 0, end: 12, text: "new"), Segment(start: 12, end: 20, text: "more")])
        #expect(b.retrySegmentsData == nil)
        #expect(b.stoppedAt == 20)
    }

    @Test func retrySegmentsDefaultToNil() throws {
        let store = try makeStore()
        let t = store.add(fileURL: URL(fileURLWithPath: "/tmp/a.m4a"), wantsCleanup: false)
        #expect(t.retrySegmentsData == nil)
        #expect(t.retrySegments == nil)
    }
}
