import Foundation

/// A grade (gradient) profile derived from a GPX track's elevation data, to
/// be followed via FTMS "Indoor Bike Simulation" (`setSimulationGrade`)
/// instead of a fixed time-based power/resistance schedule like
/// `WorkoutProgram`. Breakpoints are keyed by *cumulative distance* rather
/// than time – how long a given stretch takes depends on the rider's own
/// effort, a feedback loop time-based programs don't have.
struct GradeProfile: Codable, Equatable {
    struct Breakpoint: Codable, Equatable {
        let distanceMeters: Double
        let gradePercent: Double
    }

    let name: String
    /// Sorted by distance, in meters from the start.
    let breakpoints: [Breakpoint]

    var totalDistanceMeters: Double { breakpoints.last?.distanceMeters ?? 0 }

    /// Indoor Bike Simulation is, as the name says, a bike-only FTMS feature.
    var compatibleMachineKind: MachineKind { .bike }

    /// Linearly interpolated grade % at `distance` meters into the route;
    /// `nil` once the route's full length has been covered.
    func grade(atDistanceMeters distance: Double) -> Double? {
        guard let first = breakpoints.first, distance <= totalDistanceMeters else { return nil }
        guard distance >= first.distanceMeters else { return first.gradePercent }

        var lowerIndex = 0
        for index in breakpoints.indices where breakpoints[index].distanceMeters <= distance {
            lowerIndex = index
        }
        let lower = breakpoints[lowerIndex]
        guard lowerIndex + 1 < breakpoints.count else { return lower.gradePercent }
        let upper = breakpoints[lowerIndex + 1]
        guard upper.distanceMeters > lower.distanceMeters else { return upper.gradePercent }
        let fraction = (distance - lower.distanceMeters) / (upper.distanceMeters - lower.distanceMeters)
        return lower.gradePercent + fraction * (upper.gradePercent - lower.gradePercent)
    }
}

/// Turns a raw GPX trackpoint sequence into a `GradeProfile`: cumulative
/// distance via the haversine formula, resampled into fixed-width windows to
/// smooth out GPS/barometric elevation noise (real-world GPX exports are
/// noisy even where every point *does* have `<ele>`), then grade % derived
/// between consecutive smoothed points and held flat across each window –
/// clearer and more honest than implying false precision with a continuous
/// curve through noisy source data.
enum GradeProfileBuilder {
    /// Width of each smoothing window, in meters. Elevation is averaged
    /// within each window before deriving a grade from it.
    static let smoothingWindowMeters: Double = 50

    static func build(name: String, points: [GPXTrackpoint]) -> GradeProfile? {
        guard points.count >= 2 else { return nil }

        var cumulative: [(distance: Double, elevation: Double)] = [(0, points[0].elevationMeters)]
        var totalDistance = 0.0
        for i in 1..<points.count {
            totalDistance += haversineDistanceMeters(from: points[i - 1], to: points[i])
            cumulative.append((totalDistance, points[i].elevationMeters))
        }
        guard totalDistance > 0 else { return nil }

        let smoothed = resample(cumulative, totalDistance: totalDistance)
        guard smoothed.count >= 2 else { return nil }

        var breakpoints: [GradeProfile.Breakpoint] = []
        for i in 0..<(smoothed.count - 1) {
            let a = smoothed[i]
            let b = smoothed[i + 1]
            let deltaDistance = b.distance - a.distance
            guard deltaDistance > 0 else { continue }
            let grade = (-25.0...25.0).clamp((b.elevation - a.elevation) / deltaDistance * 100)
            // Two points at the same grade, one at each end of the window –
            // the same "flat block" encoding `.erg`/`.mrc` files use.
            breakpoints.append(GradeProfile.Breakpoint(distanceMeters: a.distance, gradePercent: grade))
            breakpoints.append(GradeProfile.Breakpoint(distanceMeters: b.distance, gradePercent: grade))
        }
        guard !breakpoints.isEmpty else { return nil }
        return GradeProfile(name: name, breakpoints: breakpoints)
    }

    /// Buckets the raw (distance, elevation) samples into fixed-width windows
    /// and averages the elevation within each.
    private static func resample(_ cumulative: [(distance: Double, elevation: Double)], totalDistance: Double) -> [(distance: Double, elevation: Double)] {
        var smoothed: [(distance: Double, elevation: Double)] = []
        var windowStart = 0.0
        var index = 0
        while windowStart <= totalDistance {
            let windowEnd = windowStart + smoothingWindowMeters
            var sum = 0.0
            var count = 0
            while index < cumulative.count, cumulative[index].distance < windowEnd {
                sum += cumulative[index].elevation
                count += 1
                index += 1
            }
            if count > 0 {
                smoothed.append((windowStart, sum / Double(count)))
            } else if let last = smoothed.last {
                smoothed.append((windowStart, last.elevation))
            }
            windowStart = windowEnd
        }
        if let lastRaw = cumulative.last, (smoothed.last?.distance ?? -1) < totalDistance {
            smoothed.append((totalDistance, lastRaw.elevation))
        }
        return smoothed
    }

    /// Great-circle distance between two points via the haversine formula –
    /// GPX gives lat/lon, not distance, so this is needed before anything
    /// distance-based (smoothing, grade, playback) can happen.
    private static func haversineDistanceMeters(from a: GPXTrackpoint, to b: GPXTrackpoint) -> Double {
        let earthRadiusMeters = 6_371_000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let deltaLat = (b.latitude - a.latitude) * .pi / 180
        let deltaLon = (b.longitude - a.longitude) * .pi / 180
        let sinHalfDeltaLat = sin(deltaLat / 2)
        let sinHalfDeltaLon = sin(deltaLon / 2)
        let h = sinHalfDeltaLat * sinHalfDeltaLat + cos(lat1) * cos(lat2) * sinHalfDeltaLon * sinHalfDeltaLon
        let centralAngle = 2 * atan2(sqrt(h), sqrt(1 - h))
        return earthRadiusMeters * centralAngle
    }
}
