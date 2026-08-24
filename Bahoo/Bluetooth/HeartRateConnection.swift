import Foundation
import CoreBluetooth

enum HeartRateConnectionState: Equatable {
    case connecting
    case discoveringServices
    case ready
    case failed(String)
    case disconnected
}

/// Represents the active connection to exactly one heart rate strap: discovery of
/// the heart rate characteristic and live heart rate. Runs independently and in
/// parallel to any existing `TrainerConnection`.
final class HeartRateConnection: NSObject, ObservableObject {
    @Published private(set) var state: HeartRateConnectionState = .connecting
    @Published private(set) var bpm: Int?

    let peripheral: CBPeripheral
    private weak var central: CBCentralManager?

    init(peripheral: CBPeripheral, central: CBCentralManager) {
        self.peripheral = peripheral
        self.central = central
        super.init()
        peripheral.delegate = self
    }

    var deviceName: String { peripheral.name ?? "HR Strap" }

    // MARK: - Callbacks invoked by BluetoothManager

    func handleConnected() {
        state = .discoveringServices
        peripheral.discoverServices([HeartRate.service])
    }

    func handleFailedToConnect(error: Error?) {
        state = .failed(error?.localizedDescription ?? "Connection failed")
    }

    func handleDisconnected(error: Error?) {
        bpm = nil
        state = .disconnected
    }

    func disconnect() {
        central?.cancelPeripheralConnection(peripheral)
    }
}

extension HeartRateConnection: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == HeartRate.service }) else {
            state = .failed("Device does not support Heart Rate service")
            return
        }
        peripheral.discoverCharacteristics([HeartRate.measurement], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == HeartRate.measurement }) else {
            state = .failed("Heart rate measurement not available")
            return
        }
        peripheral.setNotifyValue(true, for: characteristic)
        state = .ready
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == HeartRate.measurement, let data = characteristic.value else { return }
        bpm = Self.parseBPM(from: data)
    }

    /// Parses the Heart Rate Measurement characteristic (Bluetooth SIG spec, section 3.1.1).
    /// Byte 0 = flags; bit 0 determines whether the measurement follows as UInt8 (1 byte) or
    /// UInt16 (2 bytes). The Energy Expended and RR-Interval fields aren't needed here
    /// and are therefore ignored.
    private static func parseBPM(from data: Data) -> Int? {
        let bytes = [UInt8](data)
        guard let flags = bytes.first else { return nil }
        let isUInt16 = (flags & 0x01) != 0
        if isUInt16 {
            guard bytes.count >= 3 else { return nil }
            return Int(UInt16(bytes[1]) | (UInt16(bytes[2]) << 8))
        } else {
            guard bytes.count >= 2 else { return nil }
            return Int(bytes[1])
        }
    }
}
