import SwiftUI

/// Lists locally saved MetricKit crash/hang diagnostics – see
/// `DiagnosticsReporter`'s own doc comment for what's actually captured and
/// why. Not itself where a crash gets decoded or explained – each entry is
/// still the raw JSON MetricKit produced; tapping the share icon just offers
/// to export the file (AirDrop/Mail/Files/…), since there's no backend to
/// send it to automatically.
struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = DiagnosticsReporter.savedDiagnostics()

    var body: some View {
        NavigationStack {
            Group {
                if files.isEmpty {
                    emptyView
                } else {
                    List {
                        ForEach(files, id: \.self) { file in
                            row(for: file)
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
                if !files.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Delete All", role: .destructive) { deleteAll() }
                    }
                }
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Diagnostics Yet")
                .font(.headline)
            Text("Crash and hang reports collected by iOS show up here – usually not until the next time the app is opened after one happens.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func row(for file: URL) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(dateLabel(for: file)).font(.headline)
                Text("Tap to share").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: file) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
        }
    }

    private func dateLabel(for file: URL) -> String {
        guard let date = DiagnosticsReporter.date(for: file) else {
            return file.lastPathComponent
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            DiagnosticsReporter.delete(files[index])
        }
        files = DiagnosticsReporter.savedDiagnostics()
    }

    private func deleteAll() {
        DiagnosticsReporter.deleteAll()
        files = DiagnosticsReporter.savedDiagnostics()
    }
}
