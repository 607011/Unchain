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
    /// The device's own reported ranges for the four "Supported … Range"
    /// characteristics (0x2AD4/0x2AD5/0x2AD6/0x2AD8) – shown as a value
    /// under the matching row in `characteristicRow(_:)` rather than just
    /// the bare characteristic name, since a range is exactly the kind of
    /// thing worth cross-checking against the spec/another app here. Each
    /// still starts at `TrainerConnection`'s own placeholder default until
    /// the real read completes, same as everywhere else these are used
    /// (e.g. `ControlView`'s manual +/- controls) – not specially guarded
    /// against here either.
    let speedRangeKmh: ClosedRange<Double>
    let inclinationRangePercent: ClosedRange<Double>
    let powerRange: ClosedRange<Int>
    let resistanceRangeRaw: ClosedRange<Int>

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
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(FTMS.characteristicName(for: uuid))
                Spacer()
                Text(uuid.uuidString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let value = rangeValue(for: uuid) {
                Text(value)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The device's own reported value for the four "Supported … Range"
    /// characteristics – `nil` (no second line shown) for every other
    /// characteristic in `discoveredCharacteristics`, which have no single
    /// scalar/range value worth summarizing this way.
    private func rangeValue(for uuid: CBUUID) -> String? {
        switch uuid {
        case FTMS.supportedSpeedRange:
            return String(format: "%.1f–%.1f km/h", locale: .current, speedRangeKmh.lowerBound, speedRangeKmh.upperBound)
        case FTMS.supportedInclinationRange:
            return String(format: "%.1f–%.1f %%", locale: .current, inclinationRangePercent.lowerBound, inclinationRangePercent.upperBound)
        case FTMS.supportedPowerRange:
            return "\(powerRange.lowerBound)–\(powerRange.upperBound) W"
        case FTMS.supportedResistanceLevelRange:
            // Same ×0.1 native-FTMS-unit scaling, no unit suffix, as
            // `ControlView.formattedResistanceRange` already uses for this
            // same range elsewhere – resistance level has no physical unit
            // of its own, just a device-defined scale.
            return String(format: "%.1f–%.1f", locale: .current, Double(resistanceRangeRaw.lowerBound) / 10, Double(resistanceRangeRaw.upperBound) / 10)
        default:
            return nil
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
