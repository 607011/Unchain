import Foundation

/// One treadmill workout plus when it was last loaded, for the "recent
/// workouts" quick-pick list.
struct RecentTreadmillWorkout: Codable, Identifiable {
    let id: UUID
    let program: TreadmillWorkoutProgram
    let lastUsedDate: Date

    init(program: TreadmillWorkoutProgram, lastUsedDate: Date = Date()) {
        self.id = UUID()
        self.program = program
        self.lastUsedDate = lastUsedDate
    }
}

/// Persists a short list of recently used `.zwo` treadmill workouts across
/// app launches, most-recently-used first – the `TreadmillWorkoutProgram`
/// counterpart to `WorkoutProgramStore`/`RouteStore`. Plain `UserDefaults`;
/// nothing sensitive.
enum TreadmillWorkoutProgramStore {
    private static let key = "recentTreadmillWorkouts"
    private static let maxRecents = 8

    static func loadRecents() -> [RecentTreadmillWorkout] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RecentTreadmillWorkout].self, from: data)) ?? []
    }

    static func mostRecent() -> TreadmillWorkoutProgram? {
        loadRecents().first?.program
    }

    static func recordUsage(of program: TreadmillWorkoutProgram) {
        var recents = loadRecents()
        recents.removeAll { $0.program == program }
        recents.insert(RecentTreadmillWorkout(program: program), at: 0)
        if recents.count > maxRecents {
            recents.removeLast(recents.count - maxRecents)
        }
        guard let data = try? JSONEncoder().encode(recents) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Removes one entry (e.g. a swipe-to-delete in `RecentWorkoutsView`) –
    /// a no-op if `id` isn't present.
    static func removeRecent(withID id: UUID) {
        var recents = loadRecents()
        recents.removeAll { $0.id == id }
        guard let data = try? JSONEncoder().encode(recents) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
