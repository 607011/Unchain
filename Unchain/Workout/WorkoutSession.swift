import Foundation
import UIKit
import AVFoundation
import Combine

/// How the interval sound (see `SettingsView`) announces a new Program file
/// entry being reached – `.single` just beeps once on arrival, `.countdown`
/// additionally beeps once a second for the four seconds leading up to it.
enum IntervalSoundType: String, CaseIterable, Identifiable {
    case single
    case countdown

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .single: return String(localized: "Single Beep")
        case .countdown: return String(localized: "Countdown")
        }
    }
}

/// One second-resolution reading of actual power output – see
/// `WorkoutSession.powerHistory`.
struct PowerSample {
    let timeSeconds: TimeInterval
    let watts: Int
}

/// One second-resolution heart rate reading – see
/// `WorkoutSession.heartRateHistory`.
struct HeartRateSample {
    let timeSeconds: TimeInterval
    let bpm: Int
}

enum WorkoutState: Equatable {
    case idle
    case running
    case paused
    case ended
}

/// What the Program tab currently has loaded: a time-based power/resistance
/// schedule (`.erg`/`.mrc`), a distance-based grade profile (GPX), or a
/// time-based speed/incline schedule for a treadmill (`.zwo`). Mutually
/// exclusive – loading one replaces whichever was loaded before.
enum ActiveWorkout {
    case program(WorkoutProgram)
    case route(GradeProfile)
    case treadmillProgram(TreadmillWorkoutProgram)

    var name: String {
        switch self {
        case .program(let program): return program.name
        case .route(let route): return route.name
        case .treadmillProgram(let program): return program.name
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
    /// Seconds spent in each heart rate zone – see `HeartRateZone`. Unchain-only,
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
///
/// Elapsed time is derived from `Date()`, not counted in ticks – see
/// `currentElapsedSeconds(at:)` – so it reads correctly even if updates
/// arrive irregularly, which they do once the app is backgrounded: a plain
/// `Timer` stops firing the moment the app is suspended (see
/// `project.yml`'s `UIBackgroundModes`), but with `bluetooth-central`
/// declared there, the trainer's characteristic notifications keep arriving
/// regardless, and `startTracking()` subscribes to those too, so a running
/// workout keeps progressing – elapsed time, distance, and the Program/Route
/// target sent to the trainer – for as long as the connection survives in
/// the background, not just while the app is on screen. What this doesn't
/// cover: the OS fully terminating the process (e.g. under memory pressure)
/// rather than just suspending it – surviving that would need CoreBluetooth
/// state restoration (`CBCentralManagerOptionRestoreIdentifierKey`), which
/// isn't implemented.
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
    /// Distance integrated from live speed – published (not just captured in
    /// the final `WorkoutSummary`) so a route's live progress can be shown
    /// against `GradeProfile.totalDistanceMeters` while riding.
    @Published private(set) var distanceMeters: Double = 0
    /// One sample per elapsed second of actual power output, so
    /// `ControlView`'s `WorkoutProgramChart` can plot it alongside the
    /// planned target curve – a power-kind Program's whole point is
    /// comparing the two. At most one entry per second regardless of how
    /// often `refreshWorkoutState` itself fires (see the class doc comment).
    @Published private(set) var powerHistory: [PowerSample] = []
    /// Same "at most one entry per elapsed second" shape as `powerHistory`,
    /// for `ControlView`'s `WorkoutProgramChart` to optionally overlay a
    /// heart rate trace on its own (secondary) axis alongside Target/Actual
    /// – only populated while a heart rate strap is actually connected.
    @Published private(set) var heartRateHistory: [HeartRateSample] = []
    /// Live active-energy (calorie) estimate, updated every sample tick –
    /// shown in the metrics row in place of the speed tile once Speed
    /// Display is set to "Off" (see `SettingsView.speedDisplayUnitKey`).
    /// Same formula `HealthKitManager.save()`'s final figure uses for
    /// cycling (`EnergyEstimator.cyclingActiveEnergyKcal`) – deliberately
    /// cycling-only for now: the walk/run formula also needs a live body
    /// weight fetch and distance-based estimate wired up here, which hasn't
    /// been done yet, even though Walk vs. Run itself is now known from the
    /// start of a treadmill workout (`ControlView.chooseTreadmillActivity`)
    /// rather than only after stopping. `nil` for a treadmill for now – same
    /// "no accurate figure means no invented one" rule as everywhere else
    /// energy gets estimated.
    @Published private(set) var liveActiveEnergyKcal: Double?
    /// Session-local nudge to a Program's target values, e.g. "+5" means
    /// every target is sent (and shown) at 105 % of what the file/shorthand
    /// actually says – lets the rider scale a loaded workout up/down live
    /// without touching their stored FTP, which only resolves `%FTP` at
    /// *load* time (see `WorkoutProgramParser`/`ShorthandWorkoutParser`) and
    /// can't retroactively rescale an already-loaded program anyway. Not
    /// persisted, and reset back to 0 whenever a program is (re)loaded –
    /// see `loadProgram(_:)`/`loadRoute(_:)`/`reset()` – so every fresh
    /// attempt starts neutral rather than carrying over an old adjustment.
    @Published private(set) var intensityAdjustmentPercent: Int = 0
    /// No upper bound – unlike going lower (where -50 % already gets most
    /// targets close to nothing, so more headroom below isn't that useful),
    /// there's no equivalent ceiling on how much *more* a rider might
    /// reasonably want to push, and the trainer connection itself already
    /// clamps whatever this produces to its own reported range before
    /// anything is actually sent (`TrainerConnection.setTargetPower`/
    /// `setTargetResistancePercent`), so this doesn't need to be the thing
    /// guarding against an unsafe value reaching the trainer.
    private let minIntensityAdjustmentPercent = -50

    /// The last loaded `.erg`/`.mrc`/GPX file, if any. Stays loaded across
    /// `reset()` so the same workout can be re-run without picking the file
    /// again – whether a given session actually *follows* it is decided at
    /// `start(usingProgram:)`, not just by this being non-nil.
    @Published private(set) var activeWorkout: ActiveWorkout?
    @Published private(set) var isProgramFinished = false

    private let connection: TrainerConnection
    private let heartRateProvider: () -> HeartRateConnection?

    private var timer: Timer?
    private var metricsCancellable: AnyCancellable?
    private var startDate: Date?
    /// Set whenever tracking stops (`pause()`, `stop()`) to the moment it
    /// stopped; cleared (and folded into `totalPausedDuration`) the moment it
    /// resumes (`start()`, `resume()`, or `cancelStop()` restoring `.running`)
    /// – see `startTracking()`/`stopTracking()`. Together with
    /// `totalPausedDuration` this is what makes `currentElapsedSeconds(at:)`
    /// pause-aware without needing a continuously-running timer to track it.
    private var pauseDate: Date?
    private var totalPausedDuration: TimeInterval = 0
    /// When live metrics (speed, power) were last integrated into
    /// `distanceMeters`/`workDoneJoules` – used to scale each integration
    /// step by the *actual* real time since the last one, since updates can
    /// now arrive at irregular intervals (see the class doc comment), not
    /// reliably once a second the way a foreground-only `Timer` guaranteed.
    private var lastMetricsSampleDate: Date?
    private var workDoneJoules: Double = 0
    /// Fractional-second accumulator backing the published, whole-second
    /// `heartRateZoneSeconds` – refreshes can now arrive faster than once a
    /// second (a trainer's BLE notifications, not just the foreground
    /// `Timer`), so each individual `sampleDuration` is often under half a
    /// second; rounding *that* to the nearest second before accumulating
    /// would silently discard most of it instead of it adding up correctly.
    private var heartRateZoneSecondsAccumulator: [HeartRateZone: Double] = [:]
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
    /// Offset between `elapsedSeconds` (real, wall-clock workout time –
    /// never touched by a jump) and where playback actually is within the
    /// loaded program/route, e.g. after `jump(toElapsedSeconds:)`. Zero for
    /// the entire session unless that's been called at least once. See
    /// `programPositionSeconds`.
    private var programOffsetSeconds: TimeInterval = 0
    /// Which `.erg`/`.mrc` file entry playback last reached – see
    /// `WorkoutProgram.breakpointIndex(atElapsedSeconds:)`. Compared against
    /// on every tick to fire the step-change vibration exactly once per new
    /// entry, not continuously while interpolating between two of them.
    private var lastProgramBreakpointIndex: Int?
    /// Speed-ramp state for a `.treadmillProgram` interval transition – see
    /// `sendCurrentWorkoutTarget(for:)`'s own note on why speed (not
    /// incline) is what gets smoothed here. `treadmillSpeedRampDurationSeconds`
    /// staying `0` (its default, and after a delta-free transition) is what
    /// keeps the ramp inactive – speed is sent as a flat target whenever
    /// it's `0`, the same as before this existed.
    private var treadmillSpeedRampFromKmh: Double?
    private var treadmillSpeedRampToKmh: Double?
    private var treadmillSpeedRampStartSeconds: TimeInterval?
    private var treadmillSpeedRampDurationSeconds: TimeInterval = 0
    /// The actual speed/incline last sent to a treadmill – as opposed to
    /// the current segment's own nominal target, which a still-in-progress
    /// ramp (see above) can differ from. Used as the *next* ramp's starting
    /// point, so a transition arriving before the previous one's ramp
    /// finished continues smoothly from wherever the belt actually is.
    private var lastSentTreadmillSpeedKmh: Double?
    private var lastSentTreadmillInclinePercent: Double?
    /// Set by `jump(toElapsedSeconds:)`, consumed (and cleared) by the very
    /// next `sendCurrentWorkoutTarget(for:)` call. Unlike `didReachNewEntry`
    /// (used only for vibration/interval-sound, which a jump deliberately
    /// keeps suppressed – see `jump`'s own note on why) a jump *should*
    /// still restart the speed ramp toward wherever it landed: the incline
    /// is genuinely about to change there too, and the belt getting ahead
    /// of it is exactly the hazard ramping exists to avoid – whether that
    /// transition was reached by ordinary playback or a manual tap in
    /// `TreadmillProgramSegmentList` makes no physical difference to the
    /// treadmill. First left out of `jump` entirely; fixed after realizing
    /// the "it's just a preview, no need to ramp" reasoning didn't actually
    /// hold up while a workout is still running – `jump` only works then
    /// in the first place (see its own `state == .running || .paused`
    /// guard), so whatever it lands on is being walked/run on for real.
    private var pendingTreadmillSpeedRampRestart = false
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
        programOffsetSeconds = 0
        connection.startOrResumeWorkout()
        startDate = Date()
        state = .running
        startTracking()
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
        intensityAdjustmentPercent = 0
    }

    /// Loads a GPX-derived grade profile. Same rules as `loadProgram(_:)`.
    func loadRoute(_ route: GradeProfile) {
        guard state == .idle else { return }
        activeWorkout = .route(route)
        isProgramFinished = false
        intensityAdjustmentPercent = 0
    }

    /// Loads a `.zwo`-derived treadmill speed/incline schedule. Same rules
    /// as `loadProgram(_:)` – `intensityAdjustmentPercent` is reset too,
    /// even though nothing currently lets the rider actually adjust it for
    /// this workout kind (see `sendCurrentWorkoutTarget(for:)`'s own note),
    /// just so it can't carry over a stale nonzero value from an earlier
    /// `.program` run into this one.
    func loadTreadmillProgram(_ program: TreadmillWorkoutProgram) {
        guard state == .idle else { return }
        activeWorkout = .treadmillProgram(program)
        isProgramFinished = false
        intensityAdjustmentPercent = 0
    }

    /// Nudges `intensityAdjustmentPercent` by `delta` (1 per +/- tap),
    /// floored at `minIntensityAdjustmentPercent` but with no ceiling.
    /// Kind-agnostic – works the same for a power-kind or resistance-kind
    /// Program, both just scale the resolved target value (see
    /// `adjustedTargetValue(_:)`).
    func adjustIntensity(byPercent delta: Int) {
        intensityAdjustmentPercent = Swift.max(minIntensityAdjustmentPercent, intensityAdjustmentPercent + delta)
    }

    /// Applies `intensityAdjustmentPercent` to a raw target/breakpoint
    /// value – what's actually sent to the trainer
    /// (`sendCurrentWorkoutTarget`) and the live number in `ControlView` both
    /// go through this.
    func adjustedTargetValue(_ rawValue: Int) -> Int {
        Self.adjustedValue(rawValue, byPercent: intensityAdjustmentPercent)
    }

    /// The actual math behind `adjustedTargetValue(_:)`, factored out as a
    /// `static` so `WorkoutProgramChart` (which only gets a plain
    /// `Int` percent, not a `WorkoutSession` reference) can apply the exact
    /// same formula to the chart's target curve – one formula, so the
    /// number, the trainer, and the chart can never drift apart. Floored at
    /// 0 – a negative watt/percent target isn't meaningful.
    static func adjustedValue(_ rawValue: Int, byPercent percent: Int) -> Int {
        let scaled = Double(rawValue) * (1 + Double(percent) / 100)
        return Swift.max(0, Int(scaled.rounded()))
    }

    func pause() {
        guard state == .running else { return }
        connection.pauseWorkout()
        elapsedSeconds = currentElapsedSeconds() // freeze at the moment Pause was tapped, not the last refresh
        state = .paused
        stopTracking()
    }

    func resume() {
        guard state == .paused else { return }
        connection.startOrResumeWorkout()
        state = .running
        startTracking()
    }

    /// Skips playback to `target` seconds into the workout – e.g. tapping a
    /// row in `TreadmillProgramSegmentList` to jump straight to that
    /// segment, rather than only ever moving forward one second at a time.
    /// Only meaningful while actually following a loaded workout
    /// (`isDrivenByProgram`); a no-op for a plain manual session, which has
    /// no file position to jump within.
    ///
    /// Moves `programOffsetSeconds`, *not* `elapsedSeconds`/`startDate` –
    /// `elapsedSeconds` is how long the workout has actually been
    /// running/walked, and must keep ticking with the real clock no matter
    /// where playback has been jumped to (previously this shifted
    /// `startDate` itself, which made the on-screen total time jump too,
    /// backward or forward, every time a row was tapped). See
    /// `programPositionSeconds`.
    func jump(toElapsedSeconds target: TimeInterval) {
        guard isDrivenByProgram, state == .running || state == .paused else { return }
        programOffsetSeconds = target - TimeInterval(elapsedSeconds)
        // A big jump shouldn't itself count as "reached a new entry" for
        // vibration/interval-sound purposes – let the next regular tick
        // re-establish that from a clean slate instead of possibly firing
        // on a jump spanning many entries at once.
        lastProgramBreakpointIndex = nil
        // But it *should* still restart the treadmill speed ramp toward
        // wherever it landed – see `pendingTreadmillSpeedRampRestart`'s own
        // note on why that's a separate concern from the vibration/sound
        // suppression right above.
        pendingTreadmillSpeedRampRestart = true
        if let workout = activeWorkout {
            sendCurrentWorkoutTarget(for: workout)
        }
    }

    /// Where playback actually is within the loaded program/route's own
    /// timeline – equal to `elapsedSeconds` (real, wall-clock workout time)
    /// unless `jump(toElapsedSeconds:)` has shifted it away, e.g. tapping
    /// ahead or back in `TreadmillProgramSegmentList` to preview a
    /// different segment. Kept separate from `elapsedSeconds` itself so a
    /// preview jump can change *this* (which segment is "current", what
    /// target gets sent) without also making the on-screen total time jump.
    var programPositionSeconds: TimeInterval { TimeInterval(elapsedSeconds) + programOffsetSeconds }

    func stop() {
        guard state == .running || state == .paused else { return }
        stateBeforeStop = state
        connection.stopWorkout()
        elapsedSeconds = currentElapsedSeconds() // freeze at the moment Stop was tapped, not the last refresh
        stopTracking()
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
            startTracking()
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
        powerHistory.removeAll()
        heartRateHistory.removeAll()
        liveActiveEnergyKcal = nil
        workDoneJoules = 0
        heartRateSamples.removeAll()
        startDate = nil
        pauseDate = nil
        totalPausedDuration = 0
        lastMetricsSampleDate = nil
        lastSampledBPM = nil
        stateBeforeStop = nil
        isDrivenByProgram = false
        isProgramFinished = false
        programOffsetSeconds = 0
        intensityAdjustmentPercent = 0
        lastProgramBreakpointIndex = nil
        treadmillSpeedRampFromKmh = nil
        treadmillSpeedRampToKmh = nil
        treadmillSpeedRampStartSeconds = nil
        treadmillSpeedRampDurationSeconds = 0
        lastSentTreadmillSpeedKmh = nil
        lastSentTreadmillInclinePercent = nil
        pendingTreadmillSpeedRampRestart = false
        powerStats = LiveStat()
        cadenceStats = LiveStat()
        speedStats = LiveStat()
        heartRateStats = LiveStat()
        heartRateZoneSeconds = [:]
        heartRateZoneSecondsAccumulator = [:]
    }

    /// Elapsed *active* seconds at `now` – total time since `startDate`,
    /// minus every paused interval (completed ones already folded into
    /// `totalPausedDuration`, plus the one currently in progress if
    /// `pauseDate` is set). Recomputing from `Date()` on every refresh,
    /// rather than counting ticks, means a gap between refreshes – whether
    /// from the foreground `Timer` being coalesced or the app having been
    /// backgrounded entirely – reads correctly the moment the next refresh
    /// happens instead of silently losing that time.
    private func currentElapsedSeconds(at now: Date = Date()) -> Int {
        guard let startDate else { return 0 }
        let pausedSoFar = totalPausedDuration + (pauseDate.map { now.timeIntervalSince($0) } ?? 0)
        return max(0, Int((now.timeIntervalSince(startDate) - pausedSoFar).rounded(.down)))
    }

    /// Starts (or resumes) tracking: a foreground `Timer` for the normal
    /// once-a-second cadence while the app is on screen, plus a subscription
    /// to the trainer's live metrics that fires `refreshWorkoutState` on
    /// every new BLE notification too – see the class doc comment for why
    /// that second path matters once the app is backgrounded.
    private func startTracking() {
        if let pauseDate {
            totalPausedDuration += Date().timeIntervalSince(pauseDate)
            self.pauseDate = nil
        }
        lastMetricsSampleDate = Date()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshWorkoutState(metrics: self.connection.metrics)
        }

        // `@Published`'s projected publisher hands the *new* value to the
        // sink itself – used directly rather than re-reading
        // `connection.metrics` here, which could still observe the old value
        // for a moment (a known `@Published`/Combine timing quirk).
        metricsCancellable = connection.$metrics
            .dropFirst() // skip the just-subscribed replay of the current value
            .sink { [weak self] metrics in
                self?.refreshWorkoutState(metrics: metrics)
            }
    }

    private func stopTracking() {
        timer?.invalidate()
        timer = nil
        metricsCancellable?.cancel()
        metricsCancellable = nil
        if pauseDate == nil {
            pauseDate = Date()
        }
    }

    /// Re-derives elapsed time and integrates distance/work/heart-rate-zone
    /// time over the real time since the last refresh (`lastMetricsSampleDate`)
    /// rather than assuming exactly one second, since refreshes can now come
    /// from either the once-a-second foreground `Timer` or an irregular BLE
    /// metrics notification – see `startTracking()`.
    private func refreshWorkoutState(metrics: TrainerMetrics) {
        let now = Date()
        elapsedSeconds = currentElapsedSeconds(at: now)
        let sampleDuration = lastMetricsSampleDate.map { now.timeIntervalSince($0) } ?? 0
        lastMetricsSampleDate = now

        if let speedKmh = metrics.instantaneousSpeedKmh {
            distanceMeters += speedKmh * 1000 / 3600 * sampleDuration
            speedStats.record(speedKmh)
        }
        if let power = metrics.instantaneousPowerWatts {
            workDoneJoules += Double(power) * sampleDuration // that many joules over sampleDuration seconds
            powerStats.record(Double(power))
            // At most one entry per elapsed second – refreshes can fire more
            // often than that (see the class doc comment), which would
            // otherwise pile up multiple points on the same second.
            if powerHistory.last?.timeSeconds != TimeInterval(elapsedSeconds) {
                powerHistory.append(PowerSample(timeSeconds: TimeInterval(elapsedSeconds), watts: power))
            }
            if connection.machineKind == .bike {
                liveActiveEnergyKcal = EnergyEstimator.cyclingActiveEnergyKcal(workDoneKilojoules: workDoneJoules / 1000)
            }
        }
        if let cadence = metrics.instantaneousCadenceRPM {
            cadenceStats.record(cadence)
        }
        if let bpm = heartRateProvider()?.bpm {
            heartRateStats.record(Double(bpm))
            // Same "at most one entry per elapsed second" dedup as
            // `powerHistory` above.
            if heartRateHistory.last?.timeSeconds != TimeInterval(elapsedSeconds) {
                heartRateHistory.append(HeartRateSample(timeSeconds: TimeInterval(elapsedSeconds), bpm: bpm))
            }
            // Read directly rather than cached in a published property: the
            // user can edit these in Settings mid-ride, and `.containing`
            // already treats "0/unset" as "no zone" (max) or "no resting
            // heart rate on record" (resting, falls back to plain %-of-max)
            // – see `SettingsView.maxHeartRateBPMKey`/`restingHeartRateBPMKey`.
            let maxHR = UserDefaults.standard.integer(forKey: SettingsView.maxHeartRateBPMKey)
            let restingHR = UserDefaults.standard.integer(forKey: SettingsView.restingHeartRateBPMKey)
            if let zone = HeartRateZone.containing(bpm: bpm, maxHeartRateBPM: maxHR, restingHeartRateBPM: restingHR) {
                heartRateZoneSecondsAccumulator[zone, default: 0] += sampleDuration
                heartRateZoneSeconds[zone] = Int(heartRateZoneSecondsAccumulator[zone, default: 0].rounded())
            }
            if bpm != lastSampledBPM {
                heartRateSamples.append((date: now, bpm: bpm))
                lastSampledBPM = bpm
            }
        }
        if isDrivenByProgram, let workout = activeWorkout {
            sendCurrentWorkoutTarget(for: workout)
        }
    }

    /// Forces an immediate refresh using whatever metrics the connection
    /// currently has, instead of waiting for the next `Timer` tick or BLE
    /// notification – called when the app returns to the foreground (see
    /// `ControlView`'s `scenePhase` handling) so the UI shows caught-up
    /// numbers right away rather than visibly stale ones for up to a second.
    /// A no-op while not actually running.
    func refreshNow() {
        guard state == .running else { return }
        refreshWorkoutState(metrics: connection.metrics)
    }

    /// Looks up and sends the target for `workout` at the current position –
    /// elapsed time for a `.program`/`.treadmillProgram`, distance covered so
    /// far for a `.route` (reusing the same `distanceMeters` this session
    /// already tracks for the post-workout summary). Marks
    /// `isProgramFinished` once past the end instead of sending anything
    /// further.
    private func sendCurrentWorkoutTarget(for workout: ActiveWorkout) {
        switch workout {
        case .program(let program):
            let elapsed = programPositionSeconds
            if let target = program.target(atElapsedSeconds: elapsed) {
                // Explicit, not just "stays false in the ordinary case" –
                // `jump(toElapsedSeconds:)` can move `elapsed` *backward*
                // too, e.g. back into range after having already run past
                // the end, and this is what un-sticks a stale "complete"
                // state from before that jump.
                isProgramFinished = false
                sendProgramTarget(adjustedTargetValue(target), kind: program.targetKind)
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
                isProgramFinished = false
                connection.setSimulationGrade(percent: grade)
            } else {
                isProgramFinished = true
            }
        case .treadmillProgram(let program):
            // Same step-transition handling as `.program` above (vibration/
            // interval sound, `lastProgramBreakpointIndex` reused as-is –
            // safe since only one `ActiveWorkout` case is ever loaded at a
            // time) – but no `adjustedTargetValue(_:)` call: that scales a
            // single `Int`, and this sends two `Double` targets at once.
            // Session-local intensity adjustment for this workout kind is
            // simply out of scope for now, not silently dropped – nothing
            // in `ControlView` exposes the +/- for it either.
            let elapsed = programPositionSeconds
            if let target = program.target(atElapsedSeconds: elapsed) {
                // See the `.program` case's own note above on why this is
                // explicit – `jump(toElapsedSeconds:)` is exactly why.
                isProgramFinished = false
                let index = program.segmentIndex(atElapsedSeconds: elapsed)
                let didReachNewEntry = index != nil && lastProgramBreakpointIndex != nil && index != lastProgramBreakpointIndex
                // Reported from real use: jumping straight from e.g. 15 %
                // incline at 4 km/h to 0 % at 6.5 km/h used to send both
                // targets at once – the belt speeds up almost instantly,
                // but the incline motor takes real, measurable time to
                // physically get there, so for those few seconds the rider
                // is doing 6.5 km/h on a platform still tilted close to
                // 15 % – enough to push someone off the back. Only *speed*
                // is ramped here, linearly, over the incline's own
                // estimated travel time – incline itself is still sent as
                // one flat target immediately, same as before, since
                // nothing here controls how fast the motor itself moves;
                // this only paces how fast the belt gets ahead of it.
                // Recomputed fresh on every genuine step transition *and*
                // on a manual jump (see `pendingTreadmillSpeedRampRestart`'s
                // own note on why a jump still needs this even though it
                // suppresses vibration/interval-sound) – the incline is
                // physically about to change either way, so the hazard
                // this ramp exists to avoid applies regardless of what
                // triggered the transition. A tick partway through an
                // already-running ramp just keeps interpolating using
                // whichever ramp was started last, so a second transition
                // arriving before the first ramp finished still continues
                // smoothly from wherever the belt actually is, not from
                // the old segment's nominal target.
                let shouldRestartSpeedRamp = didReachNewEntry || pendingTreadmillSpeedRampRestart
                pendingTreadmillSpeedRampRestart = false
                if shouldRestartSpeedRamp {
                    let previousInclinePercent = lastSentTreadmillInclinePercent ?? target.inclinePercent
                    let inclineDeltaPercent = abs(target.inclinePercent - previousInclinePercent)
                    let secondsPerUnit = TrainerDeviceSettingsStore.load(for: connection.peripheral.identifier).effectiveInclineChangeSecondsPerDegree
                    treadmillSpeedRampFromKmh = lastSentTreadmillSpeedKmh ?? target.speedKmh
                    treadmillSpeedRampToKmh = target.speedKmh
                    treadmillSpeedRampStartSeconds = elapsed
                    treadmillSpeedRampDurationSeconds = inclineDeltaPercent * secondsPerUnit
                }
                let speedToSend: Double
                if let rampFrom = treadmillSpeedRampFromKmh, let rampTo = treadmillSpeedRampToKmh,
                   let rampStart = treadmillSpeedRampStartSeconds, treadmillSpeedRampDurationSeconds > 0 {
                    let fraction = min(max((elapsed - rampStart) / treadmillSpeedRampDurationSeconds, 0), 1)
                    speedToSend = rampFrom + (rampTo - rampFrom) * fraction
                } else {
                    speedToSend = target.speedKmh
                }
                connection.setTargetSpeed(kmh: speedToSend)
                connection.setTargetInclination(percent: target.inclinePercent)
                lastSentTreadmillSpeedKmh = speedToSend
                lastSentTreadmillInclinePercent = target.inclinePercent
                if let index {
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
        metricsCancellable?.cancel()
    }
}
