import Foundation
import CoreBluetooth

/// Which role a device found during scanning can take on.
enum DeviceKind: Equatable {
    case trainer
    case heartRateMonitor
}

/// A device found during scanning that offers the FTMS or the Heart Rate service.
struct DiscoveredDevice: Identifiable, Equatable {
    let id: UUID
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int
    var kind: DeviceKind

    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool {
        lhs.id == rhs.id
    }
}

/// Central point of contact for BLE scanning and connections.
/// Currently holds exactly one active trainer connection plus, optionally,
/// a heart rate strap connection running in parallel (MVP scope).
final class BluetoothManager: NSObject, ObservableObject {
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var isBluetoothReady = false
    @Published private(set) var isScanning = false
    @Published private(set) var currentConnection: TrainerConnection?
    @Published private(set) var currentHeartRateConnection: HeartRateConnection?

    private var central: CBCentralManager!

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil) // nil -> callbacks on the main thread
    }

    var trainerDevices: [DiscoveredDevice] { discoveredDevices.filter { $0.kind == .trainer } }
    var heartRateDevices: [DiscoveredDevice] { discoveredDevices.filter { $0.kind == .heartRateMonitor } }

    func startScan() {
        guard central.state == .poweredOn else { return }
        discoveredDevices.removeAll()
        isScanning = true
        central.scanForPeripherals(
            withServices: [FTMS.fitnessMachineService, HeartRate.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScan() {
        central.stopScan()
        isScanning = false
    }

    // MARK: - Trainer

    func connect(to device: DiscoveredDevice) {
        stopScan()
        let connection = TrainerConnection(peripheral: device.peripheral, central: central)
        currentConnection = connection
        central.connect(device.peripheral, options: nil)
    }

    func disconnectCurrent() {
        currentConnection?.disconnect()
    }

    /// Reconnects the same `TrainerConnection` (e.g. after the trainer went out of
    /// range and dropped the link) instead of tearing it down and going back to
    /// the device list. Reuses the existing peripheral reference — `connect()`
    /// simply stays pending until the device is reachable again.
    func reconnectCurrent() {
        guard let connection = currentConnection else { return }
        connection.prepareForReconnect()
        central.connect(connection.peripheral, options: nil)
    }

    /// Resets the active trainer connection, e.g. when the user returns to the device list.
    func clearConnection() {
        currentConnection = nil
    }

    // MARK: - Heart rate strap

    func connectHeartRate(to device: DiscoveredDevice) {
        let connection = HeartRateConnection(peripheral: device.peripheral, central: central)
        currentHeartRateConnection = connection
        central.connect(device.peripheral, options: nil)
    }

    func disconnectHeartRateCurrent() {
        currentHeartRateConnection?.disconnect()
    }

    func clearHeartRateConnection() {
        currentHeartRateConnection = nil
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isBluetoothReady = (central.state == .poweredOn)
        if isBluetoothReady {
            startScan()
        } else {
            discoveredDevices.removeAll()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let kind: DeviceKind = advertisedServices.contains(HeartRate.service) ? .heartRateMonitor : .trainer
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unknown device"
        let device = DiscoveredDevice(id: peripheral.identifier, peripheral: peripheral, name: name, rssi: RSSI.intValue, kind: kind)
        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index] = device
        } else {
            discoveredDevices.append(device)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        if peripheral.identifier == currentConnection?.peripheral.identifier {
            currentConnection?.handleConnected()
        } else if peripheral.identifier == currentHeartRateConnection?.peripheral.identifier {
            currentHeartRateConnection?.handleConnected()
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        if peripheral.identifier == currentConnection?.peripheral.identifier {
            currentConnection?.handleFailedToConnect(error: error)
        } else if peripheral.identifier == currentHeartRateConnection?.peripheral.identifier {
            currentHeartRateConnection?.handleFailedToConnect(error: error)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        if peripheral.identifier == currentConnection?.peripheral.identifier {
            currentConnection?.handleDisconnected(error: error)
        } else if let heartRate = currentHeartRateConnection, peripheral.identifier == heartRate.peripheral.identifier {
            heartRate.handleDisconnected(error: error)
            // A deliberate disconnect (tapping the row in the device list)
            // already clears `currentHeartRateConnection` before this callback
            // fires, so reaching here means the strap dropped out unexpectedly
            // (out of range, low battery, …) — retry automatically instead of
            // making the user notice and reconnect by hand, since there's no
            // "Reconnect" button for the HR strap.
            heartRate.prepareForReconnect()
            central.connect(peripheral, options: nil)
        }
    }
}
