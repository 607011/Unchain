import Foundation
import UIKit
import AVFoundation

/// How the interval sound (see `SettingsView`) announces a new Program file
/// entry being reached – `.single` just beeps once on arrival, `.countdown`
/// additionally beeps once a second for the four seconds leading up to it.
enum IntervalSoundType: String, CaseIterable, Identifiable {
    case single
    case countdown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: return "Single Beep"
        case .countdown: return "Countdown"
        }
    }
}

enum WorkoutState: Equatable {
    case idle
    case running
    case paused
    case ended
}

/// What the Program tab currently has loaded: a time-based power/resistance
/// schedule (`.erg`/`.mrc`) or a distance-based grade profile (GPX). Mutually
/// exclusive – loading one replaces the other.
enum ActiveWorkout {
    case program(WorkoutProgram)
    case route(GradeProfile)

    var name: String {
        switch self {
        case .program(let program): return program.name
        case .route(let route): return route.name
        }
    }
}

/// Snapshot of a finished workout, ready to be handed off to `HealthKitManager`
/// and/or shown in a post-save summary.
struct WorkoutSummary: Identifiable {
    let id = UUID()
    let machineKind: MachineKind
    let startDate: Date
    let endDate: Date
    /// Active time only – excludes any paused intervals.
    let activeDuration: TimeInterval
    let distanceMeters: Double?
    /// Mechanical work done against the pedals, integrated from live power.
    /// `nil` for machines that don't report power (e.g. treadmills).
    let workDoneKilojoules: Double?
    let heartRateSamples: [(date: Date, bpm: Int)]
    /// The loaded workout's name, but only if this particular run actually
    /// followed it – `nil` for a manual Power/Resistance session even when a
    /// program/route happens to be loaded from an earlier run. Saved to
    /// Health as `HKMetadataKeyWorkoutBrandName`, shown as a subtitle under
    /// the workout type in the Fitness app.
    let programName: String?
    /// Seconds spent in each heart rate zone – see `HeartRateZone`. Bahoo-only,
    /// not written to Health (there's no HealthKit type for it), but shown
    /// live during the workout and again in the post-save summary.
    let heartRateZoneSeconds: [HeartRateZone: Int]
}

/// Tracks a workout session on top of an existing FTMS connection: local
/// start/pause/stop state, elapsed active time (pause-aware), a rough distance
/// estimate integrated from the live speed reading, running min/avg/max stats
/// for the live metrics, and heart rate samples from an optionally paired HR
/// strap. Also forwards Start/Resume/Stop/Pause commands to the trainer's FTMS
/// control point (best-effort – most trainers don't require this to keep
/// reporting live data, it's mainly for the machine's own display/logging).
final class WorkoutSession: ObservableObject {
    /// `UserDefaults` key for the "Vibration" setting in `SettingsView` –
    /// shared here since `WorkoutSession`, not the settings screen, is what
    /// actually acts on it. Defaults to `false` both here (raw
    /// `UserDefaults.bool(forKey:)` returns `false` for an absent key) and in
    /// `SettingsView`'s `@AppStorage` declaration – kept in sync deliberately,
    /// since `@AppStorage`'s default only reaches `UserDefaults` once that
    /// view has actually appeared, and this class may read the key first.
    static let vibrationEnabledKey = "vibrationEnabled"
    /// `UserDefaults` key for the interval sound type (`IntervalSoundType`).
    /// Defaults to `.single` – an absent key reads back as `nil` from
    /// `UserDefaults.string(forKey:)`, which every read site here treats the
    /// same as `.single` (no countdown pre-beeps), matching `SettingsView`'s
    /// `@AppStorage` default.
    static let intervalSoundTypeKey = "intervalSoundType"
    /// `UserDefaults` key for the interval sound volume, 0–100. Defaults to
    /// `0` (silent) both here (`UserDefaults.integer(forKey:)` returns `0`
    /// for an absent key) and in `SettingsView` – same reasoning as
    /// `vibrationEnabledKey` above.
    static let intervalSoundVolumeKey = "intervalSoundVolumePercent"

    @Published private(set) var state: WorkoutState = .idle
    @Published private(set) var elapsedSeconds: Int = 0
    @Published var pendingSummary: WorkoutSummary?

    @Published private(set) var powerStats = LiveStat()
    @Published private(set) var cadenceStats = LiveStat()
    @Published private(set) var speedStats = LiveStat()
    @Published private(set) var heartRateStats = LiveStat()
    @Published private(set) var heartRateZoneSeconds: [HeartRateZone: Int] = [:]
    /// Estimated max heart rate used to classify samples into zones – see
    /// `HealthKitManager.fetchMaxHeartRateBPM`. `nil` until fetched, or if
    /// unavailable (e.g. no date of birth set in Health), in which case
    /// zones just stay empty.
    @Published private(set) var maxHeartRateBPM: Int?
    /// Distance integrated from live speed – published (not just captured in
    /// the final `WorkoutSummary`) so a route's live progress can be shown
    /// against `GradeProfile.totalDistanceMeters` while riding.
    @Published private(set) var distanceMeters: Double = 0

    /// The last loaded `.erg`/`.mrc`/GPX file, if any. Stays loaded across
    /// `reset()` so the same workout can be re-run without picking the file
    /// again – whether a given session actually *follows* it is decided at
    /// `start(usingProgram:)`, not just by this being non-nil.
    @Published private(set) var activeWorkout: ActiveWorkout?
    @Published private(set) var isProgramFinished = false

    private let connection: TrainerConnection
    private let heartRateProvider: () -> HeartRateConnection?

    private var timer: Timer?
    private var startDate: Date?
    private var workDoneJoules: Double = 0
    private var heartRateSamples: [(date: Date, bpm: Int)] = []
    private var lastSampledBPM: Int?
    /// Remembers what state a workout was in before `stop()`, so `cancelStop()`
    /// can put it back exactly the way it was.
    private var stateBeforeStop: WorkoutState?
    /// Whether *this* run is being driven by `activeWorkout` — set once at
    /// `start()`, so loading a different file (or none) mid-workout, or
    /// starting a later manual session while a workout is still loaded from a
    /// previous run, can never make `tick()` fight the user's own +/- taps.
    private var isDrivenByProgram = false
    /// Which `.erg`/`.mrc` file entry playback last reached – see
    /// `WorkoutProgram.breakpointIndex(atElapsedSeconds:)`. Compared against
    /// on every tick to fire the step-change vibration exactly once per new
    /// entry, not continuously while interpolating between two of them.
    private var lastProgramBreakpointIndex: Int?
    /// Strong reference to the currently (or most recently) playing interval
    /// beep – `AVAudioPlayer` doesn't keep itself alive, so a purely local
    /// instance would be deallocated, and silenced, right after `play()`
    /// returns since playback is asynchronous.
    private var audioPlayer: AVAudioPlayer?

    init(connection: TrainerConnection, heartRateProvider: @escaping () -> HeartRateConnection?) {
        self.connection = connection
        self.heartRateProvider = heartRateProvider
        // `.playback` + `.mixWithOthers` so interval beeps play over
        // whatever the rider is already listening to (music, a podcast)
        // instead of pausing it, and aren't silenced by the mute switch the
        // way `.ambient` would be – best-effort, a workout shouldn't fail to
        // start just because the audio session couldn't be configured.
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
    }

    /// - Parameter usingProgram: Whether this run should follow `activeWorkout`
    ///   (if one is loaded). Pass `false` for a plain manual Power/Resistance
    ///   session even while a workout happens to be loaded from an earlier run.
    func start(usingProgram: Bool) {
        guard state == .idle else { return }
        isDrivenByProgram = usingProgram && activeWorkout != nil
        isProgramFinished = false
        connection.startOrResumeWorkout()
        startDate = Date()
        state = .running
        startTimer()
        // Send the starting target immediately rather than waiting for the
        // first tick a second later.
        if isDrivenByProgram, let workout = activeWorkout {
            sendCurrentWorkoutTarget(for: workout)
        }
    }

    /// Loads a time-based power/resistance schedule to optionally follow once
    /// the session starts. Only while idle – stop the current session first
    /// to swap files.
    func loadProgram(_ program: WorkoutProgram) {
        guard state == .idle else { return }
        activeWorkout = .program(program)
        isProgramFinished = false
    }

    /// Loads a GPX-derived grade profile. Same rules as `loadProgram(_:)`.
    func loadRoute(_ route: GradeProfile) {
        guard state == .idle else { return }
        activeWorkout = .route(route)
        isProgramFinished = false
    }

    func setMaxHeartRateBPM(_ bpm: Int?) {
        maxHeartRateBPM = bpm
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
        stateBeforeStop = state
        connection.stopWorkout()
        stopTimer()
        let end = Date()
        pendingSummary = WorkoutSummary(
            machineKind: connection.machineKind,
            startDate: startDate ?? end,
            endDate: end,
            activeDuration: TimeInterval(elapsedSeconds),
            distanceMeters: distanceMeters > 0 ? distanceMeters : nil,
            workDoneKilojoules: workDoneJoules > 0 ? workDoneJoules / 1000 : nil,
            heartRateSamples: heartRateSamples,
            programName: isDrivenByProgram ? activeWorkout?.name : nil,
            heartRateZoneSeconds: heartRateZoneSeconds
        )
        state = .ended
    }

    /// Called when the user taps "Cancel" in the save/discard dialog (or
    /// dismisses it without picking anything) – undoes `stop()` and returns to
    /// whichever state the workout was in before, without losing any collected
    /// data. A no-op unless a stop is actually pending, so it's safe to call
    /// speculatively (e.g. from a dismiss handler that can't tell *why* the
    /// dialog closed).
    func cancelStop() {
        guard state == .ended else { return }
        pendingSummary = nil
        let restoredState = stateBeforeStop ?? .paused
        stateBeforeStop = nil
        state = restoredState
        if restoredState == .running {
            connection.startOrResumeWorkout()
            startTimer()
        } else {
            connection.pauseWorkout()
        }
    }

    /// Called once the save/discard dialog has been resolved, to reset for a
    /// new workout. Deliberately leaves `activeWorkout` loaded – re-running
    /// the same ramp test or route shouldn't require picking the file again.
    func reset() {
        pendingSummary = nil
        state = .idle
        elapsedSeconds = 0
        distanceMeters = 0
        workDoneJoules = 0
        heartRateSamples.removeAll()
        startDate = nil
        lastSampledBPM = nil
        stateBeforeStop = nil
        isDrivenByProgram = false
        isProgramFinished = false
        lastProgramBreakpointIndex = nil
        powerStats = LiveStat()
        cadenceStats = LiveStat()
        speedStats = LiveStat()
        heartRateStats = LiveStat()
        heartRateZoneSeconds = [:]
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

    /// Runs once per second while `state == .running`. Distance, work, and the
    /// live stats are only integrated here too, so pausing naturally excludes
    /// all of them from the totals.
    private func tick() {
        elapsedSeconds += 1
        if let speedKmh = connection.metrics.instantaneousSpeedKmh {
            distanceMeters += speedKmh * 1000 / 3600 // one second at this speed
            speedStats.record(speedKmh)
        }
        if let power = connection.metrics.instantaneousPowerWatts {
            workDoneJoules += Double(power) // one second at this power = that many joules
            powerStats.record(Double(power))
        }
        if let cadence = connection.metrics.instantaneousCadenceRPM {
            cadenceStats.record(cadence)
        }
        if let bpm = heartRateProvider()?.bpm {
            heartRateStats.record(Double(bpm))
            if let maxHR = maxHeartRateBPM, let zone = HeartRateZone.containing(bpm: bpm, maxHeartRateBPM: maxHR) {
                heartRateZoneSeconds[zone, default: 0] += 1
            }
            if bpm != lastSampledBPM {
                heartRateSamples.append((date: Date(), bpm: bpm))
                lastSampledBPM = bpm
            }
        }
        if isDrivenByProgram, let workout = activeWorkout {
            sendCurrentWorkoutTarget(for: workout)
        }
    }

    /// Looks up and sends the target for `workout` at the current position –
    /// elapsed time for a `.program`, distance covered so far for a `.route`
    /// (reusing the same `distanceMeters` this session already tracks for the
    /// post-workout summary). Marks `isProgramFinished` once past the end
    /// instead of sending anything further.
    private func sendCurrentWorkoutTarget(for workout: ActiveWorkout) {
        switch workout {
        case .program(let program):
            let elapsed = TimeInterval(elapsedSeconds)
            if let target = program.target(atElapsedSeconds: elapsed) {
                sendProgramTarget(target, kind: program.targetKind)
                if let index = program.breakpointIndex(atElapsedSeconds: elapsed) {
                    let didReachNewEntry = lastProgramBreakpointIndex != nil && index != lastProgramBreakpointIndex
                    if didReachNewEntry {
                        triggerStepVibrationIfEnabled()
                    }
                    let secondsUntilNextEntry = program.nextTransitionTimeSeconds(afterIndex: index)
                        .map { Int(($0 - elapsed).rounded()) }
                    playIntervalSoundIfNeeded(secondsUntilNextEntry: secondsUntilNextEntry, didReachNewEntry: didReachNewEntry)
                    lastProgramBreakpointIndex = index
                }
            } else {
                isProgramFinished = true
            }
        case .route(let route):
            if let grade = route.grade(atDistanceMeters: distanceMeters) {
                connection.setSimulationGrade(percent: grade)
            } else {
                isProgramFinished = true
            }
        }
    }

    /// Brief haptic tap for reaching a new Program (.erg/.mrc) file entry –
    /// see the "Vibration" setting in `SettingsView`. Not used for GPX
    /// routes, which don't have discrete file entries to reach in the same
    /// way (grade changes continuously with distance instead). Read fresh
    /// off `UserDefaults` rather than cached, since this class outlives any
    /// settings sheet that might toggle it mid-workout.
    private func triggerStepVibrationIfEnabled() {
        guard UserDefaults.standard.bool(forKey: Self.vibrationEnabledKey) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Plays the interval beep for reaching a new Program file entry
    /// (`didReachNewEntry`, always beeps if volume > 0 regardless of sound
    /// type) or for one of the four countdown seconds leading up to it
    /// (`secondsUntilNextEntry` in `1...4`, only for `IntervalSoundType
    /// .countdown` – `.single` stays quiet until the entry itself is
    /// reached). Volume and sound type are read fresh off `UserDefaults`
    /// rather than cached, same reasoning as `triggerStepVibrationIfEnabled`.
    private func playIntervalSoundIfNeeded(secondsUntilNextEntry: Int?, didReachNewEntry: Bool) {
        let volumePercent = UserDefaults.standard.integer(forKey: Self.intervalSoundVolumeKey)
        guard volumePercent > 0 else { return }
        if didReachNewEntry {
            playBeep(volumePercent: volumePercent)
            return
        }
        guard let secondsUntilNextEntry, (1...4).contains(secondsUntilNextEntry) else { return }
        let soundTypeRaw = UserDefaults.standard.string(forKey: Self.intervalSoundTypeKey)
        guard soundTypeRaw == IntervalSoundType.countdown.rawValue else { return }
        playBeep(volumePercent: volumePercent)
    }

    private func playBeep(volumePercent: Int) {
        guard let url = Bundle.main.url(forResource: "IntervalBeep", withExtension: "wav") else { return }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.volume = Float(volumePercent) / 100
            player.play()
            audioPlayer = player
        } catch {
            // Best-effort – a missing/corrupt sound file shouldn't interrupt
            // a workout.
        }
    }

    private func sendProgramTarget(_ value: Int, kind: ProgramTargetKind) {
        switch kind {
        case .power: connection.setTargetPower(watts: value)
        case .resistance: connection.setTargetResistancePercent(value)
        }
    }

    deinit {
        timer?.invalidate()
    }
}
