import Foundation

// MARK: - Accelerometer (BMI160)

public struct MWAccelerometerBMI160: MWLoggable {
    public typealias Sample = CartesianFloat

    public enum ODR: UInt8, Sendable, CaseIterable {
        case hz0_78  = 0,  hz1_56,  hz3_12,  hz6_25
        case hz12_5,       hz25,    hz50,    hz100
        case hz200,        hz400,   hz800,   hz1600

        /// The byte value written to the config register (enum value + 1)
        var configByte: UInt8 { rawValue + 1 }

        public var hz: Double {
            [0.78125, 1.5625, 3.125, 6.25, 12.5, 25, 50, 100, 200, 400, 800, 1600][Int(rawValue)]
        }

        /// Under-sampling flag: required for ODR < 12.5 Hz
        var underSampling: Bool { rawValue < 4 }
    }

    public enum Range: UInt8, Sendable, CaseIterable {
        case g2 = 0, g4, g8, g16

        var configByte: UInt8 { [0x03, 0x05, 0x08, 0x0C][Int(rawValue)] }
        var scale: Float      { [16384, 8192, 4096, 2048][Int(rawValue)] }
        public var rangeG: Float { [2, 4, 8, 16][Int(rawValue)] }
    }

    public let odr: ODR
    public let range: Range

    public init(odr: ODR = .hz100, range: Range = .g2) {
        self.odr = odr
        self.range = range
    }

    // MARK: MWSensor

    public let module: MWModule = .accelerometer
    public let dataRegister: UInt8 = 0x04           // DATA_INTERRUPT
    public let packedDataRegister: UInt8? = 0x1C    // PACKED_ACC_DATA

    // MARK: MWStreamable

    public var configureCommands: [Data] {
        // BMI160 acc_conf register:
        //   bits [3:0] = acc_odr  (1-indexed ODR code)
        //   bits [6:4] = acc_bwp  (2 = normal for ODR >= 12.5 Hz; 0 when acc_us is set)
        //   bit  7     = acc_us   (under-sampling: 1 for ODR < 12.5 Hz, 0 otherwise)
        let bwp: UInt8 = odr.underSampling ? 0 : 2
        let us:  UInt8 = odr.underSampling ? 0x80 : 0x00
        let confByte: UInt8 = us | (bwp << 4) | odr.configByte
        return [MWPacket.command(.accelerometer, 0x03, [confByte, range.configByte])]
    }

    public var enableCommand:  Data { MWPacket.command(.accelerometer, 0x02, [0x01, 0x00]) }
    public var startCommand:   Data { MWPacket.command(.accelerometer, 0x01, [0x01]) }
    public var stopCommand:    Data { MWPacket.command(.accelerometer, 0x01, [0x00]) }
    public var disableCommand: Data { MWPacket.command(.accelerometer, 0x02, [0x00, 0x01]) }

    public let loggerKey = "acceleration"

    public func parseSample(from packet: Data) throws -> CartesianFloat {
        try MWPacketParser.parseCartesianFloat(packet, scale: range.scale)
    }

    public func parsePackedSamples(from packet: Data) throws -> [CartesianFloat] {
        try MWPacketParser.parsePackedCartesianFloat(packet, scale: range.scale)
    }
}

// MARK: - Accelerometer (BMI270)

public struct MWAccelerometerBMI270: MWLoggable {
    public typealias Sample = CartesianFloat

    public enum ODR: UInt8, Sendable, CaseIterable {
        case hz0_78  = 0,  hz1_56,  hz3_12,  hz6_25
        case hz12_5,       hz25,    hz50,    hz100
        case hz200,        hz400,   hz800,   hz1600

        var configByte: UInt8 { rawValue + 1 }
        var underSampling: Bool { rawValue < 4 }

        public var hz: Double {
            [0.78125, 1.5625, 3.125, 6.25, 12.5, 25, 50, 100, 200, 400, 800, 1600][Int(rawValue)]
        }
    }

    public enum Range: UInt8, Sendable, CaseIterable {
        case g2 = 0, g4, g8, g16

        var configByte: UInt8 { rawValue }          // BMI270 range byte is 0-based
        var scale: Float      { [16384, 8192, 4096, 2048][Int(rawValue)] }
        public var rangeG: Float { [2, 4, 8, 16][Int(rawValue)] }
    }

    public let odr: ODR
    public let range: Range

    public init(odr: ODR = .hz100, range: Range = .g2) {
        self.odr = odr
        self.range = range
    }

    // MARK: MWSensor

    public let module: MWModule = .accelerometer
    public let dataRegister: UInt8 = 0x04           // DATA_INTERRUPT
    public let packedDataRegister: UInt8? = 0x05    // PACKED_ACC_DATA (BMI270)

    // MARK: MWStreamable

    public var configureCommands: [Data] {
        // BMI270 acc_conf register:
        //   bits [3:0] = acc_odr  (1-indexed ODR code)
        //   bits [6:4] = acc_bwp  (always 2 = normal averaging)
        //   bit  7     = acc_filter_perf (1 = high-performance, required for ODR >= 12.5 Hz)
        let perf: UInt8    = odr.underSampling ? 0x00 : 0x80
        let confByte: UInt8 = perf | (2 << 4) | odr.configByte
        return [MWPacket.command(.accelerometer, 0x03, [confByte, range.configByte])]
    }

    public var enableCommand:  Data { MWPacket.command(.accelerometer, 0x02, [0x01, 0x00]) }
    public var startCommand:   Data { MWPacket.command(.accelerometer, 0x01, [0x01]) }
    public var stopCommand:    Data { MWPacket.command(.accelerometer, 0x01, [0x00]) }
    public var disableCommand: Data { MWPacket.command(.accelerometer, 0x02, [0x00, 0x01]) }

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
        case bmi160
        case bmi270
    }

    // MARK: - Orientation detection

    /// The eight board orientations reported by interrupt register 0x11.
    /// Parse index = `(responseByte >> 1) & 0x07`.
    public enum SensorOrientation: Int, Sendable, CaseIterable {
        case faceUpPortraitUpright       = 0
        case faceUpPortraitUpsideDown    = 1
        case faceUpLandscapeLeft         = 2
        case faceUpLandscapeRight        = 3
        case faceDownPortraitUpright     = 4
        case faceDownPortraitUpsideDown  = 5
        case faceDownLandscapeLeft       = 6
        case faceDownLandscapeRight      = 7
    }

    /// Enable orientation-change interrupts on the MetaWear.
    public struct EnableOrientation: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.accelerometer, 0x0f, [0x01, 0x00]) }
    }

    /// Disable orientation-change interrupts.
    public struct DisableOrientation: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.accelerometer, 0x0f, [0x00, 0x01]) }
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
        public let xAxisActive: Bool
        public let yAxisActive: Bool
        public let zAxisActive: Bool

        public init(isPositive: Bool, xAxisActive: Bool, yAxisActive: Bool, zAxisActive: Bool) {
            self.isPositive  = isPositive
            self.xAxisActive = xAxisActive
            self.yAxisActive = yAxisActive
            self.zAxisActive = zAxisActive
        }
    }

    /// Write the any-motion configuration to register 0x0a.
    public struct ConfigureAnyMotion: MWCommand, Sendable {
        public let chip: ChipVariant
        /// Consecutive over-threshold samples required before the interrupt fires (1–4).
        public let count: Int
        /// Detection threshold in g.
        public let thresholdG: Float
        /// Current accelerometer full-scale range in g (2, 4, 8, or 16).
        public let rangeG: Float
        /// No-motion threshold byte (firmware default 0x14 = 20).
        public let noMotionThreshold: UInt8

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
            return MWPacket.command(.accelerometer, 0x0a, payload)
        }
    }

    /// Enable any-motion detection on all three axes (register 0x09).
    public struct EnableAnyMotion: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.accelerometer, 0x09, [0x07, 0x00]) }
    }

    /// Disable any-motion detection (register 0x09).
    public struct DisableAnyMotion: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.accelerometer, 0x09, [0x00, 0x7f]) }
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
        case ms50  = 0
        case ms100 = 1
        case ms150 = 2
        case ms200 = 3
        case ms250 = 4
        case ms375 = 5
        case ms500 = 6
        case ms700 = 7
    }

    /// Whether the fired interrupt was a single or double tap.
    public enum TapType: UInt8, Sendable {
        case double = 1
        case single = 2
    }

    /// Tap event decoded from notification register 0x0e.
    public struct TapEvent: Sendable, Equatable {
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
        public let shockTime:       TapShockTime
        public let quietTime:       TapQuietTime
        /// Double-tap window. Also encoded for single-tap (firmware always writes both bytes).
        public let doubleTapWindow: DoubleTapWindow
        /// Detection threshold in g.
        public let thresholdG: Float
        /// Current accelerometer full-scale range in g.
        public let rangeG: Float

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
            return MWPacket.command(.accelerometer, 0x0d, [timingByte, tapTh])
        }
    }

    /// Enable single-tap and/or double-tap detection (register 0x0c).
    public struct EnableTap: MWCommand, Sendable {
        public let single: Bool
        public let double: Bool

        public init(single: Bool = true, double: Bool = false) {
            self.single = single
            self.double = double
        }

        public var commandData: Data {
            // bit 1 = single-tap, bit 0 = double-tap
            let enableByte: UInt8 = (single ? 0x02 : 0) | (double ? 0x01 : 0)
            return MWPacket.command(.accelerometer, 0x0c, [enableByte, 0x00])
        }
    }

    /// Disable both single- and double-tap detection (register 0x0c).
    public struct DisableTap: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.accelerometer, 0x0c, [0x00, 0x03]) }
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
        public let mode: StepCounterMode

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
            return MWPacket.command(.accelerometer, 0x18, [b0, b1])
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
        public var commandData: Data { MWPacket.command(.accelerometer, 0x17, [0x01, 0x00]) }
    }

    /// Disable the step detector interrupt on register 0x17. Sends [0x03, 0x17, 0x00, 0x01].
    public struct DisableStepDetector: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.accelerometer, 0x17, [0x00, 0x01]) }
    }

    /// Subscribe to step detection events: send [0x03, 0x19, 0x01] to the board.
    /// This register byte is used by `device.stream()` when subscribing.
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

public enum MWAccelerometerBMI270Steps {

    // MARK: - Step Counter

    /// Configures and enables the BMI270 step counter.
    /// Equivalent to: set_step_counter_trigger + enable_step_counter + write_step_counter_config.
    public struct ConfigureStepCounter: MWCommandSequence {
        /// Watermark level: number of steps between notifications (1–1023). Default = 1 (every ~20 steps).
        public let trigger: UInt16

        public init(trigger: UInt16 = 1) {
            self.trigger = min(max(trigger, 1), 1023)
        }

        /// Enables step counter interrupts and features.
        /// Sends FEATURE_INTERRUPT_ENABLE (0x07) with step_counter bit set.
        public var interruptEnableCommand: Data {
            MWPacket.command(.accelerometer, 0x07, [0x02, 0x00])
        }

        /// Enables the step counter feature.
        /// Sends FEATURE_ENABLE (0x06) with step_counter bit set.
        public var featureEnableCommand: Data {
            MWPacket.command(.accelerometer, 0x06, [0x02, 0x00])
        }

        /// Writes the watermark trigger level to FEATURE_CONFIG (0x08). Sends [0x03, 0x08, 0x07, ...].
        /// The C++ Python test asserts this as the last command in the sequence.
        public var configCommand: Data {
            // step_counter_3.bitmap: [param_250, param_251, watermark_low, (watermark_high:2|reset:1|pad:5)]
            let wm0 = UInt8(trigger & 0x00FF)
            let wm1 = UInt8((trigger & 0x0300) >> 8)   // upper 2 bits of watermark
            return MWPacket.command(.accelerometer, 0x08, [0x07, 0x00, 0x0E, wm0, wm1])
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
            MWPacket.command(.accelerometer, 0x07, [0x80, 0x00])
        }

        /// [0x03, 0x06, 0x80, 0x00]  — the command asserted by the C++ Python test.
        public var featureEnableCommand: Data {
            MWPacket.command(.accelerometer, 0x06, [0x80, 0x00])
        }

        /// Both commands in order.
        public var commands: [Data] { [interruptEnableCommand, featureEnableCommand] }
    }

    /// Disables the BMI270 step detector.
    public struct DisableStepDetector: MWCommandSequence {
        public init() {}

        /// [0x03, 0x07, 0x00, 0x80]
        public var interruptDisableCommand: Data {
            MWPacket.command(.accelerometer, 0x07, [0x00, 0x80])
        }

        /// [0x03, 0x06, 0x00, 0x80]  — the command asserted by the C++ Python test.
        public var featureDisableCommand: Data {
            MWPacket.command(.accelerometer, 0x06, [0x00, 0x80])
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

public enum MWAccelerometerBMI270Features {

    // MARK: - Activity Classification

    /// Activity class reported by the BMI270 activity-output feature.
    /// Value is decoded from the notification payload byte as `byte >> 1`.
    public enum Activity: UInt8, Sendable, Equatable {
        case still   = 0
        case walking = 1
        case running = 2
        case unknown = 3
    }

    /// Enables activity-output detection (bit 0x04).
    public struct EnableActivityDetection: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x04, 0x00]
        public var interruptEnableCommand: Data {
            MWPacket.command(.accelerometer, 0x07, [0x04, 0x00])
        }
        /// [0x03, 0x06, 0x04, 0x00]
        public var featureEnableCommand: Data {
            MWPacket.command(.accelerometer, 0x06, [0x04, 0x00])
        }
        public var commands: [Data] { [interruptEnableCommand, featureEnableCommand] }
    }

    /// Disables activity-output detection (bit 0x04).
    public struct DisableActivityDetection: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x00, 0x04]
        public var interruptDisableCommand: Data {
            MWPacket.command(.accelerometer, 0x07, [0x00, 0x04])
        }
        /// [0x03, 0x06, 0x00, 0x04]
        public var featureDisableCommand: Data {
            MWPacket.command(.accelerometer, 0x06, [0x00, 0x04])
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
        case left  = 0
        case right = 1
    }

    /// BMI270 wrist-gesture classifications (see Bosch BMI270 datasheet).
    public enum WristGestureCode: UInt8, Sendable, Equatable {
        case unknown     = 0
        case pushArmDown = 1
        case pivotUp     = 2
        case shake       = 3   // aka "jiggle"
        case armFlickIn  = 4
        case armFlickOut = 5
    }

    /// Distinguishes a wrist-wakeup notification from a wrist-gesture notification
    /// on the shared 0x0A register. Encoded in the low 2 bits of the payload byte.
    public enum WristEventKind: UInt8, Sendable, Equatable {
        case wakeup  = 0
        case gesture = 1
    }

    /// A single wrist-event notification. For `.wakeup`, `gestureCode` is `.unknown`.
    public struct WristEvent: Sendable, Equatable {
        public let kind: WristEventKind
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
        public let arm: WristArm
        public let peak: UInt16
        public let samples: UInt16
        public let duration: UInt16

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
            return MWPacket.command(.accelerometer, 0x08, payload)
        }
    }

    /// Enables wrist gesture (bit 0x10).
    public struct EnableWristGesture: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x10, 0x00]
        public var interruptEnableCommand: Data {
            MWPacket.command(.accelerometer, 0x07, [0x10, 0x00])
        }
        /// [0x03, 0x06, 0x10, 0x00]
        public var featureEnableCommand: Data {
            MWPacket.command(.accelerometer, 0x06, [0x10, 0x00])
        }
        public var commands: [Data] { [interruptEnableCommand, featureEnableCommand] }
    }

    /// Disables wrist gesture (bit 0x10).
    public struct DisableWristGesture: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x00, 0x10]
        public var interruptDisableCommand: Data {
            MWPacket.command(.accelerometer, 0x07, [0x00, 0x10])
        }
        /// [0x03, 0x06, 0x00, 0x10]
        public var featureDisableCommand: Data {
            MWPacket.command(.accelerometer, 0x06, [0x00, 0x10])
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
        public let minAngleFocus: UInt16
        public let minAngleNonFocus: UInt16
        public let maxTiltLR: UInt16
        public let maxTiltLL: UInt16
        public let maxTiltPD: UInt16
        public let maxTiltPU: UInt16

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
            return MWPacket.command(.accelerometer, 0x08, payload)
        }
    }

    /// Enables wrist wakeup (bit 0x08).
    public struct EnableWristWakeup: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x08, 0x00]
        public var interruptEnableCommand: Data {
            MWPacket.command(.accelerometer, 0x07, [0x08, 0x00])
        }
        /// [0x03, 0x06, 0x08, 0x00]
        public var featureEnableCommand: Data {
            MWPacket.command(.accelerometer, 0x06, [0x08, 0x00])
        }
        public var commands: [Data] { [interruptEnableCommand, featureEnableCommand] }
    }

    /// Disables wrist wakeup (bit 0x08).
    public struct DisableWristWakeup: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x00, 0x08]
        public var interruptDisableCommand: Data {
            MWPacket.command(.accelerometer, 0x07, [0x00, 0x08])
        }
        /// [0x03, 0x06, 0x00, 0x08]
        public var featureDisableCommand: Data {
            MWPacket.command(.accelerometer, 0x06, [0x00, 0x08])
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
        public let selectX: Bool
        public let selectY: Bool
        public let selectZ: Bool

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
            return MWPacket.command(.accelerometer, 0x08, [0x02, d0, d1, t0, t1])
        }
    }

    /// Enables no-motion detection (bit 0x20).
    public struct EnableNoMotion: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x20, 0x00]
        public var interruptEnableCommand: Data {
            MWPacket.command(.accelerometer, 0x07, [0x20, 0x00])
        }
        /// [0x03, 0x06, 0x20, 0x00]
        public var featureEnableCommand: Data {
            MWPacket.command(.accelerometer, 0x06, [0x20, 0x00])
        }
        public var commands: [Data] { [interruptEnableCommand, featureEnableCommand] }
    }

    /// Disables no-motion detection (bit 0x20).
    public struct DisableNoMotion: MWCommandSequence {
        public init() {}
        /// [0x03, 0x07, 0x00, 0x20]
        public var interruptDisableCommand: Data {
            MWPacket.command(.accelerometer, 0x07, [0x00, 0x20])
        }
        /// [0x03, 0x06, 0x00, 0x20]
        public var featureDisableCommand: Data {
            MWPacket.command(.accelerometer, 0x06, [0x00, 0x20])
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
        public let gyroOrdinal: UInt8
        public let gyroFilterData: Bool
        public let accOrdinal: UInt8
        public let accFilterData: Bool

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
            return MWPacket.command(.accelerometer, 0x11, [b])
        }
    }
}

// MARK: - Type-erased accelerometer (chosen at runtime from module info)

public enum MWAccelerometer: Sendable {
    case bmi160(MWAccelerometerBMI160)
    case bmi270(MWAccelerometerBMI270)

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
    /// The config is applied to the board when `device.stream()` or `device.startLogging()` is called.
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
    /// The config is applied to the board when `device.stream()` or `device.startLogging()` is called.
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
