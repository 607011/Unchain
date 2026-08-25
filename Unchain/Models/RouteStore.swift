import Foundation

/// One grade profile plus when it was last loaded, for the "recent
/// workouts" quick-pick list.
struct RecentRoute: Codable, Identifiable {
    let id: UUID
    let route: GradeProfile
    let lastUsedDate: Date

    init(route: GradeProfile, lastUsedDate: Date = Date()) {
        self.id = UUID()
        self.route = route
        self.lastUsedDate = lastUsedDate
    }
}

/// Persists a short list of recently used GPX-derived grade profiles across
/// app launches, most-recently-used first – the `GradeProfile` counterpart to
/// `WorkoutProgramStore`. Plain `UserDefaults`; nothing sensitive.
enum RouteStore {
    private static let key = "recentRoutes"
    private static let maxRecents = 8

    static func loadRecents() -> [RecentRoute] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RecentRoute].self, from: data)) ?? []
    }

    static func mostRecent() -> GradeProfile? {
        loadRecents().first?.route
    }

    static func recordUsage(of route: GradeProfile) {
        var recents = loadRecents()
        recents.removeAll { $0.route == route }
        recents.insert(RecentRoute(route: route), at: 0)
        if recents.count > maxRecents {
            recents.removeLast(recents.count - maxRecents)
        }
        guard let data = try? JSONEncoder().encode(recents) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
