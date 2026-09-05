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

/// One second-resolution speed reading – see `WorkoutSession.speedHistory`.
struct SpeedSample {
    let timeSeconds: TimeInterval
    let kmh: Double
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

/// What a freely-ridden (non-`.program`) manual session's own target
/// schedule can be exported as, if anything – built live from the rider's
/// own `+`/`-` taps (see `WorkoutSession.beginRecordingManualTarget(kind:value:)`
/// and its siblings) rather than parsed from a file, but otherwise just an
/// ordinary `WorkoutProgram`/`TreadmillWorkoutProgram` value: reuses their
/// existing `fileContents()`/`suggestedFileName`, so once built, a
/// recording is exported exactly like a loaded one, and could equally be
/// fed straight back into `loadProgram(_:)`/`loadTreadmillProgram(_:)` to
/// repeat it. `.grade` sessions never produce one at all (see
/// `recordedProgramForCurrentWorkout()`'s own doc comment on why): neither
/// `.erg`/`.mrc` (power/resistance only) nor `.zwo` (speed/incline only,
/// and machine-kind-locked to treadmill throughout this app – a bike's
/// `.zwo` "export" could never even be loaded back into it) have anywhere
/// to put a recorded simulation grade.
///
/// `Codable` (Swift's own enum-with-associated-values synthesis) so it can
/// travel inside `WorkoutRecord` – saved into `WorkoutHistoryStore`
/// unconditionally by `reset()`, same as every other part of a finished
/// workout, rather than needing a decision about whether to keep it made
/// under the same time pressure as the Health save/discard choice. Only
/// `WorkoutHistoryDetailView` ever actually offers to export/repeat it
/// later, once there's no rush.
enum RecordedManualProgram: Codable {
    case program(WorkoutProgram)
    case treadmillProgram(TreadmillWorkoutProgram)

    func fileContents() -> String {
        switch self {
        case .program(let program): return program.fileContents()
        case .treadmillProgram(let program): return program.fileContents()
        }
    }

    var suggestedFileName: String {
        switch self {
        case .program(let program): return program.suggestedFileName
        case .treadmillProgram(let program): return program.suggestedFileName
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
    /// Same "at most one entry per elapsed second" shape again – exists for
    /// `WorkoutHistoryStore` to build a `.tcx` export's per-trackpoint
    /// distance/speed from (see `reset()`), not shown live anywhere itself.
    @Published private(set) var speedHistory: [SpeedSample] = []
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
    /// `nil` unless a `.power`/`.resistance` manual session is currently
    /// being recorded (see `beginRecordingManualTarget(kind:value:)`) – i.e.
    /// never for `.grade`/`.program`, which never call it. Set once at the
    /// start; `recordedBreakpoints` then grows by two entries per `+`/`-`
    /// tap (see `recordManualTarget(value:)`'s own note on why two, not
    /// one), and by one more once `recordedProgramForCurrentWorkout()`
    /// closes off the final held value at the actual stop time.
    private var recordedTargetKind: ProgramTargetKind?
    private var recordedBreakpoints: [WorkoutProgramBreakpoint] = []
    /// The `.speedIncline` counterpart to the two properties above – see
    /// `beginRecordingTreadmillTarget(speedKmh:inclinePercent:)`.
    /// `recordedTreadmillSegmentStartSeconds` is the currently *open*
    /// segment's own start – there's always at most one open at a time,
    /// closed into `recordedTreadmillSegments` (and immediately replaced by
    /// a new one) the moment either target actually changes.
    private var recordedTreadmillSegments: [TreadmillWorkoutSegment] = []
    private var recordedTreadmillSegmentStartSeconds: TimeInterval?
    private var recordedTreadmillSpeedKmh: Double?
    private var recordedTreadmillInclinePercent: Double?

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
        // `startDate` in the future, not `Date()` – some treadmills count
        // down on their own console ("3, 2, 1, go") after this command
        // before the belt actually moves; `TrainerDeviceSettings
        // .effectiveStartCountdownSeconds` is how long that takes for this
        // one. `currentElapsedSeconds(at:)` already clamps a negative
        // `now.timeIntervalSince(startDate)` to `0`, so `elapsedSeconds`
        // (and, through it, `programPositionSeconds` –
        // `sendCurrentWorkoutTarget(for:)`'s own `elapsed`) simply holds at
        // `0` for the rest of this method's `sendCurrentWorkoutTarget`
        // call below and every tick after it, until real time actually
        // reaches `startDate` – no separate "waiting" state needed, the
        // workout program only starts *advancing* once the treadmill is
        // actually moving. Defaults to `0` (no delay) for any device this
        // hasn't been measured for, so behavior is unchanged unless it's
        // deliberately set.
        startDate = Date().addingTimeInterval(startCountdownSeconds)
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
        // `max(...)`, not a flat overwrite – freezes at the moment Pause
        // was tapped, not the last refresh, same as before, but without
        // regressing *below* whatever `elapsedSeconds` was last published
        // as. That published value can be treadmill-sourced (see
        // `refreshWorkoutState`'s own note) and momentarily ahead of what
        // this purely local, `startDate`-based recompute alone would say.
        elapsedSeconds = max(currentElapsedSeconds(), elapsedSeconds)
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
        // See `pause()`'s own note on why `max(...)`, not a flat overwrite.
        elapsedSeconds = max(currentElapsedSeconds(), elapsedSeconds)
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
    ///
    /// Also where a finished workout gets saved to `WorkoutHistoryStore` –
    /// deliberately here, not in `stop()`: `stop()` can still be undone via
    /// `cancelStop()` (the confirmation dialog's own Cancel button), and
    /// `reset()` is the one place every path that actually *keeps* a stop –
    /// Save to Health, Discard, and the silent Watch-companion one (see
    /// `ControlView`'s `.onReceive(session.$pendingSummary)`) – all funnel
    /// through, always, regardless of what (if anything) got saved to
    /// Health. The two are independent by design: declining Health here
    /// doesn't lose the workout, it just stays out of Health.
    func reset() {
        if let summary = pendingSummary {
            let samples = mergedWorkoutSamples()
            WorkoutHistoryStore.save(WorkoutRecord(
                id: summary.id,
                machineKind: summary.machineKind,
                startDate: summary.startDate,
                endDate: summary.endDate,
                activeDuration: summary.activeDuration,
                distanceMeters: summary.distanceMeters,
                workDoneKilojoules: summary.workDoneKilojoules,
                programName: summary.programName,
                heartRateZoneSeconds: summary.heartRateZoneSeconds,
                samples: samples,
                estimatedVO2Max: estimatedVO2Max(samples: samples),
                recordedProgram: recordedProgramForCurrentWorkout()
            ))
        }
        pendingSummary = nil
        state = .idle
        elapsedSeconds = 0
        distanceMeters = 0
        powerHistory.removeAll()
        heartRateHistory.removeAll()
        speedHistory.removeAll()
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
        recordedTargetKind = nil
        recordedBreakpoints.removeAll()
        recordedTreadmillSegments.removeAll()
        recordedTreadmillSegmentStartSeconds = nil
        recordedTreadmillSpeedKmh = nil
        recordedTreadmillInclinePercent = nil
    }

    /// Fresh from `TrainerDeviceSettingsStore` every call, not cached – the
    /// rider can tweak this in Settings between workouts (or even mid-ride,
    /// though it only actually matters at the next Start/Resume), same
    /// "read at the point of use" pattern `refreshWorkoutState` already
    /// uses for the Heart Rate Zone boundaries.
    private var startCountdownSeconds: TimeInterval {
        TrainerDeviceSettingsStore.load(for: connection.peripheral.identifier).effectiveStartCountdownSeconds
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

    /// Merges `powerHistory`/`heartRateHistory`/`speedHistory` – three
    /// independently-deduped-to-one-per-second arrays, each only as long as
    /// its own metric was actually being reported – into one row per
    /// distinct elapsed second, for `WorkoutHistoryStore`/`TCXExporter`.
    /// Called from `reset()`, before those three get cleared a few lines
    /// later.
    private func mergedWorkoutSamples() -> [WorkoutSample] {
        // `uniquingKeysWith:` (keep whichever duplicate appears *last*),
        // not `uniqueKeysWithValues:` – the latter fatal-errors outright on
        // a duplicate `timeSeconds`. A real crash on a long workout
        // confirmed these three arrays weren't *quite* guaranteed never to
        // contain one (`elapsedSeconds` briefly stepping backward, back
        // when `refreshWorkoutState` used to nudge `startDate` to
        // resync against the connected machine's own elapsed-time counter – fixed
        // at the source since, `elapsedSeconds` is published straight from
        // that counter now, never derived by shifting `startDate` toward
        // it). Belt and braces: keeping the latest value on a duplicate is
        // a harmless, sensible fallback regardless of the cause, worlds
        // better than crashing over it.
        let powerBySecond = Dictionary(powerHistory.map { ($0.timeSeconds, $0.watts) }, uniquingKeysWith: { _, latest in latest })
        let heartRateBySecond = Dictionary(heartRateHistory.map { ($0.timeSeconds, $0.bpm) }, uniquingKeysWith: { _, latest in latest })
        let speedBySecond = Dictionary(speedHistory.map { ($0.timeSeconds, $0.kmh) }, uniquingKeysWith: { _, latest in latest })
        let allSeconds = Set(powerBySecond.keys).union(heartRateBySecond.keys).union(speedBySecond.keys)
        return allSeconds.sorted().map { second in
            WorkoutSample(
                elapsedSeconds: second,
                heartRateBPM: heartRateBySecond[second],
                powerWatts: powerBySecond[second],
                speedKmh: speedBySecond[second]
            )
        }
    }

    /// `nil` unless this run actually followed a `.zwo` treadmill program
    /// (`activeWorkout` might still be a leftover `.treadmillProgram` from
    /// an earlier run even for a plain manual session – `isDrivenByProgram`
    /// is what says whether *this* run actually followed it, same guard
    /// `sendCurrentWorkoutTarget(for:)` itself relies on). See
    /// `VO2MaxEstimator`'s own doc comment for the method/caveats.
    private func estimatedVO2Max(samples: [WorkoutSample]) -> Double? {
        guard isDrivenByProgram, case .treadmillProgram(let program) = activeWorkout else { return nil }
        let maxHR = UserDefaults.standard.integer(forKey: SettingsView.maxHeartRateBPMKey)
        let restingHR = UserDefaults.standard.integer(forKey: SettingsView.restingHeartRateBPMKey)
        return VO2MaxEstimator.estimate(program: program, samples: samples, restingHeartRateBPM: restingHR, maxHeartRateBPM: maxHR)
    }

    /// The public entry point for the same estimate `reset()` itself saves
    /// into `WorkoutHistoryStore` – lets `ControlView` show it immediately
    /// in `SavedWorkoutSummaryView`, right after the workout, instead of
    /// only ever being visible after navigating to Workout History. Has to
    /// be called *before* `reset()` runs (i.e. while `stop()`'s pending
    /// summary is still showing) – `reset()` clears `powerHistory`/
    /// `heartRateHistory`/`speedHistory` this reads via
    /// `mergedWorkoutSamples()`, and `activeWorkout`/`isDrivenByProgram`
    /// this itself needs.
    func estimatedVO2MaxForCurrentWorkout() -> Double? {
        estimatedVO2Max(samples: mergedWorkoutSamples())
    }

    /// Starts recording a `.power`/`.resistance` manual session's target
    /// schedule – called once, right after `start(usingProgram:)`, with
    /// whatever target is already showing at that moment as the schedule's
    /// first breakpoint (`t = 0`). `ControlView` simply never calls this
    /// (or `beginRecordingTreadmillTarget(speedKmh:inclinePercent:)`) for a
    /// `.grade`/`.program` session, so `recordedProgramForCurrentWorkout()`
    /// naturally stays `nil` for those – no separate "is this kind
    /// recordable" flag needed here.
    func beginRecordingManualTarget(kind: ProgramTargetKind, value: Int) {
        recordedTargetKind = kind
        recordedBreakpoints = [WorkoutProgramBreakpoint(timeSeconds: 0, value: value)]
    }

    /// Appends one `+`/`-` tap's new value to the schedule being recorded –
    /// a no-op unless `beginRecordingManualTarget(kind:value:)` actually
    /// ran first this session (e.g. a tap while still `.idle`, dialing in a
    /// starting value before Start is even pressed). Two breakpoints, not
    /// one, at the current elapsed time – `WorkoutProgram`'s own doc
    /// comment explains why: between two consecutive breakpoints the
    /// target is linearly interpolated, so a single new point would ramp
    /// smoothly from the old value to the new one instead of stepping,
    /// same "flat block = two points, step = two points at the same time"
    /// convention every `.erg`/`.mrc` file already relies on.
    func recordManualTarget(value: Int) {
        guard let lastValue = recordedBreakpoints.last?.value else { return }
        let now = TimeInterval(elapsedSeconds)
        recordedBreakpoints.append(WorkoutProgramBreakpoint(timeSeconds: now, value: lastValue))
        recordedBreakpoints.append(WorkoutProgramBreakpoint(timeSeconds: now, value: value))
    }

    /// The `.speedIncline` counterpart to `beginRecordingManualTarget(kind:value:)`
    /// – opens the first segment at `t = 0` with both targets as they
    /// already stand.
    func beginRecordingTreadmillTarget(speedKmh: Double, inclinePercent: Double) {
        recordedTreadmillSegments = []
        recordedTreadmillSegmentStartSeconds = 0
        recordedTreadmillSpeedKmh = speedKmh
        recordedTreadmillInclinePercent = inclinePercent
    }

    /// The `.speedIncline` counterpart to `recordManualTarget(value:)` –
    /// called with *both* current targets on every `+`/`-` tap to either
    /// one (`stepSpeed(_:)`/`stepIncline(_:)` each pass the other's own
    /// unchanged value along too), since a `TreadmillWorkoutSegment` always
    /// carries both at once. Unlike the power/resistance case above, no
    /// "two points" trick is needed – `TreadmillWorkoutSegment` is already
    /// flat over its own `duration` by construction (see its own doc
    /// comment), so closing the currently open segment off at the new
    /// elapsed time and opening a fresh one is enough on its own.
    func recordTreadmillTarget(speedKmh: Double, inclinePercent: Double) {
        guard let segmentStart = recordedTreadmillSegmentStartSeconds,
              let previousSpeedKmh = recordedTreadmillSpeedKmh,
              let previousInclinePercent = recordedTreadmillInclinePercent else { return }
        let now = TimeInterval(elapsedSeconds)
        guard now > segmentStart else {
            // Same elapsed second as the currently open segment's own
            // start (two taps in quick succession) – update it in place
            // rather than closing off a zero-length segment.
            recordedTreadmillSpeedKmh = speedKmh
            recordedTreadmillInclinePercent = inclinePercent
            return
        }
        recordedTreadmillSegments.append(TreadmillWorkoutSegment(
            startSeconds: segmentStart,
            duration: now - segmentStart,
            speedKmh: previousSpeedKmh,
            inclinePercent: previousInclinePercent,
            kind: nil
        ))
        recordedTreadmillSegmentStartSeconds = now
        recordedTreadmillSpeedKmh = speedKmh
        recordedTreadmillInclinePercent = inclinePercent
    }

    /// Builds the recorded `.power`/`.resistance`/`.speedIncline` target
    /// schedule into a `RecordedManualProgram` for `reset()` to save into
    /// `WorkoutRecord.recordedProgram` unconditionally, alongside every
    /// other part of a finished workout – no separate "do you want to keep
    /// this as a file" decision at Stop time, under the same time pressure
    /// as the Health save/discard choice (reported as genuinely unpleasant
    /// mid-workout, heart rate still up); `WorkoutHistoryDetailView` is
    /// where exporting it actually happens, once there's no rush. Closes
    /// off whatever's still open at the actual stop time first (without
    /// this, the file's own duration would end at the *last change* rather
    /// than however long that final value was actually held for – see
    /// `WorkoutProgram.duration`/`TreadmillWorkoutProgram.duration`, both
    /// derived from their last entry). `nil` for a `.grade`/`.program`
    /// session (neither ever calls a `beginRecording…` method above to
    /// begin with – see `RecordedManualProgram`'s own doc comment on why
    /// `.grade` specifically has nowhere to export to regardless), or for
    /// one stopped before a single real second of it was ever held (one
    /// breakpoint/no segment isn't a workout to repeat). Called from
    /// `reset()` itself, *before* it zeroes `elapsedSeconds`, which this
    /// reads.
    private func recordedProgramForCurrentWorkout() -> RecordedManualProgram? {
        let finalElapsedSeconds = TimeInterval(elapsedSeconds)
        let name = String(localized: "Recorded Workout \(recordedProgramTimestamp)")
        if let kind = recordedTargetKind, let lastValue = recordedBreakpoints.last?.value {
            var breakpoints = recordedBreakpoints
            if finalElapsedSeconds > (breakpoints.last?.timeSeconds ?? 0) {
                breakpoints.append(WorkoutProgramBreakpoint(timeSeconds: finalElapsedSeconds, value: lastValue))
            }
            guard breakpoints.count >= 2 else { return nil }
            return .program(WorkoutProgram(name: name, targetKind: kind, breakpoints: breakpoints))
        }
        if let segmentStart = recordedTreadmillSegmentStartSeconds,
           let speedKmh = recordedTreadmillSpeedKmh, let inclinePercent = recordedTreadmillInclinePercent {
            var segments = recordedTreadmillSegments
            if finalElapsedSeconds > segmentStart {
                segments.append(TreadmillWorkoutSegment(startSeconds: segmentStart, duration: finalElapsedSeconds - segmentStart, speedKmh: speedKmh, inclinePercent: inclinePercent, kind: nil))
            }
            guard !segments.isEmpty else { return nil }
            return .treadmillProgram(TreadmillWorkoutProgram(name: name, segments: segments))
        }
        return nil
    }

    /// A medium-date/short-time formatted timestamp (locale-aware, unlike
    /// the machine-readable `en_US_POSIX` numbers `fileContents()` itself
    /// writes) for `recordedProgramForCurrentWorkout()`'s default name –
    /// `pendingSummary?.startDate` if `stop()` already ran (the normal
    /// case, timestamps the workout itself rather than the moment it
    /// happened to get saved), falling back to `Date()` for the
    /// unreachable-in-practice case of building one with no pending
    /// summary at all.
    private var recordedProgramTimestamp: String {
        let date = pendingSummary?.startDate ?? Date()
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Starts (or resumes) tracking: a foreground `Timer` for the normal
    /// once-a-second cadence while the app is on screen, plus a subscription
    /// to the trainer's live metrics that fires `refreshWorkoutState` on
    /// every new BLE notification too – see the class doc comment for why
    /// that second path matters once the app is backgrounded.
    private func startTracking() {
        if let pauseDate {
            // Folding in `startCountdownSeconds` too, not just the real
            // paused interval – `resume()`/`cancelStop()` both send another
            // `startOrResumeWorkout()` right alongside this, so the same
            // console countdown `start()`'s own note explains almost
            // certainly plays again here, and `elapsedSeconds` shouldn't
            // resume ticking until it's actually done either.
            totalPausedDuration += Date().timeIntervalSince(pauseDate) + startCountdownSeconds
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
        // The connected machine's own elapsed-time counter (see
        // `TrainerMetrics.deviceElapsedSeconds`'s own doc comment – both
        // Indoor Bike Data and Treadmill Data can report one, so this
        // isn't treadmill-only), when reported, *is* the workout duration
        // as far as the machine's own console is concerned – so it's used
        // directly, not as a target to slowly correct the local
        // `startDate`-based clock toward. An earlier version of this tried
        // exactly that (nudging `startDate` to chase it every refresh) –
        // needlessly complicated, carried a real crash risk (a large
        // correction could step `elapsedSeconds` *backward*, and
        // `powerHistory`/`heartRateHistory`/`speedHistory` each dedupe by
        // comparing only against their own *last* entry, so a backward
        // step reintroduced an already-recorded second once forward
        // ticking resumed – `mergedWorkoutSamples()`'s `Dictionary` build
        // fatal-errors on the resulting duplicate key), and had its own
        // quiet side effect: shifting `startDate` also shifts the
        // workout's own reported *start time* (`stop()` uses it for
        // `WorkoutSummary.startDate`, which becomes the Health workout's
        // start timestamp) – not something a display-sync feature should
        // be touching at all.
        //
        // `max(deviceElapsedSeconds, elapsedSeconds)` – never regresses
        // `elapsedSeconds` below what's already been published, same
        // invariant the history arrays' dedup relies on, just enforced
        // directly on the published value instead of via `startDate`
        // gymnastics.
        //
        // Only actually considered once the local, `startDate`-based
        // `currentElapsedSeconds(at:)` itself shows genuine forward
        // progress since the last refresh (`localElapsedSeconds >
        // elapsedSeconds` below) – i.e. once whichever countdown hold is
        // currently in effect, if any, has actually lifted. `start()`'s
        // own initial countdown and a post-`resume()` one (folded into
        // `totalPausedDuration` – see `startTracking()`) both already make
        // the local computation hold flat at its pre-hold value for
        // exactly this long, so checking "did it move" covers either kind
        // of hold without this needing to know which one, if any, is
        // active. Deliberately not superseded by the device's own value
        // during a hold, in case a particular machine's own elapsed-time
        // counter runs through its own console countdown rather than only
        // once it's actually moving – this keeps "hold the program at
        // 0/frozen until it's actually moving" intact either way. The
        // local value is also the fallback whenever nothing's reported at
        // all (a machine that simply doesn't include this optional field,
        // or one that does but hasn't sent its first notification with it
        // yet).
        let localElapsedSeconds = currentElapsedSeconds(at: now)
        if let deviceElapsedSeconds = metrics.deviceElapsedSeconds, localElapsedSeconds > elapsedSeconds {
            elapsedSeconds = max(deviceElapsedSeconds, elapsedSeconds)
        } else {
            elapsedSeconds = localElapsedSeconds
        }
        let sampleDuration = lastMetricsSampleDate.map { now.timeIntervalSince($0) } ?? 0
        lastMetricsSampleDate = now

        if let speedKmh = metrics.instantaneousSpeedKmh {
            distanceMeters += speedKmh * 1000 / 3600 * sampleDuration
            speedStats.record(speedKmh)
            // Same "at most one entry per elapsed second" dedup as
            // `powerHistory`/`heartRateHistory` below – exists purely so
            // `WorkoutHistoryStore` (see `reset()`) has a real per-second
            // speed trace to build `.tcx` trackpoints from, not shown live
            // anywhere itself (unlike the other two, which back their own
            // charts).
            if speedHistory.last?.timeSeconds != TimeInterval(elapsedSeconds) {
                speedHistory.append(SpeedSample(timeSeconds: TimeInterval(elapsedSeconds), kmh: speedKmh))
            }
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
                // Clamped to what this specific treadmill's own
                // `inclinationRangePercent` actually supports *before* it's
                // used for anything below – not just when
                // `setTargetInclination(percent:)` would clamp it anyway a
                // few lines down. Reported from real use: computing the
                // ramp duration from the file's raw, unclamped target (e.g.
                // a `.zwo`'s -6 % on a treadmill that can't go below 0 %)
                // overstated how far the incline motor actually has to
                // travel (16 percentage points instead of the real 10),
                // which overstated how long the speed ramp needs to take to
                // match it – the belt sat at an intermediate speed for far
                // longer than the incline motor, which only had to cover
                // the real, smaller, clamped distance, actually took to
                // get there.
                let clampedInclinePercent = connection.inclinationRangePercent.clamp(target.inclinePercent)
                if shouldRestartSpeedRamp {
                    let previousInclinePercent = lastSentTreadmillInclinePercent ?? clampedInclinePercent
                    let inclineDeltaPercent = abs(clampedInclinePercent - previousInclinePercent)
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
                connection.setTargetInclination(percent: clampedInclinePercent)
                lastSentTreadmillSpeedKmh = speedToSend
                lastSentTreadmillInclinePercent = clampedInclinePercent
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
