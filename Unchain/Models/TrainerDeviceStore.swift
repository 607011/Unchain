import Foundation

/// A trainer this app has connected to at least once, remembered so its
/// own device-specific settings (`TrainerDeviceSettings`) stay reachable
/// from `SettingsView` even while it isn't currently connected – the same
/// "doesn't need a live connection" reasoning `SettingsView` itself already
/// documents for FTP/Heart Rate. Keyed by `CBPeripheral.identifier`
/// (`id` here), stable across scans and app launches for a given device on
/// this phone – same identifier `BluetoothManager` already relies on for
/// the last-used heart rate strap.
struct KnownTrainerDevice: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var machineKind: MachineKind
    var lastConnectedDate: Date
}

/// Persists the list of known trainers (see `KnownTrainerDevice`) across
/// app launches – plain `UserDefaults`, nothing sensitive, same shape as
/// `TreadmillWorkoutProgramStore`/`RouteStore`. Deliberately uncapped
/// (unlike those "recent files" lists): realistically a handful of actual
/// trainers, not something that grows without bound.
enum TrainerDeviceStore {
    private static let key = "knownTrainerDevices"

    static func loadAll() -> [KnownTrainerDevice] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([KnownTrainerDevice].self, from: data)) ?? []
    }

    /// Adds or refreshes the entry for `id` – called every time
    /// `ControlView` observes `machineKind` resolve to something concrete,
    /// so the name and kind stay in sync with whatever was most recently
    /// seen and `lastConnectedDate` keeps each group's most-recently-used
    /// device first. A no-op while `machineKind` is still `.unknown` (right
    /// after connecting, before the trainer's own characteristics have been
    /// read) – there'd be nothing meaningful to group it under yet.
    static func recordConnection(id: UUID, name: String, machineKind: MachineKind) {
        guard machineKind != .unknown else { return }
        var all = loadAll()
        all.removeAll { $0.id == id }
        all.insert(KnownTrainerDevice(id: id, name: name, machineKind: machineKind, lastConnectedDate: Date()), at: 0)
        guard let data = try? JSONEncoder().encode(all) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// One live-data tile a trainer's `ControlView` can show during a workout –
/// user-orderable and independently toggleable per device (see
/// `TrainerDeviceSettings.liveMetrics`), replacing what used to be one
/// fixed tile row per machine kind (treadmill: Watt/km-h-or-pace/bpm; bike:
/// Watt/RPM/km-h-or-kcal/bpm). Covers both machine kinds in one enum,
/// rather than two separate ones, since a specific device is always fixed
/// to exactly one kind – no risk of a bike ending up with `.pace` or a
/// treadmill with `.power` – but the two kinds' *needs* genuinely differ
/// (a treadmill cares about pace and climbed meters; a bike about power and
/// cadence), hence `compatibleMachineKinds` to keep each device's own
/// picker (and defaults) scoped to what actually applies to it.
enum LiveMetricKind: String, Codable, CaseIterable, Identifiable {
    // Shared
    case speedKmh
    case heartRate
    case heartRateAverage
    case distance
    // Treadmill-only
    case pace
    case heartRateMax
    case elevationGain
    // Bike-only
    case speedKmhAverage
    case power
    case powerAverage
    case cadence
    case cadenceAverage

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .speedKmh: return String(localized: "Speed (km/h)")
        case .heartRate: return String(localized: "Heart Rate")
        case .heartRateAverage: return String(localized: "Average Heart Rate")
        case .distance: return String(localized: "Distance (km)")
        case .pace: return String(localized: "Pace (min/km)")
        case .heartRateMax: return String(localized: "Max Heart Rate")
        case .elevationGain: return String(localized: "Elevation Gain (m)")
        case .speedKmhAverage: return String(localized: "Average Speed (km/h)")
        case .power: return String(localized: "Power (W)")
        case .powerAverage: return String(localized: "Average Power (W)")
        case .cadence: return String(localized: "Cadence (RPM)")
        case .cadenceAverage: return String(localized: "Average Cadence (RPM)")
        }
    }

    /// Which machine kind(s) can actually show this tile – used to scope
    /// `TrainerDeviceSettingsView`'s "Add Live Data" menu (and the
    /// defaults below) to what applies to a given device, since a bike has
    /// no incline to pace against and a treadmill has no crank to turn.
    var compatibleMachineKinds: Set<MachineKind> {
        switch self {
        case .speedKmh, .heartRate, .heartRateAverage, .distance:
            return [.bike, .treadmill]
        case .pace, .heartRateMax, .elevationGain:
            return [.treadmill]
        case .speedKmhAverage, .power, .powerAverage, .cadence, .cadenceAverage:
            return [.bike]
        }
    }
}

/// Per-device settings, keyed by the same `CBPeripheral.identifier` as
/// `KnownTrainerDevice.id`. Currently just treadmill-specific values; more
/// are expected to land here as device-specific behavior (like
/// compensating for this lag during `.zwo` playback) gets built.
struct TrainerDeviceSettings: Codable, Equatable {
    /// How many seconds this treadmill takes to actually reach a new
    /// incline once commanded, per degree changed – e.g. `1.5` means a 2°
    /// change takes about 3 seconds to settle. `nil` until the rider
    /// measures and enters it – see `effectiveInclineChangeSecondsPerDegree`
    /// for what's actually used in the meantime. Read by
    /// `WorkoutSession.sendCurrentWorkoutTarget(for:)` to pace how fast a
    /// `.treadmillProgram` interval change ramps the belt *speed* up or
    /// down, so it doesn't get ahead of an incline that's still physically
    /// moving.
    var inclineChangeSecondsPerDegree: Double?

    /// Assumed for any treadmill whose actual response time hasn't been
    /// measured yet – a deliberately conservative placeholder, not `0`
    /// (which would mean "the incline snaps instantly" and silently skip
    /// speed ramping altogether for every unmeasured device).
    static let defaultInclineChangeSecondsPerDegree = 1.0

    var effectiveInclineChangeSecondsPerDegree: Double {
        inclineChangeSecondsPerDegree ?? Self.defaultInclineChangeSecondsPerDegree
    }

    /// How many seconds this treadmill spends counting down on its own
    /// console ("3, 2, 1, go") after receiving a Start/Resume command
    /// before the belt actually starts moving. Read by `WorkoutSession
    /// .start(usingProgram:)`/`startTracking()` to delay `elapsedSeconds`
    /// (and, via `programPositionSeconds`, the workout program's own
    /// target-sending/segment advancement) by the same amount – without
    /// this, the app's displayed elapsed time and the workout program
    /// would both run ahead of the treadmill by however long it spends
    /// counting down. `nil` until measured; unlike
    /// `inclineChangeSecondsPerDegree`, defaults to `0` (no delay) rather
    /// than a conservative non-zero guess – plenty of trainers react
    /// immediately, and assuming a countdown that isn't really there would
    /// introduce a *new* sync error instead of fixing one.
    var startCountdownSeconds: Double?

    var effectiveStartCountdownSeconds: Double {
        startCountdownSeconds ?? 0
    }

    /// Which live-data tiles this device's `ControlView` shows during a
    /// workout, and in what order – `nil` until customized in
    /// `TrainerDeviceSettingsView`, meaning "use the machine kind's own
    /// default set" (see `effectiveLiveMetrics(for:)`). Only ever holds a
    /// *subset* of `LiveMetricKind.allCases`, in display order – a kind
    /// missing from this array simply isn't shown, rather than every case
    /// needing its own explicit on/off flag. One shared array rather than
    /// separate treadmill/bike ones – a specific device is always fixed to
    /// one machine kind for its whole lifetime, so there's nothing to keep
    /// apart.
    var liveMetrics: [LiveMetricKind]?

    /// Roughly what a treadmill's tile row already showed before this
    /// became configurable (Speed, Heart Rate), plus Distance – a
    /// reasonable, immediately useful starting point rather than an empty
    /// row the first time this screen is opened.
    static let defaultTreadmillLiveMetrics: [LiveMetricKind] = [.speedKmh, .heartRate, .distance]

    /// Same reasoning as `defaultTreadmillLiveMetrics`, for a bike's own
    /// previously-fixed row (Watt, RPM, km/h, bpm) – RPM dropped, since a
    /// bike's own default was never really about cadence specifically, and
    /// this way the starting row matches the treadmill default's own size.
    static let defaultBikeLiveMetrics: [LiveMetricKind] = [.power, .speedKmh, .heartRate]

    func effectiveLiveMetrics(for machineKind: MachineKind) -> [LiveMetricKind] {
        if let liveMetrics { return liveMetrics }
        switch machineKind {
        case .treadmill: return Self.defaultTreadmillLiveMetrics
        case .bike: return Self.defaultBikeLiveMetrics
        case .unknown: return []
        }
    }
}

enum TrainerDeviceSettingsStore {
    private static func key(for id: UUID) -> String { "trainerDeviceSettings.\(id.uuidString)" }

    static func load(for id: UUID) -> TrainerDeviceSettings {
        guard let data = UserDefaults.standard.data(forKey: key(for: id)),
              let settings = try? JSONDecoder().decode(TrainerDeviceSettings.self, from: data) else {
            return TrainerDeviceSettings()
        }
        return settings
    }

    static func save(_ settings: TrainerDeviceSettings, for id: UUID) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key(for: id))
    }
}
