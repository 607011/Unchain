import Foundation
import UniformTypeIdentifiers

/// Which `.zwo` block a `TreadmillWorkoutSegment` came from – used by
/// `VO2MaxEstimator` to pick only a genuinely held, steady-effort segment
/// (not a Warmup/Cooldown, which by definition aren't representative of a
/// stable submaximal load) as its basis. `Optional` on the segment itself
/// rather than required, so a `TreadmillWorkoutProgram` persisted before
/// this existed (`TreadmillWorkoutProgramStore`'s saved recents) still
/// decodes – such a segment just never qualifies, rather than the whole
/// list of recents failing to load.
enum TreadmillSegmentKind: String, Codable {
    case warmup
    case steadyState
    case cooldown
}

/// One block of a treadmill workout: a target speed and inclination held
/// for `duration` seconds, either flat (`startSpeedKmh == endSpeedKmh` and
/// likewise for incline) or ramping linearly from the start value to the
/// end value across the segment's own duration – see `isRamped`. Unlike
/// `WorkoutProgram` (`.erg`/`.mrc`, whose *own* breakpoint-to-breakpoint
/// ramping is a real Zwift/ERG-format concept), a `.zwo` file has no
/// standard way to ramp Speed/Incline at all – Zwift's own `<Ramp>`
/// element is Power/cycling-only (`PowerLow`/`PowerHigh`). A ramped
/// segment here comes from this app and `docs/builder.html`'s web Workout
/// Builder's own invented extension: a `<Ramp>` block carrying
/// `SpeedLow`/`SpeedHigh`/`InclineLow`/`InclineHigh` instead of Power –
/// deliberately mirroring Zwift's own `<Ramp>`/`PowerLow`/`PowerHigh`
/// shape rather than bolting these onto `Warmup`/`SteadyState`/
/// `Cooldown`, which stay genuinely flat (plain `Pace`/`Incline`) both in
/// the real format and in this app's own model – see `ZWOWorkoutParser`.
/// A ramped segment's own `kind` is always `nil`: Zwift's own `<Ramp>`
/// isn't tagged Warmup/SteadyState/Cooldown either, so there's nothing to
/// carry over.
struct TreadmillWorkoutSegment: Codable, Equatable {
    let startSeconds: TimeInterval
    let duration: TimeInterval
    let startSpeedKmh: Double
    let endSpeedKmh: Double
    let startInclinePercent: Double
    let endInclinePercent: Double
    let kind: TreadmillSegmentKind?
    /// `<TextEvent>` markers nested in this segment's own `.zwo` block, if
    /// any – see `TextEventMarker`. `var`, unlike every other field here,
    /// because `ZWOWorkoutParser` appends to it in place as it encounters
    /// each `<TextEvent>` child while a segment is already sitting in its
    /// `segments` array (a `TextEvent` is only ever seen *after* its
    /// containing block's own opening tag). Defaults to `[]` – both for a
    /// non-`.zwo` origin (only `ZWOWorkoutParser` ever populates this) and
    /// so a `TreadmillWorkoutProgram` persisted before this existed still
    /// decodes, the same reasoning `kind` above already has. That backward-
    /// compat decode needs a custom `init(from:)` below, though – unlike
    /// `kind`, a non-`Optional` stored property's own default value isn't
    /// actually honored by synthesized `Decodable` for a key that's simply
    /// absent (confirmed directly – it throws `keyNotFound` instead), so
    /// this can't just rely on the property default the way it looks like
    /// it could.
    var textEvents: [TextEventMarker] = []

    /// Whether this segment's speed and/or incline actually changes across
    /// its own duration – used by `VO2MaxEstimator` to exclude a ramping
    /// segment from SteadyState candidacy (not a genuinely held, steady
    /// effort), and by UI/export code to decide whether a single value or a
    /// start→end range is the honest thing to show.
    var isRamped: Bool { startSpeedKmh != endSpeedKmh || startInclinePercent != endInclinePercent }

    init(startSeconds: TimeInterval, duration: TimeInterval, startSpeedKmh: Double, endSpeedKmh: Double, startInclinePercent: Double, endInclinePercent: Double, kind: TreadmillSegmentKind?, textEvents: [TextEventMarker] = []) {
        self.startSeconds = startSeconds
        self.duration = duration
        self.startSpeedKmh = startSpeedKmh
        self.endSpeedKmh = endSpeedKmh
        self.startInclinePercent = startInclinePercent
        self.endInclinePercent = endInclinePercent
        self.kind = kind
        self.textEvents = textEvents
    }

    private enum CodingKeys: String, CodingKey {
        case startSeconds, duration, startSpeedKmh, endSpeedKmh, startInclinePercent, endInclinePercent, kind, textEvents
    }

    /// Decode-only, deliberately kept separate from `CodingKeys` above so
    /// `Encodable` stays fully synthesized (a case here has no
    /// corresponding stored property, which would break that synthesis if
    /// mixed into the main enum) – reads a `TreadmillWorkoutProgramStore`
    /// recent saved before this type had ramping at all, back when it only
    /// ever stored one flat speed/incline pair per segment.
    private enum LegacyCodingKeys: String, CodingKey {
        case speedKmh, inclinePercent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startSeconds = try container.decode(TimeInterval.self, forKey: .startSeconds)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        if let startSpeed = try container.decodeIfPresent(Double.self, forKey: .startSpeedKmh),
           let startIncline = try container.decodeIfPresent(Double.self, forKey: .startInclinePercent) {
            startSpeedKmh = startSpeed
            endSpeedKmh = try container.decode(Double.self, forKey: .endSpeedKmh)
            startInclinePercent = startIncline
            endInclinePercent = try container.decode(Double.self, forKey: .endInclinePercent)
        } else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            let speedKmh = try legacy.decode(Double.self, forKey: .speedKmh)
            let inclinePercent = try legacy.decode(Double.self, forKey: .inclinePercent)
            startSpeedKmh = speedKmh
            endSpeedKmh = speedKmh
            startInclinePercent = inclinePercent
            endInclinePercent = inclinePercent
        }
        kind = try container.decodeIfPresent(TreadmillSegmentKind.self, forKey: .kind)
        textEvents = try container.decodeIfPresent([TextEventMarker].self, forKey: .textEvents) ?? []
    }
}

/// A `<TextEvent>` marker nested inside a `.zwo` `Warmup`/`SteadyState`/
/// `Cooldown` block – see
/// https://github.com/h4l/zwift-workout-file-reference/blob/master/zwift_workout_file_tag_reference.md#element-TextEvent
/// `timeOffset` is seconds from the *containing segment's own* start, not
/// the whole workout's – exactly how the file format itself defines it,
/// and how `docs/builder.html`'s own Mark-mode markers already work.
struct TextEventMarker: Codable, Equatable {
    let timeOffset: TimeInterval
    let message: String
    /// Seconds the message should stay visible once shown, if the file
    /// specified one – real files often don't. `nil` falls back to
    /// `defaultDurationSeconds` at *display* time only (`TextEventOverlayView`)
    /// rather than being filled in here, keeping this model an honest
    /// reflection of what the file actually said – the same "don't invent
    /// data" rule `docs/builder.html`'s own export already follows.
    let duration: TimeInterval?

    /// Not documented by Zwift for an unspecified `Duration` – picked as a
    /// deliberate, named app-side default rather than left as a magic
    /// number at each call site.
    static let defaultDurationSeconds: TimeInterval = 5
}

/// A structured treadmill workout loaded from a `.zwo` file (Zwift's XML
/// workout format) – the `TreadmillWorkoutSegment`-based counterpart to
/// `WorkoutProgram`, needed because a treadmill drives *two* simultaneous
/// targets (speed and incline) where `WorkoutProgram` only ever carries
/// one (power *or* resistance) – the same reasoning `GradeProfile` already
/// got its own model for, just along a different axis (two values instead
/// of a different index).
struct TreadmillWorkoutProgram: Codable, Equatable {
    let name: String
    /// Sorted by `startSeconds`, contiguous – each segment's end is the
    /// next one's start – enforced by `ZWOWorkoutParser` building them this
    /// way in the first place, not just assumed here.
    let segments: [TreadmillWorkoutSegment]

    var duration: TimeInterval { segments.last.map { $0.startSeconds + $0.duration } ?? 0 }

    /// Index of the segment containing `elapsed`, if any – `nil` before the
    /// start or past the end. Exposed (rather than kept private to
    /// `target(atElapsedSeconds:)`, which uses it too) so a caller can tell
    /// when playback has crossed into a *new* segment – the same "fire a
    /// vibration/interval sound once per entry" need `WorkoutProgram
    /// .breakpointIndex(atElapsedSeconds:)` serves for `.erg`/`.mrc`.
    func segmentIndex(atElapsedSeconds elapsed: TimeInterval) -> Int? {
        segments.firstIndex { elapsed >= $0.startSeconds && elapsed < $0.startSeconds + $0.duration }
    }

    /// Elapsed-seconds time the segment right after `index` starts, i.e.
    /// when playback will next cross into a different one – `nil` if
    /// `index` is already the last one. Mirrors `WorkoutProgram
    /// .nextTransitionTimeSeconds(afterIndex:)`.
    func nextTransitionTimeSeconds(afterIndex index: Int) -> TimeInterval? {
        let nextIndex = index + 1
        guard segments.indices.contains(nextIndex) else { return nil }
        return segments[nextIndex].startSeconds
    }

    /// The (speed, incline) target at `elapsed` seconds into the workout;
    /// `nil` once the workout has run its full length. For a ramping
    /// segment (`isRamped`), linearly interpolates between its start and
    /// end values based on how far `elapsed` is into the segment's own
    /// duration – a flat segment (the common case, and the only case
    /// before ramping existed) is unaffected, since start==end makes the
    /// interpolation a no-op.
    func target(atElapsedSeconds elapsed: TimeInterval) -> (speedKmh: Double, inclinePercent: Double)? {
        guard elapsed <= duration else { return nil }
        if let index = segmentIndex(atElapsedSeconds: elapsed) {
            return Self.interpolatedTarget(segments[index], atElapsedSeconds: elapsed)
        }
        // Exactly at `duration` itself falls just outside every segment's
        // own half-open range above – hold the last segment's own end
        // value rather than reporting "finished" one instant early.
        guard let last = segments.last, elapsed >= last.startSeconds else { return nil }
        return (last.endSpeedKmh, last.endInclinePercent)
    }

    private static func interpolatedTarget(_ segment: TreadmillWorkoutSegment, atElapsedSeconds elapsed: TimeInterval) -> (speedKmh: Double, inclinePercent: Double) {
        guard segment.duration > 0 else { return (segment.startSpeedKmh, segment.startInclinePercent) }
        let fraction = min(max((elapsed - segment.startSeconds) / segment.duration, 0), 1)
        let speedKmh = segment.startSpeedKmh + (segment.endSpeedKmh - segment.startSpeedKmh) * fraction
        let inclinePercent = segment.startInclinePercent + (segment.endInclinePercent - segment.startInclinePercent) * fraction
        return (speedKmh, inclinePercent)
    }

    /// The `<TextEvent>` marker that should currently be showing at
    /// `elapsed` seconds into the workout, if any – the one whose own
    /// `[start, start + duration)` window (`duration` falling back to
    /// `TextEventMarker.defaultDurationSeconds` when unset) contains
    /// `elapsed`. `nil` outside every such window, including whenever no
    /// segment is active at all. Only ever within the *currently* active
    /// segment – a marker belonging to an already-finished segment never
    /// lingers, and one belonging to a not-yet-reached segment never shows
    /// early, both already implied by only checking `segmentIndex
    /// (atElapsedSeconds:)`'s own segment rather than all of them.
    func activeTextEvent(atElapsedSeconds elapsed: TimeInterval) -> TextEventMarker? {
        guard let index = segmentIndex(atElapsedSeconds: elapsed) else { return nil }
        let segment = segments[index]
        return segment.textEvents.first { event in
            let start = segment.startSeconds + event.timeOffset
            let end = start + (event.duration ?? TextEventMarker.defaultDurationSeconds)
            return elapsed >= start && elapsed < end
        }
    }

    /// The write-side counterpart to `ZWOWorkoutParser.parse`, for
    /// exporting a recorded `.speedIncline` session as a portable `.zwo`
    /// file (see `WorkoutSession.RecordedManualProgram`) – not used for a
    /// *loaded* `.zwo`, which already has its own original file contents
    /// (there's no "Export" for those the way `WorkoutProgram.fileContents()`
    /// offers for a loaded `.erg`/`.mrc`, since a recorded program is the
    /// only kind of `TreadmillWorkoutProgram` that doesn't already have a
    /// file to fall back on). Every segment is written as a flat
    /// `SteadyState` block regardless of its own `kind` – a recording never
    /// tags any (`kind: nil` throughout, see
    /// `WorkoutSession.recordTreadmillTarget(speedKmh:inclinePercent:)`),
    /// and `SteadyState` is what `ZWOWorkoutParser` itself would derive for
    /// an untagged block on re-import anyway, so this round-trips cleanly.
    /// `sportType` is always `run` – this app's own `.zwo` support is
    /// treadmill-only throughout (see `TreadmillWorkoutSegment`'s own doc
    /// comment), never actually read back by `ZWOWorkoutParser` either, but
    /// included for compatibility with other tools that do expect it.
    func fileContents() -> String {
        var lines = [
            "<workout_file>",
            "  <author>Unchain</author>",
            "  <name>\(Self.xmlEscaped(name))</name>",
            "  <description>Recorded from a free Speed &amp; Incline session.</description>",
            "  <sportType>run</sportType>",
            "  <workout>",
        ]
        for run in Self.mergedRuns(segments) {
            // A machine-readable file format, not UI text – always "." and
            // no thousands separator, same reasoning `WorkoutProgram
            // .fileContents()` already uses for its own `MINUTES` column.
            // No `SpeedLow`/`SpeedHigh`/`InclineLow`/`InclineHigh` here –
            // every segment a recorded manual session produces has
            // start==end by construction (see `WorkoutSession
            // .recordTreadmillTarget(speedKmh:inclinePercent:)`), so
            // `mergedRuns` below only ever merges flat runs and a plain
            // `Pace`/`Incline` is always the whole story.
            let duration = String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), run.duration)
            let pace = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), run.speedKmh)
            let incline = String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), run.inclinePercent)
            lines.append("    <SteadyState Duration=\"\(duration)\" Pace=\"\(pace)\" Incline=\"\(incline)\"/>")
        }
        lines.append("  </workout>")
        lines.append("</workout_file>")
        return lines.joined(separator: "\n")
    }

    /// Combines consecutive flat `segments` sharing the same start speed/
    /// incline into a single run spanning their combined duration –
    /// requested directly, alongside the identical fix for
    /// `WorkoutProgram.fileContents()`'s own `.erg`/`.mrc` export: a
    /// rider holding one target for a long stretch of a recorded session
    /// would otherwise write one `<SteadyState>` line per individual
    /// recording tick (`WorkoutSession
    /// .recordTreadmillTarget(speedKmh:inclinePercent:)`) instead of one
    /// line for the whole held stretch. Excludes any `isRamped` segment
    /// from merging (never actually encountered here in practice – see
    /// `fileContents()`'s own note – but comparing only the start value
    /// would otherwise silently discard a merged run's own end value).
    /// Applied only here, at export time – `segments` itself is left
    /// untouched, so nothing that reads it during a live workout
    /// (`segmentIndex(atElapsedSeconds:)` and everything built on it) is
    /// affected.
    private static func mergedRuns(_ segments: [TreadmillWorkoutSegment]) -> [(duration: TimeInterval, speedKmh: Double, inclinePercent: Double)] {
        var runs: [(duration: TimeInterval, speedKmh: Double, inclinePercent: Double, merges: Bool)] = []
        for segment in segments {
            if !segment.isRamped, let last = runs.last, last.merges,
               last.speedKmh == segment.startSpeedKmh, last.inclinePercent == segment.startInclinePercent {
                runs[runs.count - 1].duration += segment.duration
            } else {
                runs.append((segment.duration, segment.startSpeedKmh, segment.startInclinePercent, !segment.isRamped))
            }
        }
        return runs.map { ($0.duration, $0.speedKmh, $0.inclinePercent) }
    }

    /// Suggested filename for exporting `fileContents()` – mirrors
    /// `WorkoutProgram.suggestedFileName`'s own sanitizing, just with a
    /// fixed `.zwo` extension (there's no `targetKind`-style branch here –
    /// every `TreadmillWorkoutProgram` is always speed+incline).
    var suggestedFileName: String {
        let sanitized = name.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined()
        return "\(sanitized.isEmpty ? String(localized: "Workout") : sanitized).zwo"
    }

    /// Escapes the five XML predefined entities – `name` is free-form rider
    /// text (a recorded session's own default name, or one they've since
    /// renamed it to) that could contain any of them, and this is the only
    /// place in `fileContents()` that isn't already either a fixed literal
    /// or a plain number.
    private static func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

enum ZWOParseError: LocalizedError {
    case unreadable
    case noSegments
    case unsupportedSegment(String)

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return String(localized: "The file couldn't be parsed as a .zwo workout.")
        case .noSegments:
            return String(localized: "No Warmup/SteadyState/Cooldown blocks with Pace/Incline found in this .zwo file – a cycling (Power-based) .zwo isn't supported yet.")
        case .unsupportedSegment(let name):
            return String(localized: "This .zwo file uses a \"\(name)\" block Unchain doesn't support yet – only Warmup, SteadyState, Cooldown (flat Pace/Incline) and Ramp (Speed/Incline, this app's own extension – not Zwift's Power-based Ramp) are.")
        }
    }
}

/// Parses a `.zwo` file (Zwift's XML workout format) into a
/// `TreadmillWorkoutProgram`. Scoped deliberately narrowly: only the flat
/// `Pace`/`Incline` attributes real-world treadmill `.zwo` files have
/// actually been seen using, on `Warmup`/`SteadyState`/`Cooldown` blocks –
/// not a genuine Zwift cycling workout (`Power`/`PowerLow`/`PowerHigh`, %FTP
/// based – the same "would need an FTP concept for %-based targets" gap
/// `.mrc` already has) – or a repeating interval block (`IntervalsT`)
/// either. It *does* additionally read a treadmill-flavored `<Ramp>` block
/// – `SpeedLow`/`SpeedHigh`/`InclineLow`/`InclineHigh`, a non-standard set
/// of attribute names this app and `docs/builder.html`'s web Workout
/// Builder invented together (see `TreadmillWorkoutSegment`'s own doc
/// comment), deliberately mirroring how Zwift's own `<Ramp>` carries
/// `PowerLow`/`PowerHigh` for cycling – as a genuinely ramped segment; all
/// four attributes are required (a `<Ramp>` block has no flat fallback of
/// its own), so a real, Power-based cycling `<Ramp>` – or a malformed
/// treadmill one missing an attribute – correctly falls through to the
/// same "unsupported element" failure as `IntervalsT`/`FreeRide`/
/// `MaxEffort`. A file using an actually unsupported element fails
/// clearly (`ZWOParseError.unsupportedSegment`) rather than silently
/// producing a wrong or incomplete workout.
enum ZWOWorkoutParser {
    static var contentType: UTType? { UTType(filenameExtension: "zwo") }

    /// `fallbackName` is used when the file has no `<name>` element (or an
    /// empty one) – mirrors `WorkoutProgramParser.parse`'s own
    /// `fileExtension`-derived fallback.
    static func parse(data: Data, fallbackName: String) -> Result<TreadmillWorkoutProgram, Error> {
        let delegate = SegmentCollector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            return .failure(delegate.parseError ?? ZWOParseError.unreadable)
        }
        if let unsupported = delegate.unsupportedSegmentName {
            return .failure(ZWOParseError.unsupportedSegment(unsupported))
        }
        guard !delegate.segments.isEmpty else {
            return .failure(ZWOParseError.noSegments)
        }
        let name = delegate.workoutName ?? fallbackName
        return .success(TreadmillWorkoutProgram(name: name, segments: delegate.segments))
    }

    private final class SegmentCollector: NSObject, XMLParserDelegate {
        var segments: [TreadmillWorkoutSegment] = []
        var workoutName: String?
        var unsupportedSegmentName: String?
        var parseError: Error?

        private var cursorSeconds: TimeInterval = 0
        private var isInsideName = false
        private var nameBuffer = ""
        /// Index into `segments` of whatever segment-opening block is
        /// currently open (`allSegmentElements` – Warmup/SteadyState/
        /// Cooldown/Ramp), so a `<TextEvent>` encountered while inside it
        /// (the only place it's ever meaningful – a `<TextEvent>` outside
        /// all of these is simply ignored, same as any other unrecognized
        /// element) knows which segment to attach itself to. `nil`
        /// outside all of them.
        private var currentSegmentIndex: Int?

        private static let flatSegmentElements: Set<String> = ["Warmup", "SteadyState", "Cooldown"]
        /// `flatSegmentElements` plus `"Ramp"` – every element that can
        /// open a segment and take nested `<TextEvent>` children. Used
        /// wherever `didEndElement` needs to recognize the close of
        /// *any* segment-opening element, not just a flat one.
        private static let allSegmentElements: Set<String> = flatSegmentElements.union(["Ramp"])
        /// Named explicitly (rather than lumping them into "anything
        /// else") so the resulting error can name the actual element, and
        /// so a future version adding support for one of these has a
        /// ready-made list to start from. `"Ramp"` itself is *not* here –
        /// it's handled by its own `case` below, which falls through to
        /// `unsupportedSegmentName` on its own terms (missing one of the
        /// required Speed/Incline attributes, e.g. a real Power-based
        /// cycling Ramp) rather than being unconditionally rejected.
        private static let knownUnsupportedSegmentElements: Set<String> = ["IntervalsT", "FreeRide", "MaxEffort"]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            // Once one unsupported block's been seen, stop collecting
            // further segments entirely – a partial workout built from
            // *some* of the file's blocks would silently understate what's
            // actually in it, worse than just failing outright.
            guard unsupportedSegmentName == nil else { return }
            switch elementName {
            case "name":
                isInsideName = true
                nameBuffer = ""
            case let name where Self.flatSegmentElements.contains(name):
                guard let duration = attributeDict["Duration"].flatMap(Double.init), duration > 0,
                      let pace = attributeDict["Pace"].flatMap(Double.init),
                      let incline = attributeDict["Incline"].flatMap(Double.init) else { return }
                let kind: TreadmillSegmentKind? = switch name {
                case "Warmup": .warmup
                case "SteadyState": .steadyState
                case "Cooldown": .cooldown
                default: nil
                }
                segments.append(TreadmillWorkoutSegment(startSeconds: cursorSeconds, duration: duration, startSpeedKmh: pace, endSpeedKmh: pace, startInclinePercent: incline, endInclinePercent: incline, kind: kind))
                currentSegmentIndex = segments.count - 1
                cursorSeconds += duration
            case "Ramp":
                // This app's own treadmill-flavored Ramp – see
                // `ZWOWorkoutParser`'s own doc comment. All four
                // attributes are required, independently of each other
                // being ramped or not (the writer always emits all four,
                // `Low === High` for whichever dimension isn't actually
                // ramping) – a real, Power-based cycling `<Ramp>` simply
                // doesn't have these and falls through to the `guard`
                // failing below, same treatment as any other genuinely
                // unsupported element.
                guard let duration = attributeDict["Duration"].flatMap(Double.init), duration > 0,
                      let speedLow = Self.attributeValue(attributeDict, "SpeedLow").flatMap(Double.init),
                      let speedHigh = Self.attributeValue(attributeDict, "SpeedHigh").flatMap(Double.init),
                      let inclineLow = Self.attributeValue(attributeDict, "InclineLow").flatMap(Double.init),
                      let inclineHigh = Self.attributeValue(attributeDict, "InclineHigh").flatMap(Double.init) else {
                    unsupportedSegmentName = "Ramp"
                    return
                }
                segments.append(TreadmillWorkoutSegment(startSeconds: cursorSeconds, duration: duration, startSpeedKmh: speedLow, endSpeedKmh: speedHigh, startInclinePercent: inclineLow, endInclinePercent: inclineHigh, kind: nil))
                currentSegmentIndex = segments.count - 1
                cursorSeconds += duration
            case "TextEvent":
                guard let currentSegmentIndex, segments.indices.contains(currentSegmentIndex),
                      let message = Self.attributeValue(attributeDict, "message"), !message.isEmpty else { return }
                let timeOffset = Self.attributeValue(attributeDict, "timeoffset").flatMap(Double.init) ?? 0
                let duration = Self.attributeValue(attributeDict, "duration").flatMap(Double.init)
                segments[currentSegmentIndex].textEvents.append(TextEventMarker(timeOffset: timeOffset, message: message, duration: duration))
            case let name where Self.knownUnsupportedSegmentElements.contains(name):
                unsupportedSegmentName = name
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if isInsideName { nameBuffer += string }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if Self.allSegmentElements.contains(elementName), let index = currentSegmentIndex {
                // Sorted once the block closes rather than kept sorted on
                // every insert – real files list `<TextEvent>`s in order
                // already, this just doesn't assume that.
                segments[index].textEvents.sort { $0.timeOffset < $1.timeOffset }
                currentSegmentIndex = nil
            }
            guard elementName == "name", isInsideName else { return }
            let trimmed = nameBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { workoutName = trimmed }
            isInsideName = false
        }

        /// Case-insensitive attribute lookup – real `.zwo` files use both
        /// `timeoffset` and `TimeOffset` for the same attribute (lowercase
        /// dominant by a wide margin, per the file format reference), and
        /// `XMLParser`'s own `attributeDict` keys are exact-case.
        private static func attributeValue(_ attributes: [String: String], _ name: String) -> String? {
            attributes.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            self.parseError = parseError
        }
    }
}
