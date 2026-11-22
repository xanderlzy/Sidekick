/// Per-sample gain smoothing for the IO proc. Pure and allocation-free.
///
/// Starts at `initial` (0 by default: a new tap fades in). Each time the target changes, the gain
/// moves linearly from where it is to the new target and lands on it exactly after `duration`.
struct GainRamp: Sendable {
    private(set) var current: Float
    private var target: Float
    private var step: Float = 0
    private var remaining: Int = 0
    private let length: Int

    init(sampleRate: Double, duration: Double = 0.02, initial: Float = 0) {
        let samples = sampleRate * duration
        length = samples.isFinite && samples >= 1 ? Int(samples.rounded()) : 1
        current = initial
        target = initial
    }

    mutating func next(target newTarget: Float) -> Float {
        if newTarget != target {
            target = newTarget
            remaining = length
            step = (newTarget - current) / Float(length)
        }
        guard remaining > 0 else { return current }
        remaining -= 1
        if remaining == 0 {
            current = target
        } else {
            // Clamp so float rounding can never step past the target (keeps the ramp monotonic).
            let moved = current + step
            current = step > 0 ? min(moved, target) : max(moved, target)
        }
        return current
    }
}
