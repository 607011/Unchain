import SwiftUI

/// How the metrics row's speed tile displays speed – or whether it's shown
/// at all. See `ControlView.metricsRow`. "Off" frees up that tile's spot for
/// a live kcal reading instead (see `WorkoutSession.liveActiveEnergyKcal`) –
/// speed in km/h is fairly pointless for an indoor trainer that never
/// actually moves, and running/walking pace is usually given in min/km
/// rather than km/h anyway.
/// How `ControlView`'s speed tile presents the trainer's speed reading – or
/// whether it shows a live calorie count in that slot instead. Configurable
/// because "km/h" is a fairly meaningless number on an indoor bike (it
/// reflects the simulated wheel speed, not anything the rider actually feels)
/// and running/walking is conventionally tracked as pace (min/km) rather than
/// speed at all.
enum SpeedDisplayUnit: String, CaseIterable, Identifiable {
    case kmh
    case pace
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .kmh: return String(localized: "km/h")
        case .pace: return String(localized: "min/km")
        case .off: return String(localized: "Off")
        }
    }
}

/// App-wide settings, not tied to any particular trainer connection – opened
/// via the gear icon in `ControlView`'s toolbar. The rider's FTP, used to
/// interpret %FTP-based workout files (see `WorkoutProgramParser.parse`,
/// which already reads FTP from a file's own header when present – this is
/// for the app's own reference instead, e.g. for files that don't declare
/// one); Max/Resting Heart Rate and the Heart Rate Zone boundaries derived
/// from them (see `HeartRateZone`); Vibration/Interval Sound for Program
/// workouts; and an explicit Language override (see `LanguageManager`),
/// which defaults to following the device's own Language & Region setting;
/// links to the Privacy Policy/Terms of Use, both served from the project's
/// GitHub Pages site alongside a small landing page (see `docs/index.html`
/// in the repo); and, right at the bottom, "Log a Workout…" (see
/// `LogWorkoutView`) for backfilling one into Health that Unchain never
/// recorded live. Each section's explanation lives behind its `InfoButton`
/// rather than a permanent footer, to keep the screen from growing too tall
/// now that there are several of them. More settings are expected to land
/// here over time.
struct SettingsView: View {
    /// `UserDefaults` key for the rider's FTP – shared here since
    /// `CreateWorkoutView`'s shorthand workout notation (`%FTP` targets) also
    /// needs to read it, not just this settings screen.
    static let ftpWattsKey = "userFTPWatts"
    /// `UserDefaults` key for the rider's max heart rate – shared here since
    /// `WorkoutSession`, not this settings screen, is what actually reads it
    /// to classify live BPM samples into zones (same reasoning as
    /// `WorkoutSession.vibrationEnabledKey` et al.). `0` means "not set yet",
    /// same convention as `ftpWattsKey` above – `HeartRateZone.containing`
    /// already treats a non-positive max heart rate as "no zones".
    static let maxHeartRateBPMKey = "userMaxHeartRateBPM"
    /// `UserDefaults` key for the rider's resting heart rate – used, along
    /// with `maxHeartRateBPMKey`, as the basis for `HeartRateZone`'s Heart
    /// Rate Reserve (Karvonen) zone-boundary defaults. `0` means "not set /
    /// not on record in Health", in which case `HeartRateZone` quietly falls
    /// back to the plain %-of-max-heart-rate breakpoints instead.
    static let restingHeartRateBPMKey = "userRestingHeartRateBPM"
    /// `UserDefaults` key for `SpeedDisplayUnit` – read directly by
    /// `ControlView.metricsRow`, the same "read at the point of use" pattern
    /// as `WorkoutSession`'s own settings.
    static let speedDisplayUnitKey = "speedDisplayUnit"

    @AppStorage(ftpWattsKey) private var ftpWatts: Int = 188
    @AppStorage(maxHeartRateBPMKey) private var maxHeartRateBPM: Int = 0
    @AppStorage(restingHeartRateBPMKey) private var restingHeartRateBPM: Int = 0
    @AppStorage(HeartRateZone.zone2LowerBPMKey) private var zone2LowerBPM: Int = 0
    @AppStorage(HeartRateZone.zone3LowerBPMKey) private var zone3LowerBPM: Int = 0
    @AppStorage(HeartRateZone.zone4LowerBPMKey) private var zone4LowerBPM: Int = 0
    @AppStorage(HeartRateZone.zone5LowerBPMKey) private var zone5LowerBPM: Int = 0
    @AppStorage(WorkoutSession.vibrationEnabledKey) private var isVibrationEnabled = false
    @AppStorage(WorkoutSession.intervalSoundTypeKey) private var intervalSoundType = IntervalSoundType.single
    @AppStorage(WorkoutSession.intervalSoundVolumeKey) private var intervalSoundVolumePercent: Int = 0
    @AppStorage(LanguageManager.storageKey) private var languageOverride = AppLanguage.system.rawValue
    @AppStorage(speedDisplayUnitKey) private var speedDisplayUnit = SpeedDisplayUnit.kmh
    @State private var isShowingLogWorkout = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. 250", text: zeroAsEmptyText($ftpWatts))
                        .keyboardType(.numberPad)
                } header: {
                    HStack(spacing: 4) {
                        Text("FTP (Watts)")
                        InfoButton(text: "Your Functional Threshold Power – the highest average power you can sustain for about an hour, commonly estimated as 95 % of your best 20-minute effort (a \"20-minute FTP test\"), or read off a ramp test's result. Used throughout the app: to interpret %FTP-based workout targets, both in files that declare an FTP header (e.g. TrainerDay's .mrc exports) and in the Create sheet's own shorthand notation (e.g. \"75%FTP\"), and to draw the FTP reference line on the Program workout chart.")
                    }
                }
                Section {
                    LabeledContent {
                        TextField("e.g. 185", text: zeroAsEmptyText($maxHeartRateBPM))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Max")
                    }
                    LabeledContent {
                        TextField("e.g. 55", text: zeroAsEmptyText($restingHeartRateBPM))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Resting")
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("Heart Rate (bpm)")
                        InfoButton(text: "Used for the live heart rate zones below. Max is pre-filled with an age-based estimate (Tanaka formula) from your date of birth in Health; Resting from your most recent Watch-recorded reading, or 60 bpm if Health has none on record. Enter your own values if you know them more precisely, e.g. Max from a lab or max-effort test.")
                    }
                }
                Section {
                    LabeledContent {
                        TextField("e.g. 125", text: zeroAsEmptyText($zone2LowerBPM))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Zone 1 → 2")
                    }
                    LabeledContent {
                        TextField("e.g. 136", text: zeroAsEmptyText($zone3LowerBPM))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Zone 2 → 3")
                    }
                    LabeledContent {
                        TextField("e.g. 146", text: zeroAsEmptyText($zone4LowerBPM))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Zone 3 → 4")
                    }
                    LabeledContent {
                        TextField("e.g. 157", text: zeroAsEmptyText($zone5LowerBPM))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Zone 4 → 5")
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("Heart Rate Zones")
                        InfoButton(text: "Each value is the first bpm belonging to the next zone – Zone 1 covers everything below the first value, Zone 5 everything at or above the last. Pre-filled from Max/Resting Heart Rate using the Heart Rate Reserve (Karvonen) method: resting + 60/70/80/90 % of the reserve between resting and max. Apple Watch's own zones use a different, personalized calculation (Cardio Fitness/VO2 max), so there's no way to copy them exactly – enter the same numbers Fitness already shows you here instead if these don't quite match.")
                    }
                }
                Section {
                    Toggle(isOn: $isVibrationEnabled) {
                        HStack(spacing: 4) {
                            Text("Vibration")
                            InfoButton(text: "Briefly vibrates whenever a Program workout (.erg/.mrc) reaches its next scheduled entry.")
                        }
                    }
                }
                Section {
                    Picker("Sound Type", selection: $intervalSoundType) {
                        ForEach(IntervalSoundType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Volume")
                            Spacer()
                            Text("\(intervalSoundVolumePercent) %").foregroundStyle(.secondary)
                        }
                        Slider(value: volumePercentBinding, in: 0...100, step: 1)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("Interval Sound")
                        InfoButton(text: "Plays alongside Vibration when a Program workout reaches its next scheduled entry. Volume 0 % stays silent. \"Countdown\" adds one beep a second for the four seconds before, on top of the one for the entry itself.")
                    }
                }
                Section {
                    Picker("Language", selection: $languageOverride) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("Language")
                        InfoButton(text: "Applies immediately, no restart needed. \"System\" follows your device's own Language & Region setting.")
                    }
                }
                Section {
                    Picker("Speed Display", selection: $speedDisplayUnit) {
                        ForEach(SpeedDisplayUnit.allCases) { unit in
                            Text(unit.displayName).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    HStack(spacing: 4) {
                        Text("Speed Display")
                        InfoButton(text: "km/h rarely matters on an indoor trainer, and running/walking is usually tracked in min/km instead – choose whichever fits, or turn it off to show live calories in that spot instead (cycling only).")
                    }
                }
                // Self-explanatory row labels – unlike the sections above,
                // there's nothing here worth hiding behind an `InfoButton`.
                // `Link` opens the system browser rather than an in-app
                // `WKWebView`, so these are always the current, up-to-date
                // pages (and the same ones App Store Connect's Support/
                // Marketing URLs point to), not a copy that could drift.
                Section {
                    Link("Privacy Policy", destination: URL(string: "https://607011.github.io/Unchain/privacy.html")!)
                    Link("Terms of Use", destination: URL(string: "https://607011.github.io/Unchain/terms.html")!)
                } header: {
                    Text("Legal")
                }
                // Deliberately the very last section – this isn't a setting
                // so much as an occasional action, and it isn't tied to a
                // trainer connection either (unlike the live post-workout
                // save dialog in `ControlView`), so it belongs wherever
                // Settings itself is reachable from, not buried behind one.
                Section {
                    Button {
                        isShowingLogWorkout = true
                    } label: {
                        Label("Log a Workout…", systemImage: "square.and.pencil")
                    }
                } footer: {
                    Text("Add a workout to Health that wasn't recorded live in Unchain – e.g. one done without the app running.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $isShowingLogWorkout) {
            LogWorkoutView()
        }
        .onAppear {
            if maxHeartRateBPM == 0 || restingHeartRateBPM == 0 {
                // A Health lookup is about to run (async) and will very
                // likely change one or both values – let the `.onChange`
                // handlers below do the one, correctly-timed zone prefill
                // once it lands, rather than prefilling zones here first
                // with a stale/still-missing resting heart rate that would
                // then be stuck (each zone field's own `== 0` guard means
                // it only ever gets materialized once).
                prefillHeartRateProfileIfNeeded()
            } else {
                // Nothing to wait for – both already known (e.g. from an
                // earlier visit), so there's no async step zone prefill
                // needs to sit behind.
                prefillHeartRateZonesIfNeeded()
            }
        }
        .onChange(of: maxHeartRateBPM) { _ in
            prefillHeartRateZonesIfNeeded()
        }
        .onChange(of: restingHeartRateBPM) { _ in
            prefillHeartRateZonesIfNeeded()
        }
    }

    /// A `TextField` bound directly to a stored `Int` would show a
    /// persistent "0" before anything's entered – this shows an empty field
    /// with a placeholder instead, since `@AppStorage` has no natural `Int?`
    /// support. Shared by every numeric field on this screen (FTP, Max Heart
    /// Rate, the four zone boundaries).
    private func zeroAsEmptyText(_ value: Binding<Int>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue == 0 ? "" : String(value.wrappedValue) },
            set: { value.wrappedValue = Int($0) ?? 0 }
        )
    }

    /// A plausible average resting heart rate, used to still prefill
    /// something reasonable for Resting Heart Rate when Health has no
    /// reading on record at all (e.g. no Watch, or one that's never
    /// measured it yet) — better than leaving Heart Rate Zones' Karvonen
    /// calculation without a resting heart rate entirely, which would fall
    /// further back to the plain, less accurate %-of-max-heart-rate
    /// breakpoints instead (see `HeartRateZone.defaultLowerBoundBPM`). Like
    /// every other prefilled value on this screen, freely overwritable.
    private static let restingHeartRateFallbackBPM = 60

    /// Only runs while at least one of Max/Resting Heart Rate hasn't been
    /// entered yet (manually, or by a previous prefill) – checked
    /// separately per field below, since either can already be set while
    /// the other isn't (e.g. Max entered by hand before Resting Heart Rate
    /// existed as a setting at all). `HealthKitManager
    /// .fetchHeartRateProfile` prompts for Health authorization the first
    /// time, so this deliberately waits until the fields that actually need
    /// the answer are on screen, rather than asking eagerly at app launch.
    /// Resting Heart Rate always ends up with *some* value once this
    /// completes – Health's own reading if there is one,
    /// `restingHeartRateFallbackBPM` otherwise – never left unset the way
    /// Max Heart Rate can be if Health is unavailable/denied (there's no
    /// equally reasonable fixed fallback for max heart rate, which varies
    /// far more from person to person).
    private func prefillHeartRateProfileIfNeeded() {
        guard maxHeartRateBPM == 0 || restingHeartRateBPM == 0 else { return }
        HealthKitManager.shared.fetchHeartRateProfile { profile in
            if let maxBPM = profile.maxBPM, maxHeartRateBPM == 0 {
                maxHeartRateBPM = maxBPM
            }
            if restingHeartRateBPM == 0 {
                restingHeartRateBPM = profile.restingBPM ?? Self.restingHeartRateFallbackBPM
            }
        }
    }

    /// Materializes each zone boundary's Heart Rate Reserve (Karvonen)
    /// default (see `HeartRateZone.defaultLowerBoundBPM(maxHeartRateBPM:
    /// restingHeartRateBPM:)`) into its stored setting, the first time Max
    /// Heart Rate is actually known and as long as that particular boundary
    /// hasn't been set yet (by hand, or by an earlier prefill) – same
    /// one-time-default pattern as `prefillHeartRateProfileIfNeeded()`. Safe
    /// to call repeatedly: each field's own `== 0` guard makes every call
    /// after the first a no-op. Doesn't wait on Resting Heart Rate
    /// specifically – if it's still `0` at this point, the boundary formula
    /// itself already degrades gracefully to the plain %-of-max fallback.
    private func prefillHeartRateZonesIfNeeded() {
        guard maxHeartRateBPM > 0 else { return }
        if zone2LowerBPM == 0 { zone2LowerBPM = HeartRateZone.two.defaultLowerBoundBPM(maxHeartRateBPM: maxHeartRateBPM, restingHeartRateBPM: restingHeartRateBPM) }
        if zone3LowerBPM == 0 { zone3LowerBPM = HeartRateZone.three.defaultLowerBoundBPM(maxHeartRateBPM: maxHeartRateBPM, restingHeartRateBPM: restingHeartRateBPM) }
        if zone4LowerBPM == 0 { zone4LowerBPM = HeartRateZone.four.defaultLowerBoundBPM(maxHeartRateBPM: maxHeartRateBPM, restingHeartRateBPM: restingHeartRateBPM) }
        if zone5LowerBPM == 0 { zone5LowerBPM = HeartRateZone.five.defaultLowerBoundBPM(maxHeartRateBPM: maxHeartRateBPM, restingHeartRateBPM: restingHeartRateBPM) }
    }

    /// `Slider` needs a `Binding<Double>`; the stored value is an `Int`
    /// percentage (0–100).
    private var volumePercentBinding: Binding<Double> {
        Binding(
            get: { Double(intervalSoundVolumePercent) },
            set: { intervalSoundVolumePercent = Int($0.rounded()) }
        )
    }
}

/// A small ℹ️ button next to a section header that reveals `text` in a
/// compact popover when tapped – used instead of a permanent footer under
/// each section, so the settings screen stays a reasonable height now that
/// there are several sections each with their own explanation. `.popover`
/// adapts to a sheet-like presentation on iPhone's compact width on its own;
/// `popoverContent` below opts back into a small bubble there too, from
/// iOS 16.4 on.
private struct InfoButton: View {
    let text: LocalizedStringKey
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "info.circle")
                .imageScale(.small)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        // A section header isn't itself tappable, so this doesn't need
        // anything extra to avoid stealing taps meant for the header area.
        .popover(isPresented: $isPresented) {
            popoverContent
        }
    }

    /// `.presentationCompactAdaptation(.popover)` – which keeps this a small
    /// bubble even on iPhone's compact width, instead of the default
    /// adaptation's full sheet – needs iOS 16.4; the app's deployment target
    /// is 16.0, so it's applied conditionally. Pre-16.4 this still works
    /// fine, just as a sheet instead of a bubble.
    @ViewBuilder
    private var popoverContent: some View {
        let content = Text(text)
            .font(.footnote)
            .padding()
            .frame(idealWidth: 280)
        if #available(iOS 16.4, *) {
            content.presentationCompactAdaptation(.popover)
        } else {
            content
        }
    }
}
