import Foundation

/// Shared low-level parsing helpers for both `ShorthandWorkoutParser` (bike,
/// power-based) and `TreadmillShorthandParser` (speed+incline, distance- or
/// duration-based) – the two share the same top-level shape (comma-separated
/// steps, `Nx(...)` repeat groups, see each parser's own doc comment) and the
/// same "a number immediately followed by its unit, with or without a space
/// in between" token style, just with different unit vocabularies for what
/// can follow.
///
/// Exists because hand-typed shorthand is exactly the kind of input real
/// "Fehlbedienung" (mis-typing) happens on – a missing space between a
/// duration and its target, or a German keyboard's `,` where `.` was
/// expected, used to be a hard parse failure even though the intent was
/// perfectly clear. `consumePrefixedValue(_:units:)` below is what actually
/// closes that gap, for both parsers at once.
enum ShorthandNotation {
    /// Recognizes either `.` or `,` as the decimal separator. Workout
    /// numbers here (durations, watts, percent, distances) are always
    /// small and never grouped, so there's no realistic input where `,`
    /// could instead mean a thousands separator worth preserving – a bare
    /// swap to `.` before falling back to `Double.init` is unambiguous.
    static func parseNumber(_ text: some StringProtocol) -> Double? {
        Double(text) ?? Double(text.replacingOccurrences(of: ",", with: "."))
    }

    private static let numberPrefixPattern = try! NSRegularExpression(pattern: "^([0-9]+(?:[.,][0-9]+)?)")

    /// Matches `NUMBER UNIT` at the very start of `text`, `UNIT` being
    /// whichever of `units`' own suffixes matches – longest first, so e.g.
    /// "min" is tried before a shorter unit ("m") that would otherwise also
    /// match as its own prefix. Works with or without whitespace/anything
    /// between the number and its unit ("10min", "10 min", "3,5min" all
    /// match the same way) – deliberately not requiring the caller to have
    /// already split the input into separate whitespace-delimited tokens,
    /// since that's exactly what broke on a missing space before. Returns
    /// the already-scaled value (`rawNumber * unit.multiplier`), the
    /// matched unit's own suffix text (for error messages), and whatever's
    /// left of `text` after the match, whitespace-trimmed. `nil` if `text`
    /// doesn't start with a number, or none of `units` match what follows.
    ///
    /// Guards against a *longer*, unlisted word being mistaken for one of
    /// `units`' own shorter entries – e.g. "minutes" isn't "minute" plus a
    /// dangling "s" – by rejecting a match whose very next character (if
    /// any) is still a letter. A plural or spelled-out variant a caller
    /// actually wants to accept needs its own explicit entry in `units`,
    /// not a shorter prefix relying on this fallback.
    static func consumePrefixedValue(
        _ input: String,
        units: [(suffix: String, multiplier: Double)]
    ) -> (value: Double, unitSuffix: String, remainder: String)? {
        let text = input.trimmingCharacters(in: .whitespaces)
        let nsrange = NSRange(text.startIndex..., in: text)
        guard let match = numberPrefixPattern.firstMatch(in: text, range: nsrange),
              let numberRange = Range(match.range(at: 1), in: text) else { return nil }
        guard let rawValue = parseNumber(text[numberRange]) else { return nil }
        // Trimmed *before* matching, not just at the top of this function –
        // "10 Minuten" (a space between the number and its unit word, not
        // just "10min" glued together) needs this too, or `rest` still
        // starts with that space and no unit's suffix ever matches it.
        let rest = String(text[numberRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        for unit in units.sorted(by: { $0.suffix.count > $1.suffix.count }) {
            guard rest.lowercased().hasPrefix(unit.suffix.lowercased()) else { continue }
            let afterUnit = String(rest.dropFirst(unit.suffix.count))
            if let nextChar = afterUnit.first, nextChar.isLetter { continue }
            return (rawValue * unit.multiplier, unit.suffix, afterUnit.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    /// Splits on `separator`, but only outside `(...)` nesting, so a repeat
    /// group's own inner comma list isn't mistaken for top-level segments.
    /// Shared verbatim between both parsers' top-level `program` grammar.
    ///
    /// When `separator` is itself `,`, a comma with a digit immediately on
    /// both sides is never treated as a split point either – that's a
    /// German-style decimal separator (`consumePrefixedValue` above reads
    /// it back the same way), not the boundary between two steps. A comma
    /// separating steps always has whitespace, a digit-less token, or the
    /// end of the string on at least one side in every real shorthand
    /// program, so this never mistakes an actual step boundary for a
    /// decimal point.
    ///
    /// A newline always behaves as `separator` too, regardless of what
    /// `separator` actually is – requested directly, from a real
    /// multi-line workout pasted with one top-level segment per line
    /// (only the *inner* list of a repeat group's own parens used commas)
    /// rather than every step on one comma-joined line. Without this, that
    /// whole multi-line block read as a single, un-splittable top-level
    /// segment – no error, just a wrong, degenerate parse.
    static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        let chars = Array(text).map { $0.isNewline ? separator : $0 }
        var index = 0
        while index < chars.count {
            let char = chars[index]
            switch char {
            case "(": depth += 1; current.append(char)
            case ")": depth -= 1; current.append(char)
            case separator where depth == 0:
                let isDecimalComma = separator == ","
                    && index > 0 && chars[index - 1].isNumber
                    && index + 1 < chars.count && chars[index + 1].isNumber
                if isDecimalComma {
                    current.append(char)
                } else {
                    parts.append(current)
                    current = ""
                }
            default:
                current.append(char)
            }
            index += 1
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
