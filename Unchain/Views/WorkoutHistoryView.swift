import SwiftUI

/// Every workout `WorkoutSession.reset()` has ever saved locally (see
/// `WorkoutHistoryStore`) – independent of, and unaffected by, whatever was
/// separately decided about saving to Apple Health at the time. Reached
/// from the bottom of `SettingsView`, same as `LogWorkoutView`/
/// `DiagnosticsView` – not tied to a trainer connection either.
struct WorkoutHistoryView: View {
    @State private var records: [WorkoutRecord] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if records.isEmpty {
                    emptyView
                } else {
                    List {
                        ForEach(records) { record in
                            NavigationLink {
                                WorkoutHistoryDetailView(record: record)
                            } label: {
                                WorkoutHistoryRow(record: record)
                            }
                        }
                        .onDelete(perform: deleteRecords)
                    }
                }
            }
            .navigationTitle("Workout History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear {
            records = WorkoutHistoryStore.loadAll()
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "figure.run.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No workouts saved yet")
                .font(.headline)
            Text("Every workout you finish is kept here automatically, whether or not you also save it to Apple Health.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    private func deleteRecords(at offsets: IndexSet) {
        for index in offsets {
            WorkoutHistoryStore.delete(records[index])
        }
        records.remove(atOffsets: offsets)
    }
}

private struct WorkoutHistoryRow: View {
    let record: WorkoutRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbolName)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.programName ?? record.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.headline)
                Text(record.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedDuration(record.activeDuration))
                    .font(.subheadline)
                    .monospacedDigit()
                if let distanceMeters = record.distanceMeters {
                    Text(formattedDistance(distanceMeters))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var symbolName: String {
        switch record.machineKind {
        case .bike: return "figure.outdoor.cycle"
        case .treadmill: return "figure.run"
        case .unknown: return "questionmark.circle"
        }
    }
}

/// Full stats for one saved workout, plus its `.tcx` export – the file this
/// screen builds via `TCXExporter` is written to a temporary location purely
/// so `ShareLink` has a real file `URL` to hand to the share sheet; nothing
/// in this app ever reads it back afterward.
struct WorkoutHistoryDetailView: View {
    let record: WorkoutRecord

    var body: some View {
        Form {
            Section {
                LabeledContent("Date", value: record.startDate.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Duration", value: formattedDuration(record.activeDuration))
                if let distanceMeters = record.distanceMeters {
                    LabeledContent("Distance", value: formattedDistance(distanceMeters))
                }
                if let workDoneKilojoules = record.workDoneKilojoules {
                    LabeledContent("Work Done", value: String(format: "%.0f kJ", workDoneKilojoules))
                }
            }
            if !record.heartRateZoneSeconds.isEmpty {
                Section {
                    HeartRateZonesView(zoneSeconds: record.heartRateZoneSeconds)
                } header: {
                    Text("Time in Heart Rate Zones")
                }
            }
            if let estimatedVO2Max = record.estimatedVO2Max {
                Section {
                    LabeledContent("Estimated VO2max", value: String(format: "%.1f ml/kg/min", estimatedVO2Max))
                } header: {
                    HStack(spacing: 4) {
                        Text("Fitness")
                        InfoButton(text: "Estimated from a held steady-effort segment of this workout's .zwo program, using your Max/Resting Heart Rate – not a measurement (that needs lab equipment analyzing your actual breath), typically ±10–15% off a real test. Never saved to Apple Health.")
                    }
                }
            }
            Section {
                ShareLink(item: exportURL, preview: SharePreview(TCXExporter.suggestedFileName(for: record))) {
                    Label("Export as .tcx", systemImage: "square.and.arrow.up")
                }
            } footer: {
                Text("A standard file most training/analysis tools (Strava, TrainingPeaks, Golden Cheetah, …) can import.")
            }
        }
        .navigationTitle(record.programName ?? String(localized: "Workout"))
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Written once per detail-view appearance, not cached – cheap (a few
    /// hundred rows of plain text at most) and this way it's always exactly
    /// today's `TCXExporter` output, not a stale file from an earlier
    /// version of it left behind in `/tmp`.
    private var exportURL: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(TCXExporter.suggestedFileName(for: record))
        try? TCXExporter.data(for: record).write(to: url, options: .atomic)
        return url
    }
}

private func formattedDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds)
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let secs = total % 60
    return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
}

private func formattedDistance(_ meters: Double) -> String {
    meters >= 1000 ? String(format: "%.2f km", locale: .current, meters / 1000) : String(format: "%.0f m", locale: .current, meters)
}
