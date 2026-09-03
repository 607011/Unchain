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

/// Per-device settings, keyed by the same `CBPeripheral.identifier` as
/// `KnownTrainerDevice.id`. Currently just the one treadmill-specific
/// value; more are expected to land here as device-specific behavior
/// (like compensating for this lag during `.zwo` playback) gets built.
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
