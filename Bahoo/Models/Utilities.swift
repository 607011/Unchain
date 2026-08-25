import Foundation

extension ClosedRange where Bound == Int {
    /// Clamps `value` to this range (e.g. the power/resistance range reported by the trainer).
    func clamp(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

extension ClosedRange where Bound == Double {
    /// Clamps `value` to this range (e.g. a physically plausible grade %,
    /// as a safety margin against GPS/elevation noise even after smoothing).
    func clamp(_ value: Double) -> Double {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
