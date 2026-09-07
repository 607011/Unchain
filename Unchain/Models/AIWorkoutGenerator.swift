import Foundation
import FoundationModels

/// Whether the on-device "Generate with AI" workout feature can be offered
/// right now. Built on Apple's Foundation Models framework (`FoundationModels`,
/// iOS 26+) – the on-device Apple Intelligence language model, not a call to
/// any cloud LLM API. This is deliberate: like every other feature in this
/// app, workout generation needs no network access and sends nothing about
/// the rider anywhere; it simply doesn't work at all on hardware or an OS
/// version that doesn't have an on-device model to ask, rather than falling
/// back to a server this app has never otherwise needed.
///
/// Checked fresh every time rather than cached anywhere – the same "read at
/// point of use" reasoning `TrainerDeviceSettingsStore.effectiveLiveMetrics`
/// already uses, since availability can change between app launches (Apple
/// Intelligence toggled on/off in Settings, the on-device model finishing a
/// download) without this app itself doing anything.
enum AIWorkoutGeneratorAvailability {
    /// `false` before iOS 26 (the framework doesn't exist yet), on hardware
    /// Apple Intelligence doesn't support at all, or whenever the rider
    /// simply hasn't turned it on – see `unavailableReason` for which.
    static var isAvailable: Bool {
        guard #available(iOS 26.0, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// A rider-facing explanation for why the button is disabled – `nil`
    /// once/if `isAvailable` is `true`. Callers should only read this behind
    /// their own `#available(iOS 26.0, *)` check (mirroring `isAvailable`'s
    /// own internal one), since `SystemLanguageModel` itself doesn't exist
    /// before that.
    @available(iOS 26.0, *)
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return String(localized: "This device doesn't support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "Turn on Apple Intelligence in Settings to use this.")
        case .unavailable(.modelNotReady):
            return String(localized: "The on-device model is still downloading – try again in a bit.")
        case .unavailable:
            return String(localized: "On-device AI isn't available right now.")
        }
    }
}

enum AIWorkoutGeneratorError: LocalizedError {
    case unavailable(reason: String)
    /// The model replied with zero blocks – e.g. a prompt it couldn't make
    /// sense of as a workout request at all.
    case emptyResult
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): return reason
        case .emptyResult: return String(localized: "The generated workout had no steps – try rephrasing the request.")
        case .generationFailed(let message): return String(localized: "Couldn't generate a workout: \(message)")
        }
    }
}

/// Generates a workout entirely on-device via Apple's Foundation Models
/// framework – the `TreadmillWorkoutProgram`/`WorkoutProgram` counterpart to
/// typing one in by hand via `CreateWorkoutView`'s shorthand notation, just
/// from a free-form natural-language request instead of a fixed grammar.
/// Bike workouts come out power-only (`ProgramTargetKind.power`), never
/// `.resistance` – the same restriction `CreateWorkoutView`'s own shorthand
/// notation already has, for the same reason: no meaningful absolute target
/// to reason about without an FTP-relative concept, whereas a watts number
/// is at least well-defined on its own.
///
/// This app's smallest, least capable model tier: hands-on testing found it
/// genuinely unreliable at honoring more than one or two numeric details
/// from a request at once (e.g. it happily matched a plain "X minutes at Y
/// km/h" request, but a request combining a total duration, an interval
/// count, *and* an incline percentage came back with the incline dropped
/// to 0 and the total duration undershot by half or more – reformulating
/// the instructions traded one of those failures for the other rather than
/// fixing both). That's a real limit of this specific on-device model, not
/// a bug fixable by more prompt tuning – `AIWorkoutGeneratorView`'s own
/// preview step (segment list/chart, shown before Save is enabled) exists
/// precisely so a rider looks over what actually came back rather than
/// trusting it blindly, the same way they'd want to for anything else
/// this quick to state but easy to get numerically wrong.
@available(iOS 26.0, *)
enum AIWorkoutGenerator {
    /// Generates a `TreadmillWorkoutProgram` (flat speed+incline blocks,
    /// mirroring `ZWOWorkoutParser`'s own output shape) from `prompt`.
    static func generateTreadmillProgram(prompt: String) async -> Result<TreadmillWorkoutProgram, AIWorkoutGeneratorError> {
        guard case .available = SystemLanguageModel.default.availability else {
            return .failure(.unavailable(reason: AIWorkoutGeneratorAvailability.unavailableReason ?? String(localized: "On-device AI isn't available right now.")))
        }
        let session = LanguageModelSession(instructions: treadmillInstructions)
        do {
            let response = try await session.respond(to: prompt, generating: GeneratedTreadmillWorkout.self)
            let generated = response.content
            guard !generated.blocks.isEmpty else { return .failure(.emptyResult) }
            let durations = rescaledDurations(generated.blocks.map(\.durationSeconds), toSum: generated.totalDurationSeconds)
            var cursor: TimeInterval = 0
            let segments: [TreadmillWorkoutSegment] = zip(generated.blocks, durations).map { block, duration in
                let segment = TreadmillWorkoutSegment(
                    startSeconds: cursor,
                    duration: TimeInterval(duration),
                    speedKmh: block.speedKmh,
                    inclinePercent: block.inclinePercent,
                    kind: block.kind.segmentKind
                )
                cursor += segment.duration
                return segment
            }
            return .success(TreadmillWorkoutProgram(name: fallbackNamed(generated.name), segments: segments))
        } catch {
            return .failure(.generationFailed(error.localizedDescription))
        }
    }

    /// Generates a power-target `WorkoutProgram` from `prompt`. `ftpWatts`,
    /// when the rider has one set (see `SettingsView.ftpWattsKey`), is
    /// folded into the request text so the model can reason about targets
    /// relative to it (e.g. "sweet spot" or "Zone 2") – the model has no
    /// other way to know it, `LanguageModelSession` starts from nothing but
    /// this call's own instructions and prompt.
    static func generateBikeProgram(prompt: String, ftpWatts: Int?) async -> Result<WorkoutProgram, AIWorkoutGeneratorError> {
        guard case .available = SystemLanguageModel.default.availability else {
            return .failure(.unavailable(reason: AIWorkoutGeneratorAvailability.unavailableReason ?? String(localized: "On-device AI isn't available right now.")))
        }
        let session = LanguageModelSession(instructions: bikeInstructions)
        let effectivePrompt = ftpWatts.map { "The rider's FTP is \($0) W.\n\(prompt)" } ?? prompt
        do {
            let response = try await session.respond(to: effectivePrompt, generating: GeneratedBikeWorkout.self)
            let generated = response.content
            guard !generated.blocks.isEmpty else { return .failure(.emptyResult) }
            let durations = rescaledDurations(generated.blocks.map(\.durationSeconds), toSum: generated.totalDurationSeconds)
            var breakpoints: [WorkoutProgramBreakpoint] = []
            var cursor: TimeInterval = 0
            for (block, duration) in zip(generated.blocks, durations) {
                // Two breakpoints at the same value, one at the block's start
                // and one at its end, encode a flat (non-ramping) block –
                // the same convention `WorkoutProgram`'s own doc comment
                // describes for a step change, just applied to every block
                // here since the model has no notion of an in-block ramp.
                breakpoints.append(WorkoutProgramBreakpoint(timeSeconds: cursor, value: block.powerWatts))
                cursor += TimeInterval(duration)
                breakpoints.append(WorkoutProgramBreakpoint(timeSeconds: cursor, value: block.powerWatts))
            }
            return .success(WorkoutProgram(name: fallbackNamed(generated.name), targetKind: .power, breakpoints: breakpoints))
        } catch {
            return .failure(.generationFailed(error.localizedDescription))
        }
    }

    private static func fallbackNamed(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "AI Workout") : trimmed
    }

    /// Rescales `durations` (each block's own seconds) so they sum to
    /// exactly `targetTotal`, preserving every block's *relative* share of
    /// the original total rather than trusting the model's own (often
    /// badly undershot, see this type's own doc comment) absolute numbers.
    /// `targetTotal` itself comes from `totalDurationSeconds` – a *single*
    /// number the model turned out to read off a request reliably, unlike
    /// several block durations that must also sum correctly on their own;
    /// asking it for one number and doing the summing arithmetic here
    /// ourselves, exactly, is what actually fixed the undershoot (a prior
    /// attempt at fixing it through prompt wording alone did not – see
    /// STATUS.md).
    ///
    /// Uses the largest-remainder method so the result sums to *exactly*
    /// `targetTotal` despite integer rounding, not just approximately –
    /// the seconds still owed after every block gets its floor share go to
    /// the blocks with the largest fractional remainder first, one second
    /// each. Falls back to `durations` unchanged if either total is zero
    /// (nothing sensible to scale by) or `durations` is empty.
    private static func rescaledDurations(_ durations: [Int], toSum targetTotal: Int) -> [Int] {
        let originalTotal = durations.reduce(0, +)
        guard originalTotal > 0, targetTotal > 0 else { return durations }
        let scale = Double(targetTotal) / Double(originalTotal)
        let scaledExact = durations.map { Double($0) * scale }
        var scaled = scaledExact.map { Int($0) }
        let remainder = targetTotal - scaled.reduce(0, +)
        if remainder != 0 {
            let byLargestFractionFirst = scaledExact.enumerated()
                .sorted { ($0.element - Double(scaled[$0.offset])) > ($1.element - Double(scaled[$1.offset])) }
                .map(\.offset)
            let adjustment = remainder > 0 ? 1 : -1
            for index in 0..<abs(remainder) {
                let blockIndex = byLargestFractionFirst[index % byLargestFractionFirst.count]
                scaled[blockIndex] += adjustment
            }
        }
        // Scaling down could otherwise drive a block to 0 (or, in a
        // pathological rounding case, negative) seconds – never a
        // meaningful duration for an actual workout block.
        return scaled.map { max($0, 1) }
    }

    private static var treadmillInstructions: String {
        """
        You design treadmill interval workouts for a fitness app. Given a \
        free-form request, break it into a short, ordered sequence of \
        blocks – typically a warmup, several steady-state or interval \
        blocks, and a cooldown. Keep speeds and inclines realistic for \
        indoor treadmill running or walking. Reply in the same language \
        the request is written in.
        """
    }

    private static var bikeInstructions: String {
        """
        You design indoor cycling interval workouts for a fitness app. \
        Given a free-form request, break it into a short, ordered \
        sequence of blocks – typically a warmup, several steady-state or \
        interval blocks, and a cooldown – each with a single target power \
        in watts. When an FTP is given, keep power targets realistic \
        relative to it. Reply in the same language the request is \
        written in.
        """
    }
}

// MARK: - Generable schema

/// The `@Generable` counterpart to `TreadmillSegmentKind` – a separate type
/// (rather than making `TreadmillSegmentKind` itself `@Generable`) so the
/// framework's generated JSON-schema description of each case stays purely
/// an implementation detail of this file, not a constraint on the model
/// `TreadmillWorkoutSegment` already commits to elsewhere.
@available(iOS 26.0, *)
@Generable
enum GeneratedTreadmillBlockKind {
    case warmup
    case steadyState
    case cooldown

    var segmentKind: TreadmillSegmentKind {
        switch self {
        case .warmup: return .warmup
        case .steadyState: return .steadyState
        case .cooldown: return .cooldown
        }
    }
}

@available(iOS 26.0, *)
@Generable
struct GeneratedTreadmillBlock {
    @Guide(description: "What role this block plays in the workout")
    var kind: GeneratedTreadmillBlockKind
    @Guide(description: "How long this block lasts, in whole seconds", .range(10...3600))
    var durationSeconds: Int
    @Guide(description: "Target treadmill belt speed for this block, in km/h", .range(1.0...20.0))
    var speedKmh: Double
    @Guide(description: "Target treadmill incline for this block, in percent, 0 for flat", .range(0.0...15.0))
    var inclinePercent: Double
}

@available(iOS 26.0, *)
@Generable
struct GeneratedTreadmillWorkout {
    @Guide(description: "A short, descriptive name for this workout")
    var name: String
    // A single number the model reads directly off the request, rather
    // than something derived by summing `blocks`' own durations – see
    // `AIWorkoutGenerator.rescaledDurations(_:toSum:)`'s own doc comment on
    // why asking for one number here, then doing the exact arithmetic in
    // code, is what actually fixed this app's own "requested 30 minutes,
    // got 2" undershoot problem.
    @Guide(description: "Total duration of the whole workout in seconds, as stated or implied by the request", .range(60...7200))
    var totalDurationSeconds: Int
    // `.count(3...8)` is a hard cap on the response's own size, not just a
    // wish expressed in `treadmillInstructions`' prose ("typically a
    // warmup, several ... blocks, and a cooldown") – found necessary the
    // hard way: an uncapped array let the model try to emit enough blocks
    // for a longer, more granular request (e.g. "30 minutes, 5x3 minute
    // hill intervals") that the response plus the schema description
    // itself, both counted against the on-device model's small context
    // window, overran it entirely (`GenerationError
    // .exceededContextWindowSize`) rather than degrading gracefully.
    // Capping the array keeps every response within budget; the tradeoff
    // is that a request asking for more structure than 8 blocks can
    // express gets compressed rather than rejected outright, which is the
    // better failure mode of the two (see `AIWorkoutGenerator`'s own doc
    // comment on why previews exist to catch exactly this).
    @Guide(description: "The ordered blocks making up this workout, from warmup to cooldown", .count(3...8))
    var blocks: [GeneratedTreadmillBlock]
}

@available(iOS 26.0, *)
@Generable
struct GeneratedBikeBlock {
    @Guide(description: "How long this block lasts, in whole seconds", .range(10...3600))
    var durationSeconds: Int
    @Guide(description: "Target power for this block, in watts", .range(0...1000))
    var powerWatts: Int
}

@available(iOS 26.0, *)
@Generable
struct GeneratedBikeWorkout {
    @Guide(description: "A short, descriptive name for this workout")
    var name: String
    // See `GeneratedTreadmillWorkout.totalDurationSeconds`'s own doc
    // comment – identical reasoning applies here.
    @Guide(description: "Total duration of the whole workout in seconds, as stated or implied by the request", .range(60...7200))
    var totalDurationSeconds: Int
    // See `GeneratedTreadmillWorkout.blocks`'s own doc comment on why this
    // is capped – the identical context-window failure mode applies here
    // too, uncapped.
    @Guide(description: "The ordered blocks making up this workout, from warmup to cooldown", .count(3...8))
    var blocks: [GeneratedBikeBlock]
}
