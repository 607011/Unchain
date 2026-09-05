import Foundation

/// Snapshot of the live values reported by the trainer – either from the
/// Indoor Bike Data characteristic (UUID 0x2AD2, `init(data:)`) or the
/// Treadmill Data characteristic (UUID 0x2ACD, `init(treadmillData:)`),
/// depending on `TrainerConnection.machineKind`. `instantaneousCadenceRPM`
/// only ever comes from the former – FTMS defines no cadence field for a
/// treadmill at all.
struct TrainerMetrics: Equatable {
    var instantaneousPowerWatts: Int?
    var instantaneousCadenceRPM: Double?
    var instantaneousSpeedKmh: Double?
    /// The connected machine's *own* elapsed-workout-time counter, whole
    /// seconds – reported by both FTMS data characteristics this app reads
    /// (Indoor Bike Data's own Elapsed Time field, `init(data:)`; Treadmill
    /// Data's, `init(treadmillData:)`), each only while that specific
    /// device actually includes the optional field at all. `WorkoutSession`
    /// uses this directly as `elapsedSeconds` once available (see
    /// `refreshWorkoutState`), rather than only ever computing it from the
    /// iPhone's own system clock – the two run on independent clocks (the
    /// phone's vs. whatever timer the machine's own microcontroller
    /// keeps), and even a small relative rate difference between them
    /// compounds over a long workout instead of just being a fixed offset.
    var deviceElapsedSeconds: Int?
    /// Treadmill-only – the *cumulative* meters climbed so far this
    /// workout (FTMS's own "Positive Elevation Gain" field, whole meters),
    /// reported directly by the treadmill rather than estimated from
    /// incline × distance here: this app has no live *actual* incline
    /// reading to integrate from in the first place (Treadmill Data's own
    /// Inclination field is still unread, see `init(treadmillData:)`'s own
    /// note), so a self-computed number would be a guess dressed up as a
    /// measurement. `nil` for any treadmill that doesn't report this
    /// optional field at all – shown as "–" rather than `0`, so "not
    /// climbing" and "doesn't say" stay
    /// visibly different.
    var elevationGainMeters: Int?

    static let empty = TrainerMetrics()

    init() {}

    /// Parses the raw data according to the FTMS specification (section 4.9.1).
    /// Which fields are present in `data` depends on the flags bit field at
    /// the start. Reads through to and including Elapsed Time (bit 11,
    /// `deviceElapsedSeconds`) – Remaining Time (bit 12) is the only field
    /// that could still follow it, and this doesn't need it, so it's never
    /// skipped for on purpose.
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
        let metabolicEquivalentPresent = (flags & 0x0400) != 0
        let elapsedTimePresent = (flags & 0x0800) != 0

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
        if metabolicEquivalentPresent { skip(1) }
        if elapsedTimePresent, let raw = readUInt16() {
            deviceElapsedSeconds = Int(raw) // resolution 1 second, same field shape as Treadmill Data's own
        }
    }

    /// Parses the Treadmill Data characteristic (FTMS spec, section 4.4).
    /// Extracts Instantaneous Speed (same "More Data" bit and 0.01 km/h
    /// resolution as the bike's Indoor Bike Data), Elapsed Time (see
    /// `deviceElapsedSeconds`'s own doc comment), and, since some
    /// treadmills – e.g. the Paragon X this was verified against – report
    /// it too, Instantaneous Power. `instantaneousCadenceRPM` is
    /// deliberately never set here: FTMS defines no cadence/RPM field at
    /// all for a treadmill (there's nothing rotating to count), unlike
    /// Indoor Bike Data.
    ///
    /// Every optional field between Speed and Power has to be skipped (or,
    /// for Elapsed Time, read) in exactly the order and byte width the
    /// spec defines, or Power would be read from the wrong offset entirely
    /// – silently wrong numbers, not an
    /// obvious failure. Sizes/order per the Bluetooth GATT Specification
    /// Supplement's `org.bluetooth.characteristic.treadmill_data` field
    /// table: Average Speed (uint16), Total Distance (uint24), Inclination
    /// + Ramp Angle Setting (sint16 each), Positive + Negative Elevation
    /// Gain (uint16 each), Instantaneous/Average Pace (uint8 each), Total
    /// Energy (uint16) + Energy Per Hour (uint16) + Energy Per Minute
    /// (uint8), Heart Rate (uint8), Metabolic Equivalent (uint8), Elapsed/
    /// Remaining Time (uint16 each), then finally Force on Belt (sint16,
    /// skipped – not needed) + Power Output (sint16, the one field this
    /// still cares about at this point).
    init(treadmillData data: Data) {
        guard data.count >= 2 else { return }
        let bytes = [UInt8](data)
        var offset = 2
        let flags = UInt16(bytes[0]) | (UInt16(bytes[1]) << 8)

        let moreDataBitSet = (flags & 0x0001) != 0
        let averageSpeedPresent = (flags & 0x0002) != 0
        let totalDistancePresent = (flags & 0x0004) != 0
        let inclinationPresent = (flags & 0x0008) != 0
        let elevationGainPresent = (flags & 0x0010) != 0
        let instantaneousPacePresent = (flags & 0x0020) != 0
        let averagePacePresent = (flags & 0x0040) != 0
        let expendedEnergyPresent = (flags & 0x0080) != 0
        let heartRatePresent = (flags & 0x0100) != 0
        let metabolicEquivalentPresent = (flags & 0x0200) != 0
        let elapsedTimePresent = (flags & 0x0400) != 0
        let remainingTimePresent = (flags & 0x0800) != 0
        let forceAndPowerPresent = (flags & 0x1000) != 0

        func readUInt16() -> UInt16? {
            guard offset + 2 <= bytes.count else { return nil }
            let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            offset += 2
            return value
        }

        func skip(_ n: Int) {
            offset += n
        }

        // Bit 0 = "More Data": if NOT set, Instantaneous Speed follows –
        // same inverted convention as Indoor Bike Data.
        if !moreDataBitSet, let raw = readUInt16() {
            instantaneousSpeedKmh = Double(raw) * 0.01 // resolution 0.01 km/h
        }
        if averageSpeedPresent { skip(2) }
        if totalDistancePresent { skip(3) } // 24-bit value
        if inclinationPresent { skip(4) } // Inclination (2) + Ramp Angle Setting (2)
        if elevationGainPresent {
            // Positive (2), read as `elevationGainMeters`; Negative (2),
            // skipped – "elevation gained" only ever means climbed, not
            // descended, same convention every outdoor fitness app uses.
            if let raw = readUInt16() {
                elevationGainMeters = Int(raw) // resolution 1 meter
            }
            skip(2)
        }
        if instantaneousPacePresent { skip(1) }
        if averagePacePresent { skip(1) }
        if expendedEnergyPresent { skip(5) } // Total (2) + Per Hour (2) + Per Minute (1)
        if heartRatePresent { skip(1) }
        if metabolicEquivalentPresent { skip(1) }
        if elapsedTimePresent, let raw = readUInt16() {
            deviceElapsedSeconds = Int(raw) // resolution 1 second
        }
        if remainingTimePresent { skip(2) }
        if forceAndPowerPresent {
            skip(2) // Force on Belt – not needed
            if let raw = readUInt16() {
                instantaneousPowerWatts = Int(Int16(bitPattern: raw))
            }
        }
    }
}
