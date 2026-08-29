import Foundation
import HealthKit
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
/// Works for both Indoor Cycling and treadmill Walk/Run – for a treadmill,
/// `onStartRequested`'s completion doesn't fire until the rider's actually
/// answered `ControlView`'s "Walking or running?" dialog (shown on the
/// phone even when Start was tapped on the Watch, since the Watch's own
/// screen deliberately has no picker of its own – see `UnchainWatch`'s
/// `ContentView`), which is also what the Watch needs to know before it can
/// declare its own workout's activity type.
final class WatchConnectivityManager: NSObject, ObservableObject {
    static let shared = WatchConnectivityManager()

    /// `true` once a "start" command from the Watch has been accepted, until
    /// the workout ends (from either side). Mirrors `ControlView`'s own
    /// `isWatchCompanionWorkout`, published here too so other views could
    /// react to it later if needed – not currently read anywhere else.
    @Published private(set) var isWatchCompanionActive = false

    /// Set by `ControlView` – attempts to start the workout exactly like
    /// tapping "Start Workout" would, calling `completion` with whether that
    /// actually succeeded (e.g. `false` if no trainer is connected) and, if
    /// so, the activity type the workout started as – so the Watch can
    /// declare the same one for its own `HKWorkoutSession`, or show an error
    /// rather than a falsely-confirmed "Recording" state. A completion, not
    /// a plain return value: for a treadmill, `ControlView` doesn't actually
    /// know the answer until the rider's picked Walk or Run on the phone,
    /// which can take a moment – see that type's own doc comment.
    var onStartRequested: ((_ completion: @escaping (Bool, HKWorkoutActivityType?) -> Void) -> Void)?
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
                guard let onStartRequested = self.onStartRequested else {
                    replyHandler(["success": false])
                    return
                }
                // May not call `replyHandler` right away – see this
                // property's own doc comment – but `WCSession` is fine
                // holding a reply open while the rider answers a dialog on
                // the phone.
                onStartRequested { success, activityType in
                    self.isWatchCompanionActive = success
                    var reply: [String: Any] = ["success": success]
                    if let activityType {
                        reply["activityType"] = activityType.rawValue
                    }
                    replyHandler(reply)
                }
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
