import Foundation

/// Snapshot of the live values reported by the trainer
/// (Indoor Bike Data characteristic, UUID 0x2AD2).
struct TrainerMetrics: Equatable {
    var instantaneousPowerWatts: Int?
    var instantaneousCadenceRPM: Double?
    var instantaneousSpeedKmh: Double?

    static let empty = TrainerMetrics()

    init() {}

    /// Parses the raw data according to the FTMS specification (section 4.9.1).
    /// Which fields are present in `data` depends on the flags bit field at the start.
    init(data: Data) {
        guard data.count >= 2 else { return }
        let bytes = [UInt8](data)
        var offset = 2
        let flags = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)

        let moreDataBitSet = (flags & 0x0001) != 0
        let averageSpeedPresent = (flags & 0x0002) != 0
        let instantaneousCadencePresent = (flags & 0x0004) != 0
        let averageCadencePresent = (flags & 0x0008) != 0
        let totalDistancePresent = (flags & 0x0010) != 0
        let resistanceLevelPresent = (flags & 0x0020) != 0
        let instantaneousPowerPresent = (flags & 0x0040) != 0
        let averagePowerPresent = (flags & 0x0080) != 0
        let expendedEnergyPresent = (flags & 0x0100) != 0
        let heartRatePresent = (flags & 0x0200) != 0

        func readUInt16() -> UInt16? {
            guard offset + 2 <= bytes.count else { return nil }
            let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            offset += 2
            return value
        }

        func skip(_ n: Int) {
            offset += n
        }

        // Bit 0 = "More Data": if NOT set, Instantaneous Speed follows.
        if !moreDataBitSet, let raw = readUInt16() {
            instantaneousSpeedKmh = Double(raw) * 0.01 // resolution 0.01 km/h
        }
        if averageSpeedPresent { skip(2) }
        if instantaneousCadencePresent, let raw = readUInt16() {
            instantaneousCadenceRPM = Double(raw) * 0.5 // resolution 0.5 rpm
        }
        if averageCadencePresent { skip(2) }
        if totalDistancePresent { skip(3) } // 24-bit value
        if resistanceLevelPresent { skip(2) }
        if instantaneousPowerPresent, let raw = readUInt16() {
            instantaneousPowerWatts = Int(Int16(bitPattern: raw))
        }
        if averagePowerPresent { skip(2) }
        if expendedEnergyPresent { skip(5) }
        if heartRatePresent { skip(1) }
    }

    /// Parses the raw data of the Treadmill Data characteristic (FTMS spec, section 4.6).
    /// Only Instantaneous Speed is extracted, using the exact same "More Data" bit and
    /// 0.01 km/h resolution as the bike's Indoor Bike Data. Other optional fields
    /// (incline, pace, elevation, energy, …) aren't needed by this app and are skipped
    /// implicitly by simply not reading past the speed field.
    init(treadmillData data: Data) {
        guard data.count >= 2 else { return }
        let bytes = [UInt8](data)
        let flags = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)
        let moreDataBitSet = (flags & 0x0001) != 0

        if !moreDataBitSet, bytes.count >= 4 {
            let raw = UInt16(bytes[2]) | (UInt16(bytes[3]) << 8)
            instantaneousSpeedKmh = Double(raw) * 0.01 // resolution 0.01 km/h
        }
    }
}
