import Foundation
import UniformTypeIdentifiers

/// Which control primitive a loaded workout program drives.
enum ProgramTargetKind: Codable, Equatable {
    case power
    case resistance

    /// Which machine this target kind actually does something on. Today
    /// that's exclusively bikes: `.erg` (power) and `.mrc` (resistance) are
    /// both cycling-trainer formats sent via `setTargetPower`/
    /// `setTargetResistancePercent` — a treadmill mostly won't even support
    /// those FTMS targets (it needs Set Target Speed/Inclination instead,
    /// which this app doesn't drive), so a file wouldn't do anything useful
    /// there. Used to filter the "recent workouts" list to the connected
    /// machine — see `WorkoutProgramStore`.
    var compatibleMachineKind: MachineKind {
        switch self {
        case .power, .resistance: return .bike
        }
    }
}

/// One (time, target) breakpoint. A plain struct rather than a tuple so
/// `WorkoutProgram` can be `Codable` for persisting the last-loaded program
/// across launches (see `WorkoutProgramStore`) – tuples can't conform to
/// `Codable`.
struct WorkoutProgramBreakpoint: Codable, Equatable {
    let timeSeconds: Double
    let value: Int
}

/// A structured workout loaded from an `.erg` (power target, absolute watts)
/// or `.mrc` file – the de facto standard formats used by TrainerRoad, Golden
/// Cheetah, PerfPRO, TrainerDay, cyclingintervals.com, and others (see the
/// README for free sources). `.mrc` resolves to a power target too whenever
/// its header declares an FTP (percentages relative to that, converted to
/// watts at parse time); only a percent column *without* a declared FTP
/// resolves to a literal 0–100 % resistance target – see
/// `WorkoutProgramParser.parse`. Both formats share the same file structure:
/// a `[COURSE HEADER]` metadata block followed by `[COURSE DATA]`, a list of
/// (time in minutes, value) breakpoints. Between two consecutive breakpoints
/// the target is linearly interpolated – a flat block is simply two points
/// with the same value; a step change is two points at the same time with
/// different values.
struct WorkoutProgram: Codable, Equatable {
    let name: String
    let targetKind: ProgramTargetKind
    /// Sorted by time, in seconds from the start of the program.
    let breakpoints: [WorkoutProgramBreakpoint]

    var duration: TimeInterval { breakpoints.last?.timeSeconds ?? 0 }

    /// Index of the *last* breakpoint at or before `elapsed` – i.e. which
    /// file entry playback is currently past. A step change is encoded as
    /// two breakpoints sharing the same time with different values; picking
    /// the last one at that time means a tick landing exactly on the
    /// boundary already reads as the new step, not the old one for one extra
    /// second. `nil` before the first breakpoint or past the program's end.
    ///
    /// Exposed (rather than kept private to `target(atElapsedSeconds:)`, which
    /// uses it too) so a caller – see `WorkoutSession` – can tell when
    /// playback has crossed into a *new* file entry, as opposed to every
    /// second of continuous interpolation between two entries with different
    /// values; used there to fire a step-change vibration once per entry
    /// rather than continuously during a ramp.
    func breakpointIndex(atElapsedSeconds elapsed: TimeInterval) -> Int? {
        guard let first = breakpoints.first, elapsed >= first.timeSeconds, elapsed <= duration else { return nil }
        var lowerIndex = 0
        for index in breakpoints.indices where breakpoints[index].timeSeconds <= elapsed {
            lowerIndex = index
        }
        return lowerIndex
    }

    /// Elapsed-seconds time of the file entry right after `index`, i.e. when
    /// playback will next cross into a different entry – `nil` if `index` is
    /// already the last one. Always strictly greater than that entry's own
    /// time (see `breakpointIndex(atElapsedSeconds:)`: two entries sharing a
    /// time never both surface as "current"). Used to schedule anticipatory
    /// countdown beeps before a step change – see the "Interval Sound"
    /// setting in `WorkoutSession`.
    func nextTransitionTimeSeconds(afterIndex index: Int) -> TimeInterval? {
        let nextIndex = index + 1
        guard breakpoints.indices.contains(nextIndex) else { return nil }
        return breakpoints[nextIndex].timeSeconds
    }

    /// Linearly interpolated target at `elapsed` seconds into the program;
    /// `nil` once the program has run its full length (the workout is done –
    /// the rider decides what to do next, the app doesn't auto-stop).
    func target(atElapsedSeconds elapsed: TimeInterval) -> Int? {
        guard let first = breakpoints.first, elapsed <= duration else { return nil }
        guard elapsed >= first.timeSeconds else { return first.value }
        guard let lowerIndex = breakpointIndex(atElapsedSeconds: elapsed) else { return first.value }

        let lower = breakpoints[lowerIndex]
        guard lowerIndex + 1 < breakpoints.count else { return lower.value }
        let upper = breakpoints[lowerIndex + 1]
        guard upper.timeSeconds > lower.timeSeconds else { return upper.value }
        let fraction = (elapsed - lower.timeSeconds) / (upper.timeSeconds - lower.timeSeconds)
        let value = Double(lower.value) + fraction * Double(upper.value - lower.value)
        return Int(value.rounded())
    }

    /// Serializes back to the `.erg`/`.mrc` text format `WorkoutProgramParser`
    /// reads – the inverse operation, so a workout built from the shorthand
    /// notation (see `ShorthandWorkoutParser`), or just the currently loaded
    /// one, can be saved as a portable, plain-text file other apps can read
    /// too, not just kept inside Unchain's own "Recent" list. Always writes
    /// absolute values (`WATTS` for `.power`, literal `PERCENT` for
    /// `.resistance` – never an `FTP =` header), so re-parsing this output
    /// resolves to the same `targetKind` it started as.
    func fileContents() -> String {
        let columnLabel = targetKind == .power ? "WATTS" : "PERCENT"
        var lines = [
            "[COURSE HEADER]",
            "VERSION = 2",
            "UNITS = ENGLISH",
            "DESCRIPTION = \(name)",
            "MINUTES\t\(columnLabel)",
            "[END COURSE HEADER]",
            "[COURSE DATA]",
        ]
        for breakpoint in breakpoints {
            let minutes = breakpoint.timeSeconds / 60
            lines.append("\(String(format: "%.2f", minutes))\t\(breakpoint.value)")
        }
        lines.append("[END COURSE DATA]")
        return lines.joined(separator: "\n")
    }

    /// Suggested filename for exporting `fileContents()` – `.erg` for a
    /// power target, `.mrc` for resistance, matching how
    /// `WorkoutProgramParser` would interpret the extension on re-import.
    var suggestedFileName: String {
        let sanitized = name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined()
        let fileExtension = targetKind == .power ? "erg" : "mrc"
        return "\(sanitized.isEmpty ? "Workout" : sanitized).\(fileExtension)"
    }
}

enum WorkoutProgramParseError: LocalizedError {
    case unreadable
    case noCourseData

    var errorDescription: String? {
        switch self {
        case .unreadable: return "The file couldn't be read as text."
        case .noCourseData: return "No [COURSE DATA] section found – is this really an .erg/.mrc file?"
        }
    }
}

enum WorkoutProgramParser {
    /// `.erg`/`.mrc` aren't registered system types, so these are synthesized
    /// from the file extension – enough for a `.fileImporter` picker filter.
    /// Split by extension (rather than one combined list) so the picker can
    /// offer only the file type(s) whose target the connected machine
    /// actually supports – see `ControlView.allowedFileContentTypes`.
    static var ergContentType: UTType? { UTType(filenameExtension: "erg") }
    static var mrcContentType: UTType? { UTType(filenameExtension: "mrc") }

    /// `fileExtension` is used both as a fallback for whether the data column
    /// is watts or percent (before the header's own "MINUTES WATTS"/"MINUTES
    /// PERCENT" line is seen, if ever) and to name the program when no
    /// `DESCRIPTION` line is present.
    ///
    /// A percent column is *not* automatically a raw 0–100 % resistance
    /// target: real-world `.mrc` files (e.g. TrainerDay's exports) declare an
    /// `FTP = <value>` header field and mean the percentages relative to
    /// *that* – i.e. it's actually a power workout, just expressed as %FTP
    /// instead of absolute watts the way `.erg` does it. Only when a percent
    /// column has no FTP declared does this fall back to treating the number
    /// as a literal resistance percentage, for files that genuinely mean that.
    static func parse(text: String, fileExtension: String) -> Result<WorkoutProgram, Error> {
        var name = fileExtension.isEmpty ? "Workout" : "Workout (.\(fileExtension))"
        var isPercentColumn = fileExtension.lowercased() == "mrc"
        var ftp: Double?
        var targetKind: ProgramTargetKind = .power
        var breakpoints: [WorkoutProgramBreakpoint] = []
        var isInDataSection = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let upperLine = line.uppercased()

            if upperLine.hasPrefix("[COURSE DATA]") {
                isInDataSection = true
                // The header (where FTP, if any, would have appeared) is
                // fully read at this point – resolve the target kind once,
                // rather than re-deciding it on every data row.
                targetKind = (isPercentColumn && ftp == nil) ? .resistance : .power
                continue
            }
            if upperLine.hasPrefix("[END COURSE DATA]") {
                break
            }

            if isInDataSection {
                let fields = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                guard fields.count >= 2,
                      let minutes = Double(fields[0]),
                      let rawValue = Double(fields[1]) else { continue }
                let value: Int
                if isPercentColumn, let ftp {
                    value = Int((rawValue / 100 * ftp).rounded())
                } else {
                    value = Int(rawValue.rounded())
                }
                breakpoints.append(WorkoutProgramBreakpoint(timeSeconds: minutes * 60, value: value))
            } else if upperLine.hasPrefix("DESCRIPTION"), let equalsIndex = line.firstIndex(of: "=") {
                name = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
            } else if upperLine.hasPrefix("FTP"), let equalsIndex = line.firstIndex(of: "=") {
                ftp = Double(line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces))
            } else if upperLine.contains("PERCENT") {
                isPercentColumn = true
            } else if upperLine.contains("WATTS") {
                isPercentColumn = false
            }
        }

        guard !breakpoints.isEmpty else { return .failure(WorkoutProgramParseError.noCourseData) }
        breakpoints.sort { $0.timeSeconds < $1.timeSeconds }
        return .success(WorkoutProgram(name: name, targetKind: targetKind, breakpoints: breakpoints))
    }
}
