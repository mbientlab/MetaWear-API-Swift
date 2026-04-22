import Foundation

// MARK: - Sensor fusion mode

public enum MWSensorFusionMode: UInt8, Sendable, CaseIterable {
    case sleep   = 0
    case ndof    = 1   // acc + gyro + mag — absolute orientation
    case imuPlus = 2   // acc + gyro — relative orientation
    case compass = 3   // mag only — geographic heading
    case m4g     = 4   // mag + acc — low-power relative orientation
}

// MARK: - Sensor fusion accelerometer range
// Raw values match C++ `MblMwSensorFusionAccRange`.

public enum MWSensorFusionAccRange: UInt8, Sendable, CaseIterable {
    case g2  = 0
    case g4  = 1
    case g8  = 2
    case g16 = 3
}

// MARK: - Sensor fusion gyro range
// Raw values match C++ `MblMwSensorFusionGyroRange`.

public enum MWSensorFusionGyroRange: UInt8, Sendable, CaseIterable {
    case dps2000 = 0
    case dps1000 = 1
    case dps500  = 2
    case dps250  = 3
}

// MARK: - Sensor fusion output types

public enum MWSensorFusionOutput: Sendable {
    case quaternion(Quaternion)
    case eulerAngles(EulerAngles)
    case correctedAcceleration(CorrectedCartesianFloat)
    case correctedRotation(CorrectedCartesianFloat)
    case correctedMagneticField(CorrectedCartesianFloat)
    case gravityVector(CartesianFloat)
    case linearAcceleration(CartesianFloat)
}

// MARK: - Calibration state

public struct MWSensorFusionCalibration: Sendable, Equatable {
    public let accelerometer: UInt8   // 0 = uncalibrated (UNRELIABLE), 3 = fully calibrated (HIGH)
    public let gyroscope: UInt8
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

public struct MWSensorFusionCalibrationData: Sendable, Equatable {
    public let acc: [UInt8]
    public let gyro: [UInt8]
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

// MARK: - Config byte helper
//
// All sensor fusion signals share the same config register: [0x19, 0x02, mode, rangeByte].
// rangeByte = ((gyroRange + 1) << 4) | accRange  — matches the C++ bitfield layout.

private func sensorFusionConfigCommand(mode: MWSensorFusionMode, accRange: UInt8, gyroRange: UInt8) -> Data {
    let rangeByte: UInt8 = accRange | ((gyroRange + 1) << 4)
    return MWPacket.command(.sensorFusion, 0x02, [mode.rawValue, rangeByte])
}

// MARK: - Sensor fusion signal definitions
// Each signal is a separate MWStreamable — subscribe to one or more simultaneously.
// Output-enable bits (register 0x03) in MblMwSensorFusionData order:
//   0 = CORRECTED_ACC, 1 = CORRECTED_GYRO, 2 = CORRECTED_MAG,
//   3 = QUATERNION, 4 = EULER_ANGLES, 5 = GRAVITY, 6 = LINEAR_ACC

public struct MWSensorFusionQuaternion: MWLoggable {
    public typealias Sample = Quaternion

    public let mode: MWSensorFusionMode
    public let accRange: UInt8    // 0=2g, 1=4g, 2=8g, 3=16g
    public let gyroRange: UInt8   // 0=2000dps, 1=1000dps, 2=500dps, 3=250dps

    public init(mode: MWSensorFusionMode = .ndof, accRange: UInt8 = 0, gyroRange: UInt8 = 0) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x07           // QUATERNION
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        [sensorFusionConfigCommand(mode: mode, accRange: accRange, gyroRange: gyroRange)]
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x08, 0x00]) }  // bit 3 = QUATERNION
    public var startCommand:   Data { MWPacket.command(.sensorFusion, 0x01, [0x01]) }
    public var stopCommand:    Data { MWPacket.command(.sensorFusion, 0x01, [0x00]) }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x08]) }

    public func parseSample(from packet: Data) throws -> Quaternion {
        try MWPacketParser.parseQuaternion(packet)
    }

    public let loggerKey = "quaternion"
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(0,4), (4,4), (8,4), (12,4)]
    }
}

public struct MWSensorFusionEuler: MWLoggable {
    public typealias Sample = EulerAngles

    public let mode: MWSensorFusionMode
    public let accRange: UInt8
    public let gyroRange: UInt8

    public init(mode: MWSensorFusionMode = .ndof, accRange: UInt8 = 0, gyroRange: UInt8 = 0) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x08           // EULER_ANGLES
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        [sensorFusionConfigCommand(mode: mode, accRange: accRange, gyroRange: gyroRange)]
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x10, 0x00]) }  // bit 4 = EULER
    public var startCommand:   Data { MWPacket.command(.sensorFusion, 0x01, [0x01]) }
    public var stopCommand:    Data { MWPacket.command(.sensorFusion, 0x01, [0x00]) }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x10]) }

    public func parseSample(from packet: Data) throws -> EulerAngles {
        try MWPacketParser.parseEulerAngles(packet)
    }

    public let loggerKey = "euler-angles"
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(0,4), (4,4), (8,4), (12,4)]
    }
}

public struct MWSensorFusionGravity: MWLoggable {
    public typealias Sample = CartesianFloat

    public let mode: MWSensorFusionMode
    public let accRange: UInt8
    public let gyroRange: UInt8

    public init(mode: MWSensorFusionMode = .ndof, accRange: UInt8 = 0, gyroRange: UInt8 = 0) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x09           // GRAVITY_VECTOR
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        [sensorFusionConfigCommand(mode: mode, accRange: accRange, gyroRange: gyroRange)]
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x20, 0x00]) }  // bit 5 = GRAVITY
    public var startCommand:   Data { MWPacket.command(.sensorFusion, 0x01, [0x01]) }
    public var stopCommand:    Data { MWPacket.command(.sensorFusion, 0x01, [0x00]) }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x20]) }

    public func parseSample(from packet: Data) throws -> CartesianFloat {
        try MWPacketParser.parseGravityVector(packet)
    }

    public let loggerKey = "gravity"
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(0,4), (4,4), (8,4)]
    }
}

public struct MWSensorFusionLinearAcceleration: MWLoggable {
    public typealias Sample = CartesianFloat

    public let mode: MWSensorFusionMode
    public let accRange: UInt8
    public let gyroRange: UInt8

    public init(mode: MWSensorFusionMode = .ndof, accRange: UInt8 = 0, gyroRange: UInt8 = 0) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x0A           // LINEAR_ACC
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        [sensorFusionConfigCommand(mode: mode, accRange: accRange, gyroRange: gyroRange)]
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x40, 0x00]) }  // bit 6 = LINEAR_ACC
    public var startCommand:   Data { MWPacket.command(.sensorFusion, 0x01, [0x01]) }
    public var stopCommand:    Data { MWPacket.command(.sensorFusion, 0x01, [0x00]) }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x40]) }

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

public struct MWSensorFusionCorrectedAcc: MWLoggable {
    public typealias Sample = CorrectedCartesianFloat

    public let mode: MWSensorFusionMode
    public let accRange: UInt8
    public let gyroRange: UInt8

    public init(mode: MWSensorFusionMode = .ndof, accRange: UInt8 = 0, gyroRange: UInt8 = 0) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x04           // CORRECTED_ACC
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        [sensorFusionConfigCommand(mode: mode, accRange: accRange, gyroRange: gyroRange)]
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x01, 0x00]) }  // bit 0
    public var startCommand:   Data { MWPacket.command(.sensorFusion, 0x01, [0x01]) }
    public var stopCommand:    Data { MWPacket.command(.sensorFusion, 0x01, [0x00]) }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x01]) }

    public func parseSample(from packet: Data) throws -> CorrectedCartesianFloat {
        try MWPacketParser.parseCorrectedCartesianFloat(packet, scale: 1000)
    }

    public let loggerKey = "corrected-acceleration"
    // Corrected data is 3×float32 + 1 byte accuracy = 13 bytes → 4 chunks
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(0,4), (4,4), (8,4), (12,1)]
    }
}

public struct MWSensorFusionCorrectedGyro: MWLoggable {
    public typealias Sample = CorrectedCartesianFloat

    public let mode: MWSensorFusionMode
    public let accRange: UInt8
    public let gyroRange: UInt8

    public init(mode: MWSensorFusionMode = .ndof, accRange: UInt8 = 0, gyroRange: UInt8 = 0) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x05           // CORRECTED_GYRO
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        [sensorFusionConfigCommand(mode: mode, accRange: accRange, gyroRange: gyroRange)]
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x02, 0x00]) }  // bit 1
    public var startCommand:   Data { MWPacket.command(.sensorFusion, 0x01, [0x01]) }
    public var stopCommand:    Data { MWPacket.command(.sensorFusion, 0x01, [0x00]) }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x02]) }

    public func parseSample(from packet: Data) throws -> CorrectedCartesianFloat {
        try MWPacketParser.parseCorrectedCartesianFloat(packet, scale: 1.0)
    }

    public let loggerKey = "corrected-angular-velocity"
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(0,4), (4,4), (8,4), (12,1)]
    }
}

public struct MWSensorFusionCorrectedMag: MWLoggable {
    public typealias Sample = CorrectedCartesianFloat

    public let mode: MWSensorFusionMode
    public let accRange: UInt8
    public let gyroRange: UInt8

    public init(mode: MWSensorFusionMode = .ndof, accRange: UInt8 = 0, gyroRange: UInt8 = 0) {
        self.mode = mode
        self.accRange = accRange
        self.gyroRange = gyroRange
    }

    public init(mode: MWSensorFusionMode = .ndof,
                accRange: MWSensorFusionAccRange,
                gyroRange: MWSensorFusionGyroRange) {
        self.init(mode: mode, accRange: accRange.rawValue, gyroRange: gyroRange.rawValue)
    }

    public let module: MWModule = .sensorFusion
    public let dataRegister: UInt8 = 0x06           // CORRECTED_MAG
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] {
        [sensorFusionConfigCommand(mode: mode, accRange: accRange, gyroRange: gyroRange)]
    }

    public var enableCommand:  Data { MWPacket.command(.sensorFusion, 0x03, [0x04, 0x00]) }  // bit 2
    public var startCommand:   Data { MWPacket.command(.sensorFusion, 0x01, [0x01]) }
    public var stopCommand:    Data { MWPacket.command(.sensorFusion, 0x01, [0x00]) }
    public var disableCommand: Data { MWPacket.command(.sensorFusion, 0x03, [0x00, 0x04]) }

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
