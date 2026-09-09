import Foundation

/// Keeps a just-disconnected CoreBluetooth delegate object (`TrainerConnection`/
/// `HeartRateConnection`) alive for a short grace period after the code that
/// disconnected it would otherwise be free to drop its last strong
/// reference – closing a race `deinit`-based cleanup alone can't (see both
/// types' own `deinit` doc comments for the crash this was first written
/// against, and their `disconnect()` for why this exists as a follow-up to
/// that fix, called out directly: `deinit` alone still leaves a real, if
/// narrower, window open).
///
/// The problem in one sentence: with `queue: nil`, CoreBluetooth delivers a
/// delegate callback to the main thread via its own internal deferred
/// `perform` (the same `CFRunLoopSource0`/`__NSThreadPerformPerform`
/// mechanism `-[NSObject performSelector:onThread:...]` uses) – and once
/// that's actually *scheduled*, nothing on the app side can retroactively
/// cancel it. `deinit` calling `cancelPeripheralConnection(_:)` stops
/// CoreBluetooth from scheduling anything *further* for this peripheral,
/// but if a callback was already queued a moment before that ran, it still
/// fires later regardless – landing on whatever this object's own storage
/// holds by then. If ARC has *already* deallocated it by that point, that's
/// freed memory, quite possibly reused for something else entirely – the
/// `objc_msgSend`/`EXC_BAD_ACCESS` crash both types were hardened against
/// once already. `deinit` itself runs too late to close this on its own:
/// an object can't re-retain itself from inside its own `deinit` to survive
/// longer, so whatever's going to keep it alive a little longer has to run
/// *before* that point, while a valid strong reference to hand off still
/// exists – i.e. at `disconnect()`, not at `deinit`.
///
/// Keeping the object alive doesn't stop a stray callback from firing – it
/// just means that when it does, `objc_msgSend` lands on real (if by then
/// functionally inert – `cancelPeripheralConnection` has already told
/// CoreBluetooth there's nothing further to notify this delegate of, and
/// `disconnect()` also nils `peripheral.delegate` itself as an extra,
/// best-effort signal) memory instead of freed/reused memory: the actual
/// difference between a crash and a silent no-op. Not a second life for the
/// object, just a wider safety margin around its real one.
enum BLEDisconnectGracePeriod {
    /// Comfortably longer than any realistic gap between "this app called
    /// `cancelPeripheralConnection`" and "the main run loop actually gets
    /// around to a Source0 callback already queued before that" – both
    /// happen on the very same run loop this itself runs on, so in practice
    /// that resolves within a pass or two of it, not anywhere close to this
    /// long. Generous on purpose: the cost of holding one disconnected
    /// object's memory a few extra seconds is negligible, and unlike
    /// `NSObject.cancelPreviousPerformRequests(withTarget:)` (which only
    /// ever cancels a perform *this app itself* scheduled, not CoreBluetooth's
    /// own internal one), there's no way to know for certain the window has
    /// actually closed rather than just guess a generous bound for it.
    private static let graceSeconds: TimeInterval = 5

    /// Main-thread only, same as every `TrainerConnection`/`HeartRateConnection`
    /// method – both are only ever driven by `BluetoothManager`'s own
    /// `CBCentralManagerDelegate` callbacks (`queue: nil`, so always the main
    /// thread already) or directly by SwiftUI view code, never from a
    /// background queue.
    private static var keptAlive: [ObjectIdentifier: AnyObject] = [:]

    /// Called from `disconnect()`, not `deinit` – see this type's own doc
    /// comment on why it has to be. Self-expiring: removes its own strong
    /// reference again after `graceSeconds`, letting ARC deallocate the
    /// object normally from that point on (or immediately, if nothing else
    /// still references it by then).
    static func extend(_ object: AnyObject) {
        let id = ObjectIdentifier(object)
        keptAlive[id] = object
        DispatchQueue.main.asyncAfter(deadline: .now() + graceSeconds) {
            keptAlive.removeValue(forKey: id)
        }
    }
}
