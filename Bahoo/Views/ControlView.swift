import SwiftUI
import HealthKit

struct ControlView: View {
    @ObservedObject var connection: TrainerConnection
    @ObservedObject var bluetooth: BluetoothManager
    @StateObject private var session: WorkoutSession

    @State private var mode: ControlMode = .power
    @State private var targetPower: Int = 100
    @State private var targetResistance: Int = 20
    @State private var saveResult: SaveResultAlert?

    private let powerStep = 5
    private let resistanceStep = 5

    init(connection: TrainerConnection, bluetooth: BluetoothManager) {
        self.connection = connection
        self.bluetooth = bluetooth
        _session = StateObject(wrappedValue: WorkoutSession(
            connection: connection,
            heartRateProvider: { [weak bluetooth] in bluetooth?.currentHeartRateConnection }
        ))
    }

    var body: some View {
        VStack(spacing: 32) {
            statusHeader
            metricsRow
            workoutControls

            Picker("Mode", selection: $mode) {
                ForEach(ControlMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            Spacer()
            controlButtons
            Spacer()
        }
        .padding()
        .navigationTitle(connection.deviceName)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Disconnect") {
                    bluetooth.disconnectCurrent()
                    bluetooth.clearConnection()
                }
            }
        }
        .onChange(of: connection.powerRange) { newRange in
            targetPower = newRange.clamp(targetPower)
        }
        .onChange(of: connection.resistanceRange) { newRange in
            targetResistance = newRange.clamp(targetResistance)
        }
        .onAppear {
            targetPower = connection.powerRange.clamp(targetPower)
            targetResistance = connection.resistanceRange.clamp(targetResistance)
        }
        .confirmationDialog(
            "Save workout to Apple Health?",
            isPresented: Binding(
                get: { session.pendingSummary != nil },
                set: { isPresented in if !isPresented { session.reset() } }
            ),
            titleVisibility: .visible
        ) {
            if let summary = session.pendingSummary {
                saveDialogButtons(for: summary)
            }
        }
        .alert(item: $saveResult) { result in
            Alert(title: Text(result.title), message: Text(result.message), dismissButton: .default(Text("OK")))
        }
    }

    private var statusHeader: some View {
        Group {
            switch connection.state {
            case .connecting:
                Label("Connecting …", systemImage: "dot.radiowaves.left.and.right")
            case .discoveringServices:
                Label("Reading device data …", systemImage: "dot.radiowaves.left.and.right")
            case .ready:
                Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .controlNotGranted:
                Label("Control not possible", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .failed(let message):
                Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            case .disconnected:
                Label("Disconnected", systemImage: "xmark.circle").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
    }

    private var metricsRow: some View {
        HStack(spacing: 24) {
            metricTile(title: "Watt", value: connection.metrics.instantaneousPowerWatts.map { "\($0)" } ?? "–")
            metricTile(title: "RPM", value: connection.metrics.instantaneousCadenceRPM.map { String(format: "%.0f", $0) } ?? "–")
            metricTile(title: "km/h", value: connection.metrics.instantaneousSpeedKmh.map { String(format: "%.1f", $0) } ?? "–")
            if let heartRate = bluetooth.currentHeartRateConnection {
                HeartRateTile(connection: heartRate)
            }
        }
    }

    private func metricTile(title: String, value: String) -> some View {
        VStack {
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var workoutControls: some View {
        VStack(spacing: 12) {
            Text(elapsedTimeLabel)
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(session.state == .idle ? .secondary : .primary)

            HStack(spacing: 16) {
                switch session.state {
                case .idle, .ended:
                    Button("Start Workout") { session.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(connection.state != .ready)
                case .running:
                    Button("Pause") { session.pause() }
                        .buttonStyle(.bordered)
                    Button("Stop") { session.stop() }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                case .paused:
                    Button("Resume") { session.resume() }
                        .buttonStyle(.borderedProminent)
                    Button("Stop") { session.stop() }
                        .buttonStyle(.bordered)
                        .tint(.red)
                }
            }
        }
    }

    private var elapsedTimeLabel: String {
        let minutes = session.elapsedSeconds / 60
        let seconds = session.elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var controlButtons: some View {
        VStack(spacing: 16) {
            Text(currentTargetLabel)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()

            HStack(spacing: 40) {
                stepButton(systemImage: "minus.circle.fill") { step(-1) }
                stepButton(systemImage: "plus.circle.fill") { step(1) }
            }
        }
    }

    private var currentTargetLabel: String {
        switch mode {
        case .power: return "\(targetPower) W"
        case .resistance: return "\(targetResistance) %"
        }
    }

    private func stepButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 56))
        }
        .disabled(connection.state != .ready)
    }

    private func step(_ direction: Int) {
        switch mode {
        case .power:
            targetPower = connection.powerRange.clamp(targetPower + direction * powerStep)
            connection.setTargetPower(watts: targetPower)
        case .resistance:
            targetResistance = connection.resistanceRange.clamp(targetResistance + direction * resistanceStep)
            connection.setTargetResistancePercent(targetResistance)
        }
    }

    /// Buttons offered in the post-workout save dialog. Which activity types are
    /// offered depends on the detected machine kind – FTMS can tell us it's a
    /// treadmill, but not whether the user walked or ran, so that's a manual choice.
    @ViewBuilder
    private func saveDialogButtons(for summary: WorkoutSummary) -> some View {
        switch summary.machineKind {
        case .bike:
            Button("Save as Indoor Cycling") { save(summary, as: .cycling) }
        case .treadmill:
            Button("Save as Indoor Walk") { save(summary, as: .walking) }
            Button("Save as Indoor Run") { save(summary, as: .running) }
        case .unknown:
            Button("Save Workout") { save(summary, as: .other) }
        }
        Button("Discard", role: .destructive) { session.reset() }
    }

    private func save(_ summary: WorkoutSummary, as activityType: HKWorkoutActivityType) {
        HealthKitManager.shared.save(summary, as: activityType) { result in
            switch result {
            case .success:
                saveResult = SaveResultAlert(title: "Saved", message: "The workout was saved to Apple Health.")
            case .failure(let error):
                saveResult = SaveResultAlert(title: "Not Saved", message: error.localizedDescription)
            }
            session.reset()
        }
    }
}

private struct SaveResultAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// Dedicated subview so that live heart rate updates (a separate
/// ObservableObject) redraw the tile without observing the whole ControlView.
private struct HeartRateTile: View {
    @ObservedObject var connection: HeartRateConnection

    var body: some View {
        VStack {
            Text(connection.bpm.map { "\($0)" } ?? "–")
                .font(.system(size: 28, weight: .semibold, design: .rounded))
            Text("♥ bpm").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
