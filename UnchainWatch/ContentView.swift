import SwiftUI

/// The Watch app's entire UI – deliberately just Start/Stop plus status, no
/// live power/heart rate display (see `WatchWorkoutManager`'s doc comment
/// for the scoping decision). Works for whichever of Indoor Cycling or
/// treadmill Walk/Run the iPhone is actually driving – this screen has no
/// picker of its own for that (the iPhone's "Walking or running?" dialog
/// covers it, even when Start was tapped here), which is also why the idle
/// icon below is a generic one rather than a bicycle.
struct ContentView: View {
    @StateObject private var workoutManager = WatchWorkoutManager()

    var body: some View {
        // Wrapped in a `ScrollView` deliberately – a plain `VStack` here
        // doesn't reliably fit every case's content within one screen on
        // the smallest watch models (e.g. a 40mm Series 6), which silently
        // pushes whatever's lowest (the Stop button, in the `.running`
        // case) below the visible area – tapping where it "should" be then
        // does nothing, since there's nothing there to hit. Confirmed on a
        // real device: `.running`'s Stop button was exactly this – present
        // in the view hierarchy, just not on screen.
        ScrollView {
            VStack(spacing: 10) {
                switch workoutManager.state {
                case .idle:
                    Image(systemName: "flame.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Button {
                        workoutManager.start()
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                case .starting:
                    ProgressView()
                    Text("Starting…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .running:
                    Label("Recording", systemImage: "record.circle.fill")
                        .font(.headline)
                        .foregroundStyle(.red)
                    Button {
                        workoutManager.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                case .stopping:
                    ProgressView()
                    Text("Stopping…")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        workoutManager.reset()
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
            .frame(maxWidth: .infinity)
        }
    }
}
