import Foundation

/// A standard 5-zone heart rate training model. Zone 1 covers everything
/// below Zone 2's lower bound (no floor of its own – matches how Apple
/// Fitness itself labels its lowest zone as "< n bpm", not "m–n bpm"); Zone
/// 5 is everything at or above its own lower bound. There's no HealthKit
/// write API for "time in zone" — this is purely a Unchain-side computation,
/// shown in-app (live and after saving), not synced to Health.
///
/// The four boundaries between zones are editable in `SettingsView` (in bpm,
/// not a percentage) — Apple Watch's own built-in zones are personalized
/// using Cardio Fitness (VO2 max), not disclosed as an exact public formula,
/// so there's no way to reproduce them precisely; letting the rider type in
/// the same numbers Fitness already shows them is the practical fix. Each
/// boundary defaults, until explicitly set, to the Heart Rate Reserve (HRR)
/// method – also called the Karvonen method: `resting + fraction × (max −
/// resting)`, i.e. the classic 60/70/80/90 % breakpoints applied to the
/// *reserve* actually available during exercise rather than to max heart
/// rate outright, which is closer to what Apple's own zones reportedly use
/// too. Falls back further to the plain %-of-max-heart-rate breakpoint
/// whenever no resting heart rate is on record (see
/// `defaultLowerBoundBPM(maxHeartRateBPM:restingHeartRateBPM:)`). See
/// `SettingsView.prefillHeartRateZonesIfNeeded`, which materializes that
/// default into the stored setting the first time it's shown, exactly like
/// `SettingsView.maxHeartRateBPMKey`'s own Tanaka-formula default.
enum HeartRateZone: Int, CaseIterable, Identifiable {
    case one = 1
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    var id: Int { rawValue }

    var shortLabel: String { "Z\(rawValue)" }

    /// `UserDefaults` keys for each zone's editable lower bound, in bpm –
    /// shared here since `SettingsView`'s zone-boundary `TextField`s need to
    /// read/write them too, not just this type's own `lowerBoundBPM(maxHeartRateBPM:)`.
    static let zone2LowerBPMKey = "heartRateZone2LowerBPM"
    static let zone3LowerBPMKey = "heartRateZone3LowerBPM"
    static let zone4LowerBPMKey = "heartRateZone4LowerBPM"
    static let zone5LowerBPMKey = "heartRateZone5LowerBPM"

    /// `nil` for Zone 1 (no lower bound of its own – see the type's doc
    /// comment). Read directly here (rather than pushed in from a view),
    /// same pattern as `WorkoutSession`'s own settings reads.
    private var lowerBoundBPMKey: String? {
        switch self {
        case .one: return nil
        case .two: return Self.zone2LowerBPMKey
        case .three: return Self.zone3LowerBPMKey
        case .four: return Self.zone4LowerBPMKey
        case .five: return Self.zone5LowerBPMKey
        }
    }

    /// The classic %-of-max-heart-rate breakpoint this zone's boundary
    /// defaults to until the corresponding `UserDefaults` key is set.
    private var lowerBoundFractionFallback: Double {
        switch self {
        case .one: return 0
        case .two: return 0.6
        case .three: return 0.7
        case .four: return 0.8
        case .five: return 0.9
        }
    }

    /// The bpm value this zone's boundary would default to for a given max/
    /// resting heart rate. Uses Heart Rate Reserve (Karvonen): `resting +
    /// fraction × (max − resting)`, when a resting heart rate is actually
    /// on record; otherwise falls back to the plain %-of-max-heart-rate
    /// breakpoint (`fraction × max`) – the same formula this always used
    /// before Resting Heart Rate existed as a setting. Used both as the live
    /// fallback in `lowerBoundBPM(maxHeartRateBPM:restingHeartRateBPM:)`
    /// below while a boundary is unset, and by `SettingsView
    /// .prefillHeartRateZonesIfNeeded()` to materialize that default into
    /// the stored setting the first time it's shown (exactly like
    /// `SettingsView.maxHeartRateBPMKey`'s own Tanaka-formula default).
    func defaultLowerBoundBPM(maxHeartRateBPM: Int, restingHeartRateBPM: Int) -> Int {
        guard restingHeartRateBPM > 0, maxHeartRateBPM > restingHeartRateBPM else {
            return Int((lowerBoundFractionFallback * Double(maxHeartRateBPM)).rounded())
        }
        let reserve = Double(maxHeartRateBPM - restingHeartRateBPM)
        return restingHeartRateBPM + Int((lowerBoundFractionFallback * reserve).rounded())
    }

    /// This zone's lower bound in bpm: the stored override if the user (or
    /// `SettingsView`'s one-time prefill) has set one, else
    /// `defaultLowerBoundBPM(maxHeartRateBPM:restingHeartRateBPM:)`. `0` for
    /// Zone 1 always (see above).
    func lowerBoundBPM(maxHeartRateBPM: Int, restingHeartRateBPM: Int) -> Int {
        guard let key = lowerBoundBPMKey else { return 0 }
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored > 0 ? stored : defaultLowerBoundBPM(maxHeartRateBPM: maxHeartRateBPM, restingHeartRateBPM: restingHeartRateBPM)
    }

    /// The zone containing `bpm`, or `nil` if `maxHeartRateBPM`/`bpm` isn't a
    /// usable positive value. `restingHeartRateBPM` may legitimately be `0`
    /// (not on record) – see `defaultLowerBoundBPM`'s fallback.
    static func containing(bpm: Int, maxHeartRateBPM: Int, restingHeartRateBPM: Int) -> HeartRateZone? {
        guard maxHeartRateBPM > 0, bpm > 0 else { return nil }
        return HeartRateZone.allCases.reversed().first {
            bpm >= $0.lowerBoundBPM(maxHeartRateBPM: maxHeartRateBPM, restingHeartRateBPM: restingHeartRateBPM)
        }
    }
}
