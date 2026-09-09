import Foundation

/// Parses a compact, hand-typed interval notation into a `WorkoutProgram`,
/// as an offline alternative to sourcing an actual `.erg`/`.mrc` file for a
/// simple structured workout – see `CreateWorkoutView`. Grammar (informal):
///
/// ```
/// program     := segment (',' segment)*
/// segment     := repeatGroup | step
/// repeatGroup := INT 'x' '(' segment (',' segment)* ')' | INT 'x' step
/// step        := duration target ('->' target)?
/// duration    := NUMBER durationUnit
/// target      := NUMBER ('%FTP'|'W'|'Watt'|'Watts')
/// durationUnit:= 'min'|'minute'|'minuten'|'m' | 'sec'|'sekunde'|'sekunden'|'s' | 'h'|'std'|'stunde'|'stunden'
/// ```
///
/// e.g. `10min 60%FTP, 4x(5min 105%FTP, 3min 50%FTP), 10min 55%FTP`, or a
/// ramp within one step: `20min 100W->300W`. The space between `duration`
/// and `target` is optional (`10min60%FTP` parses the same as `10min
/// 60%FTP` – see `ShorthandNotation.consumePrefixedValue(_:units:)`, which
/// is what actually makes that – and the German-keyboard `,` decimal
/// separator, and the `minute`/`Minuten`/`Watt` synonyms above – all work
/// without the rider needing to hit the grammar exactly. Deliberately
/// power-only (no resistance-percent target) and offline – no network
/// call, unlike a true free-form AI-generated workout would need (tried on
/// the `feature/ai-workout-generator` branch and found not worth the
/// tradeoffs it came with – see STATUS.md).
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

    /// Every recognized spelling of each duration unit, longest-first
    /// ties broken by `ShorthandNotation.consumePrefixedValue` itself –
    /// listed here roughly shortest-to-longest per unit only for this
    /// file's own readability. `"m"` stays an alias for minutes, matching
    /// this parser's own original shorthand (`TreadmillShorthandParser`
    /// reserves bare `"m"` for meters instead, a deliberate difference
    /// between the two – see that parser's own doc comment). `"'"` (a
    /// bare prime/apostrophe for minutes, e.g. `10'`) is a bike-only
    /// alias too, and deliberately *not* added to
    /// `TreadmillShorthandParser`'s own duration units – there, `'` would
    /// be genuinely ambiguous with feet (the same prime-for-minutes-or-
    /// feet overload everywhere else this notation shows up), which a
    /// bike step never has to worry about since it has no distance unit
    /// at all. `'"'` (a bare double prime for seconds, e.g. `90"`) is the
    /// same notation's other half – added here *and* to
    /// `TreadmillShorthandParser`'s own duration units, unlike `'`,
    /// since its usual other meaning (inches) was never one of this
    /// app's supported distance units in the first place, so there's
    /// nothing for it to collide with on a treadmill step either.
    fileprivate static let durationUnits: [(suffix: String, multiplier: Double)] = [
        ("m", 60), ("min", 60), ("minute", 60), ("minuten", 60), ("'", 60),
        ("s", 1), ("sec", 1), ("sekunde", 1), ("sekunden", 1), ("\"", 1),
        ("h", 3600), ("std", 3600), ("stunde", 3600), ("stunden", 3600),
    ]
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
            return String(localized: "Type a workout, e.g. \"10min 60%FTP, 4x(5min 105%FTP, 3min 50%FTP), 10min 55%FTP\".")
        case .invalidSegment(let text):
            return String(localized: "Couldn't understand \"\(text)\" – expected something like \"5min 250W\" or \"3x(...)\".")
        case .invalidDuration(let text):
            return String(localized: "Couldn't understand the duration \"\(text)\" – use e.g. \"10min\" or \"90s\".")
        case .invalidTarget(let text):
            return String(localized: "Couldn't understand the target \"\(text)\" – use e.g. \"250W\" or \"75%FTP\".")
        case .missingFTP:
            return String(localized: "This workout uses %FTP, but no FTP is set – add one in Settings first.")
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
        let parts = ShorthandNotation.splitTopLevel(text, separator: ",")
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

    /// A repeat group – either the multi-step `Nx(...)` form, or, for a
    /// single repeated step only, the parenthesis-free shorthand
    /// ("4x5min 105%FTP" for four 5-minute efforts, not the more awkward
    /// "4x(5min 105%FTP)") – or a plain step on its own. Falling back all
    /// the way to `parseStep` (and its own error) whenever none of the
    /// repeat-group shapes match, rather than a separate, potentially
    /// confusing error path.
    private func parseSegment(_ text: String) -> Result<ShorthandSegment, ShorthandParseError> {
        if let xIndex = text.firstIndex(where: { $0 == "x" || $0 == "X" }) {
            let countText = text[text.startIndex..<xIndex].trimmingCharacters(in: .whitespaces)
            let rest = text[text.index(after: xIndex)...].trimmingCharacters(in: .whitespaces)
            if let count = Int(countText), count > 0 {
                if rest.hasPrefix("("), rest.hasSuffix(")") {
                    let inner = String(rest.dropFirst().dropLast())
                    return parseSegments(inner).map { .repeatGroup(count: count, segments: $0) }
                }
                if !rest.isEmpty {
                    return parseStep(rest).map { .repeatGroup(count: count, segments: [$0]) }
                }
            }
        }
        return parseStep(text)
    }

    /// `"<duration><target>"` (space between the two optional) or
    /// `"<duration><target>-><target>"` for a ramp, e.g. `"10min60%FTP"`,
    /// `"10min 60%FTP"`, or `"20min 100W->300W"`.
    private func parseStep(_ text: String) -> Result<ShorthandSegment, ShorthandParseError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let durationMatch = ShorthandNotation.consumePrefixedValue(trimmed, units: ShorthandWorkoutParser.durationUnits) else {
            // A leading number with no unit this parser recognizes is a
            // duration-specific problem worth its own message; anything
            // that doesn't even start with a number is the step's overall
            // shape being wrong instead.
            if trimmed.first?.isNumber == true {
                return .failure(.invalidDuration(text))
            }
            return .failure(.invalidSegment(text))
        }
        let durationSeconds = durationMatch.value
        guard durationSeconds > 0 else { return .failure(.invalidDuration(text)) }
        guard !durationMatch.remainder.isEmpty else { return .failure(.invalidSegment(text)) }

        let rampParts = durationMatch.remainder.components(separatedBy: "->")
        guard rampParts.count == 1 || rampParts.count == 2 else { return .failure(.invalidTarget(durationMatch.remainder)) }
        switch parseTarget(rampParts[0]) {
        case .failure(let error): return .failure(error)
        case .success(let startWatts):
            guard rampParts.count == 2 else {
                return .success(.step(durationSeconds: durationSeconds, startWatts: startWatts, endWatts: startWatts))
            }
            switch parseTarget(rampParts[1]) {
            case .failure(let error): return .failure(error)
            case .success(let endWatts):
                return .success(.step(durationSeconds: durationSeconds, startWatts: startWatts, endWatts: endWatts))
            }
        }
    }

    /// Terminal token (the very end of a step, or of one side of a ramp),
    /// so – unlike duration above – there's no risk of it being mistaken
    /// for a prefix of something longer that follows; a plain `hasSuffix`
    /// check per recognized spelling is enough.
    private func parseTarget(_ text: String) -> Result<Int, ShorthandParseError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // A rider sometimes puts a space before the unit ("105% FTP",
        // "200 W") – stripped here before matching, since neither this
        // parser's own suffixes nor a legitimate target value ever
        // contain a meaningful internal space of their own. Only used for
        // matching/extracting below; `text` (with whatever spacing it
        // actually had) is still what error messages report.
        let compact = trimmed.replacingOccurrences(of: " ", with: "")
        let lower = compact.lowercased()
        if lower.hasSuffix("%ftp") {
            guard let percent = ShorthandNotation.parseNumber(compact.dropLast(4)), percent >= 0 else { return .failure(.invalidTarget(text)) }
            guard let ftpWatts, ftpWatts > 0 else { return .failure(.missingFTP) }
            return .success(Int((percent / 100 * Double(ftpWatts)).rounded()))
        }
        // Longest spelling first, same reasoning as `durationUnits` –
        // "watts"/"watt" before the bare "w" they'd otherwise also match
        // the tail end of.
        for suffix in ["watts", "watt", "w"] where lower.hasSuffix(suffix) {
            guard let watts = ShorthandNotation.parseNumber(compact.dropLast(suffix.count)), watts >= 0 else { return .failure(.invalidTarget(text)) }
            return .success(Int(watts.rounded()))
        }
        return .failure(.invalidTarget(text))
    }
}
