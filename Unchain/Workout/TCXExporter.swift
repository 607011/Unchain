import Foundation

/// Builds a `.tcx` (Garmin Training Center XML) document from a
/// `WorkoutRecord` – the "get a workout out of the app" counterpart to
/// `WorkoutHistoryStore` keeping it in the app. `.tcx` was picked over
/// `.fit` (binary, needs a real encoder library to produce correctly) or a
/// bespoke CSV (nothing else would recognize it) – it's plain XML, widely
/// read (Strava, TrainingPeaks, Golden Cheetah, …), and its `<Trackpoint>`
/// shape already fits this app's own per-second samples directly. No XML
/// library involved – the document's shape is small and fixed enough that
/// plain string building is simpler than pulling one in, matching the rest
/// of this app's "no third-party SDKs" stance; the one genuinely free-text
/// field (`programName`) goes through `xmlEscaped(_:)` before being
/// inserted, everything else here is numbers/dates/a fixed enum string.
enum TCXExporter {
    /// `.tcx`'s `Sport` attribute only allows these three values – walking
    /// and running both collapse to "Running" (closer than "Other", and
    /// TCX itself makes no Walk/Run distinction), matching how FTMS itself
    /// can't tell the two apart either (see `MachineKind`'s own doc
    /// comment).
    private static func sport(for machineKind: MachineKind) -> String {
        switch machineKind {
        case .bike: return "Biking"
        case .treadmill: return "Running"
        case .unknown: return "Other"
        }
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    /// A reasonable file name for sharing/saving – e.g.
    /// "2026-09-02 Indoor Run.tcx". Not read back by anything in this app;
    /// purely for whatever the rider sees in the share sheet/Files.
    static func suggestedFileName(for record: WorkoutRecord) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HHmm"
        let datePart = dateFormatter.string(from: record.startDate)
        let kindPart = record.programName ?? sport(for: record.machineKind)
        return "\(datePart) \(kindPart).tcx"
    }

    static func data(for record: WorkoutRecord) -> Data {
        Data(xml(for: record).utf8)
    }

    private static func xml(for record: WorkoutRecord) -> String {
        let startTime = dateFormatter.string(from: record.startDate)
        let totalSeconds = Int(record.activeDuration.rounded())
        let totalDistance = record.distanceMeters ?? 0
        // Required by the schema even when unknown – `0` rather than
        // inventing a number, same "no accurate figure means no invented
        // one" rule as `WorkoutSession.liveActiveEnergyKcal`'s own doc
        // comment. Only ever non-zero for a bike, the one machine kind
        // that estimate is computed for at all today.
        let calories = record.workDoneKilojoules.map { Int(EnergyEstimator.cyclingActiveEnergyKcal(workDoneKilojoules: $0).rounded()) } ?? 0

        var trackpoints = ""
        var cumulativeDistanceMeters = 0.0
        var previousSample: WorkoutSample?
        for sample in record.samples.sorted(by: { $0.elapsedSeconds < $1.elapsedSeconds }) {
            // Distance isn't itself one of `WorkoutSample`'s fields – it's
            // integrated here from consecutive speed samples, the same
            // trapezoidal-ish "speed × elapsed time since the last sample"
            // approach `WorkoutSession.refreshWorkoutState` already uses
            // for its own live `distanceMeters`, just replayed afterward
            // from the stored per-second speed trace instead of live BLE
            // notifications. A gap in `speedKmh` (strap/metric briefly
            // missing) simply accrues no distance for that stretch, rather
            // than guessing.
            let deltaSeconds = previousSample.map { sample.elapsedSeconds - $0.elapsedSeconds } ?? 0
            if let speedKmh = sample.speedKmh, deltaSeconds > 0 {
                cumulativeDistanceMeters += speedKmh * 1000 / 3600 * deltaSeconds
            }
            previousSample = sample

            let pointTime = dateFormatter.string(from: record.startDate.addingTimeInterval(sample.elapsedSeconds))
            var point = "      <Trackpoint>\n"
            point += "        <Time>\(pointTime)</Time>\n"
            point += "        <DistanceMeters>\(String(format: "%.1f", cumulativeDistanceMeters))</DistanceMeters>\n"
            if let bpm = sample.heartRateBPM {
                point += "        <HeartRateBpm><Value>\(bpm)</Value></HeartRateBpm>\n"
            }
            if sample.speedKmh != nil || sample.powerWatts != nil {
                point += "        <Extensions>\n"
                point += "          <TPX xmlns=\"http://www.garmin.com/xmlschemas/ActivityExtension/v2\">\n"
                if let speedKmh = sample.speedKmh {
                    point += "            <Speed>\(String(format: "%.2f", speedKmh / 3.6))</Speed>\n"
                }
                if let watts = sample.powerWatts {
                    point += "            <Watts>\(watts)</Watts>\n"
                }
                point += "          </TPX>\n"
                point += "        </Extensions>\n"
            }
            point += "      </Trackpoint>\n"
            trackpoints += point
        }

        let notes = record.programName.map { "      <Notes>\(xmlEscaped($0))</Notes>\n" } ?? ""

        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">
          <Activities>
            <Activity Sport="\(sport(for: record.machineKind))">
              <Id>\(startTime)</Id>
        \(notes)      <Lap StartTime="\(startTime)">
                <TotalTimeSeconds>\(totalSeconds)</TotalTimeSeconds>
                <DistanceMeters>\(String(format: "%.1f", totalDistance))</DistanceMeters>
                <Calories>\(calories)</Calories>
                <Intensity>Active</Intensity>
                <TriggerMethod>Manual</TriggerMethod>
                <Track>
        \(trackpoints)        </Track>
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """
    }
}
