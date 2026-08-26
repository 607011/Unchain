import SwiftUI
import HealthKit
import Charts
import UniformTypeIdentifiers

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
    /// reopening on Power. `ensureModeIsAvailable()` already handles a
    /// restored mode the *currently connected* machine doesn't support (e.g.
    /// last time was Grade on a different trainer) by falling back, so this
    /// needs no extra guarding beyond that existing check.
    @AppStorage("lastActiveMode") private var mode: ControlMode = .power
    /// Restored from the last run, and kept up to date as the user steps
    /// them, so they survive an app restart.
    @AppStorage("lastTargetPowerWatts") private var targetPower: Int = 100
    @AppStorage("lastTargetResistancePercent") private var targetResistance: Int = 20
    @AppStorage("lastTargetGradePercent") private var targetGrade: Double = 0
    @State private var saveResult: SaveResultAlert?
    @State private var savedSummary: WorkoutSummary?
    @State private var isShowingFeatures = false
    @State private var isShowingSettings = false
    @State private var isShowingFileImporter = false
    @State private var isShowingRecentWorkouts = false
    @State private var loadError: LoadErrorAlert?
    /// True while an async HealthKit save is in flight — guards the
    /// confirmation dialog's dismiss handler from mistaking the dialog closing
    /// itself (after "Save as …" was tapped) for the user cancelling.
    @State private var isSaving = false

    private let powerStep = 5
    private let resistanceStep = 1
    private let gradeStep: Double = 0.5
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

    /// Only the modes the connected machine actually supports. Program (file
    /// loading) always shows – which file *types* it accepts adapts
    /// internally instead, see `allowedFileContentTypes`.
    private var availableModes: [ControlMode] {
        var modes: [ControlMode] = []
        if supportsPowerTarget { modes.append(.power) }
        if supportsResistanceTarget { modes.append(.resistance) }
        modes.append(.program)
        if supportsIndoorBikeSimulation { modes.append(.grade) }
        return modes
    }

    /// If the currently selected tab just became unavailable (feature
    /// detection completed and turned out negative), fall back to the first
    /// one that's still valid instead of leaving the picker on a hidden case.
    private func ensureModeIsAvailable() {
        guard !availableModes.contains(mode) else { return }
        mode = availableModes.first ?? .program
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
                        Text(mode.rawValue).tag(mode)
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
                        bluetooth.disconnectCurrent()
                        bluetooth.clearConnection()
                    }
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
            TrainerFeaturesView(deviceName: connection.deviceName, features: connection.supportedFeatures)
        }
        .sheet(isPresented: $isShowingRecentWorkouts) {
            RecentWorkoutsView(recents: compatibleRecents, onSelect: loadRecentEntry)
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
            fetchMaxHeartRateIfNeeded()
            loadPersistedOrDefaultProgram()
            ensureModeIsAvailable()
        }
        .onChange(of: connection.supportedFeatures) { _ in
            ensureModeIsAvailable()
        }
        .onChange(of: isHeartRateConnected) { _ in
            fetchMaxHeartRateIfNeeded()
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
    }

    private var isHeartRateConnected: Bool { bluetooth.currentHeartRateConnection != nil }

    /// Fetches (once) an estimated max heart rate from Health so `session` can
    /// classify live BPM readings into zones from the start of the workout.
    /// A no-op if there's no HR strap connected yet, or if it's already set.
    private func fetchMaxHeartRateIfNeeded() {
        guard isHeartRateConnected, session.maxHeartRateBPM == nil else { return }
        HealthKitManager.shared.fetchMaxHeartRateBPM { bpm in
            session.setMaxHeartRateBPM(bpm)
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
            metricTile(title: "Watt", value: connection.metrics.instantaneousPowerWatts.map { "\($0)" } ?? "–", stat: session.powerStats)
            metricTile(title: "RPM", value: connection.metrics.instantaneousCadenceRPM.map { String(format: "%.0f", $0) } ?? "–", stat: session.cadenceStats)
            metricTile(title: "km/h", value: connection.metrics.instantaneousSpeedKmh.map { String(format: "%.1f", $0) } ?? "–", stat: session.speedStats)
            if let heartRate = bluetooth.currentHeartRateConnection {
                HeartRateTile(connection: heartRate, stat: session.heartRateStats)
            }
        }
    }

    private func metricTile(title: String, value: String, stat: LiveStat) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: isRegularWidth ? 44 : 28, weight: .semibold, design: .rounded))
            Text(title).font(isRegularWidth ? .title3 : .caption).foregroundStyle(.secondary)
            statSummaryText(stat, isRegularWidth: isRegularWidth)
        }
        .frame(maxWidth: .infinity)
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
                    Button("Start Workout") { session.start(usingProgram: mode == .program) }
                        .buttonStyle(.borderedProminent)
                        .disabled(connection.state != .ready || (mode == .program && session.activeWorkout == nil))
                case .running:
                    Button("Pause") { session.pause() }
                        .buttonStyle(.bordered)
                    Button("Stop") { session.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                case .paused:
                    Button("Resume") { session.resume() }
                        .buttonStyle(.borderedProminent)
                    Button("Stop") { session.stop() }
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

                WorkoutProgramChart(program: program, elapsedSeconds: session.elapsedSeconds)
                    .frame(height: isRegularWidth ? 260 : 140)
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

                loadFromFileButtons
            }
        case .route(let route):
            VStack(spacing: 12) {
                Text(route.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(routeTargetLabel(for: route))
                    .font(.system(size: isRegularWidth ? 72 : 48, weight: .bold, design: .rounded))
                    .monospacedDigit()

                GradeProfileChart(route: route, distanceMeters: session.distanceMeters)
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

                loadFromFileButtons
            }
        case nil:
            VStack(spacing: 12) {
                Text(emptyWorkoutStateDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                loadFromFileButtons
                if supportsPowerTarget {
                    Button("Load Sample Ramp Test (100–700 W)") { loadSampleRampTest() }
                        .buttonStyle(.bordered)
                }
            }
        }
    }

    private var loadFromFileButtons: some View {
        HStack(spacing: 12) {
            Button("Load from File") { isShowingFileImporter = true }
                .buttonStyle(.bordered)
                .disabled(allowedFileContentTypes.isEmpty)
            Button("Recent") { isShowingRecentWorkouts = true }
                .buttonStyle(.bordered)
                .disabled(compatibleRecents.isEmpty)
        }
        .disabled(session.state == .running || session.state == .paused)
    }

    /// Which file types "Load from File" offers, matching only the targets
    /// the connected machine actually supports — `.erg` needs Power Target,
    /// `.mrc` needs Resistance Target, `.gpx` needs Indoor Bike Simulation.
    private var allowedFileContentTypes: [UTType] {
        var types: [UTType] = []
        if supportsPowerTarget, let erg = WorkoutProgramParser.ergContentType { types.append(erg) }
        if supportsResistanceTarget, let mrc = WorkoutProgramParser.mrcContentType { types.append(mrc) }
        if supportsIndoorBikeSimulation { types.append(contentsOf: GPXParser.supportedContentTypes) }
        return types
    }

    private var emptyWorkoutStateDescription: String {
        var extensions: [String] = []
        if supportsPowerTarget { extensions.append(".erg") }
        if supportsResistanceTarget { extensions.append(".mrc") }
        if supportsIndoorBikeSimulation { extensions.append(".gpx") }
        guard !extensions.isEmpty else {
            return "This trainer doesn't report support for any target type Unchain can drive from a file."
        }
        return "Load a \(extensions.joined(separator: ", ")) file to follow a structured workout or route automatically."
    }

    private func isProgramSupported(_ program: WorkoutProgram) -> Bool {
        switch program.targetKind {
        case .power: return supportsPowerTarget
        case .resistance: return supportsResistanceTarget
        }
    }

    /// Recently used programs *and* routes compatible with the currently
    /// connected machine, excluding whatever's already loaded, merged and
    /// sorted by recency. Filtered two ways: `.erg`/`.mrc`/GPX-derived routes
    /// are all cycling-trainer-only today (see `ProgramTargetKind
    /// .compatibleMachineKind` and `GradeProfile.compatibleMachineKind`), so
    /// this list is empty while connected to a treadmill; and further gated
    /// on whether the specific target that entry needs (Power/Resistance/
    /// Indoor Bike Simulation) is actually supported, since a file used with
    /// a *previous* trainer might not work with the one connected now.
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
        return (programs + routes).sorted { $0.lastUsedDate > $1.lastUsedDate }
    }

    private func isActiveWorkout(_ candidate: RecentWorkoutKind) -> Bool {
        switch (candidate, session.activeWorkout) {
        case (.program(let p), .program(let active)): return p == active
        case (.route(let r), .route(let active)): return r == active
        default: return false
        }
    }

    private func programTargetLabel(for program: WorkoutProgram) -> String {
        guard let target = program.target(atElapsedSeconds: TimeInterval(session.elapsedSeconds)) else {
            return "–"
        }
        switch program.targetKind {
        case .power: return "\(target) W"
        case .resistance: return "\(target) %"
        }
    }

    private func routeTargetLabel(for route: GradeProfile) -> String {
        guard let grade = route.grade(atDistanceMeters: session.distanceMeters) else { return "–" }
        return String(format: "%.1f %%", grade)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func formattedDistance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.2f km", meters / 1000) : String(format: "%.0f m", meters)
    }

    /// Called once when the screen first appears: if a workout is already
    /// loaded (e.g. from an earlier appearance while reconnecting) this is a
    /// no-op; otherwise restores whichever of a program or route was used
    /// most recently *and is still supported by this trainer*, or – if
    /// nothing qualifies – falls back to the bundled ramp test (itself only
    /// if Power Target is supported) so Program mode isn't empty-handed.
    private func loadPersistedOrDefaultProgram() {
        guard session.activeWorkout == nil else { return }
        let recentProgram = WorkoutProgramStore.loadRecents().first { isProgramSupported($0.program) }
        let recentRoute = supportsIndoorBikeSimulation ? RouteStore.loadRecents().first : nil
        switch (recentProgram, recentRoute) {
        case (let program?, let route?):
            if program.lastUsedDate >= route.lastUsedDate {
                loadProgramIntoSession(program.program)
            } else {
                loadRouteIntoSession(route.route)
            }
        case (let program?, nil):
            loadProgramIntoSession(program.program)
        case (nil, let route?):
            loadRouteIntoSession(route.route)
        case (nil, nil):
            if supportsPowerTarget {
                loadSampleRampTest()
            }
        }
    }

    private func loadRecentEntry(_ entry: CombinedRecentEntry) {
        switch entry.kind {
        case .program(let program): loadProgramIntoSession(program)
        case .route(let route): loadRouteIntoSession(route)
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

    private func loadSampleRampTest() {
        guard let url = Bundle.main.url(forResource: "RampTest_100-700W", withExtension: "erg") else {
            loadError = LoadErrorAlert(message: "The bundled sample ramp test is missing.")
            return
        }
        loadWorkout(contentsOf: url)
    }

    private func loadWorkout(fromSecurityScoped url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            loadError = LoadErrorAlert(message: "Couldn't access the selected file.")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        loadWorkout(contentsOf: url)
    }

    /// Dispatches by extension: `.gpx` is XML parsed into a distance-based
    /// `GradeProfile`, anything else is treated as the `.erg`/`.mrc` text
    /// format and parsed into a time-based `WorkoutProgram`.
    private func loadWorkout(contentsOf url: URL) {
        if url.pathExtension.lowercased() == "gpx" {
            loadRoute(fromGPXContentsOf: url)
        } else {
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
                    let targetName = program.targetKind == .power ? "power" : "resistance"
                    loadError = LoadErrorAlert(message: "This trainer doesn't support \(targetName) targets.")
                    return
                }
                loadProgramIntoSession(program)
            case .failure(let error):
                loadError = LoadErrorAlert(message: error.localizedDescription)
            }
        } catch {
            loadError = LoadErrorAlert(message: "Couldn't read the file: \(error.localizedDescription)")
        }
    }

    private func loadRoute(fromGPXContentsOf url: URL) {
        guard supportsIndoorBikeSimulation else {
            loadError = LoadErrorAlert(message: "This trainer doesn't support Indoor Bike Simulation (Grade), so GPX routes can't be used.")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            switch GPXParser.parse(data: data) {
            case .success(let points):
                let name = url.deletingPathExtension().lastPathComponent
                guard let route = GradeProfileBuilder.build(name: name, points: points) else {
                    loadError = LoadErrorAlert(message: "Couldn't derive a grade profile from this track.")
                    return
                }
                loadRouteIntoSession(route)
            case .failure(let error):
                loadError = LoadErrorAlert(message: error.localizedDescription)
            }
        } catch {
            loadError = LoadErrorAlert(message: "Couldn't read the file: \(error.localizedDescription)")
        }
    }

    private var formattedResistanceLevel: String {
        String(format: "%.1f", Double(connection.rawResistanceLevel(forPercent: targetResistance)) / 10)
    }

    private var formattedResistanceRange: String {
        let lower = Double(connection.resistanceRangeRaw.lowerBound) / 10
        let upper = Double(connection.resistanceRangeRaw.upperBound) / 10
        return String(format: "%.1f–%.1f", lower, upper)
    }

    /// Only shown from `manualControls`, i.e. never while `mode == .program`.
    private var currentTargetLabel: String {
        switch mode {
        case .power: return "\(targetPower) W"
        case .resistance: return "\(targetResistance) %"
        case .grade: return String(format: "%.1f %%", targetGrade)
        case .program: return ""
        }
    }

    private func stepButton(systemImage: String, action: @escaping () -> Void) -> some View {
        RepeatingStepButton(systemImage: systemImage, isDisabled: connection.state != .ready, action: action)
    }

    /// Only called from `manualControls`, i.e. never while `mode == .program`.
    private func step(_ direction: Int) {
        switch mode {
        case .power:
            targetPower = connection.powerRange.clamp(targetPower + direction * powerStep)
        case .resistance:
            targetResistance = resistancePercentRange.clamp(targetResistance + direction * resistanceStep)
        case .grade:
            targetGrade = gradePercentRange.clamp(targetGrade + Double(direction) * gradeStep)
        case .program:
            return
        }
        sendCurrentTarget()
    }

    /// Sends whichever target is currently active to the trainer — used both
    /// after +/- taps and right after (re)connecting, so the display and the
    /// device are never out of sync. In Program mode this re-sends the
    /// loaded workout's current target (time-based for a program, distance-
    /// based for a route) rather than a manual value.
    private func sendCurrentTarget() {
        switch mode {
        case .power:
            connection.setTargetPower(watts: targetPower)
        case .resistance:
            connection.setTargetResistancePercent(targetResistance)
        case .grade:
            connection.setSimulationGrade(percent: targetGrade)
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
            case nil:
                return
            }
        }
    }

    /// Buttons offered in the post-workout save dialog. Which activity types are
    /// offered depends on the detected machine kind – FTMS can tell us it's a
    /// treadmill, but not whether the user walked or ran, so that's a manual choice.
    @ViewBuilder
    private func saveDialogButtons(for summary: WorkoutSummary) -> some View {
        switch summary.machineKind {
        case .bike:
            Button("Save as Indoor Cycling") { save(summary, as: .cycling) }
        case .treadmill:
            Button("Save as Indoor Walk") { save(summary, as: .walking) }
            Button("Save as Indoor Run") { save(summary, as: .running) }
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
                saveResult = SaveResultAlert(title: "Not Saved", message: error.localizedDescription)
            }
            session.reset()
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

/// Overlay listing recently used, machine-compatible programs (see
/// `ControlView.compatibleRecents`). Each row shows whether the file targets
/// power or resistance, since that's not otherwise obvious from the name.
/// What one row in the merged "recent workouts" list represents.
private enum RecentWorkoutKind {
    case program(WorkoutProgram)
    case route(GradeProfile)
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
    let recents: [CombinedRecentEntry]
    let onSelect: (CombinedRecentEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
        }
    }
}

/// Profile of the loaded program (time on the x-axis, in minutes; target on
/// the y-axis) with a vertical rule marking how far into it the workout
/// currently is.
private struct WorkoutProgramChart: View {
    let program: WorkoutProgram
    let elapsedSeconds: Int
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Window widths (minutes) to cycle through on double-tap, narrowest
    /// last; `nil` means the full workout. Same double-tap-to-zoom gesture
    /// TrainerDay has on its workout chart.
    private static let zoomWindowsMinutes: [Double?] = [nil, 10, 3]
    @State private var zoomLevelIndex = 0
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        VStack(spacing: 2) {
            Chart {
                ForEach(Array(program.breakpoints.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Minutes", point.timeSeconds / 60),
                        y: .value(unitLabel, point.value)
                    )
                    .interpolationMethod(.linear)
                }
                RuleMark(x: .value("Elapsed", Double(elapsedSeconds) / 60))
                    .foregroundStyle(.red)
            }
            .chartXScale(domain: xDomainMinutes)
            .chartXAxisLabel("Minutes")
            .chartYAxisLabel(unitLabel)
            // `.chartXScale(domain:)` alone only remaps the scale – it doesn't
            // clip drawing to the plot area, so a line segment leading to a
            // point outside the zoomed window still gets drawn past the
            // right (or left) edge. Clip just the plot content, not the axes.
            .chartPlotStyle { plotArea in
                plotArea.clipped()
            }
            .onTapGesture(count: 2) {
                zoomLevelIndex = (zoomLevelIndex + 1) % Self.zoomWindowsMinutes.count
            }

            Text(zoomLabel)
                .font(isRegularWidth ? .footnote : .caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var unitLabel: String {
        program.targetKind == .power ? "Watts" : "Percent"
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
            return "Full workout · double-tap to zoom"
        }
        return "\(Int(window)) min window · double-tap to zoom"
    }
}

/// Profile of the loaded GPX route (distance in km on the x-axis, grade % on
/// the y-axis) with a vertical rule marking how far the ride has covered so
/// far – the `GradeProfile` counterpart to `WorkoutProgramChart`.
private struct GradeProfileChart: View {
    let route: GradeProfile
    let distanceMeters: Double
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Window widths (km) to cycle through on double-tap, narrowest last;
    /// `nil` means the full route. Same double-tap-to-zoom gesture
    /// TrainerDay has on its workout chart.
    private static let zoomWindowsKm: [Double?] = [nil, 8, 2]
    @State private var zoomLevelIndex = 0
    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        VStack(spacing: 2) {
            Chart {
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
            .onTapGesture(count: 2) {
                zoomLevelIndex = (zoomLevelIndex + 1) % Self.zoomWindowsKm.count
            }

            Text(zoomLabel)
                .font(isRegularWidth ? .footnote : .caption2)
                .foregroundStyle(.tertiary)
        }
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
            return "Full route · double-tap to zoom"
        }
        return "\(Int(window)) km window · double-tap to zoom"
    }
}

/// Small color-coded stacked bar plus per-zone durations, showing how the
/// elapsed time (so far, or for a finished workout) splits across heart rate
/// zones. Empty/hidden until there's at least one classified second – happens
/// before a max heart rate estimate is available, or before an HR strap is
/// connected.
private struct HeartRateZonesView: View {
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
                                .font(.system(size: isRegularWidth ? 15 : 10))
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
private struct HeartRateTile: View {
    @ObservedObject var connection: HeartRateConnection
    let stat: LiveStat
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var isRegularWidth: Bool { horizontalSizeClass == .regular }

    var body: some View {
        VStack(spacing: 2) {
            Text(connection.bpm.map { "\($0)" } ?? "–")
                .font(.system(size: isRegularWidth ? 44 : 28, weight: .semibold, design: .rounded))
            Text("♥ bpm").font(isRegularWidth ? .title3 : .caption).foregroundStyle(.secondary)
            statSummaryText(stat, isRegularWidth: isRegularWidth)
        }
        .frame(maxWidth: .infinity)
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

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 56))
            .foregroundStyle(isDisabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.tint))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginPressIfNeeded() }
                    .onEnded { _ in endPress() }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }

    private func beginPressIfNeeded() {
        guard !isDisabled, !isPressing else { return }
        isPressing = true
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + initialDelay) {
            guard isPressing else { return }
            repeatTimer = Timer.scheduledTimer(withTimeInterval: repeatInterval, repeats: true) { _ in
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

/// Small "↓min Øavg ↑max" line shown under a metric tile once a workout has
/// collected at least one sample; hidden before that to avoid a row of dashes.
/// Takes `isRegularWidth` as a parameter rather than reading
/// `@Environment(\.horizontalSizeClass)` itself, since a free function (as
/// opposed to a `View`-conforming struct) can't declare `@Environment`.
@ViewBuilder
private func statSummaryText(_ stat: LiveStat, isRegularWidth: Bool) -> some View {
    if stat.count > 0 {
        let min = formatStatValue(stat.minValue)
        let avg = formatStatValue(stat.average)
        let max = formatStatValue(stat.maxValue)
        Text("↓\(min) Ø\(avg) ↑\(max)")
            .font(.system(size: isRegularWidth ? 16 : 10))
            .foregroundStyle(.tertiary)
    }
}

private func formatStatValue(_ value: Double?) -> String {
    value.map { String(format: "%.0f", $0) } ?? "–"
}
