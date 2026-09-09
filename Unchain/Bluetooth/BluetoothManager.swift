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
    /// `UserDefaults` key for the last heart rate strap the user connected
    /// to (`CBPeripheral.identifier`, stable across scans and app launches
    /// for a given device on this phone – see Apple's docs on
    /// `CBPeripheral.identifier`). Lets a strap that's been paired with
    /// before reconnect on its own as soon as it's seen again (see
    /// `centralManager(_:didDiscover:)`) or, without even needing to be seen
    /// via scanning first, as soon as Bluetooth is ready (see
    /// `attemptAutoReconnectHeartRateStrap()`) – saving the one tap that
    /// would otherwise be needed every single time. Deliberately not
    /// extended to
    /// the trainer too: connecting there also navigates away to
    /// `ControlView` and requests exclusive control, a bigger, more
    /// consequential action than just starting to receive BPM values.
    private static let lastHeartRateStrapUUIDKey = "lastHeartRateStrapUUID"

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

    /// This instance is itself `central`'s own `CBCentralManagerDelegate` –
    /// same class of risk `TrainerConnection`/`HeartRateConnection`'s own
    /// `deinit` guards against (see that type's doc comment), just one
    /// level up: if CoreBluetooth already has a scan/connection-state
    /// callback queued for delivery to *this* object when it's deallocated,
    /// that callback still fires later regardless, on whatever this
    /// object's own storage holds by then. Belt-and-braces here too, though
    /// with a real caveat this doesn't have: under ordinary use this
    /// instance never actually gets deallocated at all – it's a
    /// `@StateObject` on `DeviceListView`, the app's persistent root,
    /// pushed on top of but never itself torn down by navigating into
    /// `ControlView`. The one path that *would* discard it is `UnchainApp`'s
    /// own `DeviceListView().id(languageOverride)`, rebuilding the whole
    /// subtree on a language change – unlike `TrainerConnection`'s own
    /// `disconnect()`, there's no equivalent "about to be released, still
    /// safe to act" checkpoint here to hang a `BLEDisconnectGracePeriod`
    /// call off of; `deinit` itself is too late to self-rescue from.
    /// `stopScan()` at least tells CoreBluetooth to stop scheduling
    /// anything *further*, same limited value `TrainerConnection.deinit`'s
    /// own `cancelPeripheralConnection` call already has.
    deinit {
        central?.stopScan()
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

    /// Reconnects the same `TrainerConnection` (e.g. after the trainer went out of
    /// range and dropped the link) instead of tearing it down and going back to
    /// the device list. Reuses the existing peripheral reference — `connect()`
    /// simply stays pending until the device is reachable again.
    func reconnectCurrent() {
        guard let connection = currentConnection else { return }
        connection.prepareForReconnect()
        central.connect(connection.peripheral, options: nil)
    }

    /// Resets the active trainer connection, e.g. when the user returns to
    /// the device list. Also explicitly disconnects, not just drops the
    /// reference – fixed after a real crash: leaving `ControlView` without
    /// this (a swipe-back mid-workout, in the case that prompted this fix)
    /// used to leave `TrainerConnection` "orphaned" – no longer referenced
    /// by the UI, but still `peripheral.delegate`, silently going on
    /// receiving CoreBluetooth callbacks in the background. If it later
    /// deallocated while one of those callbacks was still in flight (queued
    /// for deferred delivery on the main thread, per CoreBluetooth's own
    /// internal dispatch), the callback could land on already-freed/reused
    /// memory once delivered – textbook cause of an "unrecognized selector"
    /// crash. Calling `disconnect()` here first tells CoreBluetooth outright
    /// to stop delivering anything further for this peripheral, rather than
    /// leaving that entirely to however/whenever ARC happens to deallocate it.
    func clearConnection() {
        currentConnection?.disconnect()
        currentConnection = nil
    }

    // MARK: - Heart rate strap

    /// Found while investigating a second real "dangling CoreBluetooth
    /// callback" crash (2026-09-09, no user interaction at all – see
    /// `TrainerConnection.disconnect()`'s own doc comment for the class of
    /// bug and its `BLEDisconnectGracePeriod` fix): tapping a *different*
    /// strap's row in `DeviceListView` while already connected to one
    /// reaches this directly – `HeartRateDeviceRow` only ever offers a
    /// plain connect button for a device that *isn't* the currently
    /// connected one – and used to just overwrite `currentHeartRateConnection`
    /// outright, dropping the old `HeartRateConnection`'s last strong
    /// reference without ever calling its own `disconnect()` first. That's
    /// exactly the gap `BLEDisconnectGracePeriod` exists to close, bypassed
    /// entirely here – this old connection's own `deinit` still ran (the
    /// narrower catch-all, see its own doc comment), but the actual
    /// protection never got a chance to. Explicitly disconnecting the old
    /// one here first, same as `disconnectHeartRateCurrent()` already does
    /// on its own, closes it – not confirmed as *the* cause of that
    /// specific crash (no user interaction that time rules this exact path
    /// out for it), but a real, independently-reachable instance of the
    /// same class of bug, found along the way.
    func connectHeartRate(to device: DiscoveredDevice) {
        UserDefaults.standard.set(device.id.uuidString, forKey: Self.lastHeartRateStrapUUIDKey)
        currentHeartRateConnection?.disconnect()
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

    /// Reconnects a previously-used strap purely from its stored identifier
    /// (`lastHeartRateStrapUUIDKey`) – no scanning needed, and it works even
    /// before the strap is back in range. Once `central.connect(_:options:)`
    /// is issued for a peripheral CoreBluetooth already knows about
    /// (`retrievePeripherals(withIdentifiers:)`), the system holds that
    /// connection request pending and completes it automatically the moment
    /// the peripheral becomes reachable again – the same mechanism iOS
    /// itself uses to reconnect known accessories in the background.
    /// Complements, rather than replaces, the discovery-based auto-reconnect
    /// in `centralManager(_:didDiscover:)`, which only helps if scanning
    /// happens to still be running at that exact moment. That mattered in
    /// practice: `ControlView` itself never scans (see `connect(to:)`'s own
    /// note on `stopScan()`), so a strap that hadn't already reconnected
    /// *before* the trainer did – put on afterwards, or just missed during
    /// the brief device-list scan – could never be found again for the rest
    /// of the session without this.
    private func attemptAutoReconnectHeartRateStrap() {
        guard currentHeartRateConnection == nil,
              let uuidString = UserDefaults.standard.string(forKey: Self.lastHeartRateStrapUUIDKey),
              let uuid = UUID(uuidString: uuidString),
              let peripheral = central.retrievePeripherals(withIdentifiers: [uuid]).first else { return }
        let connection = HeartRateConnection(peripheral: peripheral, central: central)
        currentHeartRateConnection = connection
        central.connect(peripheral, options: nil)
    }
}

extension BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isBluetoothReady = (central.state == .poweredOn)
        if isBluetoothReady {
            startScan()
            attemptAutoReconnectHeartRateStrap()
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

        // Reconnect a previously-used strap the moment it's seen again,
        // rather than making the user tap it every time – see
        // `lastHeartRateStrapUUIDKey`. `currentHeartRateConnection == nil`
        // guards against re-triggering while already connected/connecting
        // to it (or to some other strap the user picked instead).
        if kind == .heartRateMonitor,
           currentHeartRateConnection == nil,
           device.id.uuidString == UserDefaults.standard.string(forKey: Self.lastHeartRateStrapUUIDKey) {
            connectHeartRate(to: device)
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
            // Deliberately deferred, not called inline here – identified as
            // the likely real trigger for a crash investigated right above
            // (same signature: a dangling CoreBluetooth main-thread
            // callback), once it turned out a Polar H10 dropping out mid-
            // workout, on its own, no interaction needed, is a known real
            // quirk of that specific strap – exactly this path, and the
            // only one of the app's auto-reconnect paths that fires with
            // zero user interaction (the trainer has no equivalent –
            // `reconnectCurrent()` only ever runs from a tapped button).
            // Calling `central.connect(_:options:)` straight back out
            // *from inside* CoreBluetooth's own delivery of the disconnect
            // that made it necessary is exactly the kind of reentrancy
            // that's plausible to provoke internal state confusion in
            // CoreBluetooth itself – and, for a strap that's genuinely
            // flapping (poor skin contact, on-again-off-again), doing this
            // inline means immediately reconnecting into the very next
            // drop too, with no gap between them at all. A short,
            // deliberate delay breaks the direct reentrancy and doubles as
            // a natural debounce against exactly that flapping, rather
            // than hammering `connect` in a tight loop. Not provable as
            // *the* cause from an unsymbolicated crash report – see that
            // entry's own doc comment for the honest limits here – but the
            // one concrete change directly motivated by what actually
            // matches "no interaction at all".
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.currentHeartRateConnection === heartRate else { return }
                self.central.connect(peripheral, options: nil)
            }
        }
    }
}
