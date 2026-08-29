import Foundation
import HealthKit
import WatchConnectivity

/// Owns the Watch side of Unchain's minimal Watch companion integration –
/// starts a real `HKWorkoutSession`/`HKLiveWorkoutBuilder` when the rider
/// taps Start here, in lockstep with `notifyPhoneToStart` telling Unchain
/// on the iPhone to start its own trainer-driving session at the same
/// moment (see `WatchConnectivityManager`, the iOS-side counterpart, for
/// the full picture of why this exists at all: only a genuine Watch-side
/// workout session lets Apple Fitness add Resting/Basal Energy on top of
/// Unchain's own Active-Energy figure for that workout's "Total Calories" –
/// something a lone iPhone reliably can't).
///
/// Deliberately minimal: no live power/heart rate display here – just
/// Start/Stop, with this session handling energy/heart-rate collection and
/// the eventual Health save entirely on its own, the same way the stock
/// Workout app would. Works for Indoor Cycling and treadmill Walk/Run alike
/// – whichever `HKWorkoutActivityType` the iPhone's reply to
/// `notifyPhoneToStart` names is what `beginSession(activityType:)` uses.
/// This side never decides Walk vs. Run itself: for a treadmill, the iPhone
/// doesn't know the answer either until the rider's picked one in its own
/// "Walking or running?" dialog – shown there, not here, deliberately (see
/// `ContentView`'s own note on staying picker-free) – so `start()` simply
/// waits for that reply, however long it takes.
final class WatchWorkoutManager: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case running
        case stopping
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    /// See `armStoppingWatchdog()`/`stop()`. Cancelled the moment `.stopping`
    /// actually resolves (from `finishWorkout()`) so it can never fire late
    /// and clobber a state that already moved on.
    private var stoppingWatchdog: DispatchWorkItem?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
        recoverOrphanedSessionIfAny()
    }

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// Guards against exactly the bug that produced duplicate Health
    /// entries during testing: if the app relaunches (reinstalled, or
    /// force-quit) while a previous `HKWorkoutSession` is still active at
    /// the system level – orphaned, with no `WatchWorkoutManager` instance
    /// left to manage it – starting a *new* session on top would leave both
    /// eventually finishing and saving separately, as two (or more) Health
    /// entries for what the rider experienced as one continuous session.
    /// Takes ownership of any such orphan on launch and cleanly ends it
    /// through the exact same state-driven `.stopped` → `end()` → `.ended`
    /// path `stop()` uses, rather than silently resuming it as a fresh
    /// "Recording" state the rider never asked for.
    private func recoverOrphanedSessionIfAny() {
        store.recoverActiveWorkoutSession { [weak self] recovered, _ in
            guard let self, let recovered else { return }
            DispatchQueue.main.async {
                self.session = recovered
                self.builder = recovered.associatedWorkoutBuilder()
                recovered.delegate = self
                self.builder?.delegate = self
                recovered.stopActivity(with: Date())
            }
        }
    }

    /// Just what this session itself writes – no read types at all (unlike
    /// `HealthKitManager` on the iOS side, this never reads anything back).
    /// Covers both distance types regardless of which activity actually
    /// starts: a treadmill workout (unlike a bike) can get distance readings
    /// straight from the Watch's own motion sensors, indoors or not, so
    /// leaving `distanceWalkingRunning` out here would risk exactly the kind
    /// of silent per-type write failure `HealthKitManager`'s own doc comment
    /// describes on the iOS side.
    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [HKObjectType.workoutType()]
        if let heartRate = HKObjectType.quantityType(forIdentifier: .heartRate) {
            types.insert(heartRate)
        }
        if let activeEnergy = HKObjectType.quantityType(forIdentifier: .activeEnergyBurned) {
            types.insert(activeEnergy)
        }
        if let distanceCycling = HKObjectType.quantityType(forIdentifier: .distanceCycling) {
            types.insert(distanceCycling)
        }
        if let distanceWalkingRunning = HKObjectType.quantityType(forIdentifier: .distanceWalkingRunning) {
            types.insert(distanceWalkingRunning)
        }
        return types
    }

    /// Starts both halves at once: this Watch-side session, and (via
    /// `notifyPhoneToStart`) Unchain's own session on the iPhone. Doesn't
    /// proceed with either if the phone side reports it couldn't (e.g. no
    /// trainer connected, or the rider cancelled the "Walking or running?"
    /// dialog there) – see that method's own doc comment on why this can
    /// take a moment to resolve for a treadmill.
    func start() {
        guard state == .idle else { return }
        guard isAvailable else {
            state = .failed(String(localized: "Health isn't available."))
            return
        }
        state = .starting
        notifyPhoneToStart { [weak self] success, activityType in
            guard let self else { return }
            guard success, let activityType else {
                self.state = .failed(String(localized: "iPhone couldn't start – check it's connected to a trainer."))
                return
            }
            self.requestAuthorizationAndBeginSession(activityType: activityType)
        }
    }

    /// Clears a `.failed` state back to `.idle` so Start can be tried again
    /// – the failure message alone doesn't do that on its own, since it's
    /// meant to stay legible until the rider's acted on it.
    func reset() {
        stoppingWatchdog?.cancel()
        stoppingWatchdog = nil
        session = nil
        builder = nil
        state = .idle
    }

    private func requestAuthorizationAndBeginSession(activityType: HKWorkoutActivityType) {
        store.requestAuthorization(toShare: shareTypes, read: []) { [weak self] granted, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.state = .failed(String(localized: "Health access denied."))
                    return
                }
                self.beginSession(activityType: activityType)
            }
        }
    }

    /// `activityType` comes from the iPhone's reply to `notifyPhoneToStart`
    /// – whatever `ControlView` actually started (or, for a treadmill, the
    /// rider's own Walk/Run answer there), not decided on this side at all.
    private func beginSession(activityType: HKWorkoutActivityType) {
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = activityType
        configuration.locationType = .indoor
        do {
            let newSession = try HKWorkoutSession(healthStore: store, configuration: configuration)
            let newBuilder = newSession.associatedWorkoutBuilder()
            newBuilder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: configuration)
            newSession.delegate = self
            newBuilder.delegate = self
            session = newSession
            builder = newBuilder
            let now = Date()
            newSession.startActivity(with: now)
            newBuilder.beginCollection(withStart: now) { [weak self] success, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.state = success ? .running : .failed(error?.localizedDescription ?? String(localized: "Couldn't start."))
                }
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Stops both halves: this Watch-side session, and (via
    /// `notifyPhoneToStop`) Unchain's own session on the iPhone. Only calls
    /// `stopActivity(with:)` here – `end()` is called from the delegate
    /// below, once the session actually confirms it reached `.stopped`,
    /// rather than firing both back to back – see the type's own note on
    /// why that matters. `stoppingWatchdog` is the fallback for if that
    /// confirmation never arrives at all.
    func stop() {
        guard state == .running else { return }
        state = .stopping
        notifyPhoneToStop()
        session?.stopActivity(with: Date())
        armStoppingWatchdog()
    }

    /// A hard ceiling on how long `.stopping` is allowed to sit without
    /// resolving, discovered after a real one: `session?.end()` called
    /// immediately after `stopActivity(with:)`, with no wait for that to
    /// actually take effect first, could end up silently dropped – the
    /// delegate's `.ended` callback (and therefore `finishWorkout()`) never
    /// fires, leaving the UI stuck showing "Stopping…" forever with no way
    /// out except force-quitting the app. Restructured `stop()`/the
    /// delegate below to be state-driven instead (only call `end()` once
    /// `.stopped` is confirmed) to fix the likely cause – but this timer
    /// stays regardless, as a hard backstop: if the delegate callback
    /// doesn't arrive from *any* cause within a few seconds, force back to
    /// `.idle` with an explanatory error rather than leaving the rider
    /// stuck on a screen with no working button.
    private func armStoppingWatchdog() {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.state == .stopping else { return }
            self.session = nil
            self.builder = nil
            self.state = .failed(String(localized: "Stopping took too long – check the Fitness app; this workout may still have saved."))
        }
        stoppingWatchdog = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: workItem)
    }
}

extension WatchWorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState, from fromState: HKWorkoutSessionState, date: Date) {
        switch toState {
        case .stopped:
            // Only now, once the session has actually confirmed it stopped
            // – not immediately after requesting it – is `end()` safe to
            // call (see `stop()`'s own comment for the bug this fixes).
            workoutSession.end()
        case .ended:
            finishWorkout()
        default:
            break
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.state = .failed(error.localizedDescription)
        }
    }
}

extension WatchWorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {}
}

private extension WatchWorkoutManager {
    /// Finalizes and saves this session's own `HKWorkout` to Health – no
    /// separate confirmation step, unlike the phone's "Save to Health?"
    /// dialog for a non-Watch workout; the rider already confirmed intent
    /// by tapping Start here in the first place.
    func finishWorkout() {
        stoppingWatchdog?.cancel()
        stoppingWatchdog = nil
        guard let builder else {
            DispatchQueue.main.async { [weak self] in self?.state = .idle }
            return
        }
        builder.endCollection(withEnd: Date()) { [weak self] _, _ in
            builder.finishWorkout { _, _ in
                DispatchQueue.main.async {
                    self?.session = nil
                    self?.builder = nil
                    self?.state = .idle
                }
            }
        }
    }
}

extension WatchWorkoutManager: WCSessionDelegate {
    // The only method `WCSessionDelegate` actually requires on watchOS – no
    // `sessionDidBecomeInactive`/`sessionDidDeactivate` here, unlike the iOS
    // side's `WatchConnectivityManager`, since a Watch only ever pairs with
    // one phone at a time (no equivalent multi-companion scenario).
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}

    /// Asks Unchain on the iPhone to start its own session, exactly as if
    /// "Start Workout" had been tapped there. `completion` reports whether
    /// that actually happened (`false` if the phone's unreachable, or it
    /// declined, e.g. no trainer connected) and, if so, which activity type
    /// it started as – this may sit waiting on the phone's reply for a
    /// while if the connected machine is a treadmill: the phone shows its
    /// own "Walking or running?" dialog before replying at all, rather than
    /// deciding that here. `WCSession`'s reply handler is fine left open for
    /// that; there's no strict timeout for it while both sides stay
    /// reachable.
    private func notifyPhoneToStart(completion: @escaping (Bool, HKWorkoutActivityType?) -> Void) {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            completion(false, nil)
            return
        }
        WCSession.default.sendMessage(["command": "start"]) { reply in
            let success = (reply["success"] as? Bool) ?? false
            let activityType = (reply["activityType"] as? UInt).flatMap { HKWorkoutActivityType(rawValue: $0) }
            DispatchQueue.main.async { completion(success, activityType) }
        } errorHandler: { _ in
            DispatchQueue.main.async { completion(false, nil) }
        }
    }

    /// Asks Unchain on the iPhone to stop, exactly as if "Stop" had been
    /// tapped there. No reply needed – `stop()` above ends this Watch-side
    /// session regardless of whether the phone actually got the message.
    private func notifyPhoneToStop() {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(["command": "stop"], replyHandler: nil)
    }
}
