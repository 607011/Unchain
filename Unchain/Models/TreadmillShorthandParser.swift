import Foundation

/// Parses a compact, hand-typed interval notation into a
/// `TreadmillWorkoutProgram` – the treadmill (speed+incline) counterpart to
/// `ShorthandWorkoutParser` (bike, power), sharing its top-level shape and
/// low-level tokenizing (`ShorthandNotation`) but with a different, three-
/// part step: a length, a speed, and an optional incline, since a treadmill
/// drives two simultaneous targets where a bike only ever drives one (see
/// `TreadmillWorkoutSegment`'s own doc comment on why it needs its own
/// model at all). Grammar (informal):
///
/// ```
/// program     := segment (',' segment)*
/// segment     := repeatGroup | step
/// repeatGroup := INT 'x' '(' segment (',' segment)* ')' | INT 'x' step
/// step        := length speed incline?
/// length      := NUMBER (durationUnit | distanceUnit)
/// speed       := NUMBER speedUnit
/// incline     := NUMBER '%'
/// durationUnit:= 'min'|'minute'|'minuten' | 'sec'|'s'|'sekunde'|'sekunden' | 'h'|'std'|'stunde'|'stunden'
/// distanceUnit:= 'm'|'meter'|'meters' | 'km'|'kilometer'|'kilometers' | 'mi'|'mile'|'miles' | 'yd'|'yard'|'yards' | 'ft'|'foot'|'feet'
/// speedUnit   := 'km/h'|'kmh'|'kph' | 'mph'|'mi/h'
/// ```
///
/// e.g. `5min 8km/h, 5x(3min 10km/h 6%, 2min 6km/h), 5min 8km/h`, or a
/// distance-based interval – common for track-style training, and the
/// reason this supports imperial units at all – `8x400m 12km/h 0%` or
/// `10x40yd 15mph`. A distance `length` is converted to the actual block
/// duration via the very `speed` that follows it in the same step
/// (`durationSeconds = distanceMeters / speedInMetersPerSecond`) – always
/// unambiguous, since (unlike a bike step) a treadmill step never ramps
/// between two different speeds, matching `TreadmillWorkoutSegment` itself
/// only ever holding one flat speed for its whole duration. `incline` is
/// optional, defaulting to `0` (flat) when omitted – most casual requests
/// don't need it spelled out every time. `mph`/`mi`/`yd`/`ft` are always
/// converted to their metric equivalents at parse time (km/h, meters) –
/// `TreadmillWorkoutSegment` itself, like the rest of the app, only ever
/// stores metric.
///
/// Same reasoning as `ShorthandWorkoutParser` on tolerating a missing space
/// ("400m12km/h" parses the same as "400m 12km/h") and a German-keyboard
/// `,` decimal separator – see `ShorthandNotation.consumePrefixedValue`.
/// Produces segments with `kind: nil` throughout (no Warmup/SteadyState/
/// Cooldown tagging) – same convention `WorkoutSession
/// .recordTreadmillTarget(speedKmh:inclinePercent:)` already uses for a
/// recorded session, since a hand-typed step has no such role to infer
/// either.
enum TreadmillShorthandParser {
    static func parse(_ text: String, name: String) -> Result<TreadmillWorkoutProgram, TreadmillShorthandParseError> {
        let parser = Parser()
        switch parser.parseSegments(text) {
        case .failure(let error):
            return .failure(error)
        case .success(let segments):
            var cursor: TimeInterval = 0
            var treadmillSegments: [TreadmillWorkoutSegment] = []
            flatten(segments, cursor: &cursor, into: &treadmillSegments)
            guard !treadmillSegments.isEmpty else { return .failure(.emptyInput) }
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            return .success(TreadmillWorkoutProgram(name: trimmedName.isEmpty ? "Custom Workout" : trimmedName, segments: treadmillSegments))
        }
    }

    /// Walks the parsed segment tree in order, expanding repeat groups and
    /// assigning each step its own `startSeconds` – the
    /// `ShorthandWorkoutParser.flatten(_:cursor:into:)` counterpart, just
    /// building `TreadmillWorkoutSegment`s (one flat value each) instead of
    /// breakpoint pairs.
    private static func flatten(_ segments: [ShorthandTreadmillSegment], cursor: inout TimeInterval, into result: inout [TreadmillWorkoutSegment]) {
        for segment in segments {
            switch segment {
            case .step(let durationSeconds, let speedKmh, let inclinePercent):
                result.append(TreadmillWorkoutSegment(startSeconds: cursor, duration: durationSeconds, speedKmh: speedKmh, inclinePercent: inclinePercent, kind: nil))
                cursor += durationSeconds
            case .repeatGroup(let count, let inner):
                for _ in 0..<count {
                    flatten(inner, cursor: &cursor, into: &result)
                }
            }
        }
    }

    /// Duration spellings for `length` – deliberately *not* including a
    /// bare `"m"` the way `ShorthandWorkoutParser.durationUnits` does for
    /// minutes: here `"m"` means meters instead (see `distanceUnits`
    /// below), so a plain `"min"` is required to say minutes. A genuinely
    /// different convention from the bike parser, on purpose – this one
    /// has an actual, common use for `"m"` already spoken for.
    /// `'"'` (a bare double prime for seconds, e.g. `90"`) is included
    /// here – unlike the bike parser's own bare `'` for minutes, which
    /// stays bike-only (would collide with `distanceUnits`' own `"ft"`
    /// below), `"` 's usual other meaning (inches) was never one of this
    /// parser's supported distance units in the first place, so there's
    /// nothing here for it to collide with. `'` (a bare prime, e.g. `3'`)
    /// used to stay excluded here for exactly that reason – requested
    /// directly, with a real example using it (`3' @ 5,5 km/h`); the
    /// ambiguity with feet is real in principle, but not in practice: a
    /// treadmill interval a few feet long is never a plausible *length*
    /// for a whole step the way a few minutes is, so minutes reading first
    /// (duration units are tried before distance ones – see `lengthUnits`
    /// below) is the sensible default here too, same trade-off the bike
    /// side already accepted. `"second"`/`"seconds"`/`"hour"`/`"hours"` –
    /// the spelled-out English forms `"sec"`/`"h"` etc. didn't cover –
    /// added for the same reason: this parser is meant to understand
    /// something close to how a workout is actually said out loud,
    /// including dictated, not just typed tersely.
    fileprivate static let durationUnits: [(suffix: String, multiplier: Double)] = [
        ("min", 60), ("minute", 60), ("minuten", 60), ("'", 60),
        ("s", 1), ("sec", 1), ("second", 1), ("seconds", 1), ("sekunde", 1), ("sekunden", 1), ("\"", 1),
        ("h", 3600), ("std", 3600), ("hour", 3600), ("hours", 3600), ("stunde", 3600), ("stunden", 3600),
    ]
    /// Every recognized suffix from `durationUnits` above, for classifying
    /// a matched `length` token as a duration (this set) vs. a distance
    /// (`distanceUnits` below, everything else `lengthUnits` matches).
    fileprivate static let durationUnitSuffixes = Set(durationUnits.map(\.suffix))

    /// Distance spellings for `length`, each multiplier already in meters –
    /// metric (`m`/`km`) plus the imperial units asked for specifically
    /// (`mi`/`yd`/`ft`), all converted at parse time since this app, like
    /// its file formats, only ever stores metric internally.
    fileprivate static let distanceUnits: [(suffix: String, multiplier: Double)] = [
        ("m", 1), ("meter", 1), ("meters", 1),
        ("km", 1000), ("kilometer", 1000), ("kilometers", 1000),
        ("mi", 1609.344), ("mile", 1609.344), ("miles", 1609.344),
        ("yd", 0.9144), ("yard", 0.9144), ("yards", 0.9144),
        ("ft", 0.3048), ("foot", 0.3048), ("feet", 0.3048),
    ]
    /// Both tables combined – a `length` token can be either kind, and
    /// `ShorthandNotation.consumePrefixedValue` needs every candidate
    /// suffix at once to pick the longest match overall (e.g. "min" over
    /// "mi" for a "5min..." input – seeing only `distanceUnits` in
    /// isolation could never know "min" wins there).
    fileprivate static let lengthUnits = durationUnits + distanceUnits

    /// `km/h`/`kmh`/`kph` are read as-is; `mph`/`mi/h` are converted to
    /// km/h right here (`× 1.609344`) so every `speed` – however it was
    /// typed – always comes out of `consumePrefixedValue` already in this
    /// app's one canonical unit.
    fileprivate static let speedUnits: [(suffix: String, multiplier: Double)] = [
        ("km/h", 1), ("kmh", 1), ("kph", 1),
        ("mi/h", 1.609344), ("mph", 1.609344),
    ]
}

enum TreadmillShorthandParseError: LocalizedError, Equatable {
    case emptyInput
    case invalidSegment(String)
    case invalidLength(String)
    case invalidSpeed(String)
    case invalidIncline(String)

    var errorDescription: String? {
        switch self {
        case .emptyInput:
            return String(localized: "Type a workout, e.g. \"5min 8km/h, 5x(3min 10km/h 6%, 2min 6km/h), 5min 8km/h\".")
        case .invalidSegment(let text):
            return String(localized: "Couldn't understand \"\(text)\" – expected something like \"5min 8km/h\", \"400m 10km/h 2%\", or \"3x(...)\".")
        case .invalidLength(let text):
            return String(localized: "Couldn't understand the length \"\(text)\" – use a duration like \"10min\" or a distance like \"400m\", \"0.5mi\", \"440yd\".")
        case .invalidSpeed(let text):
            return String(localized: "Couldn't understand the speed \"\(text)\" – use e.g. \"8km/h\" or \"5mph\".")
        case .invalidIncline(let text):
            return String(localized: "Couldn't understand the incline \"\(text)\" – use e.g. \"2%\".")
        }
    }
}

/// One node of the parsed (but not yet time-expanded) workout tree – the
/// `ShorthandSegment` counterpart for a treadmill's own (speed, incline)
/// pair instead of a bike's single power value.
private indirect enum ShorthandTreadmillSegment {
    case step(durationSeconds: TimeInterval, speedKmh: Double, inclinePercent: Double)
    case repeatGroup(count: Int, segments: [ShorthandTreadmillSegment])
}

private struct Parser {
    func parseSegments(_ text: String) -> Result<[ShorthandTreadmillSegment], TreadmillShorthandParseError> {
        let parts = ShorthandNotation.splitTopLevel(text, separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return .failure(.emptyInput) }
        var segments: [ShorthandTreadmillSegment] = []
        for part in parts {
            switch parseSegment(part) {
            case .success(let segment): segments.append(segment)
            case .failure(let error): return .failure(error)
            }
        }
        return .success(segments)
    }

    /// A repeat group – either the multi-step `Nx(...)` form, or, for a
    /// single repeated step only, the parenthesis-free shorthand real
    /// track training is actually written in ("8x400m 12km/h" for eight
    /// 400 m repeats, not the more awkward "8x(400m 12km/h)") – or a plain
    /// step on its own. The separator itself is whichever of a bare
    /// `x`/`X`, the multiplication sign `×` (some keyboards, and dictation,
    /// both produce it directly), or the spelled-out word `"times"` (closer
    /// to how a repeat count is actually said out loud) appears first –
    /// see `firstRepeatSeparatorRange(in:)`.
    private func parseSegment(_ text: String) -> Result<ShorthandTreadmillSegment, TreadmillShorthandParseError> {
        if let separatorRange = Self.firstRepeatSeparatorRange(in: text) {
            let countText = text[text.startIndex..<separatorRange.lowerBound].trimmingCharacters(in: .whitespaces)
            let rest = text[separatorRange.upperBound...].trimmingCharacters(in: .whitespaces)
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

    /// The earliest of `×`, a bare `x`/`X`, or the whole word `"times"`
    /// (case-insensitive) – whichever actually comes first in `text`, not
    /// a fixed priority order between them, since either could legitimately
    /// appear first depending on how a segment happens to be phrased.
    private static func firstRepeatSeparatorRange(in text: String) -> Range<String.Index>? {
        var best: Range<String.Index>?
        if let r = text.range(of: "×") { best = r }
        if let i = text.firstIndex(where: { $0 == "x" || $0 == "X" }) {
            let r = i..<text.index(after: i)
            if best == nil || r.lowerBound < best!.lowerBound { best = r }
        }
        if let r = text.range(of: "times", options: .caseInsensitive) {
            if best == nil || r.lowerBound < best!.lowerBound { best = r }
        }
        return best
    }

    /// A handful of natural-language filler words/connectors this parser
    /// tolerates around the actual numbers, all purely decorative – the
    /// goal, requested directly: understanding something close to how a
    /// workout is actually described out loud, dictated or typed, not just
    /// the terse form. "5 min warm-up at 5 km/h with 5% incline" parses
    /// exactly like "5min 5km/h 5%" once these are stripped, and works the
    /// same whether or not any of them are actually present. Word-boundary
    /// anchored so a legitimate token is never partially eaten – none of
    /// these appear as a substring inside any recognized unit suffix, so
    /// there's nothing here for them to collide with. "warm-up"/"cool-down"
    /// don't actually mark the resulting step as warmup/cooldown anywhere –
    /// this format has no such concept to begin with (see this file's own
    /// doc comment on why every parsed segment's `kind` is always `nil`) –
    /// they're accepted purely as the rider's own readable/spoken label,
    /// same as any of the others. `@` is accepted directly alongside the
    /// spelled-out `"at"` – whichever a rider actually typed or dictated.
    private static let fillerWordPattern = try! NSRegularExpression(
        pattern: #"@|\bat\b|\bwith\b|\band\b|\bincline\b|warm[- ]?up|cool[- ]?down"#,
        options: .caseInsensitive
    )

    private static func stripFillerWords(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return fillerWordPattern.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }

    /// `"<length><speed>"` or `"<length><speed><incline>"`, each part's
    /// own leading/trailing space optional – e.g. `"5min8km/h"`,
    /// `"5min 8km/h"`, or `"400m 10km/h 2%"`. `length` is read first, and
    /// whether it turns out to be a duration or a distance decides how the
    /// step's actual `durationSeconds` gets computed – a distance needs
    /// `speed` (read right after) to convert, so the two can't be parsed
    /// independently of each other the way bike's `duration`/`target` can.
    private func parseStep(_ text: String) -> Result<ShorthandTreadmillSegment, TreadmillShorthandParseError> {
        let trimmed = Self.stripFillerWords(text).trimmingCharacters(in: .whitespaces)
        guard let lengthMatch = ShorthandNotation.consumePrefixedValue(trimmed, units: TreadmillShorthandParser.lengthUnits) else {
            if trimmed.first?.isNumber == true {
                return .failure(.invalidLength(text))
            }
            return .failure(.invalidSegment(text))
        }
        guard lengthMatch.value > 0 else { return .failure(.invalidLength(text)) }
        guard !lengthMatch.remainder.isEmpty else { return .failure(.invalidSegment(text)) }

        guard let speedMatch = ShorthandNotation.consumePrefixedValue(lengthMatch.remainder, units: TreadmillShorthandParser.speedUnits) else {
            if lengthMatch.remainder.first?.isNumber == true {
                return .failure(.invalidSpeed(lengthMatch.remainder))
            }
            return .failure(.invalidSegment(text))
        }
        let speedKmh = speedMatch.value
        guard speedKmh > 0 else { return .failure(.invalidSpeed(lengthMatch.remainder)) }

        let durationSeconds: TimeInterval
        if TreadmillShorthandParser.durationUnitSuffixes.contains(lengthMatch.unitSuffix) {
            durationSeconds = lengthMatch.value
        } else {
            // `length` was a distance in meters (`lengthMatch.value`) –
            // convert via the speed just parsed: seconds = meters /
            // (km/h × 1000 / 3600), rearranged to avoid an intermediate
            // division by a very small number.
            let distanceMeters = lengthMatch.value
            durationSeconds = distanceMeters * 3.6 / speedKmh
        }

        guard speedMatch.remainder.isEmpty else {
            guard let inclineMatch = ShorthandNotation.consumePrefixedValue(speedMatch.remainder, units: [("%", 1)]),
                  inclineMatch.remainder.isEmpty else {
                return .failure(.invalidIncline(speedMatch.remainder))
            }
            return .success(.step(durationSeconds: durationSeconds, speedKmh: speedKmh, inclinePercent: inclineMatch.value))
        }
        return .success(.step(durationSeconds: durationSeconds, speedKmh: speedKmh, inclinePercent: 0))
    }
}
