import Foundation

/// Running min/average/max accumulator for a single live metric (power,
/// cadence, speed, heart rate, …) over the course of a workout.
struct LiveStat: Equatable {
    private(set) var minValue: Double?
    private(set) var maxValue: Double?
    private var sum: Double = 0
    private(set) var count: Int = 0

    var average: Double? { count > 0 ? sum / Double(count) : nil }

    mutating func record(_ value: Double) {
        minValue = Swift.min(minValue ?? value, value)
        maxValue = Swift.max(maxValue ?? value, value)
        sum += value
        count += 1
    }
}
