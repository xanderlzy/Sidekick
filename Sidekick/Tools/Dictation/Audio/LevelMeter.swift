import Foundation

enum LevelMeter {
    static let floorDB: Float = -50

    /// RMS of the samples in dBFS, mapped linearly from −50…0 dB to 0…1 and clamped.
    static func level(samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = (sum / Float(samples.count)).squareRoot()
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return min(1, max(0, (db - floorDB) / -floorDB))
    }
}
