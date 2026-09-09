import Foundation

/// Active-energy estimates, kept intentionally simple and documented so the
/// assumptions are visible rather than hidden inside a black box.
enum EnergyEstimator {
    /// Cycling: the standard convention used throughout the sport (Coggan/
    /// TrainingPeaks, Strava, Garmin, …) is that 1 kJ of mechanical work done
    /// against the pedals corresponds to roughly 1 kcal burned – a rider's
    /// gross efficiency (~20–25 %) and the kJ→kcal conversion factor (4.184)
    /// happen to roughly cancel out. No body weight needed.
    static func cyclingActiveEnergyKcal(workDoneKilojoules: Double) -> Double {
        workDoneKilojoules
    }

    /// Walking/running: ACSM metabolic equations (flat ground assumed – this
    /// only ever averages over a whole, already-finished workout, with no
    /// incline time series left to integrate a grade term against by the
    /// time it's called). Needs body weight, which is read from Health
    /// rather than asked for again – see `HealthKitManager.fetchLatestBodyMassKg`.
    static func walkRunActiveEnergyKcal(
        isRunning: Bool,
        distanceMeters: Double,
        duration: TimeInterval,
        weightKg: Double
    ) -> Double? {
        guard duration > 0, distanceMeters > 0, weightKg > 0 else { return nil }
        let speedMetersPerMinute = distanceMeters / (duration / 60)
        // VO2 in ml/(kg·min); ACSM equations, grade term omitted.
        let vo2 = isRunning
            ? 0.2 * speedMetersPerMinute + 3.5
            : 0.1 * speedMetersPerMinute + 3.5
        // 1 L O2 ≈ 5 kcal; VO2 is in ml/(kg·min), so kcal/min = VO2 × weightKg / 200.
        let kcalPerMinute = vo2 * weightKg / 200
        return kcalPerMinute * (duration / 60)
    }

    /// The climbing component of `treadmillPowerWatts` below – pure
    /// physics, the rate of work done raising body weight against gravity:
    /// $P = m \cdot g \cdot v \cdot \frac{\text{incline}}{100}$, with `v`
    /// in m/s – no efficiency factor, no regression, nothing empirical at
    /// all. `nil` (not `0`) for `inclinePercent <= 0`: on the flat, or on a
    /// decline, there is no climbing happening for this specific formula to
    /// measure – `treadmillPowerWatts` is what actually decides what that
    /// stretch shows instead, not this function on its own; called directly
    /// on its own only where the climbing component specifically, in
    /// isolation, is what's needed.
    static func climbingPowerWatts(
        weightKg: Double,
        speedKmh: Double,
        inclinePercent: Double
    ) -> Double? {
        guard weightKg > 0, speedKmh > 0, inclinePercent > 0 else { return nil }
        let speedMetersPerSecond = speedKmh / 3.6
        let gradeFraction = inclinePercent / 100
        let earthGravityMetersPerSecondSquared = 9.81
        return weightKg * earthGravityMetersPerSecondSquared * speedMetersPerSecond * gradeFraction
    }

    /// The other component of `treadmillPowerWatts` below – still
    /// mechanical, not metabolic, but a different mechanical quantity than
    /// `climbingPowerWatts` above: the *internal* work of swinging/
    /// decelerating the limbs relative to the body's own center of mass,
    /// present at any speed, on the flat or climbing alike – unlike
    /// `climbingPowerWatts`, this never returns `nil` for a valid
    /// speed/weight, on purpose (see `treadmillPowerWatts`'s own doc
    /// comment for why leaving it out entirely below a certain incline was
    /// a real, reported bug, not a legitimate zero). Classic gait-
    /// energetics literature (Cavagna, Saibene & Margaria; later
    /// R. McN. Alexander) puts this at roughly 0.3–0.6 J per kg of body
    /// mass per meter travelled – `0.5` here, the middle of that range, not
    /// a tightly pinned-down constant: real values vary with stride
    /// length/frequency and running style, and the figure itself is best
    /// established for *running* specifically – applying it to walking too,
    /// as this does for simplicity, likely overstates a walker's actual
    /// internal work somewhat, since walking's slower, more pendulum-like
    /// gait swings the limbs less aggressively.
    static func internalWorkPowerWatts(weightKg: Double, speedKmh: Double) -> Double? {
        guard weightKg > 0, speedKmh > 0 else { return nil }
        let speedMetersPerSecond = speedKmh / 3.6
        let internalWorkJoulesPerKilogramPerMeter = 0.5
        return weightKg * speedMetersPerSecond * internalWorkJoulesPerKilogramPerMeter
    }

    /// The actual treadmill power estimate `WorkoutSession` shows –
    /// `climbingPowerWatts` and `internalWorkPowerWatts` above, **added
    /// together**, not switched between by incline. That switch is what
    /// this replaced, and why: reported directly, empirically, after real
    /// testing – below roughly 8 % incline, the pure climbing figure alone
    /// reads far *below* what `internalWorkPowerWatts` alone already showed
    /// at 0 % incline and the same pace, meaning the displayed number
    /// dropped the instant any incline was added at all, before climbing
    /// out-grew it again higher up – backwards, and "Quatsch" as reported:
    /// adding incline at a held pace should never make the estimate go
    /// *down*. The root cause was the switch itself, not either formula:
    /// both are genuinely present at every incline, all the time – a
    /// climbing runner is still swinging their limbs exactly as they were
    /// on the flat, on top of now also climbing – so summing them is both
    /// the physically correct model and what actually fixes the
    /// discontinuity, continuous across `inclinePercent == 0` by
    /// construction rather than by a boundary case.
    static func treadmillPowerWatts(weightKg: Double, speedKmh: Double, inclinePercent: Double) -> Double? {
        guard weightKg > 0, speedKmh > 0 else { return nil }
        let internalWork = internalWorkPowerWatts(weightKg: weightKg, speedKmh: speedKmh) ?? 0
        let climbing = climbingPowerWatts(weightKg: weightKg, speedKmh: speedKmh, inclinePercent: inclinePercent) ?? 0
        return internalWork + climbing
    }
}
