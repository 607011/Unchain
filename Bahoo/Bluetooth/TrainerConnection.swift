import Foundation
import CoreBluetooth

enum ControlMode: String, CaseIterable, Identifiable {
    case power = "Power"
    case resistance = "Resistance"
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
    @Published private(set) var resistanceRange: ClosedRange<Int> = 0...100 // in percent
    @Published private(set) var machineKind: MachineKind = .unknown

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

    // MARK: - Control commands

    func setTargetPower(watts: Int) {
        guard hasControl, let cp = controlPoint else { return }
        let clamped = powerRange.clamp(watts)
        var payload = Data([FTMS.OpCode.setTargetPower.rawValue])
        payload.append(contentsOf: withUnsafeBytes(of: Int16(clamped).littleEndian) { Array($0) })
        peripheral.writeValue(payload, for: cp, type: .withResponse)
    }

    func setTargetResistancePercent(_ percent: Int) {
        guard hasControl, let cp = controlPoint else { return }
        let clamped = resistanceRange.clamp(percent)
        // FTMS expects the resistance value with a resolution of 0.1 -> *10
        var payload = Data([FTMS.OpCode.setTargetResistanceLevel.rawValue])
        payload.append(contentsOf: withUnsafeBytes(of: Int16(clamped * 10).littleEndian) { Array($0) })
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
            case FTMS.supportedPowerRange, FTMS.supportedResistanceLevelRange:
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
                let min = Int(Int16(bitPattern: UInt16(bytes[0]) | UInt16(bytes[1]) << 8)) / 10
                let max = Int(Int16(bitPattern: UInt16(bytes[2]) | UInt16(bytes[3]) << 8)) / 10
                if min < max { resistanceRange = min...max }
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
