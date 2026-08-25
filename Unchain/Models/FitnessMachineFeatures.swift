import Foundation

/// Parsed from the Fitness Machine Feature characteristic (FTMS spec, section
/// 4.3, UUID 0x2ACC): two 32-bit flag fields describing which live-data fields
/// and which control targets the connected machine reports supporting.
struct FitnessMachineFeatures: Equatable {
    /// Live values the machine can report (speed, cadence, power, …).
    var dataFeatures: [String] = []
    /// Targets the machine accepts via the Control Point (power, resistance,
    /// grade simulation, …).
    var targetFeatures: [String] = []

    // Individually named, typed flags for the specific targets the app needs
    // to gate its own UI on (which control tabs to offer, which workout file
    // types to accept) — string-matching against `targetFeatures`' display
    // names for that would be fragile, so these are tracked separately from
    // the same bits at parse time.
    private(set) var supportsPowerTarget = false
    private(set) var supportsResistanceTarget = false
    private(set) var supportsIndoorBikeSimulation = false

    init(data: Data) {
        guard data.count >= 8 else { return }
        let bytes = [UInt8](data)
        let dataFlags = Self.readUInt32(bytes, at: 0)
        let targetFlags = Self.readUInt32(bytes, at: 4)

        dataFeatures = Self.dataFeatureNames.compactMap { bit, name in
            (dataFlags & (1 << bit)) != 0 ? name : nil
        }
        targetFeatures = Self.targetFeatureNames.compactMap { bit, name in
            (targetFlags & (1 << bit)) != 0 ? name : nil
        }

        supportsResistanceTarget = (targetFlags & (1 << 2)) != 0
        supportsPowerTarget = (targetFlags & (1 << 3)) != 0
        supportsIndoorBikeSimulation = (targetFlags & (1 << 13)) != 0
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    // Bit positions per FTMS spec, table 4.3 ("Fitness Machine Features Field").
    private static let dataFeatureNames: [(bit: Int, name: String)] = [
        (0, "Average Speed"),
        (1, "Cadence"),
        (2, "Total Distance"),
        (3, "Inclination"),
        (4, "Elevation Gain"),
        (5, "Pace"),
        (6, "Step Count"),
        (7, "Resistance Level"),
        (8, "Stride Count"),
        (9, "Expended Energy"),
        (10, "Heart Rate Measurement"),
        (11, "Metabolic Equivalent"),
        (12, "Elapsed Time"),
        (13, "Remaining Time"),
        (14, "Power Measurement"),
        (15, "Force on Belt & Power Output"),
        (16, "User Data Retention"),
    ]

    // Bit positions per FTMS spec, table 4.3 ("Target Setting Features Field").
    private static let targetFeatureNames: [(bit: Int, name: String)] = [
        (0, "Speed Target"),
        (1, "Inclination Target"),
        (2, "Resistance Target"),
        (3, "Power Target"),
        (4, "Heart Rate Target"),
        (5, "Targeted Expended Energy"),
        (6, "Targeted Step Number"),
        (7, "Targeted Stride Number"),
        (8, "Targeted Distance"),
        (9, "Targeted Training Time"),
        (10, "Targeted Time in 2 HR Zones"),
        (11, "Targeted Time in 3 HR Zones"),
        (12, "Targeted Time in 5 HR Zones"),
        (13, "Indoor Bike Simulation (Grade)"),
        (14, "Wheel Circumference Config"),
        (15, "Spin Down Control"),
        (16, "Targeted Cadence"),
    ]
}
