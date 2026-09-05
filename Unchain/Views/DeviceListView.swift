import SwiftUI

struct DeviceListView: View {
    @StateObject private var bluetooth = BluetoothManager()
    /// Settings (FTP, Max/Resting Heart Rate, …) are rider profile data, not
    /// tied to any particular trainer connection – so unlike most of
    /// `ControlView`'s own sheets, the gear here needs to work with no
    /// device connected at all, e.g. setting these up before the first ride
    /// ever pairs anything. `ControlView` keeps its own copy of this same
    /// gear button for whenever settings need adjusting mid-session instead
    /// of backing all the way out to this screen.
    @State private var isShowingSettings = false
    /// Every trainer this app has ever connected to (see `TrainerDeviceStore`),
    /// not just whatever the current scan happens to have found – lets
    /// `deviceList` still show a device the rider used last time even while
    /// it's out of range right now (see `outOfRangeTrainerDevices`), rather
    /// than the screen looking like it's forgotten about it entirely.
    /// Reloaded on every appearance, same reasoning `SettingsView`'s own
    /// `knownDevices` doc comment already gives: plain `UserDefaults`, not
    /// something SwiftUI observes on its own.
    @State private var knownTrainerDevices: [KnownTrainerDevice] = []

    var body: some View {
        NavigationStack {
            Group {
                if !bluetooth.isBluetoothReady {
                    unavailableView
                } else if bluetooth.discoveredDevices.isEmpty && knownTrainerDevices.isEmpty {
                    searchingView
                } else {
                    deviceList
                }
            }
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if bluetooth.isScanning {
                        Button("Stop") { bluetooth.stopScan() }
                    } else {
                        Button {
                            bluetooth.startScan()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .navigationDestination(isPresented: Binding(
                get: { bluetooth.currentConnection != nil },
                set: { isPresented in
                    if !isPresented { bluetooth.clearConnection() }
                }
            )) {
                if let connection = bluetooth.currentConnection {
                    ControlView(connection: connection, bluetooth: bluetooth)
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
        .onAppear {
            bluetooth.startScan()
            knownTrainerDevices = TrainerDeviceStore.loadAll()
        }
    }

    /// Known trainers (see `TrainerDeviceStore`) not currently among
    /// `bluetooth.trainerDevices` – i.e. not seen by this scan (yet, or at
    /// all this time). Shown grayed out, beneath the actually-reachable
    /// ones, rather than just vanishing from the list the moment a
    /// previously-used trainer happens to be out of range or switched off.
    private var outOfRangeTrainerDevices: [KnownTrainerDevice] {
        let discoveredIDs = Set(bluetooth.trainerDevices.map { $0.id })
        return knownTrainerDevices.filter { !discoveredIDs.contains($0.id) }
    }

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Bluetooth unavailable")
                .font(.headline)
            Text("Please enable Bluetooth in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var searchingView: some View {
        VStack(spacing: 16) {
            if bluetooth.isScanning {
                ProgressView()
                Text("Searching for trainers & HR straps …")
                    .foregroundStyle(.secondary)
                Text("Turn on your trainer or treadmill and keep it within Bluetooth range.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Cancel search") {
                    bluetooth.stopScan()
                }
                .buttonStyle(.bordered)
            } else {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
                Text("No devices found")
                    .foregroundStyle(.secondary)
                Button("Search again") {
                    bluetooth.startScan()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    private var deviceList: some View {
        List {
            Section {
                if bluetooth.trainerDevices.isEmpty && outOfRangeTrainerDevices.isEmpty {
                    Text("No trainer found")
                        .foregroundStyle(.secondary)
                }
                ForEach(bluetooth.trainerDevices) { device in
                    Button {
                        bluetooth.connect(to: device)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.headline)
                                Text("RSSI \(device.rssi) dBm")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                // Below the actually-reachable ones, not interspersed –
                // grayed out and not a `Button` at all (nothing to actually
                // do while it's unreachable), just a reminder this trainer
                // exists and was used before.
                ForEach(outOfRangeTrainerDevices) { device in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Not in Bluetooth Range")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(device.name).font(.headline)
                    }
                    .foregroundStyle(.secondary)
                }
            } header: {
                Text("Smart Trainer")
            } footer: {
                Text("Unchain controls and monitors FTMS-compatible smart trainers and treadmills over Bluetooth.")
            }

            Section {
                if bluetooth.heartRateDevices.isEmpty {
                    Text("No strap found")
                        .foregroundStyle(.secondary)
                }
                ForEach(bluetooth.heartRateDevices) { device in
                    HeartRateDeviceRow(device: device, bluetooth: bluetooth)
                }
            } header: {
                Text("Heart Rate Strap")
            } footer: {
                Text("Optional – shows heart rate zones during your workout and is recorded to the Health app when you save it.")
            }
        }
        .refreshable { bluetooth.startScan() }
    }
}

/// Row for a discovered HR strap device. Tapping connects or disconnects – unlike
/// the trainer, this does not navigate away, since the strap can stay paired
/// independently of the trainer session.
private struct HeartRateDeviceRow: View {
    let device: DiscoveredDevice
    @ObservedObject var bluetooth: BluetoothManager

    var body: some View {
        if let connection = bluetooth.currentHeartRateConnection, connection.peripheral.identifier == device.id {
            ConnectedHeartRateRow(device: device, connection: connection, bluetooth: bluetooth)
        } else {
            Button {
                bluetooth.connectHeartRate(to: device)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name).font(.headline)
                        Text("RSSI \(device.rssi) dBm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.primary)
        }
    }
}

/// Dedicated subview so that changes to `HeartRateConnection` (state, bpm)
/// are reflected live in the list – not just changes to the reference itself.
private struct ConnectedHeartRateRow: View {
    let device: DiscoveredDevice
    @ObservedObject var connection: HeartRateConnection
    let bluetooth: BluetoothManager

    var body: some View {
        Button {
            bluetooth.disconnectHeartRateCurrent()
            bluetooth.clearHeartRateConnection()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if connection.state == .ready {
                    Image(systemName: "heart.fill").foregroundStyle(.red)
                } else {
                    ProgressView()
                }
            }
        }
        .foregroundStyle(.primary)
    }

    private var statusText: String {
        switch connection.state {
        case .connecting: return String(localized: "Connecting …")
        case .discoveringServices: return String(localized: "Reading device data …")
        case .ready: return connection.bpm.map { String(localized: "\($0) bpm – tap to disconnect") } ?? String(localized: "Connected – tap to disconnect")
        case .failed(let message): return message
        case .disconnected: return String(localized: "Disconnected")
        }
    }
}
