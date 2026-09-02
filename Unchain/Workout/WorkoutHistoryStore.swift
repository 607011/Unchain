import Foundation

/// One second-resolution row of a saved workout – heart rate, power, and
/// speed each independently optional, since a strap can connect/disconnect
/// mid-ride and a treadmill never reports power at all. Built once, at
/// `WorkoutSession.reset()`, by merging that session's own
/// `powerHistory`/`heartRateHistory`/`speedHistory` (each already deduped to
/// at most one entry per elapsed second) keyed by `elapsedSeconds` – not
/// three separate arrays here, so `TCXExporter` has one row per timestamp to
/// walk rather than three streams to keep in sync itself.
struct WorkoutSample: Codable {
    let elapsedSeconds: TimeInterval
    let heartRateBPM: Int?
    let powerWatts: Int?
    let speedKmh: Double?
}

/// One completed workout, saved locally regardless of whether it was also
/// saved to Apple Health – the two are entirely independent (see
/// `WorkoutSession.reset()`, the single place both `pendingSummary`
/// resolution paths – Save, Discard, and the silent Watch-companion one –
/// all funnel through). Richer than the transient `WorkoutSummary` a live
/// session hands to the post-workout dialog: `samples` is what actually
/// makes a `.tcx` export worth having, not just a row of totals.
struct WorkoutRecord: Codable, Identifiable {
    let id: UUID
    let machineKind: MachineKind
    let startDate: Date
    let endDate: Date
    /// Active time only – excludes any paused intervals. Same value
    /// `WorkoutSummary.activeDuration` already carries.
    let activeDuration: TimeInterval
    let distanceMeters: Double?
    let workDoneKilojoules: Double?
    let programName: String?
    let heartRateZoneSeconds: [HeartRateZone: Int]
    let samples: [WorkoutSample]
}

/// Persists finished workouts as one JSON file per record under this app's
/// own Application Support directory – not `UserDefaults` (too small a tool
/// once `samples` can run into the thousands of rows for a long ride) and
/// not the Documents directory either (that would make every raw JSON file
/// show up in the Files app, which isn't the point – `.tcx` export, via
/// `TCXExporter` and a plain share sheet, is the actual "get this workout
/// out of the app" path). Not included in the app's `PrivacyInfo.xcprivacy`
/// required-reason APIs – plain on-device file I/O isn't one of the listed
/// categories, unlike `UserDefaults`.
enum WorkoutHistoryStore {
    private static let directoryName = "Workouts"

    private static var directoryURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func fileURL(for id: UUID) -> URL? {
        directoryURL?.appendingPathComponent("\(id.uuidString).json")
    }

    /// Best-effort – a failure here (disk full, sandbox oddity) shouldn't
    /// crash or interrupt `reset()`, the same "never let a nice-to-have
    /// derail the actual workout flow" stance `HealthKitManager.save`
    /// already takes for its own failures.
    static func save(_ record: WorkoutRecord) {
        guard let url = fileURL(for: record.id), let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Most recent first. Reads every file in the directory each call –
    /// fine at the scale of "however many workouts one person recorded",
    /// not built for thousands of entries.
    static func loadAll() -> [WorkoutRecord] {
        guard let directoryURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        return urls
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(WorkoutRecord.self, from: $0) }
            .sorted { $0.startDate > $1.startDate }
    }

    static func delete(_ record: WorkoutRecord) {
        guard let url = fileURL(for: record.id) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
