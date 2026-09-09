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
    static let supportedSpeedRange = CBUUID(string: "2AD4")
    static let supportedInclinationRange = CBUUID(string: "2AD5")
    static let supportedResistanceLevelRange = CBUUID(string: "2AD6")
    static let supportedPowerRange = CBUUID(string: "2AD8")
    static let fitnessMachineControlPoint = CBUUID(string: "2AD9")
    static let fitnessMachineStatus = CBUUID(string: "2ADA")

    // MARK: Control Point op codes (see FTMS spec, table 4.16)

    enum OpCode: UInt8 {
        case requestControl = 0x00
        case reset = 0x01
        case setTargetSpeed = 0x02
        case setTargetInclination = 0x03
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

    /// The op code a Fitness Machine Status notification (0x2ADA) itself
    /// leads with – the *machine*'s own side of "something changed here",
    /// unprompted by any control-point command this app sent (see FTMS
    /// spec, table 4.18, for the full op-code table; only the two this app
    /// actually reacts to are listed here, same "only what's handled"
    /// scope `OpCode`/`ResultCode` above already keep). Both cover a real,
    /// safety-relevant scenario this app had no way to notice before: the
    /// treadmill physically stopping – console Stop button, or an
    /// emergency/safety key pulled – with this app's own `WorkoutSession`
    /// having no idea, still showing `.running` and still computing
    /// elapsed time/targets against a belt that's no longer moving. See
    /// `TrainerConnection.deviceInitiatedStopReason`.
    enum StatusOpCode: UInt8 {
        /// The spec uses one op code for both a stop and a pause
        /// initiated at the console – no separate parameter to tell them
        /// apart the way the control-point's own "Stop or Pause" op code
        /// (0x08) has one, unlike `StopPauseControlParameter` above.
        case stoppedOrPausedByUser = 0x02
        case stoppedBySafetyKey = 0x03
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

    /// Best-effort human-readable name for any FTMS data/control
    /// characteristic – used only by `TrainerFeaturesView`'s diagnostic
    /// "Reported Characteristics" list, so a device exposing something this
    /// app doesn't otherwise read (the exact situation that prompted adding
    /// that list – a treadmill turning out to also expose Indoor Bike Data)
    /// still shows *something* meaningful rather than being silently
    /// dropped. Covers every characteristic the Bluetooth SIG's FTMS spec
    /// defines, not just the ones `TrainerConnection` actually acts on;
    /// falls back to the raw UUID for anything genuinely unrecognized.
    /// Deliberately left untranslated – these are the spec's own official
    /// characteristic names, not app UI text.
    static func characteristicName(for uuid: CBUUID) -> String {
        switch uuid {
        case fitnessMachineFeature: return "Fitness Machine Feature"
        case treadmillData: return "Treadmill Data"
        case CBUUID(string: "2ACE"): return "Cross Trainer Data"
        case CBUUID(string: "2ACF"): return "Step Climber Data"
        case CBUUID(string: "2AD0"): return "Stair Climber Data"
        case CBUUID(string: "2AD1"): return "Rower Data"
        case indoorBikeData: return "Indoor Bike Data"
        case CBUUID(string: "2AD3"): return "Training Status"
        case supportedSpeedRange: return "Supported Speed Range"
        case supportedInclinationRange: return "Supported Inclination Range"
        case supportedResistanceLevelRange: return "Supported Resistance Level Range"
        case CBUUID(string: "2AD7"): return "Supported Heart Rate Range"
        case supportedPowerRange: return "Supported Power Range"
        case fitnessMachineControlPoint: return "Fitness Machine Control Point"
        case fitnessMachineStatus: return "Fitness Machine Status"
        default: return uuid.uuidString
        }
    }
}
