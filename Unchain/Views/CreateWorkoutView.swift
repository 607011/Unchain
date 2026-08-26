import SwiftUI
import Charts

/// Sheet for typing a workout directly in the app via the shorthand notation
/// `ShorthandWorkoutParser` understands, as an offline alternative to
/// sourcing an actual `.erg`/`.mrc` file for something simple. Parses live
/// as the user types, showing either the resulting profile or a specific
/// error, and only enables Save once there's a valid result.
struct CreateWorkoutView: View {
    @AppStorage(SettingsView.ftpWattsKey) private var ftpWatts: Int = 188
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var shorthandText: String = ""
    @State private var parseErrorMessage: String?
    @State private var previewProgram: WorkoutProgram?

    /// Called with the parsed program once the user taps Save – the caller
    /// (`ControlView`) is what actually loads it into the session and
    /// records it as a Recent, exactly like a file-loaded one.
    let onSave: (WorkoutProgram) -> Void

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
                    Text("e.g. \"10min 60%FTP, 4x(5min 105%FTP, 3min 50%FTP), 10min 55%FTP\". Durations: min or s. Targets: %FTP or W. A ramp within one step: \"20min 100W->300W\".")
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
            }
            .navigationTitle("Create Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let previewProgram else { return }
                        onSave(previewProgram)
                        dismiss()
                    }
                    .disabled(previewProgram == nil)
                }
            }
        }
    }

    private func tryParse() {
        guard !shorthandText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            previewProgram = nil
            parseErrorMessage = nil
            return
        }
        switch ShorthandWorkoutParser.parse(shorthandText, name: name, ftpWatts: ftpWatts > 0 ? ftpWatts : nil) {
        case .success(let program):
            previewProgram = program
            parseErrorMessage = nil
        case .failure(let error):
            previewProgram = nil
            parseErrorMessage = error.localizedDescription
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
