import Foundation

/// A standard 5-zone heart rate training model, expressed as fractions of
/// estimated max heart rate (Zone 1: 50–60 %, Zone 2: 60–70 %, … Zone 5:
/// 90 %+). Below 50 % of max HR isn't counted in any zone (resting/warm-up).
/// There's no HealthKit write API for "time in zone" — this is purely a
/// Unchain-side computation, shown in-app (live and after saving), not synced
/// to Health.
enum HeartRateZone: Int, CaseIterable, Identifiable {
    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    var id: Int { rawValue }

    var shortLabel: String { "Z\(rawValue)" }

    private var lowerBoundFraction: Double {
        switch self {
        case .one: return 0.5
        case .two: return 0.6
        case .three: return 0.7
        case .four: return 0.8
        case .five: return 0.9
        }
    }

    /// The zone containing `bpm`, or `nil` if below Zone 1's lower bound.
    static func containing(bpm: Int, maxHeartRateBPM: Int) -> HeartRateZone? {
        guard maxHeartRateBPM > 0 else { return nil }
        let fraction = Double(bpm) / Double(maxHeartRateBPM)
        return HeartRateZone.allCases.reversed().first { fraction >= $0.lowerBoundFraction }
    }
}
