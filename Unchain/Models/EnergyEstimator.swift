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

    /// A live, instantaneous power estimate (watts) for a treadmill –
    /// deliberately *not* the metabolic (VO2-based) approach
    /// `walkRunActiveEnergyKcal` above uses, after weighing that directly
    /// and preferring this instead: pure physics, the rate of work done
    /// raising body weight against gravity while climbing –
    /// $P = m \cdot g \cdot v \cdot \frac{\text{incline}}{100}$, with `v` in
    /// m/s – no efficiency factor, no VO2 regression, nothing empirical at
    /// all. Reads as genuine mechanical watts, comparable in magnitude to a
    /// bike's own power meter (unlike the metabolic approach, which ran
    /// noticeably higher – resting metabolism and gross inefficiency both
    /// baked into VO2 – for a similar felt effort).
    ///
    /// The trade-off, accepted deliberately rather than worked around: this
    /// is *only* the climbing component. On the flat, or on a decline, there
    /// is essentially no net *external* mechanical work being done in the
    /// classical sense at all – a treadmill belt offers no real resistance
    /// to walking/running at a steady pace, unlike a bike's wind/rolling
    /// resistance – so this returns `nil` rather than `0` for
    /// `inclinePercent <= 0`; see `internalWorkPowerWatts(weightKg:speedKmh:)`
    /// below for what `WorkoutSession` actually shows instead for that
    /// stretch, rather than "–" throughout. How plausible the numbers end
    /// up being at shallow (but still positive) inclines is something to
    /// gauge from real use, not settled in the formula itself.
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

    /// The flat-ground counterpart to `climbingPowerWatts` above – still
    /// mechanical, not metabolic, but a different mechanical quantity: the
    /// *internal* work of swinging/decelerating the limbs relative to the
    /// body's own center of mass, which continues on the flat even though
    /// there's no external (climbing) work happening there for
    /// `climbingPowerWatts` to capture. Classic gait-energetics literature
    /// (Cavagna, Saibene & Margaria; later R. McN. Alexander) puts this at
    /// roughly 0.3–0.6 J per kg of body mass per meter travelled – `0.5`
    /// here, the middle of that range, not a tightly pinned-down constant:
    /// real values vary with stride length/frequency and running style, and
    /// the figure itself is best established for *running* specifically –
    /// applying it to walking too, as this does for simplicity, likely
    /// overstates a walker's actual internal work somewhat, since walking's
    /// slower, more pendulum-like gait swings the limbs less aggressively.
    /// `WorkoutSession` flags a value computed this way as distinctly less
    /// certain than `climbingPowerWatts`'s own exact-physics figure – see
    /// `WorkoutSession.EstimatedPowerSource` – rather than presenting both
    /// as if they carried the same confidence.
    static func internalWorkPowerWatts(weightKg: Double, speedKmh: Double) -> Double? {
        guard weightKg > 0, speedKmh > 0 else { return nil }
        let speedMetersPerSecond = speedKmh / 3.6
        let internalWorkJoulesPerKilogramPerMeter = 0.5
        return weightKg * speedMetersPerSecond * internalWorkJoulesPerKilogramPerMeter
    }
}
