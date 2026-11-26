import Foundation
import os

/// Transcribes one extracted audio file start to finish, reporting as it goes.
protocol FileTranscriber: Sendable {
    /// `onSegments` gets each newly finished batch, in order, with times in seconds from the file start.
    /// `onProgress` gets 0...1, never decreasing. Throws CancellationError when the task is cancelled.
    func transcribe(_ audio: ExtractedAudio,
                    onSegments: @escaping @Sendable ([Segment]) -> Void,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws
}

/// Turns raw "seconds finished" reports into a clamped, never-decreasing 0...1 fraction.
final class ProgressMeter: Sendable {
    private let duration: Double
    private let report: @Sendable (Double) -> Void
    private let last = HighWater()

    init(duration: Double, report: @escaping @Sendable (Double) -> Void) {
        self.duration = duration
        self.report = report
    }

    func update(seconds: Double) {
        guard duration > 0, seconds.isFinite else { return }
        let fraction = min(max(seconds / duration, 0), 1)
        if let value = last.raise(to: fraction) { report(value) }
    }
}

/// Holds the highest fraction seen so far.
struct HighWater: Sendable {
    private let state = OSAllocatedUnfairLock<Double>(initialState: -1)
    /// Returns `fraction` if it is a new high, else nil.
    func raise(to fraction: Double) -> Double? {
        state.withLock { high in
            guard fraction > high else { return nil }
            high = fraction
            return fraction
        }
    }
}
