import SwiftUI

/// Settings → Protocol Log. The on/off switch lives in `SettingsView`; this
/// screen lists what's been recorded and shares it. Each app launch gets its
/// own file (see `ProtocolLog`), so a session can be shared on its own.
struct ProtocolLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var files: [URL] = ProtocolLog.logFileURLs()

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
                    }
                }
            }
            .navigationTitle("Protocol Log")
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
            Image(systemName: "doc.plaintext")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No Protocol Log Yet")
                .font(.headline)
            Text("Turn on Protocol Log in Settings, then use the app. What it records shows up here, one file per launch.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private func row(for file: URL) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.deletingPathExtension().lastPathComponent).font(.headline)
                Text(sizeLabel(for: file)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: file) {
                Image(systemName: "square.and.arrow.up")
            }
            .buttonStyle(.borderless)
        }
    }

    private func sizeLabel(for file: URL) -> String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func deleteAll() {
        ProtocolLog.deleteAll()
        files = ProtocolLog.logFileURLs()
    }
}
