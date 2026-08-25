import CoreBluetooth

/// Constants from the Bluetooth SIG "Heart Rate Service" specification.
/// An open standard – not a vendor-specific protocol – so this code works with
/// virtually any BLE heart rate strap (Polar, Garmin, Wahoo TICKR, …).
enum HeartRate {
    // MARK: Service

    static let service = CBUUID(string: "180D")

    // MARK: Characteristics

    static let measurement = CBUUID(string: "2A37")
    static let bodySensorLocation = CBUUID(string: "2A38")
}
