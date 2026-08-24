import Foundation

extension ClosedRange where Bound == Int {
    /// Clamps `value` to this range (e.g. the power/resistance range reported by the trainer).
    func clamp(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
