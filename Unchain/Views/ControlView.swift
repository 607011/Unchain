import SwiftUI
import HealthKit
import Charts
import UniformTypeIdentifiers
import UIKit

struct ControlView: View {
    @ObservedObject var connection: TrainerConnection
    @ObservedObject var bluetooth: BluetoothManager
    @StateObject private var session: WorkoutSession
    /// `.regular` on iPad (full-screen or wide Split View), `.compact` on
    /// iPhone — used instead of `UIDevice.userInterfaceIdiom` so a narrow
    /// iPad Split View correctly falls back to the iPhone-sized layout too.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Used only to force an immediate `session.refreshNow()` on return from
    /// the background – see the `onChange` below and `WorkoutSession`'s class
    /// doc comment for why the workout itself doesn't need this to stay
    /// correct, just to look caught-up right away instead of for up to a
    /// second.
    @Environment(\.scenePhase) private var scenePhase

    /// Restored from the last run, same as the target values below — picking
    /// up right where you left off (Power vs. Program vs. …) beats always
    /// reopening on Power. `ensureModeIsAvailable()` handles a restored mode
    /// the *currently connected* machine doesn't support (e.g. last time was
    /// Grade on a different trainer) by falling back – see that function's
    /// own note on why it must never run before machine capabilities are
    /// actually known, though, or this restore silently breaks instead.
    @AppStorage("lastActiveMode") private var mode: ControlMode = .power
    /// Restored from the last run, and kept up to date as the user steps
    /// them, so they survive an app restart.
    @AppStorage("lastTargetPowerWatts") private var targetPower: Int = 100
    @AppStorage("lastTargetResistancePercent") private var targetResistance: Int = 20
    @AppStorage("lastTargetGradePercent") private var targetGrade: Double = 0
    @AppStorage("lastTargetSpeedKmh") private var targetSpeedKmh: Double = 5.0
    @AppStorage("lastTargetInclinePercent") private var targetInclinePercent: Double = 0
    /// Set in Settings – see `SpeedDisplayUnit`'s own doc comment for why
    /// km/h isn't always the most useful reading here.
    @AppStorage(SettingsView.speedDisplayUnitKey) private var speedDisplayUnit = SpeedDisplayUnit.kmh
    @State private var saveResult: SaveResultAlert?
    @State private var savedSummary: WorkoutSummary?
    @State private var isShowingFeatures = false
    @State private var isShowingSettings = false
    @State private var isShowingFileImporter = false
    @State private var isShowingRecentWorkouts = false
    @State private var isShowingCreateWorkout = false
    @State private var isShowingExporter = false
    @State private var loadError: LoadErrorAlert?
    /// True while an async HealthKit save is in flight — guards the
    /// confirmation dialog's dismiss handler from mistaking the dialog closing
    /// itself (after "Save as …" was tapped) for the user cancelling.
    @State private var isSaving = false
    /// True for the duration of a workout started via the Watch companion
    /// app (see `WatchConnectivityManager`) – the Watch's own `HKWorkoutSession`
    /// is the one saving this workout to Health (more accurately than
    /// Unchain's own estimate can, see `HealthKitManager`'s doc comment), so
    /// the usual "Save workout to Apple Health?" dialog and save are both
    /// skipped for it – see the `onChange(of: session.pendingSummary)` below.
    @State private var isWatchCompanionWorkout = false
    /// Chosen once, up front, the moment a treadmill workout starts (see
    /// `startWorkout()`/`chooseTreadmillActivity(_:)`) – used at save time
    /// instead of asking again (`saveDialogButtons`), and, for a
    /// Watch-triggered start, sent along so the Watch's own
    /// `HKWorkoutSession` declares the same activity type. `nil` before the
    /// choice is made, and for any non-treadmill workout.
    @State private var treadmillActivityType: HKWorkoutActivityType?
    /// Drives the "Walking or running?" dialog below – shown the moment
    /// Start is requested for a treadmill, regardless of whether that
    /// request came from this screen's own Start button or relayed from the
    /// Watch (`configureWatchCompanion()`).
    @State private var isChoosingTreadmillActivity = false
    /// Set only while answering a Watch-triggered start request – holds the
    /// reply `WatchConnectivityManager` is waiting to send back to the
    /// Watch until the rider actually answers the dialog above. `nil` for a
    /// plain start from this screen's own button, where there's no Watch
    /// side waiting on anything.
    @State private var pendingWatchStartCompletion: ((Bool, HKWorkoutActivityType?) -> Void)?

    private let powerStep = 5
    private let resistanceStep = 1
    private let gradeStep: Double = 0.5
    private let speedStepKmh: Double = 0.5
    private let inclineStepPercent: Double = 0.5
    /// Resistance is always controlled as 0–100 % of the device's own supported
    /// range (see `TrainerConnection.setTargetResistancePercent`) — not the raw,
    /// vendor-defined FTMS resistance level, which can be far narrower.
    private let resistancePercentRange = 0...100
    /// Matches the clamp already applied in `TrainerConnection.setSimulationGrade`.
    private let gradePercentRange = -25.0...25.0

    init(connection: TrainerConnection, bluetooth: BluetoothManager) {
        self.connection = connection
        self.bluetooth = bluetooth
        _session = StateObject(wrappedValue: WorkoutSession(
            connection: connection,
            heartRateProvider: { [weak bluetooth] in bluetooth?.currentHeartRateConnection }
        ))
    }

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    // Default to `true` for Power/Resistance while `supportedFeatures` hasn't
    // been read yet (right after connecting) – both tabs already existed
    // before this gating was added, so an unknown state shouldn't ever hide
    // something that used to just work. Grade is brand new, so it defaults
    // to `false` instead: better to have it pop in a moment after Power/
    // Resistance than to show it and then yank it away.
    private var supportsPowerTarget: Bool { connection.supportedFeatures?.supportsPowerTarget ?? true }
    private var supportsResistanceTarget: Bool { connection.supportedFeatures?.supportsResistanceTarget ?? true }
    private var supportsIndoorBikeSimulation: Bool { connection.supportedFeatures?.supportsIndoorBikeSimulation ?? false }
    private var supportsSpeedTarget: Bool { connection.supportedFeatures?.supportsSpeedTarget ?? false }
    private var supportsInclinationTarget: Bool { connection.supportedFeatures?.supportsInclinationTarget ?? false }

    /// Only the modes the connected machine actually supports. Program (file
    /// loading) always shows – which file *types* it accepts adapts
    /// internally instead, see `allowedFileContentTypes`.
    private var availableModes: [ControlMode] {
        var modes: [ControlMode] = []
        if supportsPowerTarget { modes.append(.power) }
        if supportsIndoorBikeSimulation { modes.append(.grade) }
        // Treadmill-gated per its own request, not just on the target
        // features being supported – a device could in principle declare
        // Speed/Inclination Target support without actually being detected
        // as a treadmill (see `TrainerConnection.machineKind`'s own note on
        // a device exposing more than one data characteristic), and this
        // tab's controls only make sense for one.
        if connection.machineKind == .treadmill, supportsSpeedTarget || supportsInclinationTarget {
            modes.append(.speedIncline)
        }
        modes.append(.program)
        if supportsResistanceTarget { modes.append(.resistance) }
        return modes
    }

    /// If the currently selected tab just became unavailable (feature
    /// detection completed and turned out negative), fall back to the first
    /// one that's still valid instead of leaving the picker on a hidden case.
    ///
    /// Only ever call this once `connection.supportedFeatures`/
    /// `connection.machineKind` are actually known (see the call sites
    /// below – never from `.onAppear` unconditionally). `mode` is itself
    /// the `@AppStorage`-backed property, so any write here persists
    /// *immediately* – calling this before those are known used to treat
    /// "not detected yet" the same as "genuinely unsupported", silently and
    /// permanently overwriting a remembered Grade/Speed & Incline
    /// preference with "Power" before the real answer had even arrived.
    /// Reported after exactly that happened to Speed & Incline; the same
    /// bug had apparently already bitten Grade earlier.
    private func ensureModeIsAvailable() {
        guard !availableModes.contains(mode) else { return }
        mode = availableModes.first ?? .program
    }

    /// Records this trainer under Settings → Devices (see
    /// `TrainerDeviceStore`) once its kind is actually known – a no-op
    /// while `machineKind` is still `.unknown`, so it's safe to call
    /// unconditionally rather than needing its own "is this known yet"
    /// guard the way `ensureModeIsAvailable()` needs for `mode` itself.
    private func rememberConnectedDevice() {
        TrainerDeviceStore.recordConnection(id: connection.peripheral.identifier, name: connection.deviceName, machineKind: connection.machineKind)
    }

    var body: some View {
        // A ScrollView rather than a fixed VStack: iPad landscape has much
        // less height than portrait (where the iPad type/chart scale above
        // was sized against generous portrait height), so this is the safety
        // net against clipped content instead of a bespoke landscape layout.
        // On iPhone (portrait-only) and iPad portrait, content already fits,
        // so this has no visible effect there.
        ScrollView {
            VStack(spacing: isRegularWidth ? 40 : 32) {
                // Once ready, the "Disconnect"/"Reconnect" button already implies
                // the connection state — a separate "Connected" hint would be
                // redundant. The other states (connecting, error, …) still say
                // something the button alone doesn't.
                if connection.state != .ready {
                    statusHeader
                }
                metricsRow
                HeartRateZonesView(zoneSeconds: session.heartRateZoneSeconds)
                    .padding(.horizontal)
                workoutControls

                Picker("Mode", selection: $mode) {
                    ForEach(availableModes) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                // Switching mode mid-workout would leave a Program-driven session
                // fighting the manual +/- buttons (or vice versa) — commit to a
                // mode at Start, change it only once stopped.
                .disabled(session.state == .running || session.state == .paused)

                controlButtons
            }
            .padding()
        }
        .navigationTitle(connection.deviceName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        // `.navigationBarBackButtonHidden` only hides the *button* – the
        // system's own edge-swipe-to-go-back gesture stays active
        // regardless, and isn't blocked by SwiftUI's `.disabled(_:)` on
        // anything either (see the "Disconnect" toolbar button just below,
        // which only covers a *tap* on that one control). Fixed after a
        // real crash traced back to exactly this: swiping back mid-workout
        // left `TrainerConnection` orphaned – no longer referenced by the
        // UI, but still receiving CoreBluetooth callbacks in the
        // background – see `BluetoothManager.clearConnection()`'s own note
        // on the crash mechanism this produced.
        .background(InteractivePopGestureDisabler(isDisabled: session.state == .running || session.state == .paused))
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    Text(connection.deviceName).font(.headline)
                    Button {
                        isShowingFeatures = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Trainer features")
                }
            }
            ToolbarItem(placement: .cancellationAction) {
                if isReconnectable {
                    Button("Reconnect") {
                        bluetooth.reconnectCurrent()
                    }
                } else {
                    Button("Disconnect") {
                        bluetooth.clearConnection()
                    }
                    // Tapping this mid-workout would end the session (and
                    // drop back to the device list) with no way to undo it
                    // or recover the progress so far – unlike Stop, which at
                    // least offers the save/discard dialog first. Same
                    // "workout in progress" condition already used just
                    // above for the mode Picker.
                    .disabled(session.state == .running || session.state == .paused)
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
            }
        }
        .sheet(isPresented: $isShowingFeatures) {
            TrainerFeaturesView(deviceName: connection.deviceName, features: connection.supportedFeatures, discoveredCharacteristics: connection.discoveredCharacteristics)
        }
        .sheet(isPresented: $isShowingRecentWorkouts) {
            RecentWorkoutsView(recents: compatibleRecents, onSelect: loadRecentEntry, onDelete: deleteRecentEntry)
        }
        .sheet(isPresented: $isShowingCreateWorkout) {
            CreateWorkoutView(onSave: loadProgramIntoSession)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .onChange(of: connection.powerRange) { newRange in
            targetPower = newRange.clamp(targetPower)
        }
        .onChange(of: connection.state) { newState in
            // Whenever control is (re-)granted — first connect or reconnect
            // after a drop — the trainer doesn't know what's currently shown
            // on screen, so push it rather than leaving the trainer at
            // whatever it last had (its own default, or a stale value from a
            // previous session).
            if newState == .ready {
                sendCurrentTarget()
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                session.refreshNow()
            }
        }
        .onAppear {
            targetPower = connection.powerRange.clamp(targetPower)
            targetResistance = resistancePercentRange.clamp(targetResistance)
            targetGrade = gradePercentRange.clamp(targetGrade)
            targetSpeedKmh = connection.speedRangeKmh.clamp(targetSpeedKmh)
            targetInclinePercent = connection.inclinationRangePercent.clamp(targetInclinePercent)
            loadPersistedOrDefaultProgram()
            // Only if capabilities are already known at this point (e.g.
            // this view re-appearing on an already-`.ready` connection) –
            // see `ensureModeIsAvailable()`'s own note on why calling this
            // any earlier than that used to silently destroy a remembered
            // mode. The `.onChange` handlers below cover the far more
            // common case, a fresh connect, where they aren't yet.
            if connection.supportedFeatures != nil {
                ensureModeIsAvailable()
            }
            rememberConnectedDevice()
            configureWatchCompanion()
        }
        .onChange(of: connection.supportedFeatures) { _ in
            ensureModeIsAvailable()
        }
        .onChange(of: connection.machineKind) { _ in
            ensureModeIsAvailable()
            rememberConnectedDevice()
        }
        // Fires the instant `stop()` sets `pendingSummary` – for a
        // Watch-companion workout this resolves it immediately, silently,
        // before the confirmationDialog below ever gets a chance to render
        // (SwiftUI processes this before the next body evaluation), so the
        // rider never sees "Save to Health?" for a workout the Watch itself
        // is already saving, more accurately, on its own. `.onReceive`
        // rather than `.onChange(of:)` since `WorkoutSummary` isn't
        // `Equatable` (a `heartRateSamples` tuple array can't be).
        .onReceive(session.$pendingSummary) { summary in
            guard isWatchCompanionWorkout, summary != nil else { return }
            isWatchCompanionWorkout = false
            session.reset()
        }
        .confirmationDialog(
            "Save workout to Apple Health?",
            isPresented: Binding(
                get: { session.pendingSummary != nil },
                set: { isPresented in
                    // Fires for every dismissal, including "Save as …" tapping
                    // out from under an in-flight async save — only treat it as
                    // an implicit Cancel when nothing is actually saving.
                    if !isPresented, !isSaving {
                        session.cancelStop()
                    }
                }
            ),
            titleVisibility: .visible
        ) {
            if let summary = session.pendingSummary {
                saveDialogButtons(for: summary)
            }
        }
        // Shown instead of starting right away whenever the connected
        // machine is a treadmill – see `startWorkout()`/
        // `configureWatchCompanion()`, the two places that set
        // `isChoosingTreadmillActivity`. Answering it is what actually
        // starts the workout (`chooseTreadmillActivity(_:)`); Cancel here
        // leaves the workout unstarted, and, for a Watch-triggered request,
        // tells the Watch so via `pendingWatchStartCompletion`.
        .confirmationDialog(
            "Walking or running?",
            isPresented: $isChoosingTreadmillActivity,
            titleVisibility: .visible
        ) {
            Button("Indoor Walk") { chooseTreadmillActivity(.walking) }
            Button("Indoor Run") { chooseTreadmillActivity(.running) }
            Button("Cancel", role: .cancel) { cancelTreadmillActivityChoice() }
        }
        .alert(item: $saveResult) { result in
            Alert(title: Text(result.title), message: Text(result.message), dismissButton: .default(Text("OK")))
        }
        .sheet(item: $savedSummary) { summary in
            SavedWorkoutSummaryView(summary: summary)
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: allowedFileContentTypes
        ) { result in
            switch result {
            case .success(let url):
                loadWorkout(fromSecurityScoped: url)
            case .failure(let error):
                loadError = LoadErrorAlert(message: error.localizedDescription)
            }
        }
        .alert(item: $loadError) { error in
            Alert(title: Text("Couldn't Load Workout"), message: Text(error.message), dismissButton: .default(Text("OK")))
        }
        .fileExporter(
            isPresented: $isShowingExporter,
            document: exportDocument,
            contentType: exportContentType,
            defaultFilename: exportDefaultFilename
        ) { result in
            if case .failure(let error) = result {
                loadError = LoadErrorAlert(message: String(localized: "Couldn't export the file: \(error.localizedDescription)"))
            }
        }
    }

    /// Once the link is gone (dropped out of range, or the connection attempt
    /// itself failed) "Disconnect" would be a no-op — offer to reconnect instead.
    private var isReconnectable: Bool {
        switch connection.state {
        case .disconnected, .failed:
            return true
        default:
            return false
        }
    }

    private var statusHeader: some View {
        Group {
            switch connection.state {
            case .connecting:
                Label("Connecting …", systemImage: "dot.radiowaves.left.and.right")
            case .discoveringServices:
                Label("Reading device data …", systemImage: "dot.radiowaves.left.and.right")
            case .ready:
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .controlNotGranted:
                Label("Control not possible", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case .disconnected:
                Label("Disconnected", systemImage: "xmark.circle").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    private var metricsRow: some View {
        HStack(spacing: 24) {
            MetricTile(title: "Watt", value: connection.metrics.instantaneousPowerWatts.map { "\($0)" } ?? "–", stat: session.powerStats)
            // Cadence/RPM is a bike-only concept – FTMS has no such field
            // for a treadmill at all (nothing rotating to count), so
            // showing it there was always going to read "–" forever. Rather
            // than clutter the row with a tile that can never show
            // anything, it's simply not there for a treadmill.
            if connection.machineKind == .bike {
                MetricTile(title: "RPM", value: connection.metrics.instantaneousCadenceRPM.map { String(format: "%.0f", locale: .current, $0) } ?? "–", stat: session.cadenceStats)
            }
            // The kcal tile swaps places with bpm (but km/h/pace doesn't) –
            // requested after the kcal tile landed right next to Watt/RPM,
            // ahead of heart rate, which read oddly since kcal is itself
            // derived from the same live data heart rate sits next to
            // everywhere else in the app (e.g. the post-workout summary).
            if showsKcalTile {
                if let heartRate = bluetooth.currentHeartRateConnection {
                    HeartRateTile(connection: heartRate, stat: session.heartRateStats)
                }
                speedOrCalorieTile
            } else {
                speedOrCalorieTile
                if let heartRate = bluetooth.currentHeartRateConnection {
                    HeartRateTile(connection: heartRate, stat: session.heartRateStats)
                }
            }
        }
    }

    /// Whether `speedOrCalorieTile` is currently showing the kcal tile
    /// (rather than km/h, pace, or its own km/h fallback) – see
    /// `speedOrCalorieTile`'s own doc comment for the conditions.
    private var showsKcalTile: Bool { speedDisplayUnit == .off && connection.machineKind == .bike }

    /// The third tile: km/h, pace (min/km), or – for cycling, with speed
    /// display turned off – a live calorie count instead, per the
    /// `speedDisplayUnit` Settings choice. See `SpeedDisplayUnit`'s own doc
    /// comment for why km/h isn't always the most useful thing to show here.
    @ViewBuilder
    private var speedOrCalorieTile: some View {
        switch speedDisplayUnit {
        case .kmh:
            MetricTile(title: "km/h", value: connection.metrics.instantaneousSpeedKmh.map { String(format: "%.1f", locale: .current, $0) } ?? "–", stat: session.speedStats)
        case .pace:
            MetricTile(title: "min/km", value: paceString(fromSpeedKmh: connection.metrics.instantaneousSpeedKmh), stat: session.speedStats, formatValue: paceString(fromSpeedKmh:))
        case .off:
            if connection.machineKind == .bike {
                MetricTile(title: "kcal", value: session.liveActiveEnergyKcal.map { String(format: "%.0f", locale: .current, $0) } ?? "–", stat: LiveStat())
            } else {
                // Live kcal needs a run/walk split (see `liveActiveEnergyKcal`'s
                // own doc comment) that isn't knowable until the workout ends –
                // fall back to km/h rather than showing a tile that can't work.
                MetricTile(title: "km/h", value: connection.metrics.instantaneousSpeedKmh.map { String(format: "%.1f", locale: .current, $0) } ?? "–", stat: session.speedStats)
            }
        }
    }

    private var workoutControls: some View {
        VStack(spacing: 12) {
            Text(elapsedTimeLabel)
                .font(.system(size: isRegularWidth ? 48 : 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(session.state == .idle ? .secondary : .primary)

            HStack(spacing: 16) {
                switch session.state {
                case .idle, .ended:
                    Button("Start Workout") {
                        // A fresh manual start from the phone screen – not
                        // via the Watch this time, even if the *previous*
                        // workout was (stale state would otherwise wrongly
                        // skip this one's Health save too).
                        isWatchCompanionWorkout = false
                        pendingWatchStartCompletion = nil
                        startWorkout()
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(connection.state != .ready || (mode == .program && session.activeWorkout == nil))
                case .running:
                    Button("Pause") { session.pause() }
                        .buttonStyle(.bordered)
                    Button("Stop") { stopWorkout() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                case .paused:
                    Button("Resume") { session.resume() }
                        .buttonStyle(.borderedProminent)
                    Button("Stop") { stopWorkout() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
            }
        }
    }

    private var elapsedTimeLabel: String {
        let minutes = session.elapsedSeconds / 60
        let seconds = session.elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    @ViewBuilder
    private var controlButtons: some View {
        switch mode {
        case .power, .resistance, .grade:
            manualControls
        case .speedIncline:
            treadmillControls
        case .program:
            programControls
        }
    }

    private var manualControls: some View {
        VStack(spacing: 16) {
            Text(currentTargetLabel)
                .font(.system(size: isRegularWidth ? 72 : 48, weight: .bold, design: .rounded))
                .monospacedDigit()

            if mode == .resistance {
                // Diagnostic: what's actually sent to the trainer, in its own
                // units — lets an uneven-feeling step be told apart from our
                // percent mapping (which should now be smooth) vs. the
                // trainer's own physical response curve.
                Text("Device level \(formattedResistanceLevel) of \(formattedResistanceRange)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 40) {
                stepButton(systemImage: "minus.circle.fill") { step(-1) }
                stepButton(systemImage: "plus.circle.fill") { step(1) }
            }
        }
    }

    /// Two independent targets, Speed and Incline, stacked rather than
    /// `manualControls`' single big number – each only shown if the
    /// connected treadmill actually supports it (`supportsSpeedTarget`/
    /// `supportsInclinationTarget`), same as the tab itself only appearing
    /// when at least one of the two does (see `availableModes`).
    private var treadmillControls: some View {
        VStack(spacing: 24) {
            if supportsSpeedTarget {
                treadmillTargetGroup(
                    title: "Speed",
                    valueText: String(format: "%.1f km/h", locale: .current, targetSpeedKmh),
                    decrement: { stepSpeed(-1) },
                    increment: { stepSpeed(1) }
                )
            }
            if supportsInclinationTarget {
                treadmillTargetGroup(
                    title: "Incline",
                    valueText: String(format: "%.1f %%", locale: .current, targetInclinePercent),
                    decrement: { stepIncline(-1) },
                    increment: { stepIncline(1) }
                )
            }
        }
    }

    private func treadmillTargetGroup(title: LocalizedStringKey, valueText: String, decrement: @escaping () -> Void, increment: @escaping () -> Void) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(valueText)
                .font(.system(size: isRegularWidth ? 48 : 34, weight: .bold, design: .rounded))
                .monospacedDigit()
            HStack(spacing: 32) {
                stepButton(systemImage: "minus.circle.fill", action: decrement)
                stepButton(systemImage: "plus.circle.fill", action: increment)
            }
        }
    }

    @ViewBuilder
    private var programControls: some View {
        switch session.activeWorkout {
        case .program(let program):
            VStack(spacing: 12) {
                Text(program.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(programTargetLabel(for: program))
                    .font(.system(size: isRegularWidth ? 72 : 48, weight: .bold, design: .rounded))
                    .monospacedDigit()

                // Session-local nudge, independent of the rider's stored
                // FTP – see `WorkoutSession.intensityAdjustmentPercent`.
                // Always shown (as "±0 %" when neutral, not hidden), in a
                // fixed-width slot between the buttons, so neither the
                // buttons appearing/vanishing text nor a digit-count change
                // (0 vs. -15 vs. +50) ever shifts the buttons sideways.
                HStack(spacing: 16) {
                    stepButton(systemImage: "minus.circle.fill") { adjustProgramIntensity(-1) }
                    Text(intensityAdjustmentLabel)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(session.intensityAdjustmentPercent == 0 ? Color.secondary : Color.orange)
                        .frame(width: 64)
                    stepButton(systemImage: "plus.circle.fill") { adjustProgramIntensity(1) }
                }

                // No external `.frame(height:)` here – `WorkoutProgramChart`
                // sizes itself, since its height is meant to grow with the
                // y-axis ceiling (see `chartHeight`), not stay a fixed box.
                WorkoutProgramChart(program: program, elapsedSeconds: session.elapsedSeconds, powerHistory: session.powerHistory, maxActualWatts: session.powerStats.maxValue, heartRateHistory: session.heartRateHistory, isHeartRateConnected: bluetooth.currentHeartRateConnection != nil, intensityAdjustmentPercent: session.intensityAdjustmentPercent, workoutState: session.state)
                    .padding(.horizontal)

                Text("\(elapsedTimeLabel) / \(formattedDuration(program.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if session.isProgramFinished {
                    Label("Workout complete", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                workoutSourceButtons
                Button("Export…") { isShowingExporter = true }
                    .buttonStyle(.bordered)
                    .disabled(session.state == .running || session.state == .paused)
            }
        case .route(let route):
            VStack(spacing: 12) {
                Text(route.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(routeTargetLabel(for: route))
                    .font(.system(size: isRegularWidth ? 72 : 48, weight: .bold, design: .rounded))
                    .monospacedDigit()

                GradeProfileChart(route: route, distanceMeters: session.distanceMeters, workoutState: session.state)
                    .frame(height: isRegularWidth ? 260 : 140)
                    .padding(.horizontal)

                Text("\(formattedDistance(session.distanceMeters)) / \(formattedDistance(route.totalDistanceMeters))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if session.isProgramFinished {
                    Label("Route complete", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                workoutSourceButtons
            }
        case .treadmillProgram(let program):
            VStack(spacing: 12) {
                Text(program.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(treadmillProgramTargetLabel(for: program))
                    .font(.system(size: isRegularWidth ? 44 : 30, weight: .bold, design: .rounded))
                    .monospacedDigit()

                // A plain scrolling list rather than a chart, deliberately –
                // see `TreadmillProgramSegmentList`'s own doc comment.
                TreadmillProgramSegmentList(program: program, elapsedSeconds: Int(session.programPositionSeconds), onSelectSegment: session.jump(toElapsedSeconds:))
                    .padding(.horizontal)

                Text("\(elapsedTimeLabel) / \(formattedDuration(program.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if session.isProgramFinished {
                    Label("Workout complete", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }

                workoutSourceButtons
            }
        case nil:
            VStack(spacing: 12) {
                Text(emptyWorkoutStateDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                workoutSourceButtons
                if supportsPowerTarget {
                    Button("Load Sample Ramp Test (100–700 W)") { loadSampleRampTest() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var workoutSourceButtons: some View {
        HStack(spacing: 12) {
            Button("Load from File") { isShowingFileImporter = true }
                .buttonStyle(.bordered)
                .disabled(allowedFileContentTypes.isEmpty)
            Button("Recent") { isShowingRecentWorkouts = true }
                .buttonStyle(.bordered)
                .disabled(compatibleRecents.isEmpty)
            // The shorthand notation only ever produces a power-kind
            // program (no %-of-resistance-range target), so this needs
            // Power Target support the same way ".erg" does.
            Button("Create") { isShowingCreateWorkout = true }
                .buttonStyle(.bordered)
                .disabled(!supportsPowerTarget)
        }
        .disabled(session.state == .running || session.state == .paused)
    }

    /// Which file types "Load from File" offers, matching only the targets
    /// the connected machine actually supports — `.erg` needs Power Target,
    /// `.mrc` needs Resistance Target, `.gpx` needs Indoor Bike Simulation,
    /// `.zwo` needs a treadmill with Speed or Inclination Target support
    /// (see `ZWOWorkoutParser`'s own note on why this is treadmill-only,
    /// not the genuine Zwift cycling %FTP format too).
    private var allowedFileContentTypes: [UTType] {
        var types: [UTType] = []
        if supportsPowerTarget, let erg = WorkoutProgramParser.ergContentType { types.append(erg) }
        if supportsResistanceTarget, let mrc = WorkoutProgramParser.mrcContentType { types.append(mrc) }
        if supportsIndoorBikeSimulation { types.append(contentsOf: GPXParser.supportedContentTypes) }
        if connection.machineKind == .treadmill, supportsSpeedTarget || supportsInclinationTarget,
           let zwo = ZWOWorkoutParser.contentType {
            types.append(zwo)
        }
        return types
    }

    /// The currently loaded Program (not a GPX route – there's no route
    /// serializer, only `WorkoutProgram.fileContents()`), for "Export…".
    private var currentExportableProgram: WorkoutProgram? {
        if case .program(let program) = session.activeWorkout { return program }
        return nil
    }

    private var exportDocument: WorkoutProgramDocument? {
        currentExportableProgram.map { WorkoutProgramDocument(text: $0.fileContents()) }
    }

    private var exportContentType: UTType {
        switch currentExportableProgram?.targetKind {
        case .power, nil: return WorkoutProgramParser.ergContentType ?? .plainText
        case .resistance: return WorkoutProgramParser.mrcContentType ?? .plainText
        }
    }

    private var exportDefaultFilename: String? {
        currentExportableProgram?.suggestedFileName
    }

    private var emptyWorkoutStateDescription: String {
        var extensions: [String] = []
        if supportsPowerTarget { extensions.append(".erg") }
        if supportsResistanceTarget { extensions.append(".mrc") }
        if supportsIndoorBikeSimulation { extensions.append(".gpx") }
        if connection.machineKind == .treadmill, supportsSpeedTarget || supportsInclinationTarget {
            extensions.append(".zwo")
        }
        guard !extensions.isEmpty else {
            return String(localized: "This trainer doesn't report support for any target type Unchain can drive from a file.")
        }
        return String(localized: "Load a \(extensions.joined(separator: ", ")) file to follow a structured workout or route automatically.")
    }

    private func isProgramSupported(_ program: WorkoutProgram) -> Bool {
        switch program.targetKind {
        case .power: return supportsPowerTarget
        case .resistance: return supportsResistanceTarget
        }
    }

    /// Recently used programs, routes, *and* treadmill workouts compatible
    /// with the currently connected machine, excluding whatever's already
    /// loaded, merged and sorted by recency. Filtered two ways: `.erg`/
    /// `.mrc`/GPX-derived routes are all cycling-trainer-only (see
    /// `ProgramTargetKind.compatibleMachineKind` and `GradeProfile
    /// .compatibleMachineKind`), `.zwo`-derived treadmill workouts the
    /// mirror image (treadmill-only) – so only one of the two groups is
    /// ever non-empty for a given connection; and further gated on whether
    /// the specific target that entry needs is actually supported, since a
    /// file used with a *previous* trainer might not work with the one
    /// connected now.
    private var compatibleRecents: [CombinedRecentEntry] {
        let programs: [CombinedRecentEntry] = WorkoutProgramStore.loadRecents().compactMap { recent in
            guard recent.program.targetKind.compatibleMachineKind == connection.machineKind,
                  isProgramSupported(recent.program),
                  !isActiveWorkout(.program(recent.program)) else { return nil }
            return CombinedRecentEntry(id: recent.id, name: recent.program.name, lastUsedDate: recent.lastUsedDate, kind: .program(recent.program))
        }
        let routes: [CombinedRecentEntry] = supportsIndoorBikeSimulation ? RouteStore.loadRecents().compactMap { recent in
            guard recent.route.compatibleMachineKind == connection.machineKind,
                  !isActiveWorkout(.route(recent.route)) else { return nil }
            return CombinedRecentEntry(id: recent.id, name: recent.route.name, lastUsedDate: recent.lastUsedDate, kind: .route(recent.route))
        } : []
        let treadmillPrograms: [CombinedRecentEntry] = (connection.machineKind == .treadmill && (supportsSpeedTarget || supportsInclinationTarget)) ? TreadmillWorkoutProgramStore.loadRecents().compactMap { recent in
            guard !isActiveWorkout(.treadmillProgram(recent.program)) else { return nil }
            return CombinedRecentEntry(id: recent.id, name: recent.program.name, lastUsedDate: recent.lastUsedDate, kind: .treadmillProgram(recent.program))
        } : []
        return (programs + routes + treadmillPrograms).sorted { $0.lastUsedDate > $1.lastUsedDate }
    }

    private func isActiveWorkout(_ candidate: RecentWorkoutKind) -> Bool {
        switch (candidate, session.activeWorkout) {
        case (.program(let p), .program(let active)): return p == active
        case (.route(let r), .route(let active)): return r == active
        case (.treadmillProgram(let p), .treadmillProgram(let active)): return p == active
        default: return false
        }
    }

    private func programTargetLabel(for program: WorkoutProgram) -> String {
        guard let target = program.target(atElapsedSeconds: TimeInterval(session.elapsedSeconds)) else {
            return "–"
        }
        let adjusted = session.adjustedTargetValue(target)
        switch program.targetKind {
        case .power: return "\(adjusted) W"
        case .resistance: return "\(adjusted) %"
        }
    }

    /// +/- one intensity percentage point (see `WorkoutSession
    /// .adjustIntensity(byPercent:)`), then forces one immediate refresh so
    /// a running session's on-screen number and the value actually sent to
    /// the trainer update right away instead of waiting for the next tick –
    /// a no-op while not running.
    private func adjustProgramIntensity(_ delta: Int) {
        session.adjustIntensity(byPercent: delta)
        session.refreshNow()
    }

    /// "±0 %" when neutral (rather than hiding the label entirely) so its
    /// fixed-width slot never appears/disappears – only its content changes.
    private var intensityAdjustmentLabel: String {
        let percent = session.intensityAdjustmentPercent
        if percent == 0 { return "±0 %" }
        return percent > 0 ? "+\(percent) %" : "\(percent) %" // negative already carries its own "-"
    }

    private func routeTargetLabel(for route: GradeProfile) -> String {
        guard let grade = route.grade(atDistanceMeters: session.distanceMeters) else { return "–" }
        return String(format: "%.1f %%", locale: .current, grade)
    }

    /// Both targets in one line ("6.5 km/h · 3.0 %") rather than
    /// `treadmillControls`' two separate stacked numbers – there's no +/-
    /// to align around here, just a read-only display of wherever the file
    /// currently has the treadmill headed.
    private func treadmillProgramTargetLabel(for program: TreadmillWorkoutProgram) -> String {
        guard let target = program.target(atElapsedSeconds: session.programPositionSeconds) else { return "–" }
        return String(format: "%.1f km/h · %.1f %%", locale: .current, target.speedKmh, target.inclinePercent)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func formattedDistance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.2f km", locale: .current, meters / 1000) : String(format: "%.0f m", locale: .current, meters)
    }

    /// Called once when the screen first appears: if a workout is already
    /// loaded (e.g. from an earlier appearance while reconnecting) this is a
    /// no-op; otherwise restores whichever of a program or route was used
    /// most recently *and is still supported by this trainer*, or – if
    /// nothing qualifies – falls back to the bundled ramp test (itself only
    /// if Power Target is supported) so Program mode isn't empty-handed.
    private func loadPersistedOrDefaultProgram() {
        guard session.activeWorkout == nil else { return }
        // `compatibleRecents` already merges and sorts all three sources by
        // recency – and since `.erg`/`.mrc`/`.gpx` recents are bike-only and
        // `.zwo` recents are treadmill-only (mutually exclusive per
        // `connection.machineKind`), there's no ambiguity to hand-resolve
        // between "most recent program" vs. "most recent treadmill workout"
        // the way there used to be between program and route.
        if let mostRecent = compatibleRecents.first {
            loadRecentEntry(mostRecent)
            return
        }
        if supportsPowerTarget {
            loadSampleRampTest()
        }
    }

    private func loadRecentEntry(_ entry: CombinedRecentEntry) {
        switch entry.kind {
        case .program(let program): loadProgramIntoSession(program)
        case .route(let route): loadRouteIntoSession(route)
        case .treadmillProgram(let program): loadTreadmillProgramIntoSession(program)
        }
    }

    private func deleteRecentEntry(_ entry: CombinedRecentEntry) {
        switch entry.kind {
        case .program: WorkoutProgramStore.removeRecent(withID: entry.id)
        case .route: RouteStore.removeRecent(withID: entry.id)
        case .treadmillProgram: TreadmillWorkoutProgramStore.removeRecent(withID: entry.id)
        }
    }

    /// The one place that actually hands a program to the session – every
    /// load path (auto-restore, file import, sample button, recent-workouts
    /// tap) goes through here so usage always gets recorded consistently.
    private func loadProgramIntoSession(_ program: WorkoutProgram) {
        session.loadProgram(program)
        WorkoutProgramStore.recordUsage(of: program)
    }

    /// The `GradeProfile` counterpart to `loadProgramIntoSession(_:)`.
    private func loadRouteIntoSession(_ route: GradeProfile) {
        session.loadRoute(route)
        RouteStore.recordUsage(of: route)
    }

    /// The `TreadmillWorkoutProgram` counterpart to `loadProgramIntoSession(_:)`.
    private func loadTreadmillProgramIntoSession(_ program: TreadmillWorkoutProgram) {
        session.loadTreadmillProgram(program)
        TreadmillWorkoutProgramStore.recordUsage(of: program)
    }

    private func loadSampleRampTest() {
        guard let url = Bundle.main.url(forResource: "RampTest_100-700W", withExtension: "erg") else {
            loadError = LoadErrorAlert(message: String(localized: "The bundled sample ramp test is missing."))
            return
        }
        loadWorkout(contentsOf: url)
    }

    private func loadWorkout(fromSecurityScoped url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            loadError = LoadErrorAlert(message: String(localized: "Couldn't access the selected file."))
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        loadWorkout(contentsOf: url)
    }

    /// Dispatches by extension: `.gpx` is XML parsed into a distance-based
    /// `GradeProfile`, `.zwo` is XML parsed into a time-based
    /// `TreadmillWorkoutProgram`, anything else is treated as the `.erg`/
    /// `.mrc` text format and parsed into a time-based `WorkoutProgram`.
    private func loadWorkout(contentsOf url: URL) {
        switch url.pathExtension.lowercased() {
        case "gpx":
            loadRoute(fromGPXContentsOf: url)
        case "zwo":
            loadTreadmillProgram(fromZWOContentsOf: url)
        default:
            loadProgram(fromTextContentsOf: url)
        }
    }

    private func loadProgram(fromTextContentsOf url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            switch WorkoutProgramParser.parse(text: text, fileExtension: url.pathExtension) {
            case .success(let program):
                // Defensive – the picker is already filtered to supported
                // types, but this also covers the bundled sample and a
                // restored-from-storage program used with a different trainer.
                guard isProgramSupported(program) else {
                    let targetName = program.targetKind == .power ? String(localized: "power") : String(localized: "resistance")
                    loadError = LoadErrorAlert(message: String(localized: "This trainer doesn't support \(targetName) targets."))
                    return
                }
                loadProgramIntoSession(program)
            case .failure(let error):
                loadError = LoadErrorAlert(message: error.localizedDescription)
            }
        } catch {
            loadError = LoadErrorAlert(message: String(localized: "Couldn't read the file: \(error.localizedDescription)"))
        }
    }

    private func loadRoute(fromGPXContentsOf url: URL) {
        guard supportsIndoorBikeSimulation else {
            loadError = LoadErrorAlert(message: String(localized: "This trainer doesn't support Indoor Bike Simulation (Grade), so GPX routes can't be used."))
            return
        }
        do {
            let data = try Data(contentsOf: url)
            switch GPXParser.parse(data: data) {
            case .success(let points):
                let name = url.deletingPathExtension().lastPathComponent
                guard let route = GradeProfileBuilder.build(name: name, points: points) else {
                    loadError = LoadErrorAlert(message: String(localized: "Couldn't derive a grade profile from this track."))
                    return
                }
                loadRouteIntoSession(route)
            case .failure(let error):
                loadError = LoadErrorAlert(message: error.localizedDescription)
            }
        } catch {
            loadError = LoadErrorAlert(message: String(localized: "Couldn't read the file: \(error.localizedDescription)"))
        }
    }

    private func loadTreadmillProgram(fromZWOContentsOf url: URL) {
        guard connection.machineKind == .treadmill, supportsSpeedTarget || supportsInclinationTarget else {
            loadError = LoadErrorAlert(message: String(localized: "This trainer doesn't support Speed or Inclination targets, so .zwo workouts can't be used."))
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let fallbackName = url.deletingPathExtension().lastPathComponent
            switch ZWOWorkoutParser.parse(data: data, fallbackName: fallbackName) {
            case .success(let program):
                loadTreadmillProgramIntoSession(program)
            case .failure(let error):
                loadError = LoadErrorAlert(message: error.localizedDescription)
            }
        } catch {
            loadError = LoadErrorAlert(message: String(localized: "Couldn't read the file: \(error.localizedDescription)"))
        }
    }

    private var formattedResistanceLevel: String {
        String(format: "%.1f", locale: .current, Double(connection.rawResistanceLevel(forPercent: targetResistance)) / 10)
    }

    private var formattedResistanceRange: String {
        let lower = Double(connection.resistanceRangeRaw.lowerBound) / 10
        let upper = Double(connection.resistanceRangeRaw.upperBound) / 10
        return String(format: "%.1f–%.1f", locale: .current, lower, upper)
    }

    /// Only shown from `manualControls`, i.e. never while `mode == .program`
    /// or `.speedIncline` (the latter shows two targets, via
    /// `treadmillControls` instead – see that view's own labels).
    private var currentTargetLabel: String {
        switch mode {
        case .power: return "\(targetPower) W"
        case .resistance: return "\(targetResistance) %"
        case .grade: return String(format: "%.1f %%", locale: .current, targetGrade)
        case .program, .speedIncline: return ""
        }
    }

    private func stepButton(systemImage: String, action: @escaping () -> Void) -> some View {
        RepeatingStepButton(systemImage: systemImage, isDisabled: connection.state != .ready, action: action)
    }

    /// Only called from `manualControls`, i.e. never while `mode == .program`
    /// or `.speedIncline` (see `stepSpeed(_:)`/`stepIncline(_:)` instead).
    private func step(_ direction: Int) {
        switch mode {
        case .power:
            targetPower = connection.powerRange.clamp(targetPower + direction * powerStep)
        case .resistance:
            targetResistance = resistancePercentRange.clamp(targetResistance + direction * resistanceStep)
        case .grade:
            targetGrade = gradePercentRange.clamp(targetGrade + Double(direction) * gradeStep)
        case .program, .speedIncline:
            return
        }
        sendCurrentTarget()
    }

    /// +/- one `speedStepKmh`, clamp to the device's own reported range, and
    /// send right away – the `treadmillControls` counterpart to `step(_:)`
    /// above, kept separate since this mode drives two independent targets
    /// rather than one.
    private func stepSpeed(_ direction: Int) {
        targetSpeedKmh = connection.speedRangeKmh.clamp(targetSpeedKmh + Double(direction) * speedStepKmh)
        connection.setTargetSpeed(kmh: targetSpeedKmh)
    }

    /// +/- one `inclineStepPercent`, clamp to the device's own reported
    /// range, and send right away – see `stepSpeed(_:)`'s own note.
    private func stepIncline(_ direction: Int) {
        targetInclinePercent = connection.inclinationRangePercent.clamp(targetInclinePercent + Double(direction) * inclineStepPercent)
        connection.setTargetInclination(percent: targetInclinePercent)
    }

    /// Sends whichever target is currently active to the trainer — used both
    /// after +/- taps and right after (re)connecting, so the display and the
    /// device are never out of sync. In Program mode this re-sends the
    /// loaded workout's current target (time-based for a program, distance-
    /// based for a route) rather than a manual value; in `.speedIncline`,
    /// both targets go out together, same as every other reconnect case.
    private func sendCurrentTarget() {
        switch mode {
        case .power:
            connection.setTargetPower(watts: targetPower)
        case .resistance:
            connection.setTargetResistancePercent(targetResistance)
        case .grade:
            connection.setSimulationGrade(percent: targetGrade)
        case .speedIncline:
            connection.setTargetSpeed(kmh: targetSpeedKmh)
            connection.setTargetInclination(percent: targetInclinePercent)
        case .program:
            switch session.activeWorkout {
            case .program(let program):
                guard let target = program.target(atElapsedSeconds: TimeInterval(session.elapsedSeconds)) else { return }
                switch program.targetKind {
                case .power: connection.setTargetPower(watts: target)
                case .resistance: connection.setTargetResistancePercent(target)
                }
            case .route(let route):
                guard let grade = route.grade(atDistanceMeters: session.distanceMeters) else { return }
                connection.setSimulationGrade(percent: grade)
            case .treadmillProgram(let program):
                guard let target = program.target(atElapsedSeconds: TimeInterval(session.elapsedSeconds)) else { return }
                connection.setTargetSpeed(kmh: target.speedKmh)
                connection.setTargetInclination(percent: target.inclinePercent)
            case nil:
                return
            }
        }
    }

    /// Buttons offered in the post-workout save dialog. Which activity types
    /// are offered depends on the detected machine kind. For a treadmill,
    /// this used to be where Walk vs. Run was decided – it's now already
    /// known from `treadmillActivityType` (chosen up front, at Start, via
    /// `startWorkout()`/`chooseTreadmillActivity(_:)`), so there's just one
    /// button, same as the bike case always had. The two-button fallback
    /// only covers the (in practice unreachable) case of that choice
    /// somehow never having been made.
    @ViewBuilder
    private func saveDialogButtons(for summary: WorkoutSummary) -> some View {
        switch summary.machineKind {
        case .bike:
            Button("Save as Indoor Cycling") { save(summary, as: .cycling) }
        case .treadmill:
            if let treadmillActivityType {
                Button(treadmillActivityType == .running ? "Save as Indoor Run" : "Save as Indoor Walk") {
                    save(summary, as: treadmillActivityType)
                }
            } else {
                Button("Save as Indoor Walk") { save(summary, as: .walking) }
                Button("Save as Indoor Run") { save(summary, as: .running) }
            }
        case .unknown:
            Button("Save Workout") { save(summary, as: .other) }
        }
        Button("Discard", role: .destructive) { session.reset() }
        Button("Cancel", role: .cancel) { session.cancelStop() }
    }

    private func save(_ summary: WorkoutSummary, as activityType: HKWorkoutActivityType) {
        isSaving = true
        HealthKitManager.shared.save(summary, as: activityType) { result in
            isSaving = false
            switch result {
            case .success:
                savedSummary = summary
            case .failure(let error):
                saveResult = SaveResultAlert(title: String(localized: "Not Saved"), message: error.localizedDescription)
            }
            session.reset()
        }
    }

    /// The Stop button's action, from either `.running` or `.paused` – wraps
    /// `session.stop()` with the one extra step a Watch-companion workout
    /// needs: telling the Watch to end its own `HKWorkoutSession` too, since
    /// the phone side is what's ending things this time (if the Watch's own
    /// Stop button had been tapped instead, `WatchConnectivityManager`'s
    /// `onStopRequested` closure below already calls `session.stop()`
    /// directly, with no need to message the Watch back about its own
    /// action).
    private func stopWorkout() {
        WatchConnectivityManager.shared.notifyPhoneStoppedWorkout()
        session.stop()
    }

    /// The phone screen's own Start button – begins right away for a bike
    /// (and for `.unknown`, same as always: `saveDialogButtons` already
    /// falls back to a generic "Save Workout" there, with no activity
    /// choice to make either way), but for a treadmill shows the "Walking
    /// or running?" dialog first (`chooseTreadmillActivity(_:)` is what
    /// actually starts things once answered).
    private func startWorkout() {
        switch connection.machineKind {
        case .bike, .unknown:
            treadmillActivityType = nil
            startSession()
        case .treadmill:
            isChoosingTreadmillActivity = true
        }
    }

    /// Starts the session and immediately pushes whatever target is
    /// currently showing to the trainer – `session.start(usingProgram:)`
    /// itself only does this for Program mode
    /// (`sendCurrentWorkoutTarget(for:)`); every manual mode (Power/
    /// Resistance/Grade/Speed & Incline) used to rely entirely on whatever
    /// had already been sent earlier (on connect, or the last +/- tap)
    /// still being in effect. Turned out not to be a safe assumption –
    /// reported after a treadmill visibly ignored the app's shown target
    /// and started moving at whatever speed/incline *it* had stored
    /// instead, once Start was actually pressed: apparently a target set
    /// before the Start/Resume op code can be reset or ignored by the
    /// trainer, with only one sent *after* reliably sticking. Centralized
    /// here since it's needed at all three of this view's
    /// `session.start(usingProgram:)` call sites – the plain phone Start
    /// button above, the "Walking or running?" dialog's answer, and a
    /// Watch-triggered bike start, both further down.
    private func startSession() {
        session.start(usingProgram: mode == .program)
        sendCurrentTarget()
    }

    /// Answers the "Walking or running?" dialog: records the choice for
    /// `saveDialogButtons` to use later, starts the workout, and – if this
    /// dialog was actually triggered by a Watch start request rather than
    /// the phone's own Start button – replies to the Watch so *its* own
    /// `HKWorkoutSession` starts with the same activity type.
    private func chooseTreadmillActivity(_ activityType: HKWorkoutActivityType) {
        treadmillActivityType = activityType
        // Only actually a Watch-companion workout if this dialog was
        // triggered by a Watch start request in the first place – a plain
        // treadmill start from this screen's own Start button also shows
        // it, with `pendingWatchStartCompletion` left `nil`.
        if pendingWatchStartCompletion != nil {
            isWatchCompanionWorkout = true
        }
        startSession()
        pendingWatchStartCompletion?(true, activityType)
        pendingWatchStartCompletion = nil
    }

    /// Cancelling the dialog leaves the workout unstarted – for a
    /// Watch-triggered request, the Watch needs to hear that explicitly
    /// (rather than being left waiting on a reply that never comes), so it
    /// can show its usual "couldn't start" state instead of hanging on
    /// "Starting…" forever.
    private func cancelTreadmillActivityChoice() {
        pendingWatchStartCompletion?(false, nil)
        pendingWatchStartCompletion = nil
    }

    /// Wires `WatchConnectivityManager`'s two callbacks to this view's own
    /// start/stop actions – see that type's doc comment for the full
    /// picture. `onStartRequested` now takes a completion instead of
    /// returning synchronously: a bike answers it immediately, but a
    /// treadmill has to show the same "Walking or running?" dialog
    /// `startWorkout()` does first (`isChoosingTreadmillActivity`), and the
    /// Watch's reply waits – via `pendingWatchStartCompletion` – until the
    /// rider actually answers it on the phone. `.unknown` fails immediately;
    /// there'd be no honest activity type to hand the Watch either way.
    private func configureWatchCompanion() {
        WatchConnectivityManager.shared.onStartRequested = { completion in
            guard connection.state == .ready, session.state == .idle else {
                completion(false, nil)
                return
            }
            switch connection.machineKind {
            case .bike:
                isWatchCompanionWorkout = true
                treadmillActivityType = nil
                startSession()
                completion(true, .cycling)
            case .treadmill:
                // `isWatchCompanionWorkout` is set from
                // `chooseTreadmillActivity(_:)` instead, once the rider
                // actually answers – not here, where the request could
                // still be cancelled.
                pendingWatchStartCompletion = completion
                isChoosingTreadmillActivity = true
            case .unknown:
                completion(false, nil)
            }
        }
        WatchConnectivityManager.shared.onStopRequested = {
            session.stop()
        }
    }
}

private struct SaveResultAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

private struct LoadErrorAlert: Identifiable {
    let id = UUID()
    let message: String
}

/// Plain-text `.erg`/`.mrc` file wrapper for `.fileExporter` – the save-side
/// counterpart of `WorkoutProgramParser.parse`, backed by
/// `WorkoutProgram.fileContents()`. Export-only: `init(configuration:)` is
/// never actually exercised since this type is never passed as a
/// `.fileImporter`'s content type, only ever constructed in-app and handed
/// to `.fileExporter`.
private struct WorkoutProgramDocument: FileDocument {
    static var readableContentTypes: [UTType] { [] }
    static var writableContentTypes: [UTType] {
        [WorkoutProgramParser.ergContentType, WorkoutProgramParser.mrcContentType].compactMap { $0 }
    }

    let text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

/// Overlay listing recently used, machine-compatible programs (see
/// `ControlView.compatibleRecents`). Each row shows whether the file targets
/// power or resistance, since that's not otherwise obvious from the name.
/// What one row in the merged "recent workouts" list represents.
private enum RecentWorkoutKind {
    case program(WorkoutProgram)
    case route(GradeProfile)
    case treadmillProgram(TreadmillWorkoutProgram)
}

/// One row's worth of data for `RecentWorkoutsView` – built by merging
/// `WorkoutProgramStore` and `RouteStore` (see `ControlView.compatibleRecents`),
/// since the two are persisted separately but shown together.
private struct CombinedRecentEntry: Identifiable {
    let id: UUID
    let name: String
    let lastUsedDate: Date
    let kind: RecentWorkoutKind
}

/// Overlay listing recently used, machine-compatible programs and routes
/// (see `ControlView.compatibleRecents`). Each row is tagged with what kind
/// of target it drives, since that's not otherwise obvious from the name.
private struct RecentWorkoutsView: View {
    let onSelect: (CombinedRecentEntry) -> Void
    /// Actually persists the removal (`WorkoutProgramStore`/`RouteStore`) –
    /// `recents` below is a local, mutable copy so a swipe-to-delete
    /// animates and updates this list immediately, without waiting on
    /// `ControlView`'s own `compatibleRecents` (a plain computed property,
    /// not something this sheet observes live) to catch up.
    let onDelete: (CombinedRecentEntry) -> Void
    @State private var recents: [CombinedRecentEntry]
    @Environment(\.dismiss) private var dismiss

    init(recents: [CombinedRecentEntry], onSelect: @escaping (CombinedRecentEntry) -> Void, onDelete: @escaping (CombinedRecentEntry) -> Void) {
        self._recents = State(initialValue: recents)
        self.onSelect = onSelect
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Group {
                if recents.isEmpty {
                    Text("No recent workouts")
                        .foregroundStyle(.secondary)
                } else {
                    List(recents) { recent in
                        Button {
                            onSelect(recent)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(recent.name)
                                        .font(.headline)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text(recent.lastUsedDate, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                badge(for: recent.kind)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                withAnimation {
                                    recents.removeAll { $0.id == recent.id }
                                }
                                onDelete(recent)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Recent Workouts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func badge(for kind: RecentWorkoutKind) -> some View {
        switch kind {
        case .program(let program):
            switch program.targetKind {
            case .power:
                Label("Power", systemImage: "bolt.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .resistance:
                Label("Resistance", systemImage: "dial.medium.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
            }
        case .route:
            Label("Grade", systemImage: "mountain.2.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .treadmillProgram:
            Label("Speed & Incline", systemImage: "figure.run")
                .font(.caption)
                .foregroundStyle(.purple)
        }
    }
}

/// Profile of the loaded program (time on the x-axis, in minutes; target on
/// the y-axis) with a vertical rule marking how far into it the workout
/// currently is.
private struct WorkoutProgramChart: View {
    let program: WorkoutProgram
    let elapsedSeconds: Int
    /// Actual power output, one point per second – only plotted (and only
    /// meaningful) alongside a power-kind program, whose y-axis is already
    /// in watts; a resistance-kind program's axis is a 0–100 % of the
    /// trainer's own range, a different unit entirely.
    let powerHistory: [PowerSample]
    /// Highest actual power seen so far this workout (`session.powerStats
    /// .maxValue`) – kept as a running max rather than rescanning
    /// `powerHistory`, and used to grow the y-axis ceiling by a clean step
    /// if a live reading exceeds it (see `yCeiling`), instead of either
    /// stretching to fit the exact value or clipping it off invisibly.
    let maxActualWatts: Double?
    /// Plotted as a second trace against its own (right-hand) axis –
    /// see `showsHeartRate`/`heartRateDomain` – whenever a heart rate strap
    /// has produced at least one reading so far this workout, regardless of
    /// program kind (power or resistance).
    let heartRateHistory: [HeartRateSample]
    /// Whether a strap is currently paired (`bluetooth.currentHeartRateConnection
    /// != nil`) – used alongside `heartRateHistory` in `showsHeartRate` so the
    /// right-hand axis appears the moment a strap is connected, before a
    /// workout (and with it, any actual samples) has even started, rather
    /// than only once `heartRateHistory` has its first entry.
    let isHeartRateConnected: Bool
    /// See `WorkoutSession.intensityAdjustmentPercent` – the Target curve
    /// plotted here is the *adjusted* one (via `WorkoutSession
    /// .adjustedValue(_:byPercent:)`, the same formula that decides what's
    /// actually sent to the trainer), not the raw file/shorthand values, so
    /// the chart never shows a different plan than what's really happening.
    let intensityAdjustmentPercent: Int
    /// Clears the tap-to-inspect selection the moment a workout (re)starts
    /// – see the `.onChange` below.
    let workoutState: WorkoutState
    @AppStorage(SettingsView.ftpWattsKey) private var ftpWatts: Int = 188
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Window widths (minutes) to cycle through on double-tap, narrowest
    /// last; `nil` means the full workout. Same double-tap-to-zoom gesture
    /// TrainerDay has on its workout chart.
    private static let zoomWindowsMinutes: [Double?] = [nil, 10, 3]
    @State private var zoomLevelIndex = 0
    /// Which file entry (see `WorkoutProgram.breakpointIndex(atElapsedSeconds:)`)
    /// a single tap last selected, for the TrainerDay-style "tap an interval
    /// to see its duration and target" inspector below. `nil` when nothing's
    /// selected; tapping the same interval again toggles it back off.
    @State private var selectedBreakpointIndex: Int?
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }
    private var showsActualPower: Bool { program.targetKind == .power }

    // Swift Charts' automatic legend displays whatever `String` is passed to
    // `.value("Series", …)`/`.chartForegroundStyleScale` verbatim – unlike
    // `Text`, that's a plain `String` parameter, not a `LocalizedStringKey`,
    // so a literal there does *not* auto-localize (see README's L10N
    // section). Resolved once per render into `let`s instead, and reused at
    // every site below, so the legend's keys and the marks' series names are
    // guaranteed to still match after translation.
    private var targetSeriesLabel: String { String(localized: "Target") }
    private var actualSeriesLabel: String { String(localized: "Actual") }
    private var ftpSeriesLabel: String { String(localized: "FTP") }
    private var heartRateSeriesLabel: String { String(localized: "Heart Rate") }

    /// Only once a strap has actually produced a reading this workout – not
    /// just "one's currently connected", so a brief BLE dropout doesn't yank
    /// the trace (and the right-hand axis, and the chart's shape) away
    /// mid-workout.
    private var showsHeartRate: Bool { isHeartRateConnected || !heartRateHistory.isEmpty }

    var body: some View {
        let targetSeriesLabel = targetSeriesLabel
        let actualSeriesLabel = actualSeriesLabel
        let ftpSeriesLabel = ftpSeriesLabel
        let heartRateSeriesLabel = heartRateSeriesLabel
        VStack(spacing: 2) {
            Chart {
                if let index = selectedBreakpointIndex, index + 1 < program.breakpoints.count {
                    RectangleMark(
                        xStart: .value("Start", program.breakpoints[index].timeSeconds / 60),
                        xEnd: .value("End", program.breakpoints[index + 1].timeSeconds / 60)
                    )
                    .foregroundStyle(.gray.opacity(0.25))
                }
                ForEach(Array(program.breakpoints.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Minutes", point.timeSeconds / 60),
                        y: .value(unitLabel, WorkoutSession.adjustedValue(point.value, byPercent: intensityAdjustmentPercent))
                    )
                    .interpolationMethod(.linear)
                    .foregroundStyle(by: .value("Series", targetSeriesLabel))
                }
                if showsActualPower {
                    ForEach(powerHistory, id: \.timeSeconds) { sample in
                        LineMark(
                            x: .value("Minutes", sample.timeSeconds / 60),
                            y: .value(unitLabel, sample.watts)
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(by: .value("Series", actualSeriesLabel))
                    }
                }
                if showsHeartRate {
                    ForEach(heartRateHistory, id: \.timeSeconds) { sample in
                        LineMark(
                            x: .value("Minutes", sample.timeSeconds / 60),
                            y: .value(heartRateSeriesLabel, rescaledHeartRateValue(Double(sample.bpm)))
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(by: .value("Series", heartRateSeriesLabel))
                    }
                }
                RuleMark(x: .value("Elapsed", Double(elapsedSeconds) / 60))
                    .foregroundStyle(.red)
                if showsActualPower, ftpWatts > 0 {
                    RuleMark(y: .value(ftpSeriesLabel, ftpWatts))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(by: .value("Series", ftpSeriesLabel))
                        .annotation(position: .top, alignment: .leading) {
                            Text(ftpSeriesLabel)
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                }
            }
            .chartForegroundStyleScale([targetSeriesLabel: Color.blue, actualSeriesLabel: Color.green, ftpSeriesLabel: Color.orange, heartRateSeriesLabel: Color.red])
            .chartXScale(domain: xDomainMinutes)
            .chartYScale(domain: yDomain)
            .chartXAxisLabel("Minutes")
            // `position: .leading` here is deliberate, not the default –
            // `.automatic` (the parameterless overload this used before)
            // stopped reliably resolving to the left once a right-hand axis
            // existed too, and would occasionally flip this label over to
            // the trailing side, overlapping the heart rate axis' own tick
            // labels there. Pinning it explicitly keeps it with the axis
            // it's actually labeling, regardless of what else the chart
            // draws.
            .chartYAxisLabel(unitLabel, position: .leading)
            // The Watt/Percent axis stays on the left (`.leading`) with
            // Swift Charts' own automatic tick placement, exactly as before
            // – only its *position* is now explicit, needed to make room
            // for the heart rate axis on the right. `values: .automatic`
            // here is deliberate: an explicit `.stride(by:)` step overlapped
            // once this chart was short enough to need more ticks than it
            // had room for (see `yAxisStep`'s own note on the same bug).
            // The heart rate axis' tick *positions* are the rescaled y-values
            // of a handful of round bpm numbers (`heartRateAxisTickBpmValues`)
            // – Swift Charts has no native second y-domain, so each tick's
            // label is drawn as the original bpm figure while its on-screen
            // position comes from mapping that bpm through the same linear
            // rescale the plotted line itself uses (`rescaledHeartRateValue`).
            .chartYAxis {
                AxisMarks(position: .leading)
                if showsHeartRate {
                    AxisMarks(position: .trailing, values: heartRateAxisTickBpmValues.map { rescaledHeartRateValue($0) }) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let rescaled = value.as(Double.self) {
                                Text("\(Int(unrescaledHeartRateValue(rescaled)))")
                            }
                        }
                    }
                }
            }
            // `.chartXScale(domain:)` alone only remaps the scale – it doesn't
            // clip drawing to the plot area, so a line segment leading to a
            // point outside the zoomed window still gets drawn past the
            // right (or left) edge. Clip just the plot content, not the axes.
            .chartPlotStyle { plotArea in
                plotArea.clipped()
            }
            // Double-tap (zoom) and single-tap (select an interval, below)
            // both live here, as one `.exclusively(before:)` chain, rather
            // than a separate plain `.onTapGesture(count: 2)` – that let a
            // double-tap's *first* tap already fire the single-tap handler
            // before SwiftUI could tell the two apart. Listing the
            // double-tap gesture first is what makes SwiftUI hold off on
            // the single-tap one until it's actually sure it isn't part of
            // a double-tap.
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture(count: 2)
                                .onEnded { _ in
                                    zoomLevelIndex = (zoomLevelIndex + 1) % Self.zoomWindowsMinutes.count
                                }
                                .exclusively(before: SpatialTapGesture(count: 1)
                                    .onEnded { tap in
                                        selectInterval(atTapLocation: tap.location, proxy: proxy, geometry: geometry)
                                    }
                                )
                        )
                }
            }
            .frame(height: chartHeight)
            .animation(.easeOut(duration: 0.35), value: yCeiling)
            .onChange(of: workoutState) { newState in
                if newState == .running { selectedBreakpointIndex = nil }
            }
            // Auto-clears 5 s after a selection – `.task(id:)` cancels and
            // restarts this on every change to `selectedBreakpointIndex`,
            // so re-tapping (a new selection, or toggling one off) always
            // resets the clock rather than an earlier selection's timer
            // wiping out a newer one.
            .task(id: selectedBreakpointIndex) {
                guard selectedBreakpointIndex != nil else { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                selectedBreakpointIndex = nil
            }

            if let selectedIntervalLabel {
                Text(selectedIntervalLabel)
                    .font(isRegularWidth ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Text(zoomLabel)
                .font(isRegularWidth ? .footnote : .caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// Maps a raw tap location (from `SpatialTapGesture`, in the chart
    /// view's own coordinate space) to a time via `ChartProxy`, then to
    /// which file entry contains that time – same "which entry is this"
    /// question `WorkoutSession` already answers for the vibration/interval
    /// sound feature, just triggered by a tap instead of live playback.
    /// Tapping the already-selected interval again deselects it; tapping
    /// outside any interval (e.g. past the end) also clears the selection.
    private func selectInterval(atTapLocation location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        let plotAreaFrame = geometry[proxy.plotAreaFrame]
        let xPosition = location.x - plotAreaFrame.origin.x
        guard let minutes: Double = proxy.value(atX: xPosition),
              let index = program.breakpointIndex(atElapsedSeconds: minutes * 60) else {
            selectedBreakpointIndex = nil
            return
        }
        selectedBreakpointIndex = (selectedBreakpointIndex == index) ? nil : index
    }

    /// "3:00 · 150 W" for a flat interval, "3:00 · 100–180 W" for a ramp –
    /// values already reflect the live intensity adjustment, matching what
    /// the Target curve itself shows (see `intensityAdjustmentPercent`).
    private var selectedIntervalLabel: String? {
        guard let index = selectedBreakpointIndex, index + 1 < program.breakpoints.count else { return nil }
        let start = program.breakpoints[index]
        let end = program.breakpoints[index + 1]
        let durationSeconds = end.timeSeconds - start.timeSeconds
        guard durationSeconds > 0 else { return nil }
        let startValue = WorkoutSession.adjustedValue(start.value, byPercent: intensityAdjustmentPercent)
        let endValue = WorkoutSession.adjustedValue(end.value, byPercent: intensityAdjustmentPercent)
        let unit = program.targetKind == .power ? "W" : "%"
        let valueText = startValue == endValue ? "\(startValue) \(unit)" : "\(startValue)–\(endValue) \(unit)"
        return "\(formattedIntervalDuration(durationSeconds)) · \(valueText)"
    }

    private func formattedIntervalDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private var unitLabel: String {
        // Passed to `.chartYAxisLabel(_:)` as a `String`, not a literal, so
        // it needs the explicit wrap – unlike a literal argument there
        // (see the other `.chartXAxisLabel("Minutes")`-style calls), a
        // `String` variable doesn't auto-localize.
        program.targetKind == .power ? String(localized: "Watts") : String(localized: "Percent")
    }

    /// Centered on the current playback position while zoomed in, so the
    /// window scrolls along as the workout progresses instead of staying
    /// fixed on wherever it was when double-tapped.
    private var xDomainMinutes: ClosedRange<Double> {
        let totalMinutes = program.duration / 60
        guard let window = Self.zoomWindowsMinutes[zoomLevelIndex] else {
            return 0...Swift.max(totalMinutes, 0.001)
        }
        let center = Double(elapsedSeconds) / 60
        let lower = Swift.max(0, center - window / 2)
        let upper = Swift.min(totalMinutes, center + window / 2)
        return lower...Swift.max(upper, lower + 0.001)
    }

    private var zoomLabel: String {
        guard let window = Self.zoomWindowsMinutes[zoomLevelIndex] else {
            return String(localized: "Full workout · double-tap to zoom")
        }
        return String(localized: "\(Int(window)) min window · double-tap to zoom")
    }

    /// Ceiling step – 50 W for a power-kind program (the FTP-driven case),
    /// 25 % for a resistance-kind one (0–100 % is already a narrow, natural
    /// range). Axis *tick labels* are left to Swift Charts' own automatic
    /// placement (an explicit `AxisMarks(values: .stride(by:))` at this same
    /// step overlapped once the chart was short enough to need more ticks
    /// than it had room for) – this step now only drives `yCeiling` and, via
    /// that, `chartHeight`.
    private var yAxisStep: Double {
        showsActualPower ? 50 : 25
    }

    /// Smallest multiple of `yAxisStep` at or above the largest of: the
    /// *adjusted* target's own max (`intensityAdjustmentPercent` applied –
    /// dialing the whole plan up should grow the chart too, same reasoning
    /// as the next point), FTP (so its line is never clipped or stuck flush
    /// against the top edge), and the highest *actual* reading seen so far
    /// this workout. That last one is what makes the axis grow –
    /// deliberately in clean, fixed steps, not to the exact spike value –
    /// if live power exceeds the current ceiling, rather than either
    /// ignoring it (clipped off-chart) or the original bug (any outlier
    /// stretching the domain arbitrarily, e.g. 200 W → 600 W from one
    /// moment above target).
    private var yCeiling: Double {
        var maxValue = program.breakpoints
            .map { Double(WorkoutSession.adjustedValue($0.value, byPercent: intensityAdjustmentPercent)) }
            .max() ?? 0
        if showsActualPower {
            if ftpWatts > 0 { maxValue = Swift.max(maxValue, Double(ftpWatts)) }
            if let maxActualWatts { maxValue = Swift.max(maxValue, maxActualWatts) }
        }
        guard maxValue > 0 else { return yAxisStep }
        return (maxValue / yAxisStep).rounded(.up) * yAxisStep
    }

    /// Zero-based – a power/percent chart is more honest read against a true
    /// zero than a tight-fit floor (which can visually exaggerate small
    /// differences), and it keeps the 50 W/25 % ceiling landing on the same
    /// clean grid every time regardless of what's actually loaded.
    private var yDomain: ClosedRange<Double> {
        0...yCeiling
    }

    /// Fixed rather than fitted to this workout's actual readings (unlike
    /// `yCeiling`) – a stable range keeps the right-hand axis' ticks and the
    /// heart rate trace's shape from shifting every time a new min/max
    /// reading comes in, which a fitted range would otherwise do constantly
    /// over a live-updating chart. Covers essentially every rider's realistic
    /// range, resting to max effort.
    private var heartRateDomain: ClosedRange<Double> { 40...220 }

    /// Round bpm figures to label on the right-hand axis – every 20 bpm
    /// across `heartRateDomain`, the same "clean, evenly spaced" idea as the
    /// Watt/Percent axis' own automatic ticks, just chosen by hand since
    /// this axis' positions are synthetic (see `.chartYAxis` above).
    private var heartRateAxisTickBpmValues: [Double] {
        Swift.stride(from: heartRateDomain.lowerBound, through: heartRateDomain.upperBound, by: 20).map { $0 }
    }

    /// Maps a bpm value from `heartRateDomain` onto this chart's actual
    /// Watt/Percent y-domain (`yDomain`), so it can be plotted as a
    /// `LineMark` value on the same axis Swift Charts actually draws –
    /// see `.chartYAxis` above for how the right-hand axis then displays
    /// the original bpm figures instead of these rescaled ones.
    private func rescaledHeartRateValue(_ bpm: Double) -> Double {
        let hrSpan = heartRateDomain.upperBound - heartRateDomain.lowerBound
        guard hrSpan > 0 else { return yDomain.lowerBound }
        let fraction = (bpm - heartRateDomain.lowerBound) / hrSpan
        return yDomain.lowerBound + fraction * (yDomain.upperBound - yDomain.lowerBound)
    }

    /// The inverse of `rescaledHeartRateValue(_:)` – recovers the original
    /// bpm figure from a rescaled y-domain position, for the right-hand
    /// axis' tick labels.
    private func unrescaledHeartRateValue(_ rescaled: Double) -> Double {
        let ySpan = yDomain.upperBound - yDomain.lowerBound
        guard ySpan > 0 else { return heartRateDomain.lowerBound }
        let fraction = (rescaled - yDomain.lowerBound) / ySpan
        return heartRateDomain.lowerBound + fraction * (heartRateDomain.upperBound - heartRateDomain.lowerBound)
    }

    /// Chart height scales with `yCeiling` at a fixed points-per-watt ratio,
    /// rather than staying a fixed box that just gets rescaled – deliberate:
    /// genuinely exceeding the plan should show up as a taller chart, not
    /// the same-size chart with the target line now looking smaller. The
    /// ratio is chosen so a plan-only ceiling (no overshoot yet) lands
    /// close to the height this chart always had. Resistance-kind programs
    /// don't have this – `yCeiling` never grows past the plan there (no
    /// FTP/actual-power concept to exceed), so they keep the original fixed
    /// height.
    private var chartHeight: CGFloat {
        guard showsActualPower else { return isRegularWidth ? 260 : 140 }
        let pointsPerWatt: CGFloat = isRegularWidth ? 1.3 : 0.7
        return CGFloat(yCeiling) * pointsPerWatt
    }
}

/// A plain scrolling list of a `.zwo` workout's segments, auto-scrolling to
/// keep the current one in view – the `TreadmillWorkoutProgram` counterpart
/// to `WorkoutProgramChart`/`GradeProfileChart`, deliberately simpler (no
/// chart) for this first version: a genuine dual-axis speed/incline chart,
/// using the same rescale technique `WorkoutProgramChart`'s heart rate
/// overlay already established, is a reasonable next step – just not
/// something this needed to ship with.
private struct TreadmillProgramSegmentList: View {
    let program: TreadmillWorkoutProgram
    let elapsedSeconds: Int
    /// Tapping a row jumps playback straight to that segment (see
    /// `WorkoutSession.jump(toElapsedSeconds:)`) – a no-op there while not
    /// actually running/paused, so this stays harmless to call regardless
    /// of state rather than needing its own separate "is this tappable
    /// right now" gate here too.
    let onSelectSegment: (TimeInterval) -> Void

    private var currentIndex: Int? {
        program.segmentIndex(atElapsedSeconds: TimeInterval(elapsedSeconds))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(program.segments.enumerated()), id: \.offset) { index, segment in
                        Button {
                            onSelectSegment(segment.startSeconds)
                        } label: {
                            segmentRow(segment, isCurrent: index == currentIndex)
                        }
                        .buttonStyle(.plain)
                        .id(index)
                        if index < program.segments.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .frame(height: 180)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            // Keeps the current segment scrolled into view as the workout
            // progresses, without fighting a rider who's manually scrolled
            // to look ahead – only re-centers when `currentIndex` itself
            // actually changes (a new segment reached), not on every tick.
            .onChange(of: currentIndex) { newIndex in
                guard let newIndex else { return }
                withAnimation { proxy.scrollTo(newIndex, anchor: .center) }
            }
        }
    }

    private func segmentRow(_ segment: TreadmillWorkoutSegment, isCurrent: Bool) -> some View {
        HStack {
            // Counts down in 1-second steps while this is the *current*
            // segment (driven by `elapsedSeconds` ticking, same as every
            // other live number on this screen) – any other row still
            // shows its plain total duration, since a countdown only means
            // something for the interval actually playing right now.
            Text(formattedSegmentDuration(segment, isCurrent: isCurrent))
                .frame(width: 44, alignment: .leading)
                .monospacedDigit()
            Text(String(format: "%.1f km/h", locale: .current, segment.speedKmh))
                .fontWeight(isCurrent ? .semibold : .regular)
            Spacer()
            Text(String(format: "%.1f %%", locale: .current, segment.inclinePercent))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        // The current row's tint doubles as a left-to-right progress bar
        // for that segment – a light full-row wash (as before) plus a
        // more saturated overlay whose width grows with
        // `progressFraction(for:)`, instead of the old flat single-color
        // highlight.
        .background(alignment: .leading) {
            if isCurrent {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Color.accentColor.opacity(0.15)
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.35))
                            .frame(width: proxy.size.width * progressFraction(for: segment))
                    }
                }
            }
        }
    }

    private func formattedSegmentDuration(_ segment: TreadmillWorkoutSegment, isCurrent: Bool) -> String {
        let remaining: Int
        if isCurrent {
            let elapsedInSegment = elapsedSeconds - Int(segment.startSeconds)
            remaining = max(0, Int(segment.duration) - elapsedInSegment)
        } else {
            remaining = Int(segment.duration)
        }
        return String(format: "%d:%02d", remaining / 60, remaining % 60)
    }

    /// 0...1 fraction of `segment` elapsed so far – always 0 before it
    /// starts and 1 once it's finished, so it's safe to call for any
    /// segment, not just the current one (only the current row's
    /// background actually reads it today).
    private func progressFraction(for segment: TreadmillWorkoutSegment) -> CGFloat {
        guard segment.duration > 0 else { return 0 }
        let elapsedInSegment = Double(elapsedSeconds) - segment.startSeconds
        return CGFloat(min(max(elapsedInSegment / segment.duration, 0), 1))
    }
}

/// Profile of the loaded GPX route (distance in km on the x-axis, grade % on
/// the y-axis) with a vertical rule marking how far the ride has covered so
/// far – the `GradeProfile` counterpart to `WorkoutProgramChart`.
private struct GradeProfileChart: View {
    let route: GradeProfile
    let distanceMeters: Double
    /// Clears the tap-to-inspect selection the moment a workout (re)starts
    /// – see the `.onChange` below.
    let workoutState: WorkoutState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Window widths (km) to cycle through on double-tap, narrowest last;
    /// `nil` means the full route. Same double-tap-to-zoom gesture
    /// TrainerDay has on its workout chart.
    private static let zoomWindowsKm: [Double?] = [nil, 8, 2]
    @State private var zoomLevelIndex = 0
    /// Which smoothed window (see `GradeProfile.breakpointIndex(atDistanceMeters:)`)
    /// a single tap last selected – the GPX-route counterpart to
    /// `WorkoutProgramChart`'s tap-to-inspect. `nil` when nothing's
    /// selected; tapping the same window again toggles it back off.
    @State private var selectedBreakpointIndex: Int?
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        VStack(spacing: 2) {
            Chart {
                if let index = selectedBreakpointIndex, index + 1 < route.breakpoints.count {
                    RectangleMark(
                        xStart: .value("Start", route.breakpoints[index].distanceMeters / 1000),
                        xEnd: .value("End", route.breakpoints[index + 1].distanceMeters / 1000)
                    )
                    .foregroundStyle(.gray.opacity(0.25))
                }
                ForEach(Array(route.breakpoints.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Distance", point.distanceMeters / 1000),
                        y: .value("Grade", point.gradePercent)
                    )
                    .interpolationMethod(.linear)
                }
                RuleMark(x: .value("Progress", distanceMeters / 1000))
                    .foregroundStyle(.red)
            }
            .chartXScale(domain: xDomainKm)
            .chartXAxisLabel("km")
            .chartYAxisLabel("Grade %")
            // See the equivalent comment in `WorkoutProgramChart` – without
            // this, a line segment leading to a point outside the zoomed
            // window gets drawn past the plot's right (or left) edge.
            .chartPlotStyle { plotArea in
                plotArea.clipped()
            }
            // See the equivalent comment in `WorkoutProgramChart` for why
            // both gestures live in one `.chartOverlay`, `.exclusively
            // (before:)`-chained with the double-tap listed first.
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            SpatialTapGesture(count: 2)
                                .onEnded { _ in
                                    zoomLevelIndex = (zoomLevelIndex + 1) % Self.zoomWindowsKm.count
                                }
                                .exclusively(before: SpatialTapGesture(count: 1)
                                    .onEnded { tap in
                                        selectInterval(atTapLocation: tap.location, proxy: proxy, geometry: geometry)
                                    }
                                )
                        )
                }
            }
            .onChange(of: workoutState) { newState in
                if newState == .running { selectedBreakpointIndex = nil }
            }
            // See the equivalent comment in `WorkoutProgramChart` for why
            // `.task(id:)` rather than a plain scheduled timer.
            .task(id: selectedBreakpointIndex) {
                guard selectedBreakpointIndex != nil else { return }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { return }
                selectedBreakpointIndex = nil
            }

            if let selectedIntervalLabel {
                Text(selectedIntervalLabel)
                    .font(isRegularWidth ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Text(zoomLabel)
                .font(isRegularWidth ? .footnote : .caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// The `GradeProfile`/distance counterpart to `WorkoutProgramChart
    /// .selectInterval(atTapLocation:proxy:geometry:)`.
    private func selectInterval(atTapLocation location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        let plotAreaFrame = geometry[proxy.plotAreaFrame]
        let xPosition = location.x - plotAreaFrame.origin.x
        guard let km: Double = proxy.value(atX: xPosition),
              let index = route.breakpointIndex(atDistanceMeters: km * 1000) else {
            selectedBreakpointIndex = nil
            return
        }
        selectedBreakpointIndex = (selectedBreakpointIndex == index) ? nil : index
    }

    /// "50 m · 8.2 %" for a window (every window's grade is flat by
    /// construction – see `GradeProfileBuilder` – so start/end always
    /// match in practice, but this still falls back to a range if they
    /// ever don't, same as `WorkoutProgramChart`'s equivalent).
    private var selectedIntervalLabel: String? {
        guard let index = selectedBreakpointIndex, index + 1 < route.breakpoints.count else { return nil }
        let start = route.breakpoints[index]
        let end = route.breakpoints[index + 1]
        let spanMeters = end.distanceMeters - start.distanceMeters
        guard spanMeters > 0 else { return nil }
        let gradeText = start.gradePercent == end.gradePercent
            ? String(format: "%.1f %%", locale: .current, start.gradePercent)
            : String(format: "%.1f–%.1f %%", locale: .current, start.gradePercent, end.gradePercent)
        return "\(formattedSpan(spanMeters)) · \(gradeText)"
    }

    private func formattedSpan(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.2f km", locale: .current, meters / 1000) : String(format: "%.0f m", locale: .current, meters)
    }

    /// Centered on the current position while zoomed in, so the window
    /// scrolls along as the ride progresses instead of staying fixed on
    /// wherever it was when double-tapped.
    private var xDomainKm: ClosedRange<Double> {
        let totalKm = route.totalDistanceMeters / 1000
        guard let window = Self.zoomWindowsKm[zoomLevelIndex] else {
            return 0...Swift.max(totalKm, 0.001)
        }
        let center = distanceMeters / 1000
        let lower = Swift.max(0, center - window / 2)
        let upper = Swift.min(totalKm, center + window / 2)
        return lower...Swift.max(upper, lower + 0.001)
    }

    private var zoomLabel: String {
        guard let window = Self.zoomWindowsKm[zoomLevelIndex] else {
            return String(localized: "Full route · double-tap to zoom")
        }
        return String(localized: "\(Int(window)) km window · double-tap to zoom")
    }
}

/// Small color-coded stacked bar plus per-zone durations, showing how the
/// elapsed time (so far, or for a finished workout) splits across heart rate
/// zones. Empty/hidden until there's at least one classified second – happens
/// before a max heart rate estimate is available, or before an HR strap is
/// connected. Not `private` – `WorkoutHistoryView` reuses it too, same
/// "shared with another file" reasoning as `InfoButton`.
struct HeartRateZonesView: View {
    let zoneSeconds: [HeartRateZone: Int]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }
    private var totalSeconds: Int { zoneSeconds.values.reduce(0, +) }

    var body: some View {
        if totalSeconds > 0 {
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { proxy in
                    HStack(spacing: 1) {
                        ForEach(HeartRateZone.allCases) { zone in
                            let seconds = zoneSeconds[zone] ?? 0
                            if seconds > 0 {
                                Rectangle()
                                    .fill(color(for: zone))
                                    .frame(width: proxy.size.width * CGFloat(seconds) / CGFloat(totalSeconds))
                            }
                        }
                    }
                }
                .frame(height: isRegularWidth ? 14 : 8)
                .clipShape(Capsule())

                HStack(spacing: 10) {
                    ForEach(HeartRateZone.allCases) { zone in
                        let seconds = zoneSeconds[zone] ?? 0
                        if seconds > 0 {
                            Text("\(zone.shortLabel) \(formattedZoneDuration(seconds))")
                                .font(.system(size: isRegularWidth ? 23 : 15))
                                .foregroundStyle(color(for: zone))
                        }
                    }
                }
            }
        }
    }

    private func color(for zone: HeartRateZone) -> Color {
        switch zone {
        case .one: return .blue
        case .two: return .green
        case .three: return .yellow
        case .four: return .orange
        case .five: return .red
        }
    }
}

private func formattedZoneDuration(_ seconds: Int) -> String {
    String(format: "%d:%02d", seconds / 60, seconds % 60)
}

/// Shown after a successful save – confirms the write and, if there's zone
/// data, repeats the same breakdown `HeartRateZonesView` showed live (Health
/// itself has no equivalent view for non-Watch-recorded workouts).
private struct SavedWorkoutSummaryView: View {
    let summary: WorkoutSummary
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Saved to Apple Health")
                    .font(.headline)
                if !summary.heartRateZoneSeconds.isEmpty {
                    VStack(spacing: 8) {
                        Text("Time in Heart Rate Zones")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        HeartRateZonesView(zoneSeconds: summary.heartRateZoneSeconds)
                    }
                    .padding(.horizontal)
                }
                Spacer()
            }
            .padding(.top, 32)
            .padding()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Dedicated subview so that live heart rate updates (a separate
/// ObservableObject) redraw the tile without observing the whole ControlView.
/// Thin wrapper around `MetricTile` that just derives the live value from an
/// observed `HeartRateConnection` – `@ObservedObject` needs a concrete type
/// with the connection itself, unlike the other tiles which are handed an
/// already-formatted string.
private struct HeartRateTile: View {
    @ObservedObject var connection: HeartRateConnection
    let stat: LiveStat

    var body: some View {
        MetricTile(title: "♥ bpm", value: connection.bpm.map { "\($0)" } ?? "–", stat: stat)
    }
}

/// One live-metric tile (Watt/RPM/km/h/bpm). Tapping toggles between the
/// current reading and a ↓min/Øaverage/↑max summary *in the same slot*.
/// The three summary values stack vertically, one per line, each at the
/// same font size as the plain reading above them – legible at a glance
/// mid-ride, same as the current value is – rather than the three
/// squeezed onto one line and auto-shrunk to fit, which used to read
/// small enough to need a second look. The tradeoff: the tile does grow
/// taller while a summary is showing (three stacked lines vs. one), unlike
/// before this was requested, when tap-to-toggle deliberately kept the
/// tile's height constant.
private struct MetricTile: View {
    /// `LocalizedStringKey`, not `String` – unlike passing a literal
    /// straight to `Text(...)`, a literal flowing through a plain `String`
    /// property first (the shape this had before) does *not* auto-localize;
    /// the call sites already pass literals ("Watt", "RPM", …), so this
    /// change needed no call-site updates, just the type here.
    let title: LocalizedStringKey
    let value: String
    let stat: LiveStat
    /// Formats a min/average/max value for the tapped-summary state below.
    /// Defaults to the plain rounded-integer formatting every existing tile
    /// (Watt/RPM/km-h/bpm) already used – only the pace tile overrides this,
    /// since a pace's min/average/max need converting from the underlying
    /// speed-in-km/h samples `stat` actually stores, not just rounding.
    var formatValue: (Double?) -> String = formatStatValue
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showsSummary = false

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        VStack(spacing: 2) {
            if showsSummary, stat.count > 0 {
                VStack(spacing: 2) {
                    Text("↓\(formatValue(stat.minValue))")
                    Text("Ø\(formatValue(stat.average))")
                    Text("↑\(formatValue(stat.maxValue))")
                }
                .font(.system(size: isRegularWidth ? 44 : 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.4)
                .monospacedDigit()
            } else {
                Text(value)
                    .font(.system(size: isRegularWidth ? 44 : 28, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .monospacedDigit()
            }
            Text(title).font(isRegularWidth ? .title3 : .caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            guard stat.count > 0 else { return } // nothing to show yet – ignore the tap
            showsSummary.toggle()
        }
    }
}

/// A +/- button that fires once immediately on touch-down, then — if still
/// held after a short delay — keeps firing repeatedly until released. SwiftUI
/// has no built-in "press and hold to repeat" control, so this is built from
/// a zero-distance drag gesture (fires on touch-down/up, unlike `Button`,
/// which only fires on a full tap) plus a repeating `Timer`.
private struct RepeatingStepButton: View {
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    @State private var isPressing = false
    @State private var repeatTimer: Timer?

    /// Delay before holding starts repeating, and the interval once it does.
    private let initialDelay: TimeInterval = 0.4
    private let repeatInterval: TimeInterval = 0.08
    /// Hard cap on one continuous repeat, regardless of anything else. Plain
    /// `DragGesture` has no `.onCancel` – if the system ever cancels the
    /// gesture instead of ending it normally (observed occasionally; a
    /// re-render mid-press, e.g. from the once-a-second workout updates
    /// this sits next to, is the likely trigger) `.onEnded` simply never
    /// fires, and `repeatTimer` – a plain `Timer` on the run loop, not tied
    /// to this view's lifecycle once orphaned – would otherwise keep
    /// calling `action` forever with no way to stop it from the UI at all
    /// (a fresh press can't even start a new one, since `isPressing` is
    /// still stuck `true`). 20 s is generous enough for any real hold-to-
    /// traverse-the-full-range press to finish on its own first.
    private let maxRepeatDuration: TimeInterval = 20

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 56))
            .foregroundStyle(isDisabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            .contentShape(Rectangle())
            // `.simultaneousGesture` rather than `.gesture` – this sits
            // inside a `ScrollView` (the whole screen) right next to the
            // chart's own double-tap-to-zoom gesture, and `.gesture` alone
            // lets an ancestor/sibling claim the touch exclusively, which
            // cancels this one before `.onEnded` ever fires.
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginPressIfNeeded() }
                    .onEnded { _ in endPress() }
            )
            // Second line of defense against the same failure mode – if
            // this view is ever actually removed from the hierarchy
            // mid-press, stop the repeat rather than leaving it orphaned.
            .onDisappear { endPress() }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    private func beginPressIfNeeded() {
        guard !isDisabled, !isPressing else { return }
        isPressing = true
        action()
        let pressStartedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) {
            guard isPressing else { return }
            repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { timer in
                guard Date().timeIntervalSince(pressStartedAt) < maxRepeatDuration else {
                    timer.invalidate()
                    isPressing = false
                    return
                }
                action()
            }
        }
    }

    private func endPress() {
        isPressing = false
        repeatTimer?.invalidate()
        repeatTimer = nil
    }
}

private func formatStatValue(_ value: Double?) -> String {
    value.map { String(format: "%.0f", locale: .current, $0) } ?? "–"
}

/// Converts a speed in km/h to a running/walking pace, formatted "m:ss" per
/// kilometer (e.g. 10 km/h → "6:00"). `nil` or a speed too low to produce a
/// meaningful pace (below brisk-walking, where the minutes-per-km figure
/// balloons into something nobody reads as a pace) both fall back to "–".
private func paceString(fromSpeedKmh speedKmh: Double?) -> String {
    guard let speedKmh, speedKmh >= 1 else { return "–" }
    let secondsPerKm = 3600 / speedKmh
    let minutes = Int(secondsPerKm) / 60
    let seconds = Int(secondsPerKm.rounded()) % 60
    return String(format: "%d:%02d", minutes, seconds)
}

/// Toggles the enclosing screen's interactive edge-swipe-to-go-back gesture –
/// SwiftUI's `NavigationStack` has no API for this (unlike the back *button*,
/// which `.navigationBarBackButtonHidden(true)` covers), so this reaches
/// past it to the underlying `UINavigationController` directly. An
/// invisible, zero-effect `UIViewController` used purely as a handle: its
/// `updateUIViewController` fires on every SwiftUI re-render, which is what
/// lets `isDisabled` toggle the gesture live as a workout starts/stops,
/// without ever needing its own visible content.
private struct InteractivePopGestureDisabler: UIViewControllerRepresentable {
    let isDisabled: Bool

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // `navigationController` is only set once this controller's actually
        // been inserted into the hosting navigation stack's hierarchy, which
        // hasn't necessarily happened yet the *first* time this runs –
        // deferring one runloop turn is enough to be sure it has.
        DispatchQueue.main.async {
            uiViewController.navigationController?.interactivePopGestureRecognizer?.isEnabled = !isDisabled
        }
    }
}
