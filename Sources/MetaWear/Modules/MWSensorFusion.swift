import Foundation

// MARK: - Sensor fusion mode

/// Selects which underlying sensors the on-board fusion algorithm draws from,
/// and therefore which fused outputs are available and how power-hungry the
/// pipeline is.
///
/// Different modes are appropriate for different jobs: absolute orientation
/// against magnetic north (`ndof`), gyro-stable relative orientation
/// (`imuPlus`), geographic heading only (`compass`), or a low-power
/// orientation estimate without the gyro (`m4g`).
public enum MWSensorFusionMode: UInt8, Sendable, CaseIterable {
    /// Fusion disabled — underlying sensors are not driven.
    case sleep   = 0
    /// Nine-degrees-of-freedom: accelerometer + gyroscope + magnetometer.
    /// Best absolute-orientation quality (true heading), highest power.
    case ndof    = 1
    /// Accelerometer + gyroscope only — relative orientation, no magnetic heading.
    /// Excellent short-term stability without the magnetic disturbances of NDOF.
    case imuPlus = 2
    /// Magnetometer only — produces a compass heading. Lowest power orientation mode.
    case compass = 3
    /// Magnetometer + accelerometer (no gyro). Low-power relative orientation
    /// for slow motion; gyro-free so drift-immune at the cost of fast dynamics.
    case m4g     = 4
}

// MARK: - Sensor fusion accelerometer range
// Raw values match C++ `MblMwSensorFusionAccRange`.

/// Full-scale range the accelerometer is driven at while feeding sensor fusion.
///
/// Smaller ranges give better resolution for low-motion use; larger ranges
/// avoid clipping on impacts. Defaults to `.g2` in most fusion constructors.
public enum MWSensorFusionAccRange: UInt8, Sendable, CaseIterable {
    /// ±2 g — finest resolution, easiest to clip.
    case g2  = 0
    /// ±4 g.
    case g4  = 1
    /// ±8 g.
    case g8  = 2
    /// ±16 g — coarsest resolution, headroom for impacts.
    case g16 = 3
}

// MARK: - Sensor fusion gyro range
// Raw values match C++ `MblMwSensorFusionGyroRange`.

/// Full-scale range the gyroscope is driven at while feeding sensor fusion.
///
/// Wider ranges (`dps2000`) handle rapid rotation without clipping; narrower
/// ranges give finer resolution for slow motion.
public enum MWSensorFusionGyroRange: UInt8, Sendable, CaseIterable {
    /// ±2000 dps — widest, lowest resolution.
    case dps2000 = 0
    /// ±1000 dps.
    case dps1000 = 1
    /// ±500 dps.
    case dps500  = 2
    /// ±250 dps — narrowest, highest resolution.
    case dps250  = 3
}

// MARK: - Underlying chip family
//
// The sensor fusion algorithm is fed by the accelerometer + gyroscope (+ magnetometer)
// modules on the same board. Acc/gyro chip impl bytes differ between MetaMotion variants
// — BMI160 (older R/RL) and BMI270 (newer C/S) write slightly different config bytes.
// All other lifecycle commands are chip-agnostic.

/// Underlying Bosch IMU on the MetaMotion board that drives sensor fusion.
///
/// The fusion algorithm itself is chip-agnostic but the accelerometer config
/// bytes differ slightly between BMI160 (R / RL) and BMI270 (C / S). Use the
/// `init?(gyroImpl:)` or `init?(accImpl:)` initialisers to derive this from
/// the module implementation bytes reported during board discovery.
public enum MWSensorFusionChip: Sendable, CaseIterable, Equatable {
    /// Older Bosch BMI160 — found on MetaMotion R / RL boards.
    case bmi160
    /// Newer Bosch BMI270 — found on MetaMotion C / S boards.
    case bmi270

    /// Construct from the gyro module's `implementation` byte: 0 = BMI160, 1 = BMI270.
    /// (Mirrors `MBL_MW_MODULE_GYRO_TYPE_BMI160 / BMI270`.)
    public init?(gyroImpl: UInt8) {
        switch gyroImpl {
        case 0: self = .bmi160
        case 1: self = .bmi270
        default: return nil
        }
    }

    /// Construct from the accelerometer module's `implementation` byte: 1 = BMI160, 4 = BMI270.
    public init?(accImpl: UInt8) {
        switch accImpl {
        case 1: self = .bmi160
        case 4: self = .bmi270
        default: return nil
        }
    }
}

// MARK: - Sensor fusion output types

/// Type-erased wrapper for any fused output value.
///
/// Useful when handling fusion results through a single channel; the case
/// determines how the payload was scaled by the firmware.
public enum MWSensorFusionOutput: Sendable {
    /// 4-axis (w, x, y, z) orientation quaternion.
    case quaternion(Quaternion)
    /// Heading / pitch / roll / yaw in degrees.
    case eulerAngles(EulerAngles)
    /// Bias-corrected accelerometer reading (g), with per-sample accuracy byte.
    case correctedAcceleration(CorrectedCartesianFloat)
    /// Bias-corrected gyroscope reading (dps), with per-sample accuracy byte.
    case correctedRotation(CorrectedCartesianFloat)
    /// Bias-corrected magnetometer reading (µT), with per-sample accuracy byte.
    case correctedMagneticField(CorrectedCartesianFloat)
    /// Gravity component of the current acceleration (g).
    case gravityVector(CartesianFloat)
    /// Acceleration with gravity removed (g) — pure motion impulse.
    case linearAcceleration(CartesianFloat)
}

// MARK: - Calibration state

/// Per-sensor calibration accuracy reported by the fusion algorithm.
///
/// Each axis ranges from 0 (uncalibrated / unreliable) to 3 (fully calibrated /
/// high accuracy). Poll until each is at least 2 before recording orientation
/// data to ensure usable accuracy. Returned by `MWSensorFusionCalibrationState`.
public struct MWSensorFusionCalibration: Sendable, Equatable {
    /// Accelerometer calibration accuracy: 0 (UNRELIABLE) … 3 (HIGH).
    public let accelerometer: UInt8
    /// Gyroscope calibration accuracy: 0 (UNRELIABLE) … 3 (HIGH).
    public let gyroscope: UInt8
    /// Magnetometer calibration accuracy: 0 (UNRELIABLE) … 3 (HIGH).
    public let magnetometer: UInt8

    public init(accelerometer: UInt8, gyroscope: UInt8, magnetometer: UInt8) {
        self.accelerometer = accelerometer
        self.gyroscope = gyroscope
        self.magnetometer = magnetometer
    }
}

// MARK: - Calibration data
//
// Mirrors C++ `MblMwCalibrationData`: 10 bytes each for acc / gyro / mag.
// Only usable on firmware v1.4.3+ / sensor fusion revision >= 2.

/// Persisted calibration blobs that can be loaded back into the board, skipping
/// the manual figure-8 / orientation dance on next boot.
///
/// Each blob is exactly 10 bytes (opaque to the host — Bosch-defined layout).
/// Read with the corresponding read signal once calibration accuracy reaches
/// HIGH; restore via `MWSensorFusionWriteAccCalibration` / `WriteGyroCalibration`
/// / `WriteMagCalibration`. Requires sensor fusion revision ≥ 2 (firmware v1.4.3+).
public struct MWSensorFusionCalibrationData: Sendable, Equatable {
    /// 10-byte accelerometer calibration blob.
    public let acc: [UInt8]
    /// 10-byte gyroscope calibration blob.
    public let gyro: [UInt8]
    /// 10-byte magnetometer calibration blob.
    public let mag: [UInt8]

    public init(acc: [UInt8], gyro: [UInt8], mag: [UInt8]) {
        precondition(acc.count  == 10, "acc calibration data must be 10 bytes")
        precondition(gyro.count == 10, "gyro calibration data must be 10 bytes")
        precondition(mag.count  == 10, "mag calibration data must be 10 bytes")
        self.acc = acc
        self.gyro = gyro
        self.mag = mag
    }
}

// MARK: - Config / lifecycle helpers
//
// These mirror `mbl_mw_sensor_fusion_write_config`, `mbl_mw_sensor_fusion_start`,
// and `mbl_mw_sensor_fusion_stop` in `sensor_fusion.cpp`. The byte sequences are
// asserted by `MetaWear-SDK-Cpp/test/test_sensor_fusion.py::test_sensor_control`
// and `test_sensor_fusion_config.py`.

/// Fusion config command — `[0x19, 0x02, mode, rangeByte]`.
/// `rangeByte = accRange | ((gyroRange + 1) << 4)` matches the C++ bitfield layout.
private func fusionConfigCommand(mode: MWSensorFusionMode, accRange: UInt8, gyroRange: UInt8) -> Data {
    let rangeByte: UInt8 = accRange | ((gyroRange + 1) << 4)
    return MWPacket.command(.sensorFusion, 0x02, [mode.rawValue, rangeByte])
}

/// Underlying acc config — `[0x03, 0x03, confByte, rangeByte]`.
/// ODR depends on mode (NDOF/IMU+ → 100 Hz, COMPASS → 25 Hz, M4G → 50 Hz);
/// the upper bits of `confByte` (bwp/perf) and the range byte encoding differ
/// between BMI160 and BMI270.
private func fusionAccConfigCommand(mode: MWSensorFusionMode, accRange: UInt8, chip: MWSensorFusionChip) -> Data {
    // BMI160/BMI270 ODR enum values from datasheet (1-based as written to register):
    //   25 Hz → 6, 50 Hz → 7, 100 Hz → 8.
    let odrCode: UInt8
    switch mode {
    case .ndof, .imuPlus: odrCode = 8     // 100 Hz
    case .compass:        odrCode = 6     // 25 Hz
    case .m4g:            odrCode = 7     // 50 Hz
    case .sleep:          odrCode = 8     // unused (start is gated on non-sleep)
    }
    let bwp: UInt8 = 2                    // normal averaging
    switch chip {
    case .bmi160:
        // BMI160 acc_conf: bits[3:0]=odr, bits[6:4]=bwp, bit[7]=us(0 for ODR>=12.5 Hz)
        let confByte: UInt8 = (bwp << 4) | odrCode                       // → 0x28 / 0x26 / 0x27
        let rangeByte: UInt8 = [0x03, 0x05, 0x08, 0x0C][Int(accRange)]   // BMI160 range bitmask
        return MWPacket.command(.accelerometer, 0x03, [confByte, rangeByte])
    case .bmi270:
        // BMI270 acc_conf: bits[3:0]=odr, bits[6:4]=bwp, bit[7]=filter_perf (1 for ODR>=12.5 Hz)
        let confByte: UInt8 = 0x80 | (bwp << 4) | odrCode                // → 0xA8 / 0xA6 / 0xA7
        return MWPacket.command(.accelerometer, 0x03, [confByte, accRange])
    }
}

/// Underlying gyro config — `[0x13, 0x03, 0x28, gyroRange]`.
/// Always 100 Hz (gyro only runs in NDOF / IMU_PLUS). Both BMI160 and BMI270 use
/// the same register encoding, so `chip` only matters for symmetry with acc.
private func fusionGyroConfigCommand(gyroRange: UInt8, chip: MWSensorFusionChip) -> Data {
    let bwp: UInt8 = 2
    let odrCode: UInt8 = 8                              // 100 Hz
    let confByte: UInt8 = (bwp << 4) | odrCode          // → 0x28
    return MWPacket.command(.gyro, 0x03, [confByte, gyroRange])
}

/// Underlying mag config — two commands. Always xy_reps=9, z_reps=15, ODR=25 Hz
/// (matches `mbl_mw_mag_bmm150_configure(board, 9, 15, MBL_MW_MAG_BMM150_ODR_25Hz)`).
private func fusionMagConfigCommands() -> [Data] {
    // xyByte = (9 - 1) / 2 = 4, zByte = 15 - 1 = 14 = 0x0E, ODR_25Hz raw = 6
    [
        MWPacket.command(.magnetometer, 0x04, [0x04, 0x0E]),
        MWPacket.command(.magnetometer, 0x03, [0x06])
    ]
}

/// All `configureCommands` for a fusion signal: fusion config followed by the
/// per-mode underlying acc / gyro / mag configs.
private func fusionConfigureCommands(
    mode: MWSensorFusionMode,
    accRange: UInt8,
    gyroRange: UInt8,
    chip: MWSensorFusionChip
) -> [Data] {
    var cmds: [Data] = [fusionConfigCommand(mode: mode, accRange: accRange, gyroRange: gyroRange)]
    switch mode {
    case .sleep:
        break
    case .ndof:
        cmds.append(fusionAccConfigCommand(mode: mode, accRange: accRange, chip: chip))
        cmds.append(fusionGyroConfigCommand(gyroRange: gyroRange, chip: chip))
        cmds.append(contentsOf: fusionMagConfigCommands())
    case .imuPlus:
        cmds.append(fusionAccConfigCommand(mode: mode, accRange: accRange, chip: chip))
        cmds.append(fusionGyroConfigCommand(gyroRange: gyroRange, chip: chip))
    case .compass, .m4g:
        cmds.append(fusionAccConfigCommand(mode: mode, accRange: accRange, chip: chip))
        cmds.append(contentsOf: fusionMagConfigCommands())
    }
    return cmds
}

// MARK: - Underlying lifecycle commands (chip-agnostic)

private let accEnableSampling   = MWPacket.command(.accelerometer, 0x02, [0x01, 0x00])
private let accStartSampling    = MWPacket.command(.accelerometer, 0x01, [0x01])
private let accStopSampling     = MWPacket.command(.accelerometer, 0x01, [0x00])
private let accDisableSampling  = MWPacket.command(.accelerometer, 0x02, [0x00, 0x01])

private let gyroEnableSampling  = MWPacket.command(.gyro, 0x02, [0x01, 0x00])
private let gyroStartSampling   = MWPacket.command(.gyro, 0x01, [0x01])
private let gyroStopSampling    = MWPacket.command(.gyro, 0x01, [0x00])
private let gyroDisableSampling = MWPacket.command(.gyro, 0x02, [0x00, 0x01])

private let magEnableSampling   = MWPacket.command(.magnetometer, 0x02, [0x01, 0x00])
private let magStartSampling    = MWPacket.command(.magnetometer, 0x01, [0x01])
private let magStopSampling     = MWPacket.command(.magnetometer, 0x01, [0x00])
private let magDisableSampling  = MWPacket.command(.magnetometer, 0x02, [0x00, 0x01])

private let fusionStartFusion   = MWPacket.command(.sensorFusion, 0x01, [0x01])
private let fusionStopFusion    = MWPacket.command(.sensorFusion, 0x01, [0x00])
private let fusionClearMask     = MWPacket.command(.sensorFusion, 0x03, [0x00, 0x7F])

/// Underlying-sensor enable_sampling commands — issued before the underlying sensors are started.
/// Order: acc, gyro (NDOF/IMU+ only), mag (NDOF/COMPASS/M4G only).
private func fusionEnableSamplingCommands(mode: MWSensorFusionMode) -> [Data] {
    switch mode {
    case .sleep:   return []
    case .ndof:    return [accEnableSampling, gyroEnableSampling, magEnableSampling]
    case .imuPlus: return [accEnableSampling, gyroEnableSampling]
    case .compass: return [accEnableSampling, magEnableSampling]
    case .m4g:     return [accEnableSampling, magEnableSampling]
    }
}

/// Underlying-sensor start commands. Order: acc, gyro (NDOF/IMU+), mag (NDOF/COMPASS/M4G).
private func fusionStartSamplingCommands(mode: MWSensorFusionMode) -> [Data] {
    switch mode {
    case .sleep:   return []
    case .ndof:    return [accStartSampling, gyroStartSampling, magStartSampling]
    case .imuPlus: return [accStartSampling, gyroStartSampling]
    case .compass: return [accStartSampling, magStartSampling]
    case .m4g:     return [accStartSampling, magStartSampling]
    }
}

/// Underlying-sensor stop commands. Order: acc, gyro (NDOF/IMU+), mag (NDOF/COMPASS/M4G).
private func fusionStopSamplingCommands(mode: MWSensorFusionMode) -> [Data] {
    switch mode {
    case .sleep:   return []
    case .ndof:    return [accStopSampling, gyroStopSampling, magStopSampling]
    case .imuPlus: return [accStopSampling, gyroStopSampling]
    case .compass: return [accStopSampling, magStopSampling]
    case .m4g:     return [accStopSampling, magStopSampling]
    }
}

/// Underlying-sensor disable_sampling commands. Order: acc, gyro (NDOF/IMU+), mag (NDOF/COMPASS/M4G).
private func fusionDisableSamplingCommands(mode: MWSensorFusionMode) -> [Data] {
    switch mode {
    case .sleep:   return []
    case .ndof:    return [accDisableSampling, gyroDisableSampling, magDisableSampling]
    case .imuPlus: return [accDisableSampling, gyroDisableSampling]
    case .compass: return [accDisableSampling, magDisableSampling]
    case .m4g:     return [accDisableSampling, magDisableSampling]
    }
}

/// Full per-signal `startCommands` — underlying sensor starts, then the fusion
/// output-enable mask write, then the fusion start byte.
/// Mirrors `mbl_mw_sensor_fusion_start`.
private func fusionStartCommands(mode: MWSensorFusionMode, fusionEnableMaskCmd: Data) -> [Data] {
    fusionStartSamplingCommands(mode: mode) + [fusionEnableMaskCmd, fusionStartFusion]
}

/// Full per-signal `stopCommands` — fusion stop, fusion clear-mask, then underlying sensor stops.
/// Mirrors `mbl_mw_sensor_fusion_stop`.
private func fusionStopCommands(mode: MWSensorFusionMode) -> [Data] {
    [fusionStopFusion, fusionClearMask] + fusionStopSamplingCommands(mode: mode)
}

// MARK: - Sensor fusion signal definitions
// Each signal is a separate MWStreamable — subscribe to one or more simultaneously.
// Output-enable bits (register 0x03) in MblMwSensorFusionData order:
//   0 = CORRECTED_ACC, 1 = CORRECTED_GYRO, 2 = CORRECTED_MAG,
//   3 = QUATERNION, 4 = EULER_ANGLES, 5 = GRAVITY, 6 = LINEAR_ACC

/// Quaternion output (w, x, y, z) of the on-board sensor fusion algorithm.
///
/// The most numerically stable orientation representation — no gimbal lock, no
/// angular discontinuities. Use as the input to your own rotation math; convert
/// to Euler angles only at the display layer.
///
/// Pick `mode = .ndof` for absolute orientation, `.imuPlus` for drift-free
/// relative rotation. Stream live with `streamSensorFusion(...)` or log to
/// flash with `log(...)` like any other `MWLoggable`.
public struct MWSensorFusionQuaternion: MWLoggable {
    public typealias Sample = Quaternion

    public let mode: MWSensorFusionMode
    public let accRange: UInt8    // 0=2g, 1=4g, 2=8g, 3=16g
    public let gyroRange: UInt8   // 0=2000dps, 1=1000dps, 2=500dps, 3=250dps
    public let chip: MWSensorFusionChip

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: UInt8 = 0,
                gyroRange: UInt8 = 0,
                chip: MWSensorFusionChip = .bmi160) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
        self.chip = chip
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange,
                chip: MWSensorFusionChip = .bmi160) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue, chip: chip)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x07           // QUATERNION
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        fusionConfigureCommands(mode: mode, accRange: accRange, gyroRange: gyroRange, chip: chip)
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x08, 0x00]) }  // bit 3 = QUATERNION
    public var startCommand:   Data { fusionStartFusion }
    public var stopCommand:    Data { fusionStopFusion }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x08]) }

    public var enableCommands:  [Data] { fusionEnableSamplingCommands(mode: mode) }
    public var startCommands:   [Data] { fusionStartCommands(mode: mode, fusionEnableMaskCmd: enableCommand) }
    public var stopCommands:    [Data] { fusionStopCommands(mode: mode) }
    public var disableCommands: [Data] { fusionDisableSamplingCommands(mode: mode) }

    public func parseSample(from packet: Data) throws -> Quaternion {
        try MWPacketParser.parseQuaternion(packet)
    }

    public let loggerKey = "quaternion"
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(0,4), (4,4), (8,4), (12,4)]
    }
}

/// Euler-angles output (heading / pitch / roll / yaw, degrees) of sensor fusion.
///
/// Human-readable orientation — convenient for UI and CSV export but prone to
/// gimbal lock near ±90° pitch. For long-term integration prefer
/// `MWSensorFusionQuaternion`.
public struct MWSensorFusionEuler: MWLoggable {
    public typealias Sample = EulerAngles

    public let mode: MWSensorFusionMode
    public let accRange: UInt8
    public let gyroRange: UInt8
    public let chip: MWSensorFusionChip

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: UInt8 = 0,
                gyroRange: UInt8 = 0,
                chip: MWSensorFusionChip = .bmi160) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
        self.chip = chip
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange,
                chip: MWSensorFusionChip = .bmi160) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue, chip: chip)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x08           // EULER_ANGLES
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        fusionConfigureCommands(mode: mode, accRange: accRange, gyroRange: gyroRange, chip: chip)
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x10, 0x00]) }  // bit 4 = EULER
    public var startCommand:   Data { fusionStartFusion }
    public var stopCommand:    Data { fusionStopFusion }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x10]) }

    public var enableCommands:  [Data] { fusionEnableSamplingCommands(mode: mode) }
    public var startCommands:   [Data] { fusionStartCommands(mode: mode, fusionEnableMaskCmd: enableCommand) }
    public var stopCommands:    [Data] { fusionStopCommands(mode: mode) }
    public var disableCommands: [Data] { fusionDisableSamplingCommands(mode: mode) }

    public func parseSample(from packet: Data) throws -> EulerAngles {
        try MWPacketParser.parseEulerAngles(packet)
    }

    public let loggerKey = "euler-angles"
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(0,4), (4,4), (8,4), (12,4)]
    }
}

/// Estimated gravity vector (g) — the component of acceleration attributable
/// to gravity, separated from device motion by the fusion algorithm.
///
/// Together with `MWSensorFusionLinearAcceleration` (which is the complementary
/// "motion only" half), this gives an honest split of what the accelerometer
/// sees into orientation + motion.
public struct MWSensorFusionGravity: MWLoggable {
    public typealias Sample = CartesianFloat

    public let mode: MWSensorFusionMode
    public let accRange: UInt8
    public let gyroRange: UInt8
    public let chip: MWSensorFusionChip

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: UInt8 = 0,
                gyroRange: UInt8 = 0,
                chip: MWSensorFusionChip = .bmi160) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
        self.chip = chip
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange,
                chip: MWSensorFusionChip = .bmi160) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue, chip: chip)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x09           // GRAVITY_VECTOR
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        fusionConfigureCommands(mode: mode, accRange: accRange, gyroRange: gyroRange, chip: chip)
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x20, 0x00]) }  // bit 5 = GRAVITY
    public var startCommand:   Data { fusionStartFusion }
    public var stopCommand:    Data { fusionStopFusion }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x20]) }

    public var enableCommands:  [Data] { fusionEnableSamplingCommands(mode: mode) }
    public var startCommands:   [Data] { fusionStartCommands(mode: mode, fusionEnableMaskCmd: enableCommand) }
    public var stopCommands:    [Data] { fusionStopCommands(mode: mode) }
    public var disableCommands: [Data] { fusionDisableSamplingCommands(mode: mode) }

    public func parseSample(from packet: Data) throws -> CartesianFloat {
        try MWPacketParser.parseGravityVector(packet)
    }

    public let loggerKey = "gravity"
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(0,4), (4,4), (8,4)]
    }
}

/// Linear acceleration (g) — raw acceleration minus the estimated gravity vector.
///
/// "What the user actually did" — punches, drops, taps, vibration. Pair with
/// an `RSS` + `Pulse`/`Threshold` data-processor chain to detect motion events
/// without writing your own filter on the host.
public struct MWSensorFusionLinearAcceleration: MWLoggable {
    public typealias Sample = CartesianFloat

    public let mode: MWSensorFusionMode
    public let accRange: UInt8
    public let gyroRange: UInt8
    public let chip: MWSensorFusionChip

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: UInt8 = 0,
                gyroRange: UInt8 = 0,
                chip: MWSensorFusionChip = .bmi160) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
        self.chip = chip
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange,
                chip: MWSensorFusionChip = .bmi160) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue, chip: chip)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x0A           // LINEAR_ACC
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        fusionConfigureCommands(mode: mode, accRange: accRange, gyroRange: gyroRange, chip: chip)
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x40, 0x00]) }  // bit 6 = LINEAR_ACC
    public var startCommand:   Data { fusionStartFusion }
    public var stopCommand:    Data { fusionStopFusion }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x40]) }

    public var enableCommands:  [Data] { fusionEnableSamplingCommands(mode: mode) }
    public var startCommands:   [Data] { fusionStartCommands(mode: mode, fusionEnableMaskCmd: enableCommand) }
    public var stopCommands:    [Data] { fusionStopCommands(mode: mode) }
    public var disableCommands: [Data] { fusionDisableSamplingCommands(mode: mode) }

    public func parseSample(from packet: Data) throws -> CartesianFloat {
        try MWPacketParser.parseGravityVector(packet)  // same float32 layout
    }

    public let loggerKey = "linear-acceleration"
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(0,4), (4,4), (8,4)]
    }
}

// MARK: - Corrected data signals (bits 0/1/2, registers 0x04/0x05/0x06)
//
// Each produces a CorrectedCartesianFloat (x, y, z, accuracy). Per
// `datainterpreter.cpp`:
//   - CORRECTED_ACC  (register 0x04, bit 0) divides x/y/z by SENSOR_FUSION_ACC_SCALE = 1000
//   - CORRECTED_GYRO (register 0x05, bit 1) no scaling — raw float32 (dps)
//   - CORRECTED_MAG  (register 0x06, bit 2) no scaling — raw float32 (µT)

/// Bias-corrected accelerometer output (g) with a per-sample accuracy byte.
///
/// Same units as the raw accelerometer, but with the fusion algorithm's
/// estimate of zero-g bias subtracted. Use when you want raw accel data plus
/// fusion's quality metric, without the orientation/gravity decomposition.
public struct MWSensorFusionCorrectedAcc: MWLoggable {
    public typealias Sample = CorrectedCartesianFloat

    public let mode: MWSensorFusionMode
    public let accRange: UInt8
    public let gyroRange: UInt8
    public let chip: MWSensorFusionChip

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: UInt8 = 0,
                gyroRange: UInt8 = 0,
                chip: MWSensorFusionChip = .bmi160) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
        self.chip = chip
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange,
                chip: MWSensorFusionChip = .bmi160) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue, chip: chip)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x04           // CORRECTED_ACC
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        fusionConfigureCommands(mode: mode, accRange: accRange, gyroRange: gyroRange, chip: chip)
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x01, 0x00]) }  // bit 0
    public var startCommand:   Data { fusionStartFusion }
    public var stopCommand:    Data { fusionStopFusion }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x01]) }

    public var enableCommands:  [Data] { fusionEnableSamplingCommands(mode: mode) }
    public var startCommands:   [Data] { fusionStartCommands(mode: mode, fusionEnableMaskCmd: enableCommand) }
    public var stopCommands:    [Data] { fusionStopCommands(mode: mode) }
    public var disableCommands: [Data] { fusionDisableSamplingCommands(mode: mode) }

    public func parseSample(from packet: Data) throws -> CorrectedCartesianFloat {
        try MWPacketParser.parseCorrectedCartesianFloat(packet, scale: 1000)
    }

    public let loggerKey = "corrected-acceleration"
    // Corrected data is 3×float32 + 1 byte accuracy = 13 bytes → 4 chunks
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(0,4), (4,4), (8,4), (12,1)]
    }
}

/// Bias-corrected gyroscope output (dps) with a per-sample accuracy byte.
///
/// Raw gyro reading with the algorithm's drift estimate subtracted out. The
/// accuracy byte (0–3) reports the gyro calibration confidence at that sample.
public struct MWSensorFusionCorrectedGyro: MWLoggable {
    public typealias Sample = CorrectedCartesianFloat

    public let mode: MWSensorFusionMode
    public let accRange: UInt8
    public let gyroRange: UInt8
    public let chip: MWSensorFusionChip

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: UInt8 = 0,
                gyroRange: UInt8 = 0,
                chip: MWSensorFusionChip = .bmi160) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
        self.chip = chip
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange,
                chip: MWSensorFusionChip = .bmi160) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue, chip: chip)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x05           // CORRECTED_GYRO
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        fusionConfigureCommands(mode: mode, accRange: accRange, gyroRange: gyroRange, chip: chip)
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x02, 0x00]) }  // bit 1
    public var startCommand:   Data { fusionStartFusion }
    public var stopCommand:    Data { fusionStopFusion }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x02]) }

    public var enableCommands:  [Data] { fusionEnableSamplingCommands(mode: mode) }
    public var startCommands:   [Data] { fusionStartCommands(mode: mode, fusionEnableMaskCmd: enableCommand) }
    public var stopCommands:    [Data] { fusionStopCommands(mode: mode) }
    public var disableCommands: [Data] { fusionDisableSamplingCommands(mode: mode) }

    public func parseSample(from packet: Data) throws -> CorrectedCartesianFloat {
        try MWPacketParser.parseCorrectedCartesianFloat(packet, scale: 1.0)
    }

    public let loggerKey = "corrected-angular-velocity"
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(0,4), (4,4), (8,4), (12,1)]
    }
}

/// Bias-corrected magnetometer output (µT) with a per-sample accuracy byte.
///
/// Hard-iron offset removed by the fusion algorithm. The accuracy byte goes
/// to 3 only after a full figure-8 calibration motion.
public struct MWSensorFusionCorrectedMag: MWLoggable {
    public typealias Sample = CorrectedCartesianFloat

    public let mode: MWSensorFusionMode
    public let accRange: UInt8
    public let gyroRange: UInt8
    public let chip: MWSensorFusionChip

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: UInt8 = 0,
                gyroRange: UInt8 = 0,
                chip: MWSensorFusionChip = .bmi160) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
        self.chip = chip
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange,
                chip: MWSensorFusionChip = .bmi160) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue, chip: chip)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x06           // CORRECTED_MAG
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        fusionConfigureCommands(mode: mode, accRange: accRange, gyroRange: gyroRange, chip: chip)
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x04, 0x00]) }  // bit 2
    public var startCommand:   Data { fusionStartFusion }
    public var stopCommand:    Data { fusionStopFusion }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x04]) }

    public var enableCommands:  [Data] { fusionEnableSamplingCommands(mode: mode) }
    public var startCommands:   [Data] { fusionStartCommands(mode: mode, fusionEnableMaskCmd: enableCommand) }
    public var stopCommands:    [Data] { fusionStopCommands(mode: mode) }
    public var disableCommands: [Data] { fusionDisableSamplingCommands(mode: mode) }

    public func parseSample(from packet: Data) throws -> CorrectedCartesianFloat {
        try MWPacketParser.parseCorrectedCartesianFloat(packet, scale: 1.0)
    }

    public let loggerKey = "corrected-magnetic-field"
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(0,4), (4,4), (8,4), (12,1)]
    }
}

// MARK: - Fire-and-forget sensor fusion commands

/// Clear all data enable bits. Mirrors C++ `mbl_mw_sensor_fusion_clear_enabled_mask`.
/// `[0x19, 0x03, 0x00, 0x7F]` — disables all 7 output streams.
public struct MWSensorFusionClearEnabledMask: MWCommand {
    public init() {}
    public var commandData: Data {
        MWPacket.command(.sensorFusion, 0x03, [0x00, 0x7F])
    }
}

/// Reset the default orientation. Mirrors C++ `mbl_mw_sensor_fusion_reset_orientation`.
/// `[0x19, 0x0F, 0x01]` — only available on sensor fusion revision >= 3 (RESET_ORIENTATION_REVISION).
/// Callers should check `moduleInfo(for: .sensorFusion)?.revision` before sending.
public struct MWSensorFusionResetOrientation: MWCommand {
    public init() {}
    public var commandData: Data {
        MWPacket.command(.sensorFusion, 0x0F, 0x01)
    }
}

/// Write accelerometer calibration data (10 bytes). Register 0x0C. Requires
/// sensor fusion revision >= 2 (CALIB_DATA_REVISION) and firmware v1.4.3+.
public struct MWSensorFusionWriteAccCalibration: MWCommand {
    public let data: [UInt8]
    public init(_ data: [UInt8]) {
        precondition(data.count == 10, "acc calibration data must be 10 bytes")
        self.data = data
    }
    public var commandData: Data {
        MWPacket.command(.sensorFusion, 0x0C, data)
    }
}

/// Write gyroscope calibration data (10 bytes). Register 0x0D.
public struct MWSensorFusionWriteGyroCalibration: MWCommand {
    public let data: [UInt8]
    public init(_ data: [UInt8]) {
        precondition(data.count == 10, "gyro calibration data must be 10 bytes")
        self.data = data
    }
    public var commandData: Data {
        MWPacket.command(.sensorFusion, 0x0D, data)
    }
}

/// Write magnetometer calibration data (10 bytes). Register 0x0E.
public struct MWSensorFusionWriteMagCalibration: MWCommand {
    public let data: [UInt8]
    public init(_ data: [UInt8]) {
        precondition(data.count == 10, "mag calibration data must be 10 bytes")
        self.data = data
    }
    public var commandData: Data {
        MWPacket.command(.sensorFusion, 0x0E, data)
    }
}

// MARK: - Calibration state read signal
//
// Mirrors C++ `mbl_mw_sensor_fusion_calibration_state_data_signal`.
// Available on sensor fusion revision >= 1 (CALIBRATION_REVISION).
// Issue the read via `MWPacket.read(.sensorFusion, 0x0B)` → `[0x19, 0x8B]`.
// The board responds with `[0x19, 0x8B, acc, gyro, mag]` (3 accuracy bytes, 0–3 each).

/// Read signal for the current fusion calibration accuracy (`MWSensorFusionCalibration`).
///
/// One-shot read — issue with `read(_:)` on `MetaWearDevice`. Returns the per-sensor
/// accuracy (0 = unreliable, 3 = high). Poll periodically while guiding the user
/// through calibration motion; persist `MWSensorFusionCalibrationData` once all
/// three reach HIGH so future sessions can skip the calibration dance.
///
/// Available on sensor fusion revision ≥ 1 (CALIBRATION_REVISION).
public struct MWSensorFusionCalibrationState: MWReadable {
    public typealias Sample = MWSensorFusionCalibration

    public init() {}

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x0B
    public let packedDataRegister: UInt8? = nil

    public var readCommand: Data {
        MWPacket.read(.sensorFusion, 0x0B)
    }

    public func parseSample(from packet: Data) throws -> MWSensorFusionCalibration {
        guard packet.count >= 5 else {
            throw MWError.operationFailed("Calibration-state packet too short: \(packet.count) bytes")
        }
        return MWSensorFusionCalibration(
            accelerometer: packet[2],
            gyroscope:     packet[3],
            magnetometer:  packet[4]
        )
    }
}
