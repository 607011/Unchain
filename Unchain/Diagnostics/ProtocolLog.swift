import Foundation

/// Development-time protocol log: every Bluetooth packet in both directions
/// (as hex, with the characteristic it belongs to), every relevant app
/// event (launch, background/foreground, button presses), and every change
/// to a workout-relevant variable – each line stamped to the microsecond.
/// Off by default – switched on in Settings → Protocol Log – and written to
/// Application Support, not Documents, so it never shows up in the Files app
/// on its own; exported explicitly via the share sheet from the same screen.
///
/// Not a crash/hang reporter (that's `DiagnosticsReporter`, which MetricKit
/// feeds on its own) – this one exists to explain, after the fact, *why* a
/// given value on screen ended up what it did: which packet arrived, which
/// command went out, and which state changed in between.
///
/// Heart rate values are logged too, since they travel the same way as the
/// trainer's packets – the log stays on the device, same as the rest of the
/// app's local data, and is shared only when the rider chooses to.
enum ProtocolLog {
    enum Category: String {
        case app, ui, rx, tx, ble, hr, workout
    }

    static let enabledKey = "protocolLogEnabled"
    private static let directoryName = "ProtocolLog"
    /// One file per app launch, so a single session is easy to find and
    /// share on its own. Pruned to the newest `keptFileCount` on launch.
    private static let keptFileCount = 10

    /// Serial, so writes never interleave and never block the BLE callbacks
    /// that produce them.
    private static let queue = DispatchQueue(label: "net.ersatzworld.unchain.protocollog", qos: .utility)
    private static var handle: FileHandle?
    private static var handleURL: URL?

    /// Fixed for this process – the file a launch writes to.
    private static let launchFileName: String = {
        let stamp = launchStampFormatter.string(from: Date())
        return "protocol-\(stamp).log"
    }()

    private static let launchStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// Records one line. `message` is only evaluated when logging is on, so
    /// callers can build a description without paying for it otherwise.
    static func log(_ category: Category, _ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let date = Date()
        let text = message()
        queue.async {
            write("\(timestamp(for: date)) [\(category.rawValue)] \(text)\n")
        }
    }

    /// Lowercase hex, space-separated – the same form the BLE traces in
    /// `TrainerConnection` already print, so logs read the same way.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    /// Every protocol log file on disk, newest first.
    static func logFileURLs() -> [URL] {
        guard let directory = directoryURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        return urls
            .filter { $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Removes every stored log file. Closes the current one first, so a
    /// running launch just starts writing a fresh file on its next line.
    static func deleteAll() {
        queue.sync {
            try? handle?.close()
            handle = nil
            handleURL = nil
        }
        for url in logFileURLs() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Called once at launch: records the launch itself and prunes old files.
    static func startSession() {
        queue.async {
            prune()
        }
        log(.app, "launch")
    }

    // MARK: - Private

    private static var directoryURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = base.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Microsecond-resolution wall-clock time, `yyyy-MM-dd HH:mm:ss.ffffff`.
    /// Built on the caller's thread, before the queue hop, so it reflects
    /// when the event happened, not when it got written. Uses a plain
    /// `Calendar` breakdown rather than `DateFormatter`, which isn't
    /// documented as thread-safe and is hit from several BLE/UI threads.
    private static func timestamp(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let seconds = date.timeIntervalSince1970
        let micros = Int((seconds - seconds.rounded(.down)) * 1_000_000)
        return String(format: "%04ld-%02ld-%02ld %02ld:%02ld:%02ld.%06ld",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0, micros)
    }

    /// Only ever called from `queue`.
    private static func write(_ line: String) {
        guard let url = currentFileURL(), let data = line.data(using: .utf8) else { return }
        if handle == nil || handleURL != url {
            try? handle?.close()
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: url)
            _ = try? handle?.seekToEnd()
            handleURL = url
        }
        try? handle?.write(contentsOf: data)
    }

    private static func currentFileURL() -> URL? {
        directoryURL?.appendingPathComponent(launchFileName)
    }

    /// Only ever called from `queue`.
    private static func prune() {
        let urls = logFileURLs()
        guard urls.count > keptFileCount else { return }
        for url in urls.dropFirst(keptFileCount) where url != currentFileURL() {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
