import SwiftUI

struct DeviceListView: View {
    @StateObject private var bluetooth = BluetoothManager()

    var body: some View {
        NavigationStack {
            Group {
                if !bluetooth.isBluetoothReady {
                    unavailableView
                } else if bluetooth.discoveredDevices.isEmpty {
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
        .onAppear { bluetooth.startScan() }
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
            Section("Smart Trainer") {
                if bluetooth.trainerDevices.isEmpty {
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
            }

            Section("Heart Rate Strap") {
                if bluetooth.heartRateDevices.isEmpty {
                    Text("No strap found")
                        .foregroundStyle(.secondary)
                }
                ForEach(bluetooth.heartRateDevices) { device in
                    HeartRateDeviceRow(device: device, bluetooth: bluetooth)
                }
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
