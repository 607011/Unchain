import Foundation
import WatchConnectivity

/// iPhone-side half of the minimal Watch companion integration (see the
/// `UnchainWatch` target for the watchOS app) – lets the rider tap Start/
/// Stop on the Watch instead of the phone screen, while the Watch itself
/// simultaneously runs a real `HKWorkoutSession`. That's not just a
/// convenience: only a genuine Watch-side workout session lets Apple
/// Fitness add Resting/Basal Energy on top of Unchain's own Active-Energy
/// figure for that workout's "Total Calories" – something a lone iPhone
/// reliably can't (see `HealthKitManager`'s own doc comment for the full
/// explanation, added after exactly this was reported not working).
///
/// Scoped to Indoor Cycling only for now, enforced on the `ControlView` side
/// (`onStartRequested`) – the Watch has to declare its workout's activity
/// type *before* the ride starts, and unlike a bike, FTMS can't tell a
/// treadmill workout's eventual Walk/Run choice apart that early.
final class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    /// `true` once a "start" command from the Watch has been accepted, until
    /// the workout ends (from either side). Mirrors `ControlView`'s own
    /// `isWatchCompanionWorkout`, published here too so other views could
    /// react to it later if needed – not currently read anywhere else.
    @Published private(set) var isWatchCompanionActive = false

    /// Set by `ControlView` – attempts to start the workout exactly like
    /// tapping "Start Workout" would, returning whether that actually
    /// succeeded (e.g. `false` if no trainer is connected, or a treadmill
    /// is), so the Watch can show an error rather than a falsely-confirmed
    /// "Recording" state.
    var onStartRequested: (() -> Bool)?
    /// Set by `ControlView` – stops the current workout exactly like
    /// tapping "Stop" there would.
    var onStopRequested: (() -> Void)?

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Called by `ControlView` when the *phone* side ends the workout (the
    /// rider tapped Stop there, not on the Watch) while a Watch companion
    /// session is active, so the Watch's own `HKWorkoutSession` doesn't keep
    /// running, orphaned, after the phone has already moved on to the
    /// "Save to Health?" dialog.
    func notifyPhoneStoppedWorkout() {
        guard isWatchCompanionActive else { return }
        isWatchCompanionActive = false
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": "stop"], replyHandler: nil)
    }
}

extension WatchConnectivityManager: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// Required on iOS (unlike watchOS) since a phone can pair with more
    /// than one Watch over its lifetime – reactivates for whichever is
    /// current now.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        guard let command = message["command"] as? String else {
            replyHandler(["success": false])
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                replyHandler(["success": false])
                return
            }
            switch command {
            case "start":
                let success = self.onStartRequested?() ?? false
                self.isWatchCompanionActive = success
                replyHandler(["success": success])
            case "stop":
                self.onStopRequested?()
                self.isWatchCompanionActive = false
                replyHandler(["success": true])
            default:
                replyHandler(["success": false])
            }
        }
    }
}
