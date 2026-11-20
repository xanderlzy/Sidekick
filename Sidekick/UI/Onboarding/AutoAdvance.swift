import SwiftUI

/// Schedules a step's "advance after a grant" at most once, and lets it be cancelled when the step goes away.
@MainActor
final class AutoAdvance {
    private var task: Task<Void, Never>?

    func schedule(after delay: Duration = .seconds(0.9), _ action: @escaping @MainActor @Sendable () -> Void) {
        guard task == nil else { return }
        task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func cancel() { task?.cancel() }
}
