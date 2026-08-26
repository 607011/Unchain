import Foundation

/// Parses a compact, hand-typed interval notation into a `WorkoutProgram`,
/// as an offline alternative to sourcing an actual `.erg`/`.mrc` file for a
/// simple structured workout – see `CreateWorkoutView`. Grammar (informal):
///
/// ```
/// program     := segment (',' segment)*
/// segment     := repeatGroup | step
/// repeatGroup := INT 'x' '(' segment (',' segment)* ')'
/// step        := duration target ('->' target)?
/// duration    := NUMBER ('min'|'m'|'sec'|'s'|'h')
/// target      := NUMBER ('%FTP'|'W')
/// ```
///
/// e.g. `10min 60%FTP, 4x(5min 105%FTP, 3min 50%FTP), 10min 55%FTP`, or a
/// ramp within one step: `20min 100W->300W`. Deliberately power-only (no
/// resistance-percent target) and offline – no network call, unlike a true
/// free-form AI-generated workout would need (see the README's "Idea for
/// later" section for that bigger, opt-in alternative).
enum ShorthandWorkoutParser {
    static func parse(_ text: String, name: String, ftpWatts: Int?) -> Result<WorkoutProgram, ShorthandParseError> {
        let parser = Parser(ftpWatts: ftpWatts)
        switch parser.parseSegments(text) {
        case .failure(let error):
            return .failure(error)
        case .success(let segments):
            var cursor: TimeInterval = 0
            var breakpoints: [WorkoutProgramBreakpoint] = []
            flatten(segments, cursor: &cursor, into: &breakpoints)
            guard !breakpoints.isEmpty else { return .failure(.emptyInput) }
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            return .success(WorkoutProgram(name: trimmedName.isEmpty ? "Custom Workout" : trimmedName, targetKind: .power, breakpoints: breakpoints))
        }
    }

    /// Walks the parsed segment tree in order, expanding repeat groups and
    /// turning each step into a (start, end) pair of breakpoints – matching
    /// exactly how `WorkoutProgramParser` already encodes a flat block (two
    /// points, same value) or a step change (two points at the same time,
    /// different values); a ramp is simply two points with different values
    /// at different times, which `WorkoutProgram.target(atElapsedSeconds:)`
    /// already interpolates between.
    private static func flatten(_ segments: [ShorthandSegment], cursor: inout TimeInterval, into breakpoints: inout [WorkoutProgramBreakpoint]) {
        for segment in segments {
            switch segment {
            case .step(let durationSeconds, let startWatts, let endWatts):
                breakpoints.append(WorkoutProgramBreakpoint(timeSeconds: cursor, value: startWatts))
                cursor += durationSeconds
                breakpoints.append(WorkoutProgramBreakpoint(timeSeconds: cursor, value: endWatts))
            case .repeatGroup(let count, let inner):
                for _ in 0..<count {
                    flatten(inner, cursor: &cursor, into: &breakpoints)
                }
            }
        }
    }
}

enum ShorthandParseError: LocalizedError, Equatable {
    case emptyInput
    case invalidSegment(String)
    case invalidDuration(String)
    case invalidTarget(String)
    case missingFTP

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Type a workout, e.g. \"10min 60%FTP, 4x(5min 105%FTP, 3min 50%FTP), 10min 55%FTP\"."
        case .invalidSegment(let text):
            return "Couldn't understand \"\(text)\" – expected something like \"5min 250W\" or \"3x(...)\"."
        case .invalidDuration(let text):
            return "Couldn't understand the duration \"\(text)\" – use e.g. \"10min\" or \"90s\"."
        case .invalidTarget(let text):
            return "Couldn't understand the target \"\(text)\" – use e.g. \"250W\" or \"75%FTP\"."
        case .missingFTP:
            return "This workout uses %FTP, but no FTP is set – add one in Settings first."
        }
    }
}

/// One node of the parsed (but not yet time-expanded) workout tree.
private indirect enum ShorthandSegment {
    case step(durationSeconds: TimeInterval, startWatts: Int, endWatts: Int)
    case repeatGroup(count: Int, segments: [ShorthandSegment])
}

/// Holds `ftpWatts` for the duration of one parse so it doesn't need
/// threading through every recursive call individually.
private struct Parser {
    let ftpWatts: Int?

    func parseSegments(_ text: String) -> Result<[ShorthandSegment], ShorthandParseError> {
        let parts = splitTopLevel(text, separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return .failure(.emptyInput) }
        var segments: [ShorthandSegment] = []
        for part in parts {
            switch parseSegment(part) {
            case .success(let segment): segments.append(segment)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(segments)
    }

    /// Either a repeat group (`Nx(...)`) or a plain step – tried in that
    /// order, falling back to `parseStep` (and its error) whenever the text
    /// doesn't fully match the repeat-group shape, rather than a separate,
    /// potentially confusing error path.
    private func parseSegment(_ text: String) -> Result<ShorthandSegment, ShorthandParseError> {
        if let xIndex = text.firstIndex(where: { $0 == "x" || $0 == "X" }) {
            let countText = text[text.startIndex..<xIndex].trimmingCharacters(in: .whitespaces)
            let rest = text[text.index(after: xIndex)...].trimmingCharacters(in: .whitespaces)
            if let count = Int(countText), count > 0, rest.hasPrefix("("), rest.hasSuffix(")") {
                let inner = String(rest.dropFirst().dropLast())
                return parseSegments(inner).map { .repeatGroup(count: count, segments: $0) }
            }
        }
        return parseStep(text)
    }

    /// `"<duration> <target>"` or `"<duration> <target>-><target>"` for a
    /// ramp, e.g. `"10min 60%FTP"` or `"20min 100W->300W"` – exactly one
    /// space between duration and target (no internal spaces within either).
    private func parseStep(_ text: String) -> Result<ShorthandSegment, ShorthandParseError> {
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return .failure(.invalidSegment(text)) }
        guard case .success(let duration) = parseDuration(String(parts[0])) else {
            return .failure(.invalidDuration(String(parts[0])))
        }
        let rampParts = parts[1].components(separatedBy: "->")
        guard rampParts.count == 1 || rampParts.count == 2 else { return .failure(.invalidTarget(String(parts[1]))) }
        switch parseTarget(rampParts[0]) {
        case .failure(let error): return .failure(error)
        case .success(let startWatts):
            guard rampParts.count == 2 else {
                return .success(.step(durationSeconds: duration, startWatts: startWatts, endWatts: startWatts))
            }
            switch parseTarget(rampParts[1]) {
            case .failure(let error): return .failure(error)
            case .success(let endWatts):
                return .success(.step(durationSeconds: duration, startWatts: startWatts, endWatts: endWatts))
            }
        }
    }

    private func parseDuration(_ text: String) -> Result<TimeInterval, ShorthandParseError> {
        let lower = text.lowercased()
        // Longest suffix first so "min" is matched before the bare "m"/"s"
        // it would otherwise also (wrongly) match as a prefix of itself.
        let units: [(suffix: String, secondsPerUnit: TimeInterval)] = [
            ("min", 60), ("sec", 1), ("h", 3600), ("m", 60), ("s", 1),
        ]
        for unit in units where lower.hasSuffix(unit.suffix) {
            let numberText = String(lower.dropLast(unit.suffix.count))
            if let value = Double(numberText), value > 0 {
                return .success(value * unit.secondsPerUnit)
            }
        }
        return .failure(.invalidDuration(text))
    }

    private func parseTarget(_ text: String) -> Result<Int, ShorthandParseError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()
        if lower.hasSuffix("%ftp") {
            guard let percent = Double(trimmed.dropLast(4)), percent >= 0 else { return .failure(.invalidTarget(text)) }
            guard let ftpWatts, ftpWatts > 0 else { return .failure(.missingFTP) }
            return .success(Int((percent / 100 * Double(ftpWatts)).rounded()))
        }
        if lower.hasSuffix("w") {
            guard let watts = Double(trimmed.dropLast(1)), watts >= 0 else { return .failure(.invalidTarget(text)) }
            return .success(Int(watts.rounded()))
        }
        return .failure(.invalidTarget(text))
    }

    /// Splits on `separator`, but only outside `(...)` nesting, so a repeat
    /// group's own inner comma list isn't mistaken for top-level segments.
    private func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for char in text {
            switch char {
            case "(": depth += 1; current.append(char)
            case ")": depth -= 1; current.append(char)
            case separator where depth == 0:
                parts.append(current)
                current = ""
            default:
                current.append(char)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
