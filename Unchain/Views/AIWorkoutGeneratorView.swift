import SwiftUI
import Charts

/// Sheet for generating a workout from a free-form natural-language request
/// via on-device AI (see `AIWorkoutGenerator`) – the AI counterpart to
/// typing one in via `CreateWorkoutView`'s shorthand notation. Unlike that
/// view, this works for both machine kinds in one place, since a
/// natural-language request has no format restriction the way the
/// shorthand grammar does – `machineKind` just decides which of
/// `AIWorkoutGenerator`'s two generation calls (and which preview/save
/// path) is used.
struct AIWorkoutGeneratorView: View {
    let machineKind: MachineKind
    /// Folded into the request so the model can reason about power targets
    /// relative to it – `nil` when the rider hasn't set one (see
    /// `SettingsView.ftpWattsKey`). Unused for a treadmill request.
    let ftpWatts: Int?
    /// Called with the parsed program once the rider taps Save – exactly
    /// the same closures `ControlView` already hands `CreateWorkoutView`/
    /// its own file-import path, so an AI-generated workout is loaded and
    /// recorded as a Recent identically to any other source.
    let onSaveTreadmillProgram: (TreadmillWorkoutProgram) -> Void
    let onSaveProgram: (WorkoutProgram) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var promptText: String = ""
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var previewTreadmillProgram: TreadmillWorkoutProgram?
    @State private var previewProgram: WorkoutProgram?

    var body: some View {
        NavigationStack {
            Form {
                // `#available` right here (rather than only inside
                // `AIWorkoutGeneratorAvailability.isAvailable`, which is a
                // plain runtime `Bool`) is what actually lets the compiler
                // allow this branch's own call to `generate()` below –
                // a `Bool` alone, however it's computed, never satisfies a
                // static availability check the way a literal `#available`
                // condition does.
                if #available(iOS 26.0, *), AIWorkoutGeneratorAvailability.isAvailable {
                    Section {
                        TextEditor(text: $promptText)
                            .frame(minHeight: 100)
                            .disabled(isGenerating)
                    } header: {
                        Text("What kind of workout?")
                    } footer: {
                        Text(examplePromptText)
                    }
                    Section {
                        Button {
                            generate()
                        } label: {
                            if isGenerating {
                                HStack {
                                    ProgressView()
                                    Text("Generating …")
                                }
                            } else {
                                Text("Generate")
                            }
                        }
                        .disabled(isGenerating || promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let errorMessage {
                        Section {
                            Label(errorMessage, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .font(.footnote)
                        }
                    }
                    if let previewTreadmillProgram {
                        Section {
                            Text(previewTreadmillProgram.name).font(.headline)
                            AIGeneratedTreadmillPreview(program: previewTreadmillProgram)
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
                    if let previewProgram {
                        Section {
                            Text(previewProgram.name).font(.headline)
                            AIGeneratedBikePreviewChart(program: previewProgram)
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
                } else {
                    Section {
                        Label(unavailableMessage, systemImage: "sparkles")
                            .foregroundStyle(.secondary)
                    } footer: {
                        // Spelled out once, here, rather than as a tooltip on
                        // the button that opens this sheet – there's nowhere
                        // to put an explanation there without it competing
                        // with `workoutSourceButtons`' other two buttons.
                        Text("Generating a workout with AI runs entirely on this device via Apple Intelligence – nothing is sent anywhere over the network.")
                    }
                }
            }
            .navigationTitle("Generate with AI")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let previewTreadmillProgram {
                            onSaveTreadmillProgram(previewTreadmillProgram)
                        } else if let previewProgram {
                            onSaveProgram(previewProgram)
                        }
                        dismiss()
                    }
                    .disabled(previewTreadmillProgram == nil && previewProgram == nil)
                }
            }
        }
    }

    private var unavailableMessage: String {
        guard #available(iOS 26.0, *) else {
            return String(localized: "Generating a workout with AI needs iOS 26 or later.")
        }
        return AIWorkoutGeneratorAvailability.unavailableReason ?? String(localized: "On-device AI isn't available right now.")
    }

    private var examplePromptText: String {
        machineKind == .treadmill
            ? String(localized: "e.g. \"30 minutes with 5x3 minute hill intervals at 8% incline, easy jogging in between\"")
            : String(localized: "e.g. \"45 minutes with 4x5 minute sweet-spot intervals at 88% FTP\"")
    }

    /// Only ever actually called from within the `isFeatureAvailable`
    /// branch above, so `AIWorkoutGenerator`'s own iOS 26 requirement is
    /// always satisfied by the time this runs – but marked `@available`
    /// itself too regardless, rather than relying on that alone, so a
    /// future call site added elsewhere would fail to compile instead of
    /// crashing at runtime if it forgot the same guard.
    @available(iOS 26.0, *)
    private func generate() {
        let prompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        isGenerating = true
        errorMessage = nil
        previewTreadmillProgram = nil
        previewProgram = nil
        Task {
            switch machineKind {
            case .treadmill:
                switch await AIWorkoutGenerator.generateTreadmillProgram(prompt: prompt) {
                case .success(let program):
                    previewTreadmillProgram = program
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            case .bike, .unknown:
                switch await AIWorkoutGenerator.generateBikeProgram(prompt: prompt, ftpWatts: ftpWatts) {
                case .success(let program):
                    previewProgram = program
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
            }
            isGenerating = false
        }
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// A static, non-interactive list of a generated treadmill workout's
/// segments for this sheet's own preview – unlike `ControlView`'s own
/// `TreadmillProgramSegmentList`, there's no live playback position to
/// track or jump to yet (the program hasn't been loaded into the session
/// until Save is tapped), so this is just the plain segment values.
private struct AIGeneratedTreadmillPreview: View {
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

/// A minimal, static power-profile chart for this sheet's own preview –
/// the `WorkoutProgram` counterpart of the treadmill list above, and
/// otherwise identical to `CreateWorkoutView`'s own `ShorthandPreviewChart`.
private struct AIGeneratedBikePreviewChart: View {
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
