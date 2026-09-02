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
                        TextField("e.g. 1.5", text: inclineSecondsText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Seconds per 1° Incline")
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("Incline Response")
                        InfoButton(text: "How long this treadmill actually takes to reach a new incline once commanded, per degree changed – e.g. 1.5 means a 2° change takes about 3 seconds to settle. Leave empty if you don't know it; a future step will use this to smooth out .zwo incline changes.")
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
}
