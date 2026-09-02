import Foundation

/// Which kind of FTMS fitness machine the connected trainer identifies as.
/// Detected from which live-data characteristic it exposes (Indoor Bike Data
/// vs. Treadmill Data) — used to pick the right Apple Health workout type
/// when saving a finished session, and (via `TrainerDeviceStore`) to group a
/// remembered device under Settings → Devices. `Codable` for that latter
/// use — `.unknown` is never actually persisted (see
/// `TrainerDeviceStore.recordConnection`), but still needs to round-trip
/// like any other case rather than being special-cased out of the enum.
enum MachineKind: Equatable, Codable {
    case bike
    case treadmill
    case unknown
}
