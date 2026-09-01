import SwiftUI
import CoreBluetooth

/// Sheet listing which FTMS features the connected trainer reports supporting,
/// parsed from the Fitness Machine Feature characteristic (0x2ACC). Shown from
/// the info button next to the trainer name in `ControlView`.
struct TrainerFeaturesView: View {
    let deviceName: String
    let features: FitnessMachineFeatures?
    /// Raw characteristics CoreBluetooth actually reported under the
    /// Fitness Machine Service – see `TrainerConnection
    /// .discoveredCharacteristics`'s own doc comment for why this exists:
    /// a treadmill that turned out to *also* expose Indoor Bike Data
    /// confused this app's bike-vs-treadmill detection, and there was no
    /// way to see that from within the app itself until now.
    let discoveredCharacteristics: [CBUUID]

    @Environment(\.dismiss) private var dismiss

    private var hasAnythingToShow: Bool {
        !discoveredCharacteristics.isEmpty || !(features?.dataFeatures.isEmpty ?? true) || !(features?.targetFeatures.isEmpty ?? true)
    }

    var body: some View {
        NavigationStack {
            Group {
                if hasAnythingToShow {
                    List {
                        if !discoveredCharacteristics.isEmpty {
                            Section {
                                ForEach(discoveredCharacteristics, id: \.self, content: characteristicRow)
                            } header: {
                                HStack(spacing: 4) {
                                    Text("Reported Characteristics")
                                    InfoButton(text: "Every characteristic this trainer actually exposed under the Fitness Machine Service, as reported by Bluetooth itself – not just the ones Unchain reads. Useful for spotting a device that exposes more than expected (e.g. a treadmill also exposing Indoor Bike Data).")
                                }
                            }
                        }
                        if let features {
                            if !features.dataFeatures.isEmpty {
                                Section("Reports") {
                                    ForEach(features.dataFeatures, id: \.self, content: featureRow)
                                }
                            }
                            if !features.targetFeatures.isEmpty {
                                Section("Adjustable Targets") {
                                    ForEach(features.targetFeatures, id: \.self, content: featureRow)
                                }
                            }
                        }
                    }
                } else {
                    unavailableView
                }
            }
            .navigationTitle(deviceName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    private func featureRow(_ name: String) -> some View {
        Label(name, systemImage: "checkmark.circle.fill")
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.primary)
    }

    private func characteristicRow(_ uuid: CBUUID) -> some View {
        HStack {
            Text(FTMS.characteristicName(for: uuid))
            Spacer()
            Text(uuid.uuidString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Feature Data")
                .font(.headline)
            Text("This trainer hasn't reported its supported features yet.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}
