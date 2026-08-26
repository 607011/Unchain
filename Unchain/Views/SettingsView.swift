import SwiftUI

/// App-wide settings, not tied to any particular trainer connection – opened
/// via the gear icon in `ControlView`'s toolbar. The rider's FTP, used to
/// interpret %FTP-based workout files (see `WorkoutProgramParser.parse`,
/// which already reads FTP from a file's own header when present – this is
/// for the app's own reference instead, e.g. for files that don't declare
/// one); Vibration/Interval Sound for Program workouts; and an explicit
/// Language override (see `LanguageManager`), which defaults to following
/// the device's own Language & Region setting. More settings are expected to
/// land here over time.
struct SettingsView: View {
    /// `UserDefaults` key for the rider's FTP – shared here since
    /// `CreateWorkoutView`'s shorthand workout notation (`%FTP` targets) also
    /// needs to read it, not just this settings screen.
    static let ftpWattsKey = "userFTPWatts"

    @AppStorage(ftpWattsKey) private var ftpWatts: Int = 188
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

    /// `Slider` needs a `Binding<Double>`; the stored value is an `Int`
    /// percentage (0–100).
    private var volumePercentBinding: Binding<Double> {
        Binding(
            get: { Double(intervalSoundVolumePercent) },
            set: { intervalSoundVolumePercent = Int($0.rounded()) }
        )
    }
}
