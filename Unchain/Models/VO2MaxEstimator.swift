import Foundation

/// Estimated VO2max (maximal oxygen uptake, ml/(kg·min)) from a genuinely
/// held `SteadyState` segment of a treadmill `.zwo` program – the Heart
/// Rate Reserve extrapolation method (see ACSM's Guidelines for Exercise
/// Testing and Prescription): submaximal VO2 at a known, held pace/incline
/// (the ACSM walking/running metabolic equations – same family
/// `EnergyEstimator.walkRunActiveEnergyKcal` uses, just with the grade term
/// that one has to omit, since it isn't given live incline, kept in here)
/// extrapolated to maximal effort via the ratio between resting/submaximal/
/// maximal heart rate.
///
/// This is a genuine *estimate*, not a measurement – no gas-exchange data
/// involved, unlike a real spiroergometry test. Typically ±10–15 % off a
/// lab result, partly because the age-predicted max heart rate it leans on
/// (`SettingsView`'s Tanaka-formula prefill, or whatever the rider entered
/// instead) has its own error band on top. Shown in the app only – see
/// `WorkoutHistoryDetailView` – never written to HealthKit; too uncertain a
/// number to silently feed into Health's own Cardio Fitness trend.
enum VO2MaxEstimator {
    /// A `SteadyState` segment shorter than this can't realistically reach
    /// a genuine steady heart rate at all, so it's skipped entirely rather
    /// than risking an unsettled reading.
    private static let minimumSegmentSeconds: TimeInterval = 180
    /// Only the *settled* part of a qualifying segment counts – heart rate
    /// takes a while to catch up to a new pace/incline. Whichever is more
    /// of "skip the first 90 seconds" or "skip the first half", so a
    /// segment barely past `minimumSegmentSeconds` still contributes a
    /// meaningful tail instead of using an unsettled reading from its
    /// first half.
    private static let minimumSettlingSeconds: TimeInterval = 90
    /// ACSM's classic walk-to-run crossover speed – below it, the walking
    /// equation; at or above it, the running one. There's no single
    /// "correct" cutoff (both equations have their own stated validity
    /// range, with a gap between roughly 6–8 km/h neither strictly
    /// covers), but this is the commonly cited value and, applied per
    /// segment rather than once for the whole session, more precise than
    /// trusting a single "Indoor Walk"/"Indoor Run" choice made at Start –
    /// a `.zwo` program's own segments can easily cross that boundary
    /// (e.g. a brisk uphill interval within an otherwise easy walk).
    private static let runningSpeedThresholdKmh = 8.0

    /// `nil` if nothing qualifies: no `SteadyState` segment reaches
    /// `minimumSegmentSeconds`, no heart-rate sample falls in that
    /// segment's settled window (no strap connected, or one that dropped
    /// out at the wrong moment), or Max/Resting Heart Rate aren't both set
    /// in Settings.
    static func estimate(
        program: TreadmillWorkoutProgram,
        samples: [WorkoutSample],
        restingHeartRateBPM: Int,
        maxHeartRateBPM: Int
    ) -> Double? {
        guard restingHeartRateBPM > 0, maxHeartRateBPM > restingHeartRateBPM else { return nil }
        // The longest qualifying segment gives heart rate the most time to
        // genuinely settle, so it's the best candidate when a program has
        // more than one `SteadyState` block.
        guard let segment = program.segments
            .filter({ $0.kind == .steadyState && $0.duration >= minimumSegmentSeconds })
            .max(by: { $0.duration < $1.duration }) else { return nil }

        let settledStartSeconds = segment.startSeconds + max(minimumSettlingSeconds, segment.duration / 2)
        let settledEndSeconds = segment.startSeconds + segment.duration
        let settledHeartRatesBPM = samples.compactMap { sample -> Double? in
            guard sample.elapsedSeconds >= settledStartSeconds, sample.elapsedSeconds < settledEndSeconds,
                  let bpm = sample.heartRateBPM else { return nil }
            return Double(bpm)
        }
        guard !settledHeartRatesBPM.isEmpty else { return nil }
        let averageHeartRateBPM = settledHeartRatesBPM.reduce(0, +) / Double(settledHeartRatesBPM.count)
        // Guards against a near-zero (or negative) denominator below –
        // heart rate barely above resting isn't a real submaximal effort
        // to extrapolate from, it would just blow the estimate up.
        guard averageHeartRateBPM > Double(restingHeartRateBPM) + 5 else { return nil }

        let speedMetersPerMinute = segment.speedKmh * 1000 / 60
        let gradeFraction = segment.inclinePercent / 100
        let isRunning = segment.speedKmh >= runningSpeedThresholdKmh
        // ACSM metabolic equations, VO2 in ml/(kg·min).
        let submaximalVO2 = isRunning
            ? 0.2 * speedMetersPerMinute + 0.9 * speedMetersPerMinute * gradeFraction + 3.5
            : 0.1 * speedMetersPerMinute + 1.8 * speedMetersPerMinute * gradeFraction + 3.5

        let heartRateReserveFraction = Double(maxHeartRateBPM - restingHeartRateBPM) / (averageHeartRateBPM - Double(restingHeartRateBPM))
        return submaximalVO2 * heartRateReserveFraction
    }
}
