import SwiftUI
import Charts

/// Sheet for typing a workout directly in the app via a compact shorthand
/// notation, as an offline alternative to sourcing an actual `.erg`/`.mrc`/
/// `.zwo` file for something simple. Parses live as the rider types,
/// showing either the resulting profile or a specific error, and only
/// enables Save once there's a valid result. Works for both machine kinds –
/// `machineKind` picks which grammar (`ShorthandWorkoutParser` for a bike's
/// power target, `TreadmillShorthandParser` for a treadmill's speed+incline)
/// and which preview (chart vs. segment list) actually apply; `ControlView`
/// only ever passes the closure the chosen grammar can actually produce a
/// result for, but both are accepted here regardless, the same "caller
/// supplies whichever it can use" shape `AIWorkoutGeneratorView` (tried and
/// abandoned on the `feature/ai-workout-generator` branch – see STATUS.md)
/// already used for the same reason.
struct CreateWorkoutView: View {
    let machineKind: MachineKind
    @AppStorage(SettingsView.ftpWattsKey) private var ftpWatts: Int = 188
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var shorthandText: String = ""
    @State private var parseErrorMessage: String?
    @State private var previewProgram: WorkoutProgram?
    @State private var previewTreadmillProgram: TreadmillWorkoutProgram?

    /// Called with the parsed program once the rider taps Save – the caller
    /// (`ControlView`) is what actually loads it into the session and
    /// records it as a Recent, exactly like a file-loaded one. Only one of
    /// these two ever fires for a given save, matching whichever of
    /// `previewProgram`/`previewTreadmillProgram` is actually set.
    let onSave: (WorkoutProgram) -> Void
    let onSaveTreadmillProgram: (TreadmillWorkoutProgram) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Custom Workout", text: $name)
                } header: {
                    Text("Name")
                }
                Section {
                    TextEditor(text: $shorthandText)
                        .frame(minHeight: 120)
                        .font(.system(.body, design: .monospaced))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: shorthandText) { _ in tryParse() }
                } header: {
                    Text("Workout")
                } footer: {
                    Text(grammarHint)
                }
                if let parseErrorMessage {
                    Section {
                        Label(parseErrorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
                if let previewProgram {
                    Section {
                        ShorthandPreviewChart(program: previewProgram)
                            .frame(height: 140)
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text(formattedDuration(previewProgram.duration))
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Preview")
                    }
                }
                if let previewTreadmillProgram {
                    Section {
                        TreadmillShorthandPreviewList(program: previewTreadmillProgram)
                        HStack {
                            Text("Duration")
                            Spacer()
                            Text(formattedDuration(previewTreadmillProgram.duration))
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Preview")
                    }
                }
            }
            .navigationTitle("Create Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let previewProgram {
                            onSave(previewProgram)
                        } else if let previewTreadmillProgram {
                            onSaveTreadmillProgram(previewTreadmillProgram)
                        } else {
                            return
                        }
                        dismiss()
                    }
                    .disabled(previewProgram == nil && previewTreadmillProgram == nil)
                }
            }
        }
    }

    private var grammarHint: String {
        machineKind == .treadmill
            ? String(localized: "e.g. \"5min 8km/h, 5x(3min 10km/h 6%, 2min 6km/h), 5min 8km/h\", or by distance: \"8x400m 12km/h\". Length: min/sec/h, or a distance – m/km/mi/yd/ft. Speed: km/h or mph. Incline is optional (default flat): 2%.")
            : String(localized: "e.g. \"10min 60%FTP, 4x(5min 105%FTP, 3min 50%FTP), 10min 55%FTP\". Durations: min or s. Targets: %FTP or W. A ramp within one step: \"20min 100W->300W\".")
    }

    private func tryParse() {
        guard !shorthandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previewProgram = nil
            previewTreadmillProgram = nil
            parseErrorMessage = nil
            return
        }
        switch machineKind {
        case .treadmill:
            previewProgram = nil
            switch TreadmillShorthandParser.parse(shorthandText, name: name) {
            case .success(let program):
                previewTreadmillProgram = program
                parseErrorMessage = nil
            case .failure(let error):
                previewTreadmillProgram = nil
                parseErrorMessage = error.localizedDescription
            }
        case .bike, .unknown:
            previewTreadmillProgram = nil
            switch ShorthandWorkoutParser.parse(shorthandText, name: name, ftpWatts: ftpWatts > 0 ? ftpWatts : nil) {
            case .success(let program):
                previewProgram = program
                parseErrorMessage = nil
            case .failure(let error):
                previewProgram = nil
                parseErrorMessage = error.localizedDescription
            }
        }
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// A minimal, static power-profile chart for the live preview while typing –
/// unlike `ControlView`'s `WorkoutProgramChart`, no zoom or live position
/// marker, since there's no playback position yet to mark.
private struct ShorthandPreviewChart: View {
    let program: WorkoutProgram

    var body: some View {
        Chart {
            ForEach(Array(program.breakpoints.enumerated()), id: \.offset) { _, breakpoint in
                LineMark(
                    x: .value("Time", breakpoint.timeSeconds),
                    y: .value("Power", breakpoint.value)
                )
                .interpolationMethod(.linear)
            }
        }
        .chartXAxisLabel("Time (s)")
        .chartYAxisLabel("Watts")
    }
}

/// The `TreadmillWorkoutProgram` counterpart to `ShorthandPreviewChart` –
/// a plain segment list rather than a chart, since a treadmill step is a
/// flat (speed, incline) pair rather than something a line chart's
/// interpolation would add anything to seeing directly as numbers.
private struct TreadmillShorthandPreviewList: View {
    let program: TreadmillWorkoutProgram

    var body: some View {
        ForEach(Array(program.segments.enumerated()), id: \.offset) { _, segment in
            HStack {
                Text(formattedDuration(segment.duration))
                    .frame(width: 44, alignment: .leading)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f km/h", locale: .current, segment.speedKmh))
                Spacer()
                Text(String(format: "%.1f %%", locale: .current, segment.inclinePercent))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
