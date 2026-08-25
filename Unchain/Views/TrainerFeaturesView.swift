import SwiftUI

/// Sheet listing which FTMS features the connected trainer reports supporting,
/// parsed from the Fitness Machine Feature characteristic (0x2ACC). Shown from
/// the info button next to the trainer name in `ControlView`.
struct TrainerFeaturesView: View {
    let deviceName: String
    let features: FitnessMachineFeatures?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let features, !features.dataFeatures.isEmpty || !features.targetFeatures.isEmpty {
                    List {
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
