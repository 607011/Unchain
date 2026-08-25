import CoreBluetooth

/// Constants from the Bluetooth SIG "Fitness Machine Service" (FTMS) specification.
/// This is an open standard – not a Wahoo-proprietary protocol – so this code works
/// with any FTMS-capable smart trainer in principle, not just the Kickr.
enum FTMS {
    // MARK: Services

    static let fitnessMachineService = CBUUID(string: "1826")

    // MARK: Characteristics

    static let fitnessMachineFeature = CBUUID(string: "2ACC")
    static let treadmillData = CBUUID(string: "2ACD")
    static let indoorBikeData = CBUUID(string: "2AD2")
    static let supportedResistanceLevelRange = CBUUID(string: "2AD6")
    static let supportedPowerRange = CBUUID(string: "2AD8")
    static let fitnessMachineControlPoint = CBUUID(string: "2AD9")
    static let fitnessMachineStatus = CBUUID(string: "2ADA")

    // MARK: Control Point op codes (see FTMS spec, table 4.16)

    enum OpCode: UInt8 {
        case requestControl = 0x00
        case reset = 0x01
        case setTargetResistanceLevel = 0x04
        case setTargetPower = 0x05
        case startOrResume = 0x07
        case stopOrPause = 0x08
        case setIndoorBikeSimulationParameters = 0x11
        case responseCode = 0x80
    }

    enum ResultCode: UInt8 {
        case success = 0x01
        case opCodeNotSupported = 0x02
        case invalidParameter = 0x03
        case operationFailed = 0x04
        case controlNotPermitted = 0x05
    }

    /// Parameter byte for the "Stop or Pause" op code (0x08): the spec uses one
    /// op code for both actions, distinguished by this parameter.
    enum StopPauseControlParameter: UInt8 {
        case stop = 0x01
        case pause = 0x02
    }

    /// Fixed physical defaults sent with every "Set Indoor Bike Simulation
    /// Parameters" command (0x11) alongside the actual grade – this app has
    /// no wind or bike/tire model, so it always simulates a windless ride on
    /// a typical road bike. Same ballpark values commonly used by other
    /// trainer apps.
    enum SimulationDefaults {
        /// Raw UInt8, resolution 0.0001 → ~0.0040, a typical road tire.
        static let rollingResistanceCoefficientRaw: UInt8 = 40
        /// Raw UInt8, resolution 0.01 kg/m → ~0.51 kg/m, a seated road rider.
        static let windResistanceCoefficientRaw: UInt8 = 51
    }
}
