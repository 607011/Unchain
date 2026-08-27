import SwiftUI

/// App-wide settings, not tied to any particular trainer connection – opened
/// via the gear icon in `ControlView`'s toolbar. The rider's FTP, used to
/// interpret %FTP-based workout files (see `WorkoutProgramParser.parse`,
/// which already reads FTP from a file's own header when present – this is
/// for the app's own reference instead, e.g. for files that don't declare
/// one); Max Heart Rate, used for the live heart rate zones (see
/// `HeartRateZone`); Vibration/Interval Sound for Program workouts; and an
/// explicit Language override (see `LanguageManager`), which defaults to
/// following the device's own Language & Region setting. More settings are
/// expected to land here over time.
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

    @AppStorage(ftpWattsKey) private var ftpWatts: Int = 188
    @AppStorage(maxHeartRateBPMKey) private var maxHeartRateBPM: Int = 0
    @AppStorage(WorkoutSession.vibrationEnabledKey) private var isVibrationEnabled = false
    @AppStorage(WorkoutSession.intervalSoundTypeKey) private var intervalSoundType = IntervalSoundType.single
    @AppStorage(WorkoutSession.intervalSoundVolumeKey) private var intervalSoundVolumePercent: Int = 0
    @AppStorage(LanguageManager.storageKey) private var languageOverride = AppLanguage.system.rawValue
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("e.g. 250", text: ftpText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("FTP (Watts)")
                } footer: {
                    Text("Your Functional Threshold Power.")
                }
                Section {
                    TextField("e.g. 185", text: maxHeartRateText)
                        .keyboardType(.numberPad)
                } header: {
                    Text("Max Heart Rate (bpm)")
                } footer: {
                    Text("Used for the live heart rate zones. Pre-filled with an age-based estimate (Tanaka formula) from your date of birth in Health – enter your own if you know it more precisely, e.g. from a lab or max-effort test.")
                }
                Section {
                    Toggle("Vibration", isOn: $isVibrationEnabled)
                } footer: {
                    Text("Briefly vibrates whenever a Program workout (.erg/.mrc) reaches its next scheduled entry.")
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
                    Text("Interval Sound")
                } footer: {
                    Text("Plays alongside Vibration when a Program workout reaches its next scheduled entry. Volume 0 % stays silent. \"Countdown\" adds one beep a second for the four seconds before, on top of the one for the entry itself.")
                }
                Section {
                    Picker("Language", selection: $languageOverride) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language.rawValue)
                        }
                    }
                } footer: {
                    Text("Applies immediately, no restart needed. \"System\" follows your device's own Language & Region setting.")
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
        .onAppear { prefillMaxHeartRateIfNeeded() }
    }

    /// A `TextField` bound directly to `ftpWatts` would show a persistent
    /// "0" before anything's entered – this shows an empty field with a
    /// placeholder instead, since `@AppStorage` has no natural `Int?` support.
    private var ftpText: Binding<String> {
        Binding(
            get: { ftpWatts == 0 ? "" : String(ftpWatts) },
            set: { ftpWatts = Int($0) ?? 0 }
        )
    }

    /// Same "0 shows as empty" treatment as `ftpText` above.
    private var maxHeartRateText: Binding<String> {
        Binding(
            get: { maxHeartRateBPM == 0 ? "" : String(maxHeartRateBPM) },
            set: { maxHeartRateBPM = Int($0) ?? 0 }
        )
    }

    /// Only runs while nothing's been entered yet (manually, or by a
    /// previous prefill) – `HealthKitManager.fetchMaxHeartRateBPM` prompts
    /// for Health authorization the first time, so this deliberately waits
    /// until the field that actually needs the answer is on screen, rather
    /// than asking eagerly at app launch.
    private func prefillMaxHeartRateIfNeeded() {
        guard maxHeartRateBPM == 0 else { return }
        HealthKitManager.shared.fetchMaxHeartRateBPM { bpm in
            guard let bpm, maxHeartRateBPM == 0 else { return }
            maxHeartRateBPM = bpm
        }
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
