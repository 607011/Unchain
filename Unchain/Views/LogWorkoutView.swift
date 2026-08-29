import SwiftUI
import HealthKit

/// Lets the rider add a workout to Health that was never recorded live in
/// Unchain – e.g. a ride/walk/run done without the app running, or one
/// whose live save silently failed (see the HealthKit read-permission bug
/// fixed this session) and can't be replayed after the fact. Reuses
/// `HealthKitManager.save(_:as:)` and `WorkoutSummary` exactly as the live
/// post-workout save flow does (see `ControlView.save(_:as:)`) – same
/// calorie-estimate rules (a missing figure stays missing, never invented),
/// same error handling – just with hand-entered values standing in for what
/// a live session would otherwise have measured (so `heartRateSamples` and
/// `heartRateZoneSeconds` are always empty here; there's nothing to log
/// after the fact for either). Reached from the very bottom of
/// `SettingsView`, since it isn't tied to a trainer connection.
struct LogWorkoutView: View {
    private enum ActivityKind: String, CaseIterable, Identifiable {
        case cycling, walking, running

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .cycling: return String(localized: "Indoor Cycling")
            case .walking: return String(localized: "Indoor Walk")
            case .running: return String(localized: "Indoor Run")
            }
        }

        var machineKind: MachineKind { self == .cycling ? .bike : .treadmill }

        var activityType: HKWorkoutActivityType {
            switch self {
            case .cycling: return .cycling
            case .walking: return .walking
            case .running: return .running
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @State private var kind: ActivityKind = .cycling
    @State private var startDate = Date()
    @State private var durationMinutes = 0
    @State private var distanceMeters = 0
    @State private var avgPowerWatts = 0
    @State private var isSaving = false
    @State private var saveError: SaveErrorAlert?

    private var isValid: Bool { durationMinutes > 0 }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        ForEach(ActivityKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    // No `in: ...Date()` clamp on the start date – a rider
                    // might reasonably be logging this the morning after, at
                    // which point "now" has moved past when the ride ended
                    // but not past when it *started*; `isValid` already
                    // requires a positive duration, which is the actual
                    // constraint that matters.
                    DatePicker("Start", selection: $startDate)
                    LabeledContent {
                        TextField("e.g. 45", text: zeroAsEmptyText($durationMinutes))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Duration (min)")
                    }
                } header: {
                    Text("When")
                }
                Section {
                    LabeledContent {
                        TextField("e.g. 5000", text: zeroAsEmptyText($distanceMeters))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Distance (m)")
                    }
                    if kind == .cycling {
                        LabeledContent {
                            TextField("e.g. 180", text: zeroAsEmptyText($avgPowerWatts))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                        } label: {
                            Text("Avg Power (W)")
                        }
                    }
                } header: {
                    Text("Details (optional)")
                } footer: {
                    Text(detailsFooter)
                }
            }
            .navigationTitle("Log a Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!isValid || isSaving)
                }
            }
            .alert(item: $saveError) { error in
                Alert(title: Text("Not Saved"), message: Text(error.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    /// Only the cycling formula (kJ of work ≈ kcal, see `EnergyEstimator`)
    /// needs Avg Power; the walk/run formula needs distance and body weight
    /// (read from Health) instead, same as a live save.
    private var detailsFooter: LocalizedStringKey {
        kind == .cycling
            ? "Distance and average power are both optional, but average power is what enables a calorie estimate for cycling."
            : "Distance is optional, but without it there's no calorie estimate – walking/running needs it, along with your body weight from Health."
    }

    /// Same "0 shows as empty" `TextField` treatment used throughout
    /// `SettingsView` – kept local here rather than shared, since sharing it
    /// would mean either exposing `SettingsView`'s private helper or moving
    /// it somewhere both types would need to import from for a three-line
    /// function used by two views.
    private func zeroAsEmptyText(_ value: Binding<Int>) -> Binding<String> {
        Binding(
            get: { value.wrappedValue == 0 ? "" : String(value.wrappedValue) },
            set: { value.wrappedValue = Int($0) ?? 0 }
        )
    }

    private func save() {
        let duration = TimeInterval(durationMinutes * 60)
        let endDate = startDate.addingTimeInterval(duration)
        let workDoneKilojoules: Double? = (kind == .cycling && avgPowerWatts > 0)
            ? Double(avgPowerWatts) * duration / 1000
            : nil
        let summary = WorkoutSummary(
            machineKind: kind.machineKind,
            startDate: startDate,
            endDate: endDate,
            activeDuration: duration,
            distanceMeters: distanceMeters > 0 ? Double(distanceMeters) : nil,
            workDoneKilojoules: workDoneKilojoules,
            heartRateSamples: [],
            programName: nil,
            heartRateZoneSeconds: [:]
        )
        isSaving = true
        HealthKitManager.shared.save(summary, as: kind.activityType) { result in
            isSaving = false
            switch result {
            case .success:
                dismiss()
            case .failure(let error):
                saveError = SaveErrorAlert(message: error.localizedDescription)
            }
        }
    }
}

private struct SaveErrorAlert: Identifiable {
    let id = UUID()
    let message: String
}
