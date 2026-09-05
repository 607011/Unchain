import SwiftUI

/// Device-specific settings for one remembered trainer (`KnownTrainerDevice`)
/// – reached by tapping a row under `SettingsView`'s Devices section.
/// Deliberately takes just the lightweight, persisted `KnownTrainerDevice`
/// rather than a live `TrainerConnection` – these settings need to be
/// reachable (and editable) whether or not that particular trainer happens
/// to be connected right now, same reasoning as the rest of `SettingsView`.
struct TrainerDeviceSettingsView: View {
    let device: KnownTrainerDevice
    @State private var settings = TrainerDeviceSettings()

    var body: some View {
        Form {
            switch device.machineKind {
            case .treadmill:
                Section {
                    LabeledContent {
                        TextField("e.g. 3", text: startCountdownSecondsText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Start Countdown (seconds)")
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("Start Countdown")
                        InfoButton(text: "How many seconds this treadmill counts down on its own console (\"3, 2, 1, go\") after Unchain sends Start/Resume, before the belt actually starts moving. Used to hold the workout program's own clock at 0 for that long too, so its displayed elapsed time and interval changes stay in sync with when the treadmill is actually moving, instead of running ahead of it. Leave empty (0 seconds) if this treadmill starts immediately.")
                    }
                }
                Section {
                    LabeledContent {
                        TextField("e.g. 1.5", text: inclineSecondsText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    } label: {
                        Text("Seconds per 1° Incline")
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text("Incline Response")
                        InfoButton(text: "How long this treadmill actually takes to reach a new incline once commanded, per degree changed – e.g. 1.5 means a 2° change takes about 3 seconds to settle. Used to pace how fast the belt speed ramps to its next target during a .zwo interval change, instead of jumping there immediately while the incline is still catching up. Leave empty to assume 1 second per degree.")
                    }
                }
                liveMetricsSection
            case .bike:
                liveMetricsSection
            case .unknown:
                Section {
                    Text("No device-specific settings yet for this trainer.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Only actually needed for `liveMetricsSection`'s own
            // `.onMove`/`.onDelete` (`.unknown` has nothing to reorder) –
            // SwiftUI has no per-`Section` `EditMode`, so this covers the
            // whole `Form`, harmlessly, for the Start Countdown/Incline
            // Response text fields above it too on a treadmill.
            if device.machineKind != .unknown {
                EditButton()
            }
        }
        .onAppear {
            settings = TrainerDeviceSettingsStore.load(for: device.id)
        }
        .onChange(of: settings) { newValue in
            TrainerDeviceSettingsStore.save(newValue, for: device.id)
        }
    }

    /// The reorderable/removable "currently shown" list plus an "Add Live
    /// Data" menu for whatever's not shown yet – shared between the
    /// `.treadmill` and `.bike` cases above, each scoped to its own
    /// `LiveMetricKind.compatibleMachineKinds` subset via `effectiveLiveMetrics`/
    /// `metricsAvailableToAdd` below, which both already read
    /// `device.machineKind`.
    @ViewBuilder
    private var liveMetricsSection: some View {
        Section {
            ForEach(effectiveLiveMetrics) { kind in
                Text(kind.displayName)
            }
            .onMove { offsets, destination in
                var metrics = effectiveLiveMetrics
                metrics.move(fromOffsets: offsets, toOffset: destination)
                settings.liveMetrics = metrics
            }
            .onDelete { offsets in
                var metrics = effectiveLiveMetrics
                metrics.remove(atOffsets: offsets)
                settings.liveMetrics = metrics
            }
            if !metricsAvailableToAdd.isEmpty {
                Menu {
                    ForEach(metricsAvailableToAdd) { kind in
                        Button(kind.displayName) {
                            settings.liveMetrics = effectiveLiveMetrics + [kind]
                        }
                    }
                } label: {
                    Label("Add Live Data", systemImage: "plus.circle")
                }
            }
        } header: {
            HStack(spacing: 4) {
                Text("Live Data Shown")
                InfoButton(text: "Which live values this device's workout screen shows, and in what order – drag to reorder, swipe to remove, or add more from the list. Average values (and Max Heart Rate) track this specific workout so far, not your all-time values from Settings. Elevation Gain only shows a number for treadmills that report it themselves – there's no way to estimate it accurately otherwise.")
            }
        } footer: {
            Text("Tap Edit to reorder or remove.")
        }
    }

    /// `settings.effectiveLiveMetrics(for:)`, fixed to this specific
    /// device's own `machineKind` – shorthand used throughout
    /// `liveMetricsSection` above.
    private var effectiveLiveMetrics: [LiveMetricKind] {
        settings.effectiveLiveMetrics(for: device.machineKind)
    }

    /// `LiveMetricKind.allCases` compatible with this device's own
    /// `machineKind` and not already in `effectiveLiveMetrics` – what the
    /// "Add Live Data" menu offers.
    private var metricsAvailableToAdd: [LiveMetricKind] {
        LiveMetricKind.allCases.filter { $0.compatibleMachineKinds.contains(device.machineKind) && !effectiveLiveMetrics.contains($0) }
    }

    /// Accepts a comma as the decimal separator too, not just a period –
    /// the more natural key most German-locale keyboards actually offer on
    /// `.decimalPad`. `nil` (shown as an empty field, same "zero/empty"
    /// convention `SettingsView.zeroAsEmptyText` uses for its own numeric
    /// fields) rather than `0` when nothing's been entered, so an
    /// unmeasured device stays visibly unmeasured instead of silently
    /// reading as "instant".
    private var inclineSecondsText: Binding<String> {
        Binding(
            get: { settings.inclineChangeSecondsPerDegree.map { String(format: "%.1f", $0) } ?? "" },
            set: { settings.inclineChangeSecondsPerDegree = Double($0.replacingOccurrences(of: ",", with: ".")) }
        )
    }

    /// Same comma-accepting, empty-means-unset shape as `inclineSecondsText`
    /// above.
    private var startCountdownSecondsText: Binding<String> {
        Binding(
            get: { settings.startCountdownSeconds.map { String(format: "%.1f", $0) } ?? "" },
            set: { settings.startCountdownSeconds = Double($0.replacingOccurrences(of: ",", with: ".")) }
        )
    }
}
