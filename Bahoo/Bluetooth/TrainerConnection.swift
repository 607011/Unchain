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
    var id: String { rawValue }
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
    @Published private(set) var machineKind: MachineKind = .unknown
    @Published private(set) var supportedFeatures: FitnessMachineFeatures?

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
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            switch characteristic.uuid {
            case FTMS.indoorBikeData:
                machineKind = .bike
                peripheral.setNotifyValue(true, for: characteristic)
            case FTMS.treadmillData:
                machineKind = .treadmill
                peripheral.setNotifyValue(true, for: characteristic)
            case FTMS.fitnessMachineControlPoint:
                controlPoint = characteristic
                peripheral.setNotifyValue(true, for: characteristic) // indications for control responses
            case FTMS.fitnessMachineFeature, FTMS.supportedPowerRange, FTMS.supportedResistanceLevelRange:
                peripheral.readValue(for: characteristic)
            default:
                break
            }
        }
        if controlPoint != nil {
            requestControl()
        }
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
