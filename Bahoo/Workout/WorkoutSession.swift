import Foundation

enum WorkoutState: Equatable {
    case idle
    case running
    case paused
    case ended
}

/// Snapshot of a finished workout, ready to be handed off to `HealthKitManager`.
struct WorkoutSummary {
    let machineKind: MachineKind
    let startDate: Date
    let endDate: Date
    /// Active time only – excludes any paused intervals.
    let activeDuration: TimeInterval
    let distanceMeters: Double?
    let heartRateSamples: [(date: Date, bpm: Int)]
}

/// Tracks a workout session on top of an existing FTMS connection: local
/// start/pause/stop state, elapsed active time (pause-aware), a rough distance
/// estimate integrated from the live speed reading, and heart rate samples from
/// an optionally paired HR strap. Also forwards Start/Resume/Stop/Pause commands
/// to the trainer's FTMS control point (best-effort – most trainers don't
/// require this to keep reporting live data, it's mainly for the machine's own
/// display/logging).
final class WorkoutSession: ObservableObject {
    @Published private(set) var state: WorkoutState = .idle
    @Published private(set) var elapsedSeconds: Int = 0
    @Published var pendingSummary: WorkoutSummary?

    private let connection: TrainerConnection
    private let heartRateProvider: () -> HeartRateConnection?

    private var timer: Timer?
    private var startDate: Date?
    private var distanceMeters: Double = 0
    private var heartRateSamples: [(date: Date, bpm: Int)] = []
    private var lastSampledBPM: Int?

    init(connection: TrainerConnection, heartRateProvider: @escaping () -> HeartRateConnection?) {
        self.connection = connection
        self.heartRateProvider = heartRateProvider
    }

    func start() {
        guard state == .idle else { return }
        connection.startOrResumeWorkout()
        startDate = Date()
        state = .running
        startTimer()
    }

    func pause() {
        guard state == .running else { return }
        connection.pauseWorkout()
        state = .paused
        stopTimer()
    }

    func resume() {
        guard state == .paused else { return }
        connection.startOrResumeWorkout()
        state = .running
        startTimer()
    }

    func stop() {
        guard state == .running || state == .paused else { return }
        connection.stopWorkout()
        stopTimer()
        let end = Date()
        pendingSummary = WorkoutSummary(
            machineKind: connection.machineKind,
            startDate: startDate ?? end,
            endDate: end,
            activeDuration: TimeInterval(elapsedSeconds),
            distanceMeters: distanceMeters > 0 ? distanceMeters : nil,
            heartRateSamples: heartRateSamples
        )
        state = .ended
    }

    /// Called once the save/discard dialog has been resolved, to reset for a new workout.
    func reset() {
        pendingSummary = nil
        state = .idle
        elapsedSeconds = 0
        distanceMeters = 0
        heartRateSamples.removeAll()
        startDate = nil
        lastSampledBPM = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Runs once per second while `state == .running`. Distance is only
    /// integrated here too, so pausing naturally excludes both time and
    /// distance from the totals.
    private func tick() {
        elapsedSeconds += 1
        if let speedKmh = connection.metrics.instantaneousSpeedKmh {
            distanceMeters += speedKmh * 1000 / 3600 // one second at this speed
        }
        if let bpm = heartRateProvider()?.bpm, bpm != lastSampledBPM {
            heartRateSamples.append((date: Date(), bpm: bpm))
            lastSampledBPM = bpm
        }
    }

    deinit {
        timer?.invalidate()
    }
}
