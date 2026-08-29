import Foundation
import MetricKit

/// Captures MetricKit's crash/hang/CPU-exception diagnostics and saves each
/// batch to a local JSON file – the "simple way" to get crash reporting
/// without a backend, TestFlight, or the App Store: MetricKit is a plain OS
/// framework, so this works for any build, including one installed straight
/// from Xcode/`make run`. Trade-offs, per Apple's own docs: delivery can lag
/// up to a day behind the actual crash, and only arrives the next time the
/// app is relaunched – there's nothing to poll or trigger sooner.
///
/// Complements, rather than replaces, the OS's own on-device crash logs
/// (Settings → Privacy & Security → Analytics & Improvements → Analytics
/// Data, or Xcode's Devices window while the phone's connected) – this is
/// for catching one that happened while nobody was looking at either of
/// those, surfaced right in the app instead (see `DiagnosticsView`, reachable
/// from Settings).
final class DiagnosticsReporter: NSObject {
    static let shared = DiagnosticsReporter()

    private override init() {
        super.init()
    }

    /// Called once, from `UnchainApp.init()` – subscribes for the lifetime
    /// of the process. MetricKit itself decides when (and whether) anything
    /// actually arrives.
    func start() {
        MXMetricManager.shared.add(self)
    }

    private static var diagnosticsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Diagnostics", isDirectory: true)
    }

    /// `yyyyMMdd'T'HHmmss'Z'`, not a colon-containing ISO 8601 string –
    /// deliberately filename-safe (colons in a filename can trip up sharing
    /// to non-Apple systems, e.g. via AirDrop to Windows or a FAT-formatted
    /// drive), and its fixed-width, all-numeric fields still sort correctly
    /// as plain strings, which `savedDiagnostics()` relies on.
    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    /// All saved diagnostic files, newest first.
    static func savedDiagnostics() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: diagnosticsDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func deleteAll() {
        for url in savedDiagnostics() { delete(url) }
    }

    /// Parses the timestamp embedded in a saved diagnostics file's name
    /// (see `save(_:timestamp:)`) for `DiagnosticsView` to display –
    /// deliberately not the file's own creation/modification date, which
    /// would pull in the "File Timestamp APIs" required-reason category
    /// `PrivacyInfo.xcprivacy` would then need to declare a reason for.
    static func date(for url: URL) -> Date? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let range = name.range(of: "diagnostics-") else { return nil }
        return filenameDateFormatter.date(from: String(name[range.upperBound...]))
    }

    private func save(_ data: Data, timestamp: Date) {
        let directory = Self.diagnosticsDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "diagnostics-\(Self.filenameDateFormatter.string(from: timestamp)).json"
        try? data.write(to: directory.appendingPathComponent(filename))
    }
}

extension DiagnosticsReporter: MXMetricManagerSubscriber {
    /// Required by the protocol, but Unchain has no use for MetricKit's
    /// battery/performance metrics themselves – just the crash/hang
    /// diagnostics below.
    func didReceive(_ payloads: [MXMetricPayload]) {}

    /// One saved file per payload – each already bundles every crash/hang/
    /// CPU-exception/disk-write-exception diagnostic MetricKit collected for
    /// its time window as one JSON blob, so there's no need to pick apart
    /// individual diagnostic types here.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            save(payload.jsonRepresentation(), timestamp: payload.timeStampEnd)
        }
    }
}
