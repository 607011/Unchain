import Foundation

/// Which kind of FTMS fitness machine the connected trainer identifies as.
/// Detected from which live-data characteristic it exposes (Indoor Bike Data
/// vs. Treadmill Data) — used to pick the right Apple Health workout type
/// when saving a finished session.
enum MachineKind: Equatable {
    case bike
    case treadmill
    case unknown
}
