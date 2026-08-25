import Foundation

/// One workout program plus when it was last loaded, for the "recent
/// workouts" quick-pick list.
struct RecentWorkoutProgram: Codable, Identifiable {
    let id: UUID
    let program: WorkoutProgram
    let lastUsedDate: Date

    init(program: WorkoutProgram, lastUsedDate: Date = Date()) {
        self.id = UUID()
        self.program = program
        self.lastUsedDate = lastUsedDate
    }
}

/// Persists a short list of recently used workout programs across app
/// launches, most-recently-used first, so the Program tab doesn't start
/// empty-handed and a repeat file doesn't need re-picking from Files each
/// time. Plain `UserDefaults` – nothing sensitive, no need for anything
/// heavier.
enum WorkoutProgramStore {
    private static let key = "recentWorkoutPrograms"
    private static let maxRecents = 8

    static func loadRecents() -> [RecentWorkoutProgram] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RecentWorkoutProgram].self, from: data)) ?? []
    }

    /// The single most recently used program, if any – for restoring the
    /// Program tab's state right after launch.
    static func mostRecent() -> WorkoutProgram? {
        loadRecents().first?.program
    }

    /// Records `program` as just used: moves it to the front if a program
    /// with identical content is already present, or adds it, then drops
    /// anything beyond `maxRecents`.
    static func recordUsage(of program: WorkoutProgram) {
        var recents = loadRecents()
        recents.removeAll { $0.program == program }
        recents.insert(RecentWorkoutProgram(program: program), at: 0)
        if recents.count > maxRecents {
            recents.removeLast(recents.count - maxRecents)
        }
        guard let data = try? JSONEncoder().encode(recents) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
