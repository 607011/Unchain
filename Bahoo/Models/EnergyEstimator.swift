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

    /// Walking/running: ACSM metabolic equations (flat ground assumed – the
    /// app doesn't currently read treadmill incline, so the grade term is
    /// omitted). Needs body weight, which is read from Health rather than
    /// asked for again – see `HealthKitManager.fetchLatestBodyMassKg`.
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
}
