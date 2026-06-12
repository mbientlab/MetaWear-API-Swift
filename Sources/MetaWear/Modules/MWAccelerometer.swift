import Foundation

// MARK: - Accelerometer register opcodes (module 0x03)
//
// Names follow the C++ SDK headers (`AccelerometerBosch.h`,
// `AccelerometerBmi160Register.h`, `AccelerometerBmi270Register.h`). Registers
// 0x01–0x04 are shared between BMI160 and BMI270 with identical semantics;
// the chip-specific extras (0x05–0x1C) are documented per-case.
//
// Used at every command-build call site below; reach for one of these instead
// of writing a bare hex literal so the wire byte is self-describing.

enum MWAccelerometerRegister: UInt8 {
    /// POWER — `[mod, 0x01, 0x01]` starts sampling; `[mod, 0x01, 0x00]` stops. Both chips.
    case power               = 0x01
    /// DATA_INTERRUPT_ENABLE — `[mod, 0x02, enable_mask, disable_mask]`. Both chips.
    case dataInterruptEnable = 0x02
    /// DATA_INTERRUPT_CONFIG — `[mod, 0x03, acc_conf, range]`. Encoding differs per chip
    /// (see BMI160 vs BMI270 `configureCommands`). Both chips.
    case dataInterruptConfig = 0x03
    /// DATA_INTERRUPT — raw acceleration subscribe / notify register. Both chips.
    case dataInterrupt       = 0x04
    /// BMI270 only: PACKED_ACC_DATA (3 samples per packet). BMI160 uses 0x1C instead.
    case packedAccBMI270     = 0x05
    /// BMI270 only: FEATURE_ENABLE — sets which on-chip features are active.
    case featureEnable       = 0x06
    /// BMI270 only: FEATURE_INTERRUPT_ENABLE — sets which features raise interrupts.
    case featureInterruptEnable = 0x07
    /// BMI270 only: FEATURE_CONFIG — first payload byte is the feature index.
    case featureConfig       = 0x08
    /// BMI160: ANY_MOTION_INTERRUPT_ENABLE. BMI270: MOTION_INTERRUPT (shared by any/no/sig-motion).
    case motionInterruptEnable = 0x09
    /// BMI160: ANY_MOTION_CONFIG (threshold + count).
    case anyMotionConfigBMI160 = 0x0A
    /// BMI160: ANY_MOTION_INTERRUPT (notification).
    case anyMotionNotifyBMI160 = 0x0B
    /// BMI160: TAP_INTERRUPT_ENABLE.
    case tapInterruptEnableBMI160 = 0x0C
    /// BMI160: TAP_CONFIG (timing + threshold).
    case tapConfigBMI160          = 0x0D
    /// BMI160: TAP_INTERRUPT (notification).
    case tapNotifyBMI160          = 0x0E
    /// BMI160: ORIENT_INTERRUPT_ENABLE.
    case orientInterruptEnableBMI160 = 0x0F
    /// BMI160: ORIENT_INTERRUPT (notification).
    case orientNotifyBMI160          = 0x11
    /// BMI160: STEP_DETECTOR_INTERRUPT_EN.
    case stepDetectorEnableBMI160    = 0x17
    /// BMI160: STEP_DETECTOR_CONFIG (sensitivity mode + counter enable).
    case stepDetectorConfigBMI160    = 0x18
    /// BMI160: STEP_DETECTOR_INTERRUPT (subscribe / notification).
    case stepDetectorNotifyBMI160    = 0x19
    /// BMI160: STEP_COUNTER_DATA (one-shot read).
    case stepCounterDataBMI160       = 0x1A
    /// BMI160: PACKED_ACC_DATA (3 samples per packet). BMI270 uses 0x05.
    case packedAccBMI160             = 0x1C
}

// MARK: - Accelerometer (BMI160)

/// Bosch BMI160 accelerometer configuration.
///
/// Construct with a chosen output data rate and full-scale range, then pass
/// to `device.startStream(...)` or `device.startLogging(...)`. Sample values
/// are reported as `CartesianFloat` in units of g.
///
/// Use `MWAccelerometer.make(impl:)` if you do not know the chip variant
/// at compile time — it picks BMI160 or BMI270 based on the board's module
/// info response.
public struct MWAccelerometerBMI160: MWBoschIMUSensor {
    public typealias Sample = CartesianFloat

    /// BMI160 output data rates. Higher rates yield more samples per second
    /// but increase BLE bandwidth and battery use. Rates below 12.5 Hz require
    /// the chip's under-sampling mode (handled automatically in `configPayload`).
    public enum ODR: UInt8, Sendable, CaseIterable {
        case hz0_78  = 0,  hz1_56,  hz3_12,  hz6_25
        case hz12_5,       hz25,    hz50,    hz100
        case hz200,        hz400,   hz800,   hz1600

        /// The byte value written to the config register (enum value + 1)
        var configByte: UInt8 { rawValue + 1 }

        /// The output data rate in Hz.
        public var hz: Double {
            [0.78125, 1.5625, 3.125, 6.25, 12.5, 25, 50, 100, 200, 400, 800, 1600][Int(rawValue)]
        }

        /// Under-sampling flag: required for ODR < 12.5 Hz
        var underSampling: Bool { rawValue < 4 }
    }

    /// BMI160 accelerometer full-scale range. Smaller ranges give finer resolution
    /// per LSB; wider ranges measure higher accelerations without clipping.
    public enum Range: UInt8, Sendable, CaseIterable {
        case g2 = 0, g4, g8, g16

        var configByte: UInt8 { [0x03, 0x05, 0x08, 0x0C][Int(rawValue)] }
        var scale: Float      { [16384, 8192, 4096, 2048][Int(rawValue)] }
        /// The full-scale range in g.
        public var rangeG: Float { [2, 4, 8, 16][Int(rawValue)] }
    }

    /// Output data rate.
    public let odr: ODR
    /// Full-scale measurement range.
    public let range: Range

    /// Create a BMI160 accelerometer configuration.
    /// - Parameters:
    ///   - odr:   Output data rate. Default 100 Hz.
    ///   - range: Full-scale range. Default ±2 g.
    public init(odr: ODR = .hz100, range: Range = .g2) {
        self.odr = odr
        self.range = range
    }

    // MARK: MWSensor

    public let module: MWModule = .accelerometer
    public let dataRegister: UInt8 = MWAccelerometerRegister.dataInterrupt.rawValue
    public let packedDataRegister: UInt8? = MWAccelerometerRegister.packedAccBMI160.rawValue

    // MARK: MWBoschIMUSensor — configure command payload

    /// BMI160 `acc_conf` register encoding:
    ///   bits [3:0] = acc_odr  (1-indexed ODR code)
    ///   bits [6:4] = acc_bwp  (2 = normal for ODR >= 12.5 Hz; 0 when acc_us is set)
    ///   bit  7     = acc_us   (under-sampling: 1 for ODR < 12.5 Hz, 0 otherwise)
    var configPayload: [UInt8] {
        let bwp: UInt8 = odr.underSampling ? 0 : 2
        let us:  UInt8 = odr.underSampling ? 0x80 : 0x00
        let confByte: UInt8 = us | (bwp << 4) | odr.configByte
        return [confByte, range.configByte]
    }

    public let loggerKey = "acceleration"

    public func parseSample(from packet: Data) throws -> CartesianFloat {
        try MWPacketParser.parseCartesianFloat(packet, scale: range.scale)
    }

    public func parsePackedSamples(from packet: Data) throws -> [CartesianFloat] {
        try MWPacketParser.parsePackedCartesianFloat(packet, scale: range.scale)
    }
}

// MARK: - Accelerometer (BMI270)

/// Bosch BMI270 accelerometer configuration.
///
/// Construct with a chosen output data rate and full-scale range, then pass
/// to `device.startStream(...)` or `device.startLogging(...)`. Sample values
/// are reported as `CartesianFloat` in units of g.
///
/// The BMI270 also exposes on-chip gesture and motion features — see
/// `MWAccelerometerBMI270Steps` and `MWAccelerometerBMI270Features`.
public struct MWAccelerometerBMI270: MWBoschIMUSensor {
    public typealias Sample = CartesianFloat

    /// BMI270 output data rates. Rates below 12.5 Hz disable the high-performance
    /// filter (handled automatically in `configPayload`).
    public enum ODR: UInt8, Sendable, CaseIterable {
        case hz0_78  = 0,  hz1_56,  hz3_12,  hz6_25
        case hz12_5,       hz25,    hz50,    hz100
        case hz200,        hz400,   hz800,   hz1600

        var configByte: UInt8 { rawValue + 1 }
        var underSampling: Bool { rawValue < 4 }

        /// The output data rate in Hz.
        public var hz: Double {
            [0.78125, 1.5625, 3.125, 6.25, 12.5, 25, 50, 100, 200, 400, 800, 1600][Int(rawValue)]
        }
    }

    /// BMI270 accelerometer full-scale range. Smaller ranges give finer resolution
    /// per LSB; wider ranges measure higher accelerations without clipping.
    public enum Range: UInt8, Sendable, CaseIterable {
        case g2 = 0, g4, g8, g16

        var configByte: UInt8 { rawValue }          // BMI270 range byte is 0-based
        var scale: Float      { [16384, 8192, 4096, 2048][Int(rawValue)] }
        /// The full-scale range in g.
        public var rangeG: Float { [2, 4, 8, 16][Int(rawValue)] }
    }

    /// Output data rate.
    public let odr: ODR
    /// Full-scale measurement range.
    public let range: Range

    /// Create a BMI270 accelerometer configuration.
    /// - Parameters:
    ///   - odr:   Output data rate. Default 100 Hz.
    ///   - range: Full-scale range. Default ±2 g.
    public init(odr: ODR = .hz100, range: Range = .g2) {
        self.odr = odr
        self.range = range
    }

    // MARK: MWSensor

    public let module: MWModule = .accelerometer
    public let dataRegister: UInt8 = MWAccelerometerRegister.dataInterrupt.rawValue
    public let packedDataRegister: UInt8? = MWAccelerometerRegister.packedAccBMI270.rawValue

    // MARK: MWBoschIMUSensor — configure command payload

    /// BMI270 `acc_conf` register encoding:
    ///   bits [3:0] = acc_odr  (1-indexed ODR code)
    ///   bits [6:4] = acc_bwp  (always 2 = normal averaging)
    ///   bit  7     = acc_filter_perf (1 = high-performance, required for ODR >= 12.5 Hz)
    var configPayload: [UInt8] {
        let perf: UInt8    = odr.underSampling ? 0x00 : 0x80
        let confByte: UInt8 = perf | (2 << 4) | odr.configByte
        return [confByte, range.configByte]
    }

    public let loggerKey = "acceleration"

    public func parseSample(from packet: Data) throws -> CartesianFloat {
        try MWPacketParser.parseCartesianFloat(packet, scale: range.scale)
    }

    public func parsePackedSamples(from packet: Data) throws -> [CartesianFloat] {
        try MWPacketParser.parsePackedCartesianFloat(packet, scale: range.scale)
    }
}

// MARK: - Bosch-specific gesture detection (BMI160 and BMI270)

/// Orientation detection, any-motion detection, and tap detection for Bosch accelerometers.
/// These features use MetaWear accelerometer module registers 0x09–0x11.
public enum MWAccelerometerBosch {

    // MARK: Chip variant

    /// Distinguishes BMI160 from BMI270 for commands that differ in payload length.
    public enum ChipVariant: Sendable, Equatable {
        /// Bosch BMI160 IMU (impl id 1).
        case bmi160
        /// Bosch BMI270 IMU (impl id 4).
        case bmi270
    }

    // MARK: - Orientation detection

    /// The eight board orientations reported by interrupt register 0x11.
    /// Parse index = `(responseByte >> 1) & 0x07`.
    public enum SensorOrientation: Int, Sendable, CaseIterable {
        /// Display face up, board's long axis vertical, top edge up.
        case faceUpPortraitUpright       = 0
        /// Display face up, board's long axis vertical, top edge down.
        case faceUpPortraitUpsideDown    = 1
        /// Display face up, board's long axis horizontal, top edge left.
        case faceUpLandscapeLeft         = 2
        /// Display face up, board's long axis horizontal, top edge right.
        case faceUpLandscapeRight        = 3
        /// Display face down, board's long axis vertical, top edge up.
        case faceDownPortraitUpright     = 4
        /// Display face down, board's long axis vertical, top edge down.
        case faceDownPortraitUpsideDown  = 5
        /// Display face down, board's long axis horizontal, top edge left.
        case faceDownLandscapeLeft       = 6
        /// Display face down, board's long axis horizontal, top edge right.
        case faceDownLandscapeRight      = 7
    }

    /// Enable orientation-change interrupts on the MetaWear.
    ///
    /// Orientation detection is BMI160-specific — the BMI270 has no equivalent
    /// feature. Constructing this command with `chip == .bmi270` throws
    /// `MWError.operationFailed` with the same diagnostic the legacy Combine
    /// SDK reported when this stream was attempted on the wrong chip:
    /// `"Orientation requires a BMI160 module, which this device lacks."`.
    public struct EnableOrientation: MWCommand, Sendable {
        public init(chip: ChipVariant) throws {
            guard chip == .bmi160 else {
                throw MWError.operationFailed(
                    "Orientation requires a BMI160 module, which this device lacks."
                )
            }
        }
        public var commandData: Data { MWPacket.command(.accelerometer, MWAccelerometerRegister.orientInterruptEnableBMI160, [0x01, 0x00]) }
    }

    /// Disable orientation-change interrupts.
    ///
    /// Unguarded by chip variant: writing the disable bits on a BMI270 is a
    /// harmless no-op (the register isn't wired to a feature there), so we
    /// keep the no-arg `init()` for callers that want to tear down without
    /// having to remember the chip variant.
    public struct DisableOrientation: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.accelerometer, MWAccelerometerRegister.orientInterruptEnableBMI160, [0x00, 0x01]) }
    }

    /// Parse an orientation notification packet `[0x03, 0x11, byte]`.
    public static func parseOrientation(from packet: Data) throws -> SensorOrientation {
        guard packet.count >= 3 else {
            throw MWError.operationFailed("Orientation packet too short: \(packet.count) bytes")
        }
        let index = Int((packet[2] >> 1) & 0x07)
        guard let orientation = SensorOrientation(rawValue: index) else {
            throw MWError.operationFailed("Unknown orientation index: \(index)")
        }
        return orientation
    }

    // MARK: - Any-motion detection

    /// Any-motion event decoded from notification register 0x0b.
    public struct AnyMotionEvent: Sendable, Equatable {
        /// `true` = positive direction, `false` = negative direction.
        public let isPositive:  Bool
        /// `true` if motion was detected on the X axis.
        public let xAxisActive: Bool
        /// `true` if motion was detected on the Y axis.
        public let yAxisActive: Bool
        /// `true` if motion was detected on the Z axis.
        public let zAxisActive: Bool

        public init(isPositive: Bool, xAxisActive: Bool, yAxisActive: Bool, zAxisActive: Bool) {
            self.isPositive  = isPositive
            self.xAxisActive = xAxisActive
            self.yAxisActive = yAxisActive
            self.zAxisActive = zAxisActive
        }
    }

    /// Write the any-motion configuration to register 0x0a.
    ///
    /// The encoded payload length differs between chips (BMI160 appends an
    /// extra no-motion byte), so the `chip` variant must be supplied.
    public struct ConfigureAnyMotion: MWCommand, Sendable {
        /// IMU chip variant the command is being built for.
        public let chip: ChipVariant
        /// Consecutive over-threshold samples required before the interrupt fires (1–4).
        public let count: Int
        /// Detection threshold in g.
        public let thresholdG: Float
        /// Current accelerometer full-scale range in g (2, 4, 8, or 16).
        public let rangeG: Float
        /// No-motion threshold byte (firmware default 0x14 = 20).
        public let noMotionThreshold: UInt8

        /// Build an any-motion configuration command.
        /// - Parameters:
        ///   - chip:              IMU chip variant — controls payload length.
        ///   - count:             Over-threshold samples required to fire (1–4). Default 4.
        ///   - thresholdG:        Detection threshold in g. Default 0.75 g.
        ///   - rangeG:            The accelerometer's currently-configured range in g. Default 8 g.
        ///   - noMotionThreshold: Raw firmware byte for the paired no-motion threshold. Default 0x14.
        public init(chip: ChipVariant, count: Int = 4, thresholdG: Float = 0.75,
                    rangeG: Float = 8.0, noMotionThreshold: UInt8 = 0x14) {
            self.chip              = chip
            self.count             = count
            self.thresholdG        = thresholdG
            self.rangeG            = rangeG
            self.noMotionThreshold = noMotionThreshold
        }

        public var commandData: Data {
            let countByte: UInt8 = UInt8(max(0, min(255, count - 1)))
            // Resolution: (raw + 1) * (rangeG / 512) g per LSB  ⟹  raw = round(thresholdG * 512 / rangeG) − 1
            let thresholdByte: UInt8 = UInt8(max(0, min(255, Int(round(thresholdG * 512.0 / rangeG)) - 1)))
            var payload: [UInt8] = [countByte, thresholdByte, noMotionThreshold]
            if chip == .bmi160 { payload.append(noMotionThreshold) }   // BMI160 needs an extra no-motion byte
            return MWPacket.command(.accelerometer, MWAccelerometerRegister.anyMotionConfigBMI160, payload)
        }
    }

    /// Enable any-motion detection on all three axes (register 0x09).
    public struct EnableAnyMotion: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.accelerometer, MWAccelerometerRegister.motionInterruptEnable, [0x07, 0x00]) }
    }

    /// Disable any-motion detection (register 0x09).
    public struct DisableAnyMotion: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.accelerometer, MWAccelerometerRegister.motionInterruptEnable, [0x00, 0x7f]) }
    }

    /// Parse an any-motion notification packet `[0x03, 0x0b, byte]`.
    public static func parseAnyMotion(from packet: Data) throws -> AnyMotionEvent {
        guard packet.count >= 3 else {
            throw MWError.operationFailed("Any-motion packet too short: \(packet.count) bytes")
        }
        let b = packet[2]
        // bit 6 = 0 → positive direction; bit 6 = 1 → negative direction
        let isPositive  = (b & 0x40) == 0
        let zAxisActive = (b >> 5) & 1 == 1
        let yAxisActive = (b >> 4) & 1 == 1
        let xAxisActive = (b >> 3) & 1 == 1
        return AnyMotionEvent(isPositive: isPositive,
                              xAxisActive: xAxisActive,
                              yAxisActive: yAxisActive,
                              zAxisActive: zAxisActive)
    }

    // MARK: - Tap detection

    /// Tap shock duration: how long a tap impulse can last.
    public enum TapShockTime: UInt8, Sendable {
        /// 50 ms shock window.
        case ms50 = 0
        /// 75 ms shock window.
        case ms75 = 1
    }

    /// Quiet time after a tap before another tap can be detected.
    public enum TapQuietTime: UInt8, Sendable {
        /// 30 ms quiet time.
        case ms30 = 0
        /// 20 ms quiet time.
        case ms20 = 1
    }

    /// Time window in which a second tap must occur for a double-tap to be registered.
    public enum DoubleTapWindow: UInt8, Sendable {
        /// 50 ms double-tap window.
        case ms50  = 0
        /// 100 ms double-tap window.
        case ms100 = 1
        /// 150 ms double-tap window.
        case ms150 = 2
        /// 200 ms double-tap window.
        case ms200 = 3
        /// 250 ms double-tap window.
        case ms250 = 4
        /// 375 ms double-tap window.
        case ms375 = 5
        /// 500 ms double-tap window.
        case ms500 = 6
        /// 700 ms double-tap window.
        case ms700 = 7
    }

    /// Whether the fired interrupt was a single or double tap.
    public enum TapType: UInt8, Sendable {
        /// Two taps occurred within the configured double-tap window.
        case double = 1
        /// A single tap with no second tap inside the window.
        case single = 2
    }

    /// Tap event decoded from notification register 0x0e.
    public struct TapEvent: Sendable, Equatable {
        /// Single-tap or double-tap classification.
        public let type: TapType
        /// `true` = tap in the positive axis direction, `false` = negative.
        public let isPositive: Bool

        public init(type: TapType, isPositive: Bool) {
            self.type       = type
            self.isPositive = isPositive
        }
    }

    /// Write tap-detection configuration to register 0x0d.
    public struct ConfigureTap: MWCommand, Sendable {
        /// Maximum duration of a single tap impulse.
        public let shockTime:       TapShockTime
        /// Quiet time required after a tap before another can register.
        public let quietTime:       TapQuietTime
        /// Double-tap window. Also encoded for single-tap (firmware always writes both bytes).
        public let doubleTapWindow: DoubleTapWindow
        /// Detection threshold in g.
        public let thresholdG: Float
        /// Current accelerometer full-scale range in g.
        public let rangeG: Float

        /// Build a tap-detection configuration command.
        /// - Parameters:
        ///   - shockTime:       Shock impulse duration. Default 50 ms.
        ///   - quietTime:       Quiet time between taps. Default 30 ms.
        ///   - doubleTapWindow: Maximum time between two taps to qualify as a double-tap. Default 250 ms.
        ///   - thresholdG:      Detection threshold in g (capped at the chip's 5-bit `tap_th` field).
        ///   - rangeG:          The accelerometer's currently-configured range in g.
        public init(shockTime:       TapShockTime    = .ms50,
                    quietTime:       TapQuietTime    = .ms30,
                    doubleTapWindow: DoubleTapWindow = .ms250,
                    thresholdG: Float,
                    rangeG:     Float) {
            self.shockTime       = shockTime
            self.quietTime       = quietTime
            self.doubleTapWindow = doubleTapWindow
            self.thresholdG      = thresholdG
            self.rangeG          = rangeG
        }

        public var commandData: Data {
            // Byte 0 (INT_TAP[0]): bit7=shock, bit6=quiet, bits[3:0]=double-tap window
            let timingByte: UInt8 = (shockTime.rawValue << 7)
                                  | (quietTime.rawValue << 6)
                                  | doubleTapWindow.rawValue
            // Byte 1 (INT_TAP[1]): tap_th = round(threshold_g * 32 / range_g), max 31 (5-bit field)
            let tapTh: UInt8 = UInt8(max(0, min(31, Int(round(thresholdG * 32.0 / rangeG)))))
            return MWPacket.command(.accelerometer, MWAccelerometerRegister.tapConfigBMI160, [timingByte, tapTh])
        }
    }

    /// Enable single-tap and/or double-tap detection (register 0x0c).
    public struct EnableTap: MWCommand, Sendable {
        /// Whether to fire interrupts for single taps.
        public let single: Bool
        /// Whether to fire interrupts for double taps.
        public let double: Bool

        /// Build a tap-enable command.
        /// - Parameters:
        ///   - single: Enable single-tap interrupts. Default `true`.
        ///   - double: Enable double-tap interrupts. Default `false`.
        public init(single: Bool = true, double: Bool = false) {
            self.single = single
            self.double = double
        }

        public var commandData: Data {
            // bit 1 = single-tap, bit 0 = double-tap
            let enableByte: UInt8 = (single ? 0x02 : 0) | (double ? 0x01 : 0)
            return MWPacket.command(.accelerometer, MWAccelerometerRegister.tapInterruptEnableBMI160, [enableByte, 0x00])
        }
    }

    /// Disable both single- and double-tap detection (register 0x0c).
    public struct DisableTap: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.accelerometer, MWAccelerometerRegister.tapInterruptEnableBMI160, [0x00, 0x03]) }
    }

    /// Parse a tap notification packet `[0x03, 0x0e, byte]`.
    public static func parseTap(from packet: Data) throws -> TapEvent {
        guard packet.count >= 3 else {
            throw MWError.operationFailed("Tap packet too short: \(packet.count) bytes")
        }
        let b = packet[2]
        guard let type = TapType(rawValue: b & 0x03) else {
            throw MWError.operationFailed("Unknown tap type in byte: 0x\(String(b, radix: 16))")
        }
        // tap_sign bit 5: 0 = positive direction, 1 = negative direction
        let isPositive = ((b >> 5) & 1) == 0
        return TapEvent(type: type, isPositive: isPositive)
    }
}

// MARK: - BMI160 Step Counter & Step Detector
//
// Registers (AccelerometerBmi160Register):
//   0x17 = STEP_DETECTOR_INTERRUPT_EN   enable/disable step detector
//   0x18 = STEP_DETECTOR_CONFIG         step counter mode + enable
//   0x19 = STEP_DETECTOR_INTERRUPT      subscribe → [0x03, 0x19, 0x01]
//   0x1A = STEP_COUNTER_DATA            read → [0x03, 0x9A]; silent → [0x03, 0xDA]
//
// Byte layout for test_set_mode (NORMAL):
//   set_mode(NORMAL) → uint16 = 0x0315 → bytes [0x15, 0x03]
//   enable_step_counter → sets step_cnt_en bit → byte1 |= 0x08 → [0x15, 0x0B]
//   write_step_counter_config → [0x03, 0x18, 0x15, 0x0B]

/// On-chip step counter and step detector commands for the BMI160 IMU.
///
/// The step counter accumulates total steps in firmware (readable on demand);
/// the step detector fires an interrupt for each step as it occurs. Both share
/// the same on-chip filter — typically only one is enabled at a time.
public enum MWAccelerometerBMI160Steps {

    // MARK: - Step Counter

    /// BMI160 step counter sensitivity mode.
    public enum StepCounterMode: Sendable {
        /// Balanced between false positives and negatives (recommended).
        case normal     // combined bytes: [0x15, 0x0B]
        /// Fewer false negatives; may have more false positives.
        case sensitive  // combined bytes: [0x2D, 0x08]
        /// Fewer false positives; may have more false negatives.
        case robust     // combined bytes: [0x1D, 0x0F]
    }

    /// Writes the step counter mode + enable to register 0x18.
    /// Equivalent to: set_step_counter_mode + enable_step_counter + write_step_counter_config.
    public struct ConfigureStepCounter: MWCommand, Sendable {
        /// Sensitivity profile baked into the on-chip filter parameters.
        public let mode: StepCounterMode

        /// Build a step counter configuration command.
        /// - Parameter mode: Sensitivity profile. Default `.normal`.
        public init(mode: StepCounterMode = .normal) {
            self.mode = mode
        }

        public var commandData: Data {
            // Byte 0: steptime_min | min_threshold | alpha (mode-specific)
            // Byte 1: min_step_buf | step_cnt_en=1 | padding (mode-specific, always enabled)
            let (b0, b1): (UInt8, UInt8)
            switch mode {
            case .normal:    (b0, b1) = (0x15, 0x0B)
            case .sensitive: (b0, b1) = (0x2D, 0x08)
            case .robust:    (b0, b1) = (0x1D, 0x0F)
            }
            return MWPacket.command(.accelerometer, MWAccelerometerRegister.stepDetectorConfigBMI160, [b0, b1])
        }
    }

    /// Read the step count on demand. Sends [0x03, 0x9A].
    /// Call this after subscribing (i.e., a response handler is registered).
    public struct ReadStepCounter: MWCommand, Sendable {
        public init() {}
        // Register 0x1A with bit 7 set = 0x9A
        public var commandData: Data { MWPacket.read(.accelerometer, 0x1A) }
    }

    /// Silent read — no response forwarded to subscriber. Sends [0x03, 0xDA].
    /// Use when reading without an active subscriber (bit 7 + bit 6 set = 0xC0 | 0x1A = 0xDA).
    public struct ReadStepCounterSilent: MWCommand, Sendable {
        public init() {}
        // 0xDA = 0x1A | 0x80 | 0x40
        public var commandData: Data {
            Data([MWModule.accelerometer.rawValue, UInt8(0x1A) | 0x80 | 0x40])
        }
    }

    /// Parse a step count response packet `[0x03, 0x9A, low, high]` → `UInt32`.
    /// The count is a little-endian UInt16 in bytes 2–3.
    public static func parseStepCount(from packet: Data) throws -> UInt32 {
        guard packet.count >= 4 else {
            throw MWError.operationFailed("Step counter packet too short: \(packet.count) bytes")
        }
        let raw = UInt16(packet[2]) | (UInt16(packet[3]) << 8)
        return UInt32(raw)
    }

    // MARK: - Step Detector

    /// Enable the step detector interrupt on register 0x17. Sends [0x03, 0x17, 0x01, 0x00].
    public struct EnableStepDetector: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.accelerometer, MWAccelerometerRegister.stepDetectorEnableBMI160, [0x01, 0x00]) }
    }

    /// Disable the step detector interrupt on register 0x17. Sends [0x03, 0x17, 0x00, 0x01].
    public struct DisableStepDetector: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.accelerometer, MWAccelerometerRegister.stepDetectorEnableBMI160, [0x00, 0x01]) }
    }

    /// Subscribe to step detection events: send [0x03, 0x19, 0x01] to the board.
    /// This register byte is used by `device.startStream()` when subscribing.
    public static let stepDetectorRegister: UInt8 = 0x19

    /// Parse a step detector notification `[0x03, 0x19, byte]` → `UInt32` (1 = step detected).
    public static func parseStepDetection(from packet: Data) throws -> UInt32 {
        guard packet.count >= 3 else {
            throw MWError.operationFailed("Step detection packet too short: \(packet.count) bytes")
        }
        return UInt32(packet[2])
    }
}

// MARK: - BMI270 Step Counter & Step Detector
//
// Registers (AccelerometerBmi270Register):
//   0x06 = FEATURE_ENABLE               enable/disable BMI270 features
//   0x07 = FEATURE_INTERRUPT_ENABLE     enable/disable feature interrupts
//   0x08 = FEATURE_CONFIG               write step counter configuration
//   0x0B = STEP_COUNT_INTERRUPT         both step counter and step detector share this register
//
// Step counter and step detector share the same notification register (0x0B) on BMI270.
// They are distinguished by which feature-enable bit is set (0x02 = counter, 0x80 = detector).
//
// write_step_counter_config payload:
//   [index=0x07, param_250=0x00, param_251=0x0E, watermark_low, watermark_high|reset]
//   With trigger=1: [0x07, 0x00, 0x0E, 0x01, 0x00] → full command [0x03, 0x08, 0x07, 0x00, 0x0E, 0x01, 0x00]

/// On-chip step counter and step detector commands for the BMI270 IMU.
///
/// Unlike the BMI160, both features on the BMI270 deliver notifications on the
/// same register (0x0B); the feature-enable bitmap distinguishes them. The step
/// counter additionally supports a watermark trigger so the chip can batch step
/// updates rather than firing per step.
public enum MWAccelerometerBMI270Steps {

    // MARK: - Step Counter

    /// Configures and enables the BMI270 step counter.
    /// Equivalent to: set_step_counter_trigger + enable_step_counter + write_step_counter_config.
    public struct ConfigureStepCounter: MWCommandSequence {
        /// Watermark level: number of steps between notifications (1–1023). Default = 1 (every ~20 steps).
        public let trigger: UInt16

        /// Build a step counter configuration sequence.
        /// - Parameter trigger: Watermark level in steps (clamped to 1…1023). Default 1.
        public init(trigger: UInt16 = 1) {
            self.trigger = min(max(trigger, 1), 1023)
        }

        /// Enables step counter interrupts and features.
        /// Sends FEATURE_INTERRUPT_ENABLE (0x07) with step_counter bit set.
        public var interruptEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureInterruptEnable, [0x02, 0x00])
        }

        /// Enables the step counter feature.
        /// Sends FEATURE_ENABLE (0x06) with step_counter bit set.
        public var featureEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureEnable, [0x02, 0x00])
        }

        /// Writes the watermark trigger level to FEATURE_CONFIG (0x08). Sends [0x03, 0x08, 0x07, ...].
        /// The C++ Python test asserts this as the last command in the sequence.
        public var configCommand: Data {
            // step_counter_3.bitmap: [param_250, param_251, watermark_low, (watermark_high:2|reset:1|pad:5)]
            let wm0 = UInt8(trigger & 0x00FF)
            let wm1 = UInt8((trigger & 0x0300) >> 8)   // upper 2 bits of watermark
            return MWPacket.command(.accelerometer, MWAccelerometerRegister.featureConfig, [0x07, 0x00, 0x0E, wm0, wm1])
        }

        /// All three commands in the correct order: interrupt enable, feature enable, config.
        public var allCommands: [Data] { [interruptEnableCommand, featureEnableCommand, configCommand] }

        /// `MWCommandSequence` conformance — alias for `allCommands`.
        public var commands: [Data] { allCommands }
    }

    /// Read step count from the board. Sends [0x03, 0x8B] = [module, 0x80 | 0x0B].
    public struct ReadStepCounter: MWCommand, Sendable {
        public init() {}
        // Register 0x0B with bit 7 set = 0x8B
        public var commandData: Data { MWPacket.read(.accelerometer, 0x0B) }
    }

    /// Parse a step count response `[0x03, 0x0B, low, high]` → `UInt32`.
    public static func parseStepCount(from packet: Data) throws -> UInt32 {
        guard packet.count >= 4 else {
            throw MWError.operationFailed("Step counter packet too short: \(packet.count) bytes")
        }
        let raw = UInt16(packet[2]) | (UInt16(packet[3]) << 8)
        return UInt32(raw)
    }

    // MARK: - Step Detector

    /// Enables the BMI270 step detector.
    /// Sends two commands: FEATURE_INTERRUPT_ENABLE (0x07) then FEATURE_ENABLE (0x06),
    /// both with bit 7 (0x80) = step_detector set.
    public struct EnableStepDetector: MWCommandSequence {
        public init() {}

        /// [0x03, 0x07, 0x80, 0x00]
        public var interruptEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureInterruptEnable, [0x80, 0x00])
        }

        /// [0x03, 0x06, 0x80, 0x00]  — the command asserted by the C++ Python test.
        public var featureEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureEnable, [0x80, 0x00])
        }

        /// Both commands in order.
        public var commands: [Data] { [interruptEnableCommand, featureEnableCommand] }
    }

    /// Disables the BMI270 step detector.
    public struct DisableStepDetector: MWCommandSequence {
        public init() {}

        /// [0x03, 0x07, 0x00, 0x80]
        public var interruptDisableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureInterruptEnable, [0x00, 0x80])
        }

        /// [0x03, 0x06, 0x00, 0x80]  — the command asserted by the C++ Python test.
        public var featureDisableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureEnable, [0x00, 0x80])
        }

        /// Both commands in order.
        public var commands: [Data] { [interruptDisableCommand, featureDisableCommand] }
    }

    /// Both step counter and step detector subscribe to register 0x0B on BMI270.
    public static let stepRegister: UInt8 = 0x0B

    /// Parse a step detection notification `[0x03, 0x0B, byte]` → `UInt32` (0 or 1).
    public static func parseStepDetection(from packet: Data) throws -> UInt32 {
        guard packet.count >= 3 else {
            throw MWError.operationFailed("Step detection packet too short: \(packet.count) bytes")
        }
        return UInt32(packet[2])
    }
}

// MARK: - BMI270 Additional Features
//
// Activity classification, wrist gestures, wrist wakeup, no-motion, and FIFO downsampling.
//
// Registers (AccelerometerBmi270Register):
//   0x06 = FEATURE_ENABLE               enable bit in byte 0; disable bit in byte 1
//   0x07 = FEATURE_INTERRUPT_ENABLE     same bit layout as FEATURE_ENABLE
//   0x08 = FEATURE_CONFIG               first payload byte = feature index
//   0x09 = MOTION_INTERRUPT             any-motion / no-motion share this register
//   0x0A = WRIST_INTERRUPT              wrist gesture + wrist wakeup notifications
//   0x0C = ACTIVITY_INTERRUPT           activity classification notifications
//   0x11 = DOWNSAMPLING                 FIFO downsampling (acc + gyro)
//
// Feature bitmap (byte 0 of FEATURE_ENABLE / FEATURE_INTERRUPT_ENABLE):
//   0x01 sig_motion   0x02 step_counter  0x04 activity_out  0x08 wrist_wakeup
//   0x10 wrist_gesture 0x20 no_motion   0x40 any_motion    0x80 step_detector
//
// FEATURE_CONFIG indices:
//   0 = axis_remap   1 = any_motion   2 = no_motion   3 = sig_motion
//   4-7 = step_counter  8 = wrist_gesture   9 = wrist_wakeup

/// Additional on-chip features unique to the BMI270 IMU.
///
/// Covers activity classification, wrist gestures and wakeup, no-motion,
/// significant-motion, and FIFO downsampling. Each feature is enabled by a
/// dedicated bit in the FEATURE_ENABLE / FEATURE_INTERRUPT_ENABLE registers,
/// then configured through the FEATURE_CONFIG register.
public enum MWAccelerometerBMI270Features {

    // MARK: - Activity Classification

    /// Activity class reported by the BMI270 activity-output feature.
    /// Value is decoded from the notification payload byte as `byte >> 1`.
    public enum Activity: UInt8, Sendable, Equatable {
        /// Device is at rest.
        case still   = 0
        /// Walking-cadence motion detected.
        case walking = 1
        /// Running-cadence motion detected.
        case running = 2
        /// Motion does not match a known class.
        case unknown = 3
    }

    /// Enables activity-output detection (bit 0x04).
    public struct EnableActivityDetection: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x04, 0x00]
        public var interruptEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureInterruptEnable, [0x04, 0x00])
        }
        /// [0x03, 0x06, 0x04, 0x00]
        public var featureEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureEnable, [0x04, 0x00])
        }
        public var commands: [Data] { [interruptEnableCommand, featureEnableCommand] }
    }

    /// Disables activity-output detection (bit 0x04).
    public struct DisableActivityDetection: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x00, 0x04]
        public var interruptDisableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureInterruptEnable, [0x00, 0x04])
        }
        /// [0x03, 0x06, 0x00, 0x04]
        public var featureDisableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureEnable, [0x00, 0x04])
        }
        public var commands: [Data] { [interruptDisableCommand, featureDisableCommand] }
    }

    /// Subscribe register for activity classification (`[0x03, 0x0C, byte]`).
    public static let activityRegister: UInt8 = 0x0C

    /// Parse an activity notification `[0x03, 0x0C, byte]` → `Activity`.
    /// C++ datainterpreter: `value = response[0] >> 1`.
    public static func parseActivity(from packet: Data) throws -> Activity {
        guard packet.count >= 3 else {
            throw MWError.operationFailed("Activity packet too short: \(packet.count) bytes")
        }
        let raw = packet[2] >> 1
        return Activity(rawValue: raw) ?? .unknown
    }

    // MARK: - Wrist Events (register 0x0A — shared by gesture + wakeup)

    /// Which arm the device is worn on — affects gesture direction sign.
    public enum WristArm: UInt8, Sendable, Equatable {
        /// Device worn on the left wrist.
        case left  = 0
        /// Device worn on the right wrist.
        case right = 1
    }

    /// BMI270 wrist-gesture classifications (see Bosch BMI270 datasheet).
    public enum WristGestureCode: UInt8, Sendable, Equatable {
        /// Gesture did not match any known classification.
        case unknown     = 0
        /// Arm pushed downward from a raised position.
        case pushArmDown = 1
        /// Wrist pivoted up from a horizontal position.
        case pivotUp     = 2
        /// Quick shake / jiggle of the wrist.
        case shake       = 3   // aka "jiggle"
        /// Arm flicked inward (toward the body).
        case armFlickIn  = 4
        /// Arm flicked outward (away from the body).
        case armFlickOut = 5
    }

    /// Distinguishes a wrist-wakeup notification from a wrist-gesture notification
    /// on the shared 0x0A register. Encoded in the low 2 bits of the payload byte.
    public enum WristEventKind: UInt8, Sendable, Equatable {
        /// Wrist-wakeup event — user raised the wrist into the viewing position.
        case wakeup  = 0
        /// Wrist-gesture event — see `WristGestureCode` for the specific gesture.
        case gesture = 1
    }

    /// A single wrist-event notification. For `.wakeup`, `gestureCode` is `.unknown`.
    public struct WristEvent: Sendable, Equatable {
        /// Whether this is a wakeup or a recognized gesture.
        public let kind: WristEventKind
        /// Specific gesture code (only meaningful when `kind == .gesture`).
        public let gestureCode: WristGestureCode
    }

    /// Subscribe register for wrist gesture + wakeup events.
    public static let wristEventRegister: UInt8 = 0x0A

    /// Parse a wrist event notification `[0x03, 0x0A, byte]`.
    /// C++ datainterpreter: `type = b & 0x03; code = b >> 2`.
    public static func parseWristEvent(from packet: Data) throws -> WristEvent {
        guard packet.count >= 3 else {
            throw MWError.operationFailed("Wrist event packet too short: \(packet.count) bytes")
        }
        let b    = packet[2]
        let kind = WristEventKind(rawValue: b & 0x03) ?? .wakeup
        let code = WristGestureCode(rawValue: b >> 2) ?? .unknown
        return WristEvent(kind: kind, gestureCode: code)
    }

    // MARK: - Wrist Gesture (FEATURE_CONFIG index 8)

    /// Writes wrist-gesture parameters to FEATURE_CONFIG. 11-byte command.
    ///
    /// Bitmap layout (8 bytes after index):
    /// ```
    /// byte0: out_conf(4) | wearable_arm(1) | enable(3)   → 0x10 if right, 0x00 if left
    /// byte1: padding
    /// byte2-3: min_flick_peak     (UInt16 LE)
    /// byte4-5: min_flick_samples  (UInt16 LE)
    /// byte6-7: max_duration       (UInt16 LE)
    /// ```
    public struct ConfigureWristGesture: MWCommand, Sendable {
        /// Wrist the device is worn on — toggles the armside bit in the config bitmap.
        public let arm: WristArm
        /// Minimum flick peak threshold (`min_flick_peak`).
        public let peak: UInt16
        /// Minimum samples in a flick (`min_flick_samples`).
        public let samples: UInt16
        /// Maximum total gesture duration in samples (`max_duration`).
        public let duration: UInt16

        /// Build a wrist-gesture configuration command. Defaults match the C++ SDK.
        /// - Parameters:
        ///   - arm:      Wrist the device is worn on. Default `.left`.
        ///   - peak:     `min_flick_peak`. Default `0x0332`.
        ///   - samples:  `min_flick_samples`. Default `0x0050`.
        ///   - duration: `max_duration`. Default `0x0064`.
        public init(
            arm: WristArm = .left,
            peak: UInt16 = 0x0332,
            samples: UInt16 = 0x0050,
            duration: UInt16 = 0x0064
        ) {
            self.arm      = arm
            self.peak     = peak
            self.samples  = samples
            self.duration = duration
        }

        public var commandData: Data {
            let armByte: UInt8 = (arm == .right) ? 0x10 : 0x00
            let payload: [UInt8] = [
                0x08,                                          // FEATURE_CONFIG index
                armByte, 0x00,                                 // armside + padding
                UInt8(peak     & 0xFF), UInt8((peak     >> 8) & 0xFF),
                UInt8(samples  & 0xFF), UInt8((samples  >> 8) & 0xFF),
                UInt8(duration & 0xFF), UInt8((duration >> 8) & 0xFF),
            ]
            return MWPacket.command(.accelerometer, MWAccelerometerRegister.featureConfig, payload)
        }
    }

    /// Enables wrist gesture (bit 0x10).
    public struct EnableWristGesture: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x10, 0x00]
        public var interruptEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureInterruptEnable, [0x10, 0x00])
        }
        /// [0x03, 0x06, 0x10, 0x00]
        public var featureEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureEnable, [0x10, 0x00])
        }
        public var commands: [Data] { [interruptEnableCommand, featureEnableCommand] }
    }

    /// Disables wrist gesture (bit 0x10).
    public struct DisableWristGesture: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x00, 0x10]
        public var interruptDisableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureInterruptEnable, [0x00, 0x10])
        }
        /// [0x03, 0x06, 0x00, 0x10]
        public var featureDisableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureEnable, [0x00, 0x10])
        }
        public var commands: [Data] { [interruptDisableCommand, featureDisableCommand] }
    }

    // MARK: - Wrist Wakeup (FEATURE_CONFIG index 9)

    /// Writes wrist-wakeup parameters to FEATURE_CONFIG. 15-byte command.
    ///
    /// Bitmap is 12 bytes = six little-endian UInt16s in this order:
    /// `min_angle_focus`, `min_angle_non_focus`, `max_tilt_lr`, `max_tilt_ll`,
    /// `max_tilt_pd`, `max_tilt_pu`.
    ///
    /// Default values taken from the C++ struct initializer comment:
    /// `0xA8 0x05 0xEE 0x06 0x00 0x04 0xBC 0x02 0xB3 0x00 0x85 0x07`.
    public struct ConfigureWristWakeup: MWCommand, Sendable {
        /// Minimum angle the device must reach in the focus position.
        public let minAngleFocus: UInt16
        /// Minimum angle from the non-focus position before triggering.
        public let minAngleNonFocus: UInt16
        /// Maximum tilt allowed while rolling right.
        public let maxTiltLR: UInt16
        /// Maximum tilt allowed while rolling left.
        public let maxTiltLL: UInt16
        /// Maximum tilt allowed while pitched down.
        public let maxTiltPD: UInt16
        /// Maximum tilt allowed while pitched up.
        public let maxTiltPU: UInt16

        /// Build a wrist-wakeup configuration command. Defaults match the C++ SDK.
        public init(
            minAngleFocus:    UInt16 = 0x05A8,
            minAngleNonFocus: UInt16 = 0x06EE,
            maxTiltLR:        UInt16 = 0x0400,
            maxTiltLL:        UInt16 = 0x02BC,
            maxTiltPD:        UInt16 = 0x00B3,
            maxTiltPU:        UInt16 = 0x0785
        ) {
            self.minAngleFocus    = minAngleFocus
            self.minAngleNonFocus = minAngleNonFocus
            self.maxTiltLR        = maxTiltLR
            self.maxTiltLL        = maxTiltLL
            self.maxTiltPD        = maxTiltPD
            self.maxTiltPU        = maxTiltPU
        }

        public var commandData: Data {
            func le(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
            var payload: [UInt8] = [0x09]                      // FEATURE_CONFIG index
            payload += le(minAngleFocus)
            payload += le(minAngleNonFocus)
            payload += le(maxTiltLR)
            payload += le(maxTiltLL)
            payload += le(maxTiltPD)
            payload += le(maxTiltPU)
            return MWPacket.command(.accelerometer, MWAccelerometerRegister.featureConfig, payload)
        }
    }

    /// Enables wrist wakeup (bit 0x08).
    public struct EnableWristWakeup: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x08, 0x00]
        public var interruptEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureInterruptEnable, [0x08, 0x00])
        }
        /// [0x03, 0x06, 0x08, 0x00]
        public var featureEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureEnable, [0x08, 0x00])
        }
        public var commands: [Data] { [interruptEnableCommand, featureEnableCommand] }
    }

    /// Disables wrist wakeup (bit 0x08).
    public struct DisableWristWakeup: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x00, 0x08]
        public var interruptDisableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureInterruptEnable, [0x00, 0x08])
        }
        /// [0x03, 0x06, 0x00, 0x08]
        public var featureDisableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureEnable, [0x00, 0x08])
        }
        public var commands: [Data] { [interruptDisableCommand, featureDisableCommand] }
    }

    // MARK: - No-motion (FEATURE_CONFIG index 2)
    //
    // Shares register 0x09 (MOTION_INTERRUPT) with any-motion and sig-motion.
    // The feature-enable bit (0x20) distinguishes no-motion from any-motion (0x40).

    /// Writes no-motion parameters to FEATURE_CONFIG. 7-byte command.
    ///
    /// Bitmap layout (4 bytes after index):
    /// ```
    /// byte0: duration_lo (bits 0-7 of 13-bit duration)
    /// byte1: duration_hi (bits 8-12) | select_x(bit5) | select_y(bit6) | select_z(bit7)
    /// byte2: threshold_lo
    /// byte3: threshold_hi (bits 0-2 of 11-bit threshold) | pad(bits 3-7)
    /// ```
    public struct ConfigureNoMotion: MWCommand, Sendable {
        /// Duration in samples (0…0x1FFF).
        public let duration: UInt16
        /// Threshold in 0.48 mg/LSB units (0…0x7FF).
        public let threshold: UInt16
        /// Whether the X axis is included in the no-motion check.
        public let selectX: Bool
        /// Whether the Y axis is included in the no-motion check.
        public let selectY: Bool
        /// Whether the Z axis is included in the no-motion check.
        public let selectZ: Bool

        /// Build a no-motion configuration command.
        /// - Parameters:
        ///   - duration:  Sustained-quiet duration in samples (≤ 0x1FFF). Default 5.
        ///   - threshold: Motion threshold in 0.48 mg/LSB units (≤ 0x7FF). Default 0xAA.
        ///   - selectX:   Include X axis in the check. Default `true`.
        ///   - selectY:   Include Y axis in the check. Default `true`.
        ///   - selectZ:   Include Z axis in the check. Default `true`.
        public init(
            duration: UInt16 = 5,
            threshold: UInt16 = 0xAA,
            selectX: Bool = true,
            selectY: Bool = true,
            selectZ: Bool = true
        ) {
            precondition(duration  <= 0x1FFF, "duration must fit in 13 bits")
            precondition(threshold <= 0x07FF, "threshold must fit in 11 bits")
            self.duration  = duration
            self.threshold = threshold
            self.selectX   = selectX
            self.selectY   = selectY
            self.selectZ   = selectZ
        }

        public var commandData: Data {
            let d0 = UInt8(duration & 0xFF)
            var d1 = UInt8((duration >> 8) & 0x1F)
            if selectX { d1 |= 1 << 5 }
            if selectY { d1 |= 1 << 6 }
            if selectZ { d1 |= 1 << 7 }
            let t0 = UInt8(threshold & 0xFF)
            let t1 = UInt8((threshold >> 8) & 0x07)
            return MWPacket.command(.accelerometer, MWAccelerometerRegister.featureConfig, [0x02, d0, d1, t0, t1])
        }
    }

    /// Enables no-motion detection (bit 0x20).
    public struct EnableNoMotion: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x20, 0x00]
        public var interruptEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureInterruptEnable, [0x20, 0x00])
        }
        /// [0x03, 0x06, 0x20, 0x00]
        public var featureEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureEnable, [0x20, 0x00])
        }
        public var commands: [Data] { [interruptEnableCommand, featureEnableCommand] }
    }

    /// Disables no-motion detection (bit 0x20).
    public struct DisableNoMotion: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x00, 0x20]
        public var interruptDisableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureInterruptEnable, [0x00, 0x20])
        }
        /// [0x03, 0x06, 0x00, 0x20]
        public var featureDisableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureEnable, [0x00, 0x20])
        }
        public var commands: [Data] { [interruptDisableCommand, featureDisableCommand] }
    }

    // MARK: - Significant motion (FEATURE_CONFIG index 3)
    //
    // Shares register 0x09 (MOTION_INTERRUPT) with any-motion and no-motion.
    // The feature-enable bit (0x01) distinguishes sig-motion from no-motion
    // (0x20) and any-motion (0x40). Sig-motion fires only on sustained
    // movement (e.g. walking, biking, riding in a vehicle) — phone-in-pocket
    // while still or laid on a desk does not trigger.

    /// Writes significant-motion parameters to FEATURE_CONFIG. 5-byte command.
    ///
    /// Bitmap layout (2 bytes after the index byte):
    /// ```
    /// byte0: blocksize_lo (low 8 bits of 16-bit blocksize)
    /// byte1: blocksize_hi (high 8 bits of 16-bit blocksize)
    /// ```
    ///
    /// `blocksize` is the number of accelerometer samples accumulated before
    /// the on-chip motion-energy classifier evaluates whether to fire. The
    /// firmware default is `250` (≈ 2.5 s at 100 Hz ODR).
    public struct ConfigureSignificantMotion: MWCommand, Sendable {
        /// Block size in samples (firmware default 250).
        public let blocksize: UInt16

        /// Build a significant-motion configuration command.
        /// - Parameter blocksize: Number of samples per classifier evaluation block. Default 250.
        public init(blocksize: UInt16 = 250) {
            self.blocksize = blocksize
        }

        public var commandData: Data {
            let lo = UInt8(blocksize & 0x00FF)
            let hi = UInt8((blocksize >> 8) & 0x00FF)
            return MWPacket.command(.accelerometer, MWAccelerometerRegister.featureConfig, [0x03, lo, hi])
        }
    }

    /// Enables significant-motion detection (bit 0x01).
    public struct EnableSignificantMotion: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x01, 0x00]
        public var interruptEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureInterruptEnable, [0x01, 0x00])
        }
        /// [0x03, 0x06, 0x01, 0x00]
        public var featureEnableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureEnable, [0x01, 0x00])
        }
        public var commands: [Data] { [interruptEnableCommand, featureEnableCommand] }
    }

    /// Disables significant-motion detection (bit 0x01).
    public struct DisableSignificantMotion: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x00, 0x01]
        public var interruptDisableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureInterruptEnable, [0x00, 0x01])
        }
        /// [0x03, 0x06, 0x00, 0x01]
        public var featureDisableCommand: Data {
            MWPacket.command(.accelerometer, MWAccelerometerRegister.featureEnable, [0x00, 0x01])
        }
        public var commands: [Data] { [interruptDisableCommand, featureDisableCommand] }
    }

    // MARK: - FIFO Downsampling (register 0x11)

    /// Configures BMI270 FIFO downsampling. Single config byte:
    /// ```
    /// bit 0-2: gyroOrdinal  (gyro downsample = ODR / 2^n, n = 0…7)
    /// bit 3:   gyroFilterData (1 = filtered, 0 = unfiltered)
    /// bit 4-6: accOrdinal
    /// bit 7:   accFilterData
    /// ```
    public struct SetDownsampling: MWCommand, Sendable {
        /// Gyro downsample exponent — actual factor is `2^gyroOrdinal` (0…7).
        public let gyroOrdinal: UInt8
        /// `true` to write filtered gyro samples into the FIFO; `false` for unfiltered.
        public let gyroFilterData: Bool
        /// Accelerometer downsample exponent — actual factor is `2^accOrdinal` (0…7).
        public let accOrdinal: UInt8
        /// `true` to write filtered accelerometer samples into the FIFO; `false` for unfiltered.
        public let accFilterData: Bool

        /// Build a FIFO-downsampling configuration command.
        /// - Parameters:
        ///   - gyroOrdinal:    Gyro downsample exponent (0…7). Default 0 (no downsampling).
        ///   - gyroFilterData: Filter gyro FIFO data. Default `false`.
        ///   - accOrdinal:     Accelerometer downsample exponent (0…7). Default 0 (no downsampling).
        ///   - accFilterData:  Filter accelerometer FIFO data. Default `false`.
        public init(
            gyroOrdinal: UInt8 = 0,
            gyroFilterData: Bool = false,
            accOrdinal: UInt8 = 0,
            accFilterData: Bool = false
        ) {
            precondition(gyroOrdinal <= 7, "gyroOrdinal must fit in 3 bits (0...7)")
            precondition(accOrdinal  <= 7, "accOrdinal must fit in 3 bits (0...7)")
            self.gyroOrdinal    = gyroOrdinal
            self.gyroFilterData = gyroFilterData
            self.accOrdinal     = accOrdinal
            self.accFilterData  = accFilterData
        }

        public var commandData: Data {
            var b: UInt8 = (gyroOrdinal & 0x07) | ((accOrdinal & 0x07) << 4)
            if gyroFilterData { b |= 1 << 3 }
            if accFilterData  { b |= 1 << 7 }
            // Register 0x11 = DOWNSAMPLING on BMI270. (The same raw value is
            // ORIENT_INTERRUPT on BMI160, so it can't be a single enum case in
            // `MWAccelerometerRegister` — see `.orientNotifyBMI160`.)
            return MWPacket.command(.accelerometer, 0x11, [b])
        }
    }
}

// MARK: - Type-erased accelerometer (chosen at runtime from module info)

/// Type-erased accelerometer that wraps whichever Bosch IMU variant the connected
/// MetaWear actually has. Use this when the chip is determined at runtime
/// (typically from the module-info handshake) rather than known statically.
///
/// Conforms to `MWLoggable`, forwarding `parseSample`, `configureCommands`,
/// `enableCommand`, etc. to the underlying chip-specific implementation, so it
/// can be passed directly to `device.startStream(...)` / `device.startLogging(...)`.
public enum MWAccelerometer: Sendable {
    /// The board has a BMI160 IMU (impl id 1).
    case bmi160(MWAccelerometerBMI160)
    /// The board has a BMI270 IMU (impl id 4).
    case bmi270(MWAccelerometerBMI270)

    /// Build a type-erased accelerometer for the given chip impl id, snapping ODR
    /// and range to the nearest values supported by the chip.
    ///
    /// - Parameters:
    ///   - impl:   Module info impl id (1 = BMI160, 4 = BMI270). Other values return `nil`.
    ///   - odrHz:  Desired output data rate in Hz. Default 100.
    ///   - rangeG: Desired full-scale range in g. Default 2.
    /// - Returns: A wrapped accelerometer config, or `nil` if `impl` is unknown.
    public static func make(
        impl: UInt8,
        odrHz: Double = 100,
        rangeG: Float = 2
    ) -> MWAccelerometer? {
        switch impl {
        case 1:  // BMI160
            let odr   = MWAccelerometerBMI160.ODR.allCases.min { abs($0.hz - odrHz) < abs($1.hz - odrHz) }!
            let range = MWAccelerometerBMI160.Range.allCases.min { abs($0.rangeG - rangeG) < abs($1.rangeG - rangeG) } ?? .g2
            return .bmi160(MWAccelerometerBMI160(odr: odr, range: range))
        case 4:  // BMI270
            let odr   = MWAccelerometerBMI270.ODR.allCases.min { abs($0.hz - odrHz) < abs($1.hz - odrHz) }!
            let range = MWAccelerometerBMI270.Range.allCases.min { abs($0.rangeG - rangeG) < abs($1.rangeG - rangeG) } ?? .g2
            return .bmi270(MWAccelerometerBMI270(odr: odr, range: range))
        default:
            return nil
        }
    }

    /// The actual ODR after snapping to the nearest supported value, in Hz.
    /// Mirrors C++ `mbl_mw_acc_set_odr` return value.
    public var odrHz: Double {
        switch self {
        case .bmi160(let s): return s.odr.hz
        case .bmi270(let s): return s.odr.hz
        }
    }

    /// The actual range after snapping to the nearest supported value, in g.
    /// Mirrors C++ `mbl_mw_acc_set_range` return value.
    public var rangeG: Float {
        switch self {
        case .bmi160(let s): return s.range.rangeG
        case .bmi270(let s): return s.range.rangeG
        }
    }

    /// Returns a new sensor with the ODR snapped to the nearest supported value.
    /// Equivalent to C++ `mbl_mw_acc_set_odr` — no BLE write occurs.
    /// The config is applied to the board when `device.startStream()` or `device.startLogging()` is called.
    @discardableResult
    public func withODR(_ odrHz: Double) -> MWAccelerometer {
        switch self {
        case .bmi160(let s):
            let odr = MWAccelerometerBMI160.ODR.allCases.min { abs($0.hz - odrHz) < abs($1.hz - odrHz) }!
            return .bmi160(MWAccelerometerBMI160(odr: odr, range: s.range))
        case .bmi270(let s):
            let odr = MWAccelerometerBMI270.ODR.allCases.min { abs($0.hz - odrHz) < abs($1.hz - odrHz) }!
            return .bmi270(MWAccelerometerBMI270(odr: odr, range: s.range))
        }
    }

    /// Returns a new sensor with the range snapped to the nearest supported value.
    /// Equivalent to C++ `mbl_mw_acc_set_range` — no BLE write occurs.
    /// The config is applied to the board when `device.startStream()` or `device.startLogging()` is called.
    @discardableResult
    public func withRange(_ rangeG: Float) -> MWAccelerometer {
        switch self {
        case .bmi160(let s):
            let range = MWAccelerometerBMI160.Range.allCases.min { abs($0.rangeG - rangeG) < abs($1.rangeG - rangeG) } ?? .g2
            return .bmi160(MWAccelerometerBMI160(odr: s.odr, range: range))
        case .bmi270(let s):
            let range = MWAccelerometerBMI270.Range.allCases.min { abs($0.rangeG - rangeG) < abs($1.rangeG - rangeG) } ?? .g2
            return .bmi270(MWAccelerometerBMI270(odr: s.odr, range: range))
        }
    }
}

// MARK: - MWLoggable conformance
//
// Both BMI160 and BMI270 share Sample = CartesianFloat, so the enum can conform
// to MWLoggable by forwarding to whichever chip is present.
// This mirrors the C++ generic API (mbl_mw_acc_start, mbl_mw_acc_enable_acceleration_sampling, etc.)
// which dispatches to the correct chip implementation internally.

extension MWAccelerometer: MWLoggable {
    public typealias Sample = CartesianFloat

    public var module: MWModule { .accelerometer }

    public var dataRegister: UInt8 { 0x04 }   // same on both chips

    public var packedDataRegister: UInt8? {
        switch self {
        case .bmi160(let s): return s.packedDataRegister
        case .bmi270(let s): return s.packedDataRegister
        }
    }

    public var configureCommands: [Data] {
        switch self {
        case .bmi160(let s): return s.configureCommands
        case .bmi270(let s): return s.configureCommands
        }
    }

    public var enableCommand: Data {
        switch self {
        case .bmi160(let s): return s.enableCommand
        case .bmi270(let s): return s.enableCommand
        }
    }

    public var startCommand: Data {
        switch self {
        case .bmi160(let s): return s.startCommand
        case .bmi270(let s): return s.startCommand
        }
    }

    public var stopCommand: Data {
        switch self {
        case .bmi160(let s): return s.stopCommand
        case .bmi270(let s): return s.stopCommand
        }
    }

    public var disableCommand: Data {
        switch self {
        case .bmi160(let s): return s.disableCommand
        case .bmi270(let s): return s.disableCommand
        }
    }

    public var loggerKey: String { "acceleration" }

    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        switch self {
        case .bmi160(let s): return s.logDataChunks
        case .bmi270(let s): return s.logDataChunks
        }
    }

    public func parseSample(from packet: Data) throws -> CartesianFloat {
        switch self {
        case .bmi160(let s): return try s.parseSample(from: packet)
        case .bmi270(let s): return try s.parseSample(from: packet)
        }
    }

    public func parsePackedSamples(from packet: Data) throws -> [CartesianFloat] {
        switch self {
        case .bmi160(let s): return try s.parsePackedSamples(from: packet)
        case .bmi270(let s): return try s.parsePackedSamples(from: packet)
        }
    }

    public func parseLogSample(from data: Data) throws -> CartesianFloat {
        switch self {
        case .bmi160(let s): return try s.parseLogSample(from: data)
        case .bmi270(let s): return try s.parseLogSample(from: data)
        }
    }
}
