import SwiftUI

/// Device-specific settings for one remembered trainer (`KnownTrainerDevice`)
/// – reached by tapping a row under `SettingsView`'s Devices section.
/// Deliberately takes just the lightweight, persisted `KnownTrainerDevice`
/// rather than a live `TrainerConnection` – these settings need to be
/// reachable (and editable) whether or not that particular trainer happens
/// to be connected right now, same reasoning as the rest of `SettingsView`.
struct TrainerDeviceSettingsView: View {
    let device: KnownTrainerDevice
    @State private var settings = TrainerDeviceSettings()

    var body: some View {
        Form {
            switch device.machineKind {
            case .treadmill:
                Section {
                    LabeledContent {
                        TextField("e.g. 3", text: startCountdownSecondsText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Start Countdown (seconds)")
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("Start Countdown")
                        InfoButton(text: "How many seconds this treadmill counts down on its own console (\"3, 2, 1, go\") after Unchain sends Start/Resume, before the belt actually starts moving. Used to hold the workout program's own clock at 0 for that long too, so its displayed elapsed time and interval changes stay in sync with when the treadmill is actually moving, instead of running ahead of it. Leave empty (0 seconds) if this treadmill starts immediately.")
                    }
                }
                Section {
                    LabeledContent {
                        TextField("e.g. 1.5", text: inclineSecondsText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Seconds per 1° Incline")
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("Incline Response")
                        InfoButton(text: "How long this treadmill actually takes to reach a new incline once commanded, per degree changed – e.g. 1.5 means a 2° change takes about 3 seconds to settle. Used to pace how fast the belt speed ramps to its next target during a .zwo interval change, instead of jumping there immediately while the incline is still catching up. Leave empty to assume 1 second per degree.")
                    }
                }
            case .bike, .unknown:
                Section {
                    Text("No device-specific settings yet for this trainer.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            settings = TrainerDeviceSettingsStore.load(for: device.id)
        }
        .onChange(of: settings) { newValue in
            TrainerDeviceSettingsStore.save(newValue, for: device.id)
        }
    }

    /// Accepts a comma as the decimal separator too, not just a period –
    /// the more natural key most German-locale keyboards actually offer on
    /// `.decimalPad`. `nil` (shown as an empty field, same "zero/empty"
    /// convention `SettingsView.zeroAsEmptyText` uses for its own numeric
    /// fields) rather than `0` when nothing's been entered, so an
    /// unmeasured device stays visibly unmeasured instead of silently
    /// reading as "instant".
    private var inclineSecondsText: Binding<String> {
        Binding(
            get: { settings.inclineChangeSecondsPerDegree.map { String(format: "%.1f", $0) } ?? "" },
            set: { settings.inclineChangeSecondsPerDegree = Double($0.replacingOccurrences(of: ",", with: ".")) }
        )
    }

    /// Same comma-accepting, empty-means-unset shape as `inclineSecondsText`
    /// above.
    private var startCountdownSecondsText: Binding<String> {
        Binding(
            get: { settings.startCountdownSeconds.map { String(format: "%.1f", $0) } ?? "" },
            set: { settings.startCountdownSeconds = Double($0.replacingOccurrences(of: ",", with: ".")) }
        )
    }
}
