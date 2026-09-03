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

/// One flat-value block of a treadmill workout: a target speed and
/// inclination held constant for `duration` seconds. Unlike
/// `WorkoutProgram` (`.erg`/`.mrc`, where a value ramps linearly *between*
/// breakpoints), every real-world Warmup/SteadyState/Cooldown block seen so
/// far uses a single flat `Pace`/`Incline` value for its own whole
/// duration – no interpolation needed or attempted. A genuine Zwift ramp
/// (`PaceLow`/`PaceHigh` instead of a flat `Pace`) isn't supported yet –
/// see `ZWOWorkoutParser`.
struct TreadmillWorkoutSegment: Codable, Equatable {
    let startSeconds: TimeInterval
    let duration: TimeInterval
    let speedKmh: Double
    let inclinePercent: Double
    let kind: TreadmillSegmentKind?
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

    /// The flat (speed, incline) target at `elapsed` seconds into the
    /// workout; `nil` once the workout has run its full length.
    func target(atElapsedSeconds elapsed: TimeInterval) -> (speedKmh: Double, inclinePercent: Double)? {
        guard elapsed <= duration else { return nil }
        if let index = segmentIndex(atElapsedSeconds: elapsed) {
            let segment = segments[index]
            return (segment.speedKmh, segment.inclinePercent)
        }
        // Exactly at `duration` itself falls just outside every segment's
        // own half-open range above – hold the last segment's value rather
        // than reporting "finished" one instant early.
        guard let last = segments.last, elapsed >= last.startSeconds else { return nil }
        return (last.speedKmh, last.inclinePercent)
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
            return String(localized: "This .zwo file uses a \"\(name)\" block Unchain doesn't support yet – only Warmup, SteadyState, and Cooldown (flat Pace/Incline, no ramping or repeats) are.")
        }
    }
}

/// Parses a `.zwo` file (Zwift's XML workout format) into a
/// `TreadmillWorkoutProgram`. Scoped deliberately narrowly: only the flat
/// `Pace`/`Incline` attributes real-world treadmill `.zwo` files have
/// actually been seen using, on `Warmup`/`SteadyState`/`Cooldown` blocks –
/// not a genuine Zwift cycling workout (`Power`/`PowerLow`/`PowerHigh`, %FTP
/// based – the same "would need an FTP concept for %-based targets" gap
/// `.mrc` already has), and not a ramping Warmup/Cooldown
/// (`PaceLow`/`PaceHigh`) or repeating interval block (`IntervalsT`) either.
/// A file using one of those fails clearly (`ZWOParseError
/// .unsupportedSegment`) rather than silently producing a wrong or
/// incomplete workout.
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

        private static let flatSegmentElements: Set<String> = ["Warmup", "SteadyState", "Cooldown"]
        /// Named explicitly (rather than lumping them into "anything
        /// else") so the resulting error can name the actual element, and
        /// so a future version adding support for one of these has a
        /// ready-made list to start from.
        private static let knownUnsupportedSegmentElements: Set<String> = ["Ramp", "IntervalsT", "FreeRide", "MaxEffort"]

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
                segments.append(TreadmillWorkoutSegment(startSeconds: cursorSeconds, duration: duration, speedKmh: pace, inclinePercent: incline, kind: kind))
                cursorSeconds += duration
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
            guard elementName == "name", isInsideName else { return }
            let trimmed = nameBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { workoutName = trimmed }
            isInsideName = false
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
            self.parseError = parseError
        }
    }
}
