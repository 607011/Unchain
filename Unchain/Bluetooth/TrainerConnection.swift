import Foundation
import CoreBluetooth

enum ControlMode: String, CaseIterable, Identifiable {
    case power = "Power"
    case resistance = "Resistance"
    case program = "Program"
    /// Manual grade (%) control, via FTMS Indoor Bike Simulation – offered
    /// only when the connected machine reports supporting it (see
    /// `FitnessMachineFeatures.supportsIndoorBikeSimulation`).
    case grade = "Grade"
    /// Manual speed (km/h) + inclination (%) control for a treadmill, via
    /// the FTMS Set Target Speed/Set Target Inclination op codes – offered
    /// only for a connected treadmill that supports at least one of the two
    /// (see `FitnessMachineFeatures.supportsSpeedTarget`/
    /// `supportsInclinationTarget`). Unlike every other case here, this one
    /// drives *two* independent targets at once rather than a single
    /// scalar value – "Power" made speed control on a treadmill feel like
    /// an odd fit, since incline/speed (not wattage) are what a treadmill
    /// session is normally actually about.
    case speedIncline = "SpeedIncline"
    var id: String { rawValue }

    /// `rawValue` itself stays English and unlocalized – it's the
    /// `@AppStorage("lastActiveMode")` persistence key (via `ControlMode`'s
    /// `RawRepresentable` conformance), so changing it with the user's
    /// locale would silently lose their remembered tab on a locale change.
    /// This is the display-only counterpart the picker actually shows.
    var displayName: String {
        switch self {
        case .power: return String(localized: "Power")
        case .resistance: return String(localized: "Resistance")
        case .program: return String(localized: "Program")
        case .grade: return String(localized: "Grade")
        case .speedIncline: return String(localized: "Speed & Incline")
        }
    }
}

enum ConnectionState: Equatable {
    case connecting
    case discoveringServices
    case ready
    case controlNotGranted
    case failed(String)
    case disconnected
}

/// Represents the active connection to exactly one FTMS trainer:
/// discovery of characteristics, live metrics, and writing control commands.
final class TrainerConnection: NSObject, ObservableObject {
    @Published private(set) var state: ConnectionState = .connecting
    @Published private(set) var metrics: TrainerMetrics = .empty
    @Published private(set) var powerRange: ClosedRange<Int> = 25...400
    // The device's own supported resistance-level range, in FTMS's raw,
    // vendor-defined "Resistance Level" *integer* unit — i.e. NOT yet divided
    // down by the 0.1 resolution, and NOT percent. Kept at full native
    // precision (rather than pre-rounded to whole levels) so
    // `setTargetResistancePercent` can interpolate smoothly instead of only
    // being able to reach a handful of whole-level steps; on some trainers
    // the real range is quite narrow, so it must never be treated as 0–100 %
    // directly. `setTargetResistancePercent` maps 0–100 % onto it.
    @Published private(set) var resistanceRangeRaw: ClosedRange<Int> = 0...1000
    /// The treadmill's own supported speed range, in km/h – placeholder
    /// values (a brisk walk to a fast run) until the device's actual
    /// "Supported Speed Range" characteristic (0x2AD4) is read, same
    /// "reasonable default, then replaced" pattern as `powerRange`.
    @Published private(set) var speedRangeKmh: ClosedRange<Double> = 1.0...20.0
    /// The treadmill's own supported inclination range, in percent –
    /// placeholder values (flat to a steep incline) until the device's own
    /// "Supported Inclination Range" characteristic (0x2AD5) is read.
    @Published private(set) var inclinationRangePercent: ClosedRange<Double> = 0.0...15.0
    @Published private(set) var machineKind: MachineKind = .unknown
    @Published private(set) var supportedFeatures: FitnessMachineFeatures?
    /// Every characteristic CoreBluetooth actually reported under the
    /// Fitness Machine Service, verbatim – shown at the top of
    /// `TrainerFeaturesView` for diagnosing exactly the kind of thing that
    /// prompted adding this: a trainer reporting characteristics this app
    /// didn't expect (a treadmill that turned out to *also* expose Indoor
    /// Bike Data, confusing `machineKind` detection – see that property's
    /// own assignment in `didDiscoverCharacteristicsFor` for the fix).
    /// Deliberately the raw list CoreBluetooth handed back, not filtered
    /// down to only the ones this app actually reads.
    @Published private(set) var discoveredCharacteristics: [CBUUID] = []

    let peripheral: CBPeripheral
    private weak var central: CBCentralManager?

    private var controlPoint: CBCharacteristic?
    private var hasControl = false

    init(peripheral: CBPeripheral, central: CBCentralManager) {
        self.peripheral = peripheral
        self.central = central
        super.init()
        peripheral.delegate = self
    }

    var deviceName: String { peripheral.name ?? "Trainer" }

    // MARK: - Callbacks invoked by BluetoothManager

    func handleConnected() {
        state = .discoveringServices
        peripheral.discoverServices([FTMS.fitnessMachineService])
    }

    func handleFailedToConnect(error: Error?) {
        state = .failed(error?.localizedDescription ?? "Connection failed")
    }

    func handleDisconnected(error: Error?) {
        hasControl = false
        state = .disconnected
    }

    func disconnect() {
        central?.cancelPeripheralConnection(peripheral)
    }

    /// Called by `BluetoothManager.reconnectCurrent()` right before issuing a
    /// fresh `connect()` call, so the UI reflects "Connecting …" immediately
    /// instead of lingering on "Disconnected" until the callback arrives.
    func prepareForReconnect() {
        state = .connecting
    }

    // MARK: - Control commands

    func setTargetPower(watts: Int) {
        guard hasControl, let cp = controlPoint else { return }
        let clamped = powerRange.clamp(watts)
        var payload = Data([FTMS.OpCode.setTargetPower.rawValue])
        payload.append(contentsOf: withUnsafeBytes(of: Int16(clamped).littleEndian) { Array($0) })
        peripheral.writeValue(payload, for: cp, type: .withResponse)
    }

    /// `percent` is 0–100 % of the *device's own* supported resistance range —
    /// not the raw FTMS resistance level. FTMS resistance levels are an
    /// arbitrary, vendor-defined unit (some trainers only support a handful of
    /// whole levels total), so this maps the requested percentage linearly
    /// onto whatever range `resistanceRangeRaw` reported, at the FTMS
    /// characteristic's own 0.1 resolution, rather than sending the percent
    /// value straight through as if it were the level itself.
    func setTargetResistancePercent(_ percent: Int) {
        guard hasControl, let cp = controlPoint else { return }
        let rawValue = rawResistanceLevel(forPercent: percent)
        var payload = Data([FTMS.OpCode.setTargetResistanceLevel.rawValue])
        payload.append(contentsOf: withUnsafeBytes(of: Int16(rawValue).littleEndian) { Array($0) })
        peripheral.writeValue(payload, for: cp, type: .withResponse)
    }

    /// The raw FTMS resistance-level integer (native 0.1 resolution, e.g. `47`
    /// meaning level 4.7) that `percent` currently maps to. Exposed for
    /// UI/diagnostics too, so what's actually transmitted can be told apart
    /// from the trainer's own physical response curve when resistance feels
    /// uneven across the range.
    func rawResistanceLevel(forPercent percent: Int) -> Int {
        let clampedPercent = (0...100).clamp(percent)
        let span = resistanceRangeRaw.upperBound - resistanceRangeRaw.lowerBound
        return resistanceRangeRaw.lowerBound + (span * clampedPercent + 50) / 100 // rounded, not truncated
    }

    /// FTMS "Indoor Bike Simulation" – the real SIM-mode mechanism (used by
    /// Zwift & co. for gradient simulation), not power/resistance faked into
    /// feeling like a hill. Wind speed is always 0 (no wind model); rolling/
    /// wind resistance use fixed, reasonable defaults (see
    /// `FTMS.SimulationDefaults`) since this app has no bike/tire/rider model
    /// to derive them from. `percent` is clamped to a physically plausible
    /// range as a safety margin against noisy source data (e.g. a GPX-derived
    /// grade profile).
    func setSimulationGrade(percent: Double) {
        guard hasControl, let cp = controlPoint else { return }
        let clampedPercent = (-25.0...25.0).clamp(percent)
        var payload = Data([FTMS.OpCode.setIndoorBikeSimulationParameters.rawValue])
        payload.append(contentsOf: withUnsafeBytes(of: Int16(0).littleEndian) { Array($0) }) // wind speed, 0.001 m/s resolution
        let gradeRaw = Int16((clampedPercent * 100).rounded()) // 0.01 % resolution
        payload.append(contentsOf: withUnsafeBytes(of: gradeRaw.littleEndian) { Array($0) })
        payload.append(FTMS.SimulationDefaults.rollingResistanceCoefficientRaw)
        payload.append(FTMS.SimulationDefaults.windResistanceCoefficientRaw)
        peripheral.writeValue(payload, for: cp, type: .withResponse)
    }

    /// Treadmill-only – see `ControlMode.speedIncline`. Op code 0x02, per
    /// the FTMS spec (section 4.16.2.3): UINT16 parameter, 0.01 km/h
    /// resolution, same encoding `TrainerMetrics` already reads
    /// Instantaneous Speed with. Clamped to the device's own reported
    /// `speedRangeKmh` rather than a fixed literal range (unlike
    /// `setSimulationGrade`'s ±25 %, there's no equivalent "supported grade
    /// range" characteristic for that one) – this device tells us exactly
    /// what it actually supports.
    func setTargetSpeed(kmh: Double) {
        guard hasControl, let cp = controlPoint else { return }
        let clamped = speedRangeKmh.clamp(kmh)
        let raw = UInt16((clamped * 100).rounded())
        var payload = Data([FTMS.OpCode.setTargetSpeed.rawValue])
        payload.append(contentsOf: withUnsafeBytes(of: raw.littleEndian) { Array($0) })
        peripheral.writeValue(payload, for: cp, type: .withResponse)
    }

    /// Treadmill-only – see `ControlMode.speedIncline`. Op code 0x03, per
    /// the FTMS spec (section 4.16.2.4): SINT16 parameter, 0.1 % resolution
    /// – signed, since some treadmills support a decline. Clamped to the
    /// device's own reported `inclinationRangePercent`, same reasoning as
    /// `setTargetSpeed(kmh:)` above.
    func setTargetInclination(percent: Double) {
        guard hasControl, let cp = controlPoint else { return }
        let clamped = inclinationRangePercent.clamp(percent)
        let raw = Int16((clamped * 10).rounded())
        var payload = Data([FTMS.OpCode.setTargetInclination.rawValue])
        payload.append(contentsOf: withUnsafeBytes(of: raw.littleEndian) { Array($0) })
        peripheral.writeValue(payload, for: cp, type: .withResponse)
    }

    private func requestControl() {
        guard let cp = controlPoint else { return }
        let payload = Data([FTMS.OpCode.requestControl.rawValue])
        peripheral.writeValue(payload, for: cp, type: .withResponse)
    }

    // MARK: - Workout control commands

    /// Starts a new workout, or resumes one after `pauseWorkout()`.
    func startOrResumeWorkout() {
        guard hasControl, let cp = controlPoint else { return }
        let payload = Data([FTMS.OpCode.startOrResume.rawValue])
        peripheral.writeValue(payload, for: cp, type: .withResponse)
    }

    func pauseWorkout() {
        guard hasControl, let cp = controlPoint else { return }
        let payload = Data([FTMS.OpCode.stopOrPause.rawValue, FTMS.StopPauseControlParameter.pause.rawValue])
        peripheral.writeValue(payload, for: cp, type: .withResponse)
    }

    func stopWorkout() {
        guard hasControl, let cp = controlPoint else { return }
        let payload = Data([FTMS.OpCode.stopOrPause.rawValue, FTMS.StopPauseControlParameter.stop.rawValue])
        peripheral.writeValue(payload, for: cp, type: .withResponse)
    }
}

extension TrainerConnection: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            state = .failed(error.localizedDescription)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == FTMS.fitnessMachineService }) else {
            state = .failed("Device does not support FTMS")
            return
        }
        peripheral.discoverCharacteristics([
            FTMS.fitnessMachineFeature,
            FTMS.indoorBikeData,
            FTMS.treadmillData,
            FTMS.fitnessMachineControlPoint,
            FTMS.supportedPowerRange,
            FTMS.supportedResistanceLevelRange
        ], for: service)
        // Speed/Inclination Range deliberately requested in their own,
        // separate `discoverCharacteristics` call – not bundled into the
        // one above. CoreBluetooth delivers one combined callback per call,
        // covering everything requested in it; bundling these two in with
        // the essential characteristics above would mean a device that
        // errors out or behaves oddly discovering *these* (both newly
        // added, unlike everything else in that first call, which was
        // already proven working) could take the whole thing down with it
        // – including the control point, with no way to even reach
        // `.ready`. Keeping them separate means that, worst case, just
        // `speedRangeKmh`/`inclinationRangePercent` stay at their
        // placeholder defaults instead.
        peripheral.discoverCharacteristics([
            FTMS.supportedSpeedRange,
            FTMS.supportedInclinationRange
        ], for: service)
    }

    /// `service.characteristics` is CoreBluetooth's *cumulative* list of
    /// everything discovered on this service so far, not just what the
    /// specific `discoverCharacteristics` call that triggered this callback
    /// asked for – so with two separate calls (see `didDiscoverServices`
    /// above), this fires twice, the second time re-including everything
    /// from the first. Every operation below (`setNotifyValue`/
    /// `readValue`) is idempotent, so reprocessing already-handled
    /// characteristics a second time is harmless, if slightly redundant.
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        // Never silently give up here – an unhandled error left the app
        // stuck on "Reading device data …" forever with zero indication of
        // why, the same failure shape as the control-point race this file
        // already fixed once, just from a different cause this time.
        guard error == nil, let characteristics = service.characteristics else {
            state = .failed(error?.localizedDescription ?? "Couldn't read this trainer's characteristics.")
            return
        }
        discoveredCharacteristics = characteristics.map(\.uuid)
        for characteristic in characteristics {
            switch characteristic.uuid {
            case FTMS.indoorBikeData:
                // A device exposing *both* data characteristics – seen on a
                // Paragon X 425A treadmill, almost certainly for broader
                // compatibility with apps that only ever learned to read
                // Indoor Bike Data, not evidence the device is actually a
                // bike – used to make this a coin flip: `characteristics`'
                // order isn't something CoreBluetooth guarantees means
                // anything, so whichever of the two cases happened to run
                // last simply won, silently, every time. Treadmill Data is
                // the more specific signal (this app has real treadmill-only
                // handling built on it – the Watch's Walk/Run choice,
                // treadmill-only metric tiles, …), so it now always wins
                // regardless of which order the two are actually discovered
                // in: only claim `.bike` here if nothing's already claimed
                // `.treadmill` below, and the `.treadmill` case itself never
                // checks first, so it can never be downgraded back either
                // way.
                if machineKind != .treadmill {
                    machineKind = .bike
                }
                peripheral.setNotifyValue(true, for: characteristic)
            case FTMS.treadmillData:
                machineKind = .treadmill
                peripheral.setNotifyValue(true, for: characteristic)
            case FTMS.fitnessMachineControlPoint:
                controlPoint = characteristic
                peripheral.setNotifyValue(true, for: characteristic) // indications for control responses
            case FTMS.fitnessMachineFeature, FTMS.supportedPowerRange, FTMS.supportedResistanceLevelRange,
                 FTMS.supportedSpeedRange, FTMS.supportedInclinationRange:
                peripheral.readValue(for: characteristic)
            default:
                break
            }
        }
    }

    /// Fires once CoreBluetooth confirms a `setNotifyValue(true, for:)` call
    /// actually took effect on the peripheral – for the control point
    /// specifically, this is the earliest safe moment to call
    /// `requestControl()`. Doing it any earlier (this used to happen right
    /// after calling `setNotifyValue`, back in `didDiscoverCharacteristicsFor`,
    /// with no wait at all) raced against the indication subscription still
    /// being set up: the trainer could process the Request Control write and
    /// send its response indication back before the phone had actually
    /// finished subscribing to it, silently dropping the one response
    /// `handleControlPointResponse` is waiting on – leaving the app stuck on
    /// "Reading device data …" forever, with no error to show for it and no
    /// way to tell why. Confirmed on a treadmill (Paragon X) that hit this
    /// race reliably; a bike trainer tested earlier apparently didn't – luck
    /// in the timing, not a difference in correctness, so this was always
    /// latently broken for any trainer that happened to respond fast enough.
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == FTMS.fitnessMachineControlPoint, characteristic.isNotifying else { return }
        requestControl()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case FTMS.fitnessMachineFeature:
            supportedFeatures = FitnessMachineFeatures(data: data)
        case FTMS.indoorBikeData:
            metrics = TrainerMetrics(data: data)
        case FTMS.treadmillData:
            metrics = TrainerMetrics(treadmillData: data)
        case FTMS.fitnessMachineControlPoint:
            handleControlPointResponse(data)
        case FTMS.supportedPowerRange:
            if data.count >= 4 {
                let bytes = [UInt8](data)
                let min = Int(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8))
                let max = Int(Int16(bitPattern: UInt16(bytes[2]) | UInt16(bytes[3]) << 8))
                if min < max { powerRange = min...max }
            }
        case FTMS.supportedResistanceLevelRange:
            if data.count >= 4 {
                let bytes = [UInt8](data)
                // Kept in raw FTMS units (0.1 resolution) — NOT divided down here,
                // so the full native precision survives into the percent mapping.
                let min = Int(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8))
                let max = Int(Int16(bitPattern: UInt16(bytes[2]) | UInt16(bytes[3]) << 8))
                if min < max { resistanceRangeRaw = min...max }
            }
        case FTMS.supportedSpeedRange:
            // UINT16, 0.01 km/h resolution (FTMS spec, section 4.11) –
            // unsigned, unlike Resistance/Power/Inclination above: a
            // treadmill's minimum speed is never negative.
            if data.count >= 4 {
                let bytes = [UInt8](data)
                let min = Double(UInt16(bytes[0]) | UInt16(bytes[1]) << 8) * 0.01
                let max = Double(UInt16(bytes[2]) | UInt16(bytes[3]) << 8) * 0.01
                if min < max { speedRangeKmh = min...max }
            }
        case FTMS.supportedInclinationRange:
            // SINT16, 0.1 % resolution (FTMS spec, section 4.12) – signed,
            // since some treadmills support a decline (negative incline).
            if data.count >= 4 {
                let bytes = [UInt8](data)
                let min = Double(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8)) * 0.1
                let max = Double(Int16(bitPattern: UInt16(bytes[2]) | UInt16(bytes[3]) << 8)) * 0.1
                if min < max { inclinationRangePercent = min...max }
            }
        default:
            break
        }
    }

    private func handleControlPointResponse(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == FTMS.OpCode.responseCode.rawValue else { return }
        let requestOpCode = bytes[1]
        let resultCode = bytes[2]
        guard requestOpCode == FTMS.OpCode.requestControl.rawValue else { return }
        if resultCode == FTMS.ResultCode.success.rawValue {
            hasControl = true
            state = .ready
        } else {
            state = .controlNotGranted
        }
    }
}
