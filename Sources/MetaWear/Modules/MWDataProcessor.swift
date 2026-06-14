import Foundation

// MARK: - Source signal protocol

/// Any data source that can feed a data processor: a sensor signal or a processor's output.
///
/// The `sourceConfigByte` encodes the total sample length and byte offset into the single
/// byte that the board expects at position 5 of every ADD command:
/// ```
/// source_config = ((n_channels * channel_size - 1) << 5) | offset
/// ```
/// (Verified against MetaWear-SDK-Cpp datasignal.cpp `get_data_ubyte()`)
public protocol MWSignal: Sendable {
    /// MetaWear module ID.
    var moduleID: UInt8 { get }
    /// Register ID on that module (not OR'd with 0x80).
    var registerID: UInt8 { get }
    /// Data ID byte (0xFF means "any / no ID").
    var dataID: UInt8 { get }
    /// Number of data channels (axes) per sample.
    var nChannels: UInt8 { get }
    /// Bytes per channel.
    var channelSize: UInt8 { get }
    /// Byte offset within the sample (usually 0).
    var offset: UInt8 { get }
    /// Whether the signal values are signed.
    var isSigned: Bool { get }
}

public extension MWSignal {
    /// Total bytes per sample = nChannels × channelSize.
    var dataLength: UInt8 { nChannels * channelSize }
    /// source_config byte for ADD commands.
    var sourceConfigByte: UInt8 { ((dataLength &- 1) << 5) | offset }
}

// MARK: - Known input signals

/// Switch button state (1 byte, unsigned).
///
/// Feed into a `Counter` to count presses, or into a `Comparator` to react to
/// specific press/release transitions.
public struct MWSwitchSignal: MWSignal, Sendable {
    public var moduleID: UInt8   { MWModule.switch_.rawValue }
    public var registerID: UInt8 { 0x01 }
    public var dataID: UInt8     { 0xFF }
    public var nChannels: UInt8  { 1 }
    public var channelSize: UInt8 { 1 }
    public var offset: UInt8     { 0 }
    public var isSigned: Bool    { false }
    public init() {}
}

/// Raw 3-axis accelerometer data (3 × Int16 = 6 bytes, signed).
///
/// Use as the source of an `RMS`/`RSS` processor to reduce to magnitude, then
/// `Threshold` or `Pulse` for activity detection.
public struct MWAccelerometerSignal: MWSignal, Sendable {
    public var moduleID: UInt8    { MWModule.accelerometer.rawValue }
    public var registerID: UInt8  { 0x04 }
    public var dataID: UInt8      { 0xFF }
    public var nChannels: UInt8   { 3 }
    public var channelSize: UInt8 { 2 }
    public var offset: UInt8      { 0 }
    public var isSigned: Bool     { true }
    public init() {}
}

/// Raw 3-axis gyroscope data (3 × Int16 = 6 bytes, signed).
///
/// Pair with a `Buffer` + `Fuser` to bundle gyro samples alongside accelerometer
/// data in a single packet.
public struct MWGyroscopeSignal: MWSignal, Sendable {
    public var moduleID: UInt8    { MWModule.gyro.rawValue }
    public var registerID: UInt8  { 0x05 }
    public var dataID: UInt8      { 0xFF }
    public var nChannels: UInt8   { 3 }
    public var channelSize: UInt8 { 2 }
    public var offset: UInt8      { 0 }
    public var isSigned: Bool     { true }
    public init() {}
}

/// GPIO analog ADC reading (1 × UInt16 = 2 bytes, unsigned).
///
/// Wraps the analog input on a specific pin so it can be wired into a processor
/// (e.g. `Pulse` for spike detection on an external sensor).
public struct MWGPIOAnalogSignal: MWSignal, Sendable {
    public var moduleID: UInt8    { MWModule.gpio.rawValue }
    public var registerID: UInt8  // 0x07 ADC, 0x06 absolute
    public var dataID: UInt8      // pin number
    public var nChannels: UInt8   { 1 }
    public var channelSize: UInt8 { 2 }
    public var offset: UInt8      { 0 }
    public var isSigned: Bool     { false }

    /// Which analog read register to source from.
    public enum Mode {
        /// Raw ADC counts (register 0x07).
        case adc
        /// Absolute voltage reference reading (register 0x06).
        case absolute
    }
    public init(pin: UInt8, mode: Mode = .adc) {
        self.dataID      = pin
        self.registerID  = mode == .adc ? 0x07 : 0x06
    }
}

/// Single temperature channel (1 × Int16 = 2 bytes, signed).
///
/// Pick a specific thermistor / on-die source via the `channel` index. Often
/// paired with a `Comparator` to fire an event when temperature crosses a setpoint.
public struct MWTemperatureSignal: MWSignal, Sendable {
    public var moduleID: UInt8    { MWModule.temperature.rawValue }
    public var registerID: UInt8  { UInt8(0x01 | 0x80 | 0x40) }  // 0xC1 (read + data_id)
    public var dataID: UInt8      // channel index
    public var nChannels: UInt8   { 1 }
    public var channelSize: UInt8 { 2 }
    public var offset: UInt8      { 0 }
    public var isSigned: Bool     { true }
    public init(channel: UInt8 = 0) { self.dataID = channel }
}

// MARK: - Sensor fusion signals
//
// Each fusion output (quaternion, euler, gravity, linear-accel, corrected-acc/
// gyro/mag) is exposed as both an `MWLoggable` (`MWSensorFusionEuler`,
// `MWSensorFusionQuaternion`, etc., in `MWSensorFusion.swift`) and as an
// `MWSignal` here. The signal form is what `createProcessor(_:source:)` and
// `createTimer(...)` consume — it carries just enough metadata for the board
// to wire the signal as a processor input. Sensor lifecycle (configure /
// enable / start / stop / disable) remains the caller's responsibility via
// the `MWLoggable` form.
//
// Wire layout per `MblMwSensorFusion` register table:
//   0x04 CORRECTED_ACC / GYRO / MAG  → 13 bytes (3 × float32 + 1 byte accuracy)
//   0x07 QUATERNION                  → 16 bytes (4 × float32, Q16.16 raw)
//   0x08 EULER_ANGLES                → 16 bytes (4 × float32, Q16.16 raw)
//   0x09 GRAVITY                     → 12 bytes (3 × float32, Q16.16 raw)
//   0x0A LINEAR_ACC                  → 12 bytes (3 × float32, Q16.16 raw)
//
// All channelSize values are 4 (single float32 per axis).

/// Quaternion output of sensor fusion (4 × float32 = 16 bytes, signed).
///
/// Use this `MWSignal` form to feed orientation into a processor pipeline.
/// Sensor lifecycle (configure / start / stop) is still driven by the
/// matching `MWSensorFusionQuaternion` loggable.
public struct MWSensorFusionQuaternionSignal: MWSignal, Sendable {
    public var moduleID: UInt8    { MWModule.sensorFusion.rawValue }
    public var registerID: UInt8  { 0x07 }
    public var dataID: UInt8      { 0xFF }
    public var nChannels: UInt8   { 4 }
    public var channelSize: UInt8 { 4 }
    public var offset: UInt8      { 0 }
    public var isSigned: Bool     { true }
    public init() {}
}

/// Euler-angles output of sensor fusion (4 × float32 = 16 bytes, signed).
///
/// `MWSignal` form of `MWSensorFusionEuler` for use as a processor source.
public struct MWSensorFusionEulerSignal: MWSignal, Sendable {
    public var moduleID: UInt8    { MWModule.sensorFusion.rawValue }
    public var registerID: UInt8  { 0x08 }
    public var dataID: UInt8      { 0xFF }
    public var nChannels: UInt8   { 4 }
    public var channelSize: UInt8 { 4 }
    public var offset: UInt8      { 0 }
    public var isSigned: Bool     { true }
    public init() {}
}

/// Gravity-vector output of sensor fusion (3 × float32 = 12 bytes, signed).
///
/// `MWSignal` form of `MWSensorFusionGravity` for use as a processor source —
/// e.g. an `RSS` magnitude to detect a free-fall transition.
public struct MWSensorFusionGravitySignal: MWSignal, Sendable {
    public var moduleID: UInt8    { MWModule.sensorFusion.rawValue }
    public var registerID: UInt8  { 0x09 }
    public var dataID: UInt8      { 0xFF }
    public var nChannels: UInt8   { 3 }
    public var channelSize: UInt8 { 4 }
    public var offset: UInt8      { 0 }
    public var isSigned: Bool     { true }
    public init() {}
}

/// Linear-acceleration output of sensor fusion (3 × float32 = 12 bytes, signed).
///
/// `MWSignal` form of `MWSensorFusionLinearAcceleration` for use as a processor
/// source — gravity-compensated acceleration suitable for motion-impulse detection.
public struct MWSensorFusionLinearAccelerationSignal: MWSignal, Sendable {
    public var moduleID: UInt8    { MWModule.sensorFusion.rawValue }
    public var registerID: UInt8  { 0x0A }
    public var dataID: UInt8      { 0xFF }
    public var nChannels: UInt8   { 3 }
    public var channelSize: UInt8 { 4 }
    public var offset: UInt8      { 0 }
    public var isSigned: Bool     { true }
    public init() {}
}

// MARK: - Processor handle (result of createProcessor; also a signal for chaining)

/// Identifies a data processor created on the board.
///
/// `MWProcessorHandle` conforms to `MWSignal` so it can be passed directly as
/// the `source` argument of `createProcessor(_:source:)` to chain processors.
public struct MWProcessorHandle: Sendable, MWSignal {
    /// Board-assigned processor ID (0–based).
    public let id: UInt8
    public let nChannels: UInt8
    public let channelSize: UInt8
    public let isSigned: Bool

    // MWSignal routing to processor NOTIFY register
    public var moduleID: UInt8   { MWModule.dataProcessor.rawValue }
    public var registerID: UInt8 { 0x03 }   // NOTIFY
    public var dataID: UInt8     { id }
    public var offset: UInt8     { 0 }
}

// MARK: - Processor config protocol

/// Configuration for one data processor stage.
public protocol MWDataProcessorConfig: Sendable {
    /// Wire type ID (from MetaWear-SDK-Cpp `type_to_id` map).
    var typeID: UInt8 { get }
    /// Produce the config bytes that follow the type ID byte in the ADD command.
    func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8]
    /// Total output length in bytes.
    func outputLength(inputLength: UInt8, inputChannels: UInt8) -> UInt8
    /// Number of output channels.
    func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8
    /// Signedness of the output.
    func outputSigned(inputSigned: Bool) -> Bool
}

// MARK: - Processor implementations

/// Namespace for all data processor configuration types.
///
/// Each nested struct (`Passthrough`, `Accumulator`, `Counter`, `Average`, `RMS`,
/// `RSS`, `Time`, `Math`, `Sample`, `Comparator`, `Threshold`, `Delta`, `Pulse`,
/// `Buffer`, `Packer`, `Accounter`, `Fuser`) configures a single on-board
/// processor stage. Pass one to `MetaWearDevice.createProcessor(_:source:)` to
/// instantiate it, and chain processors by using the returned `MWProcessorHandle`
/// as the source of a subsequent call.
public enum MWDataProcessor {}

// MARK: Passthrough  (type 0x01)

public extension MWDataProcessor {

    /// Gates data flow — pass all, pass conditionally, or pass N times then stop.
    ///
    /// Chain after any source to throttle delivery, or combine with an event
    /// that toggles the gate at runtime to implement an on/off switch in the
    /// processor graph.
    struct Passthrough: MWDataProcessorConfig, Sendable {
        /// How the passthrough gate decides whether to forward a sample.
        public enum Mode: UInt8, Sendable {
            /// Forward every sample.
            case all = 0
            /// Forward only while an external `count` write opens the gate.
            case conditional = 1
            /// Forward the first `count` samples then stop.
            case count = 2
        }
        public let mode: Mode
        /// Pass-count for `.count` mode (ignored otherwise).
        public let count: UInt16

        public init(mode: Mode = .all, count: UInt16 = 0) {
            self.mode  = mode
            self.count = count
        }

        // MARK: MWDataProcessorConfig
        public let typeID: UInt8 = 0x01
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            [mode.rawValue, UInt8(count & 0xFF), UInt8(count >> 8)]
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { inputLength }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { inputChannels }
        public func outputSigned(inputSigned: Bool) -> Bool { inputSigned }
    }
}

// MARK: Accumulator / Counter  (type 0x02)

public extension MWDataProcessor {

    /// Accumulates (sums) values. The `mode` byte in `AccumulatorConfig` is 0 (SUM).
    ///
    /// Each incoming sample is added to the running total. Useful for integrating
    /// magnitude over time (e.g. step count proxy from RSS-of-accel) or any
    /// "total movement" metric. Pair with a `Comparator` to fire when the sum
    /// passes a threshold.
    ///
    /// Config byte: `{output_size-1 : 2, input_size-1 : 2, mode=0 : 3}`
    struct Accumulator: MWDataProcessorConfig, Sendable {
        public let outputSize: UInt8   // 1, 2, or 4

        public init(outputSize: UInt8 = 4) { self.outputSize = min(outputSize, 4) }

        public let typeID: UInt8 = 0x02
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            let unitSize = inputLength / max(inputChannels, 1)
            return [((outputSize - 1) & 0x3) | (((unitSize - 1) & 0x3) << 2)]  // mode=0
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { outputSize }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { 1 }
        public func outputSigned(inputSigned: Bool) -> Bool { inputSigned }
    }

    /// Counts events (mode = 1 = COUNT in AccumulatorConfig).
    ///
    /// Emits a monotonically-increasing tally — one increment per input sample,
    /// regardless of the input's value. Often chained with `Math.modulo` to drive
    /// an alternating output (odd/even LED toggle) or with `Comparator` to fire
    /// every Nth event.
    ///
    /// Config byte: `{output_size-1 : 2, 0 : 2, mode=1 : 3}`
    ///
    /// Reference test: `test_led_controller` — switch counter, outputSize=1 →
    /// config byte `0x10 = 0001_0000` ✓
    struct Counter: MWDataProcessorConfig, Sendable {
        public let outputSize: UInt8   // 1, 2, or 4

        public init(outputSize: UInt8 = 4) { self.outputSize = min(outputSize, 4) }

        public let typeID: UInt8 = 0x02
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            // mode = ACCUMULATOR_COUNT = 1 → bits 4-6 = 001
            [((outputSize - 1) & 0x3) | (1 << 4)]
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { outputSize }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { 1 }
        public func outputSigned(inputSigned: Bool) -> Bool { false }
    }
}

// MARK: Average / Low-pass filter  (type 0x03)

public extension MWDataProcessor {

    /// Computes a rolling average (low-pass filter) over the last `sampleSize` inputs.
    ///
    /// Use to smooth a noisy stream on-device, reducing both jitter and BLE
    /// traffic. Chain after `Math` or `RSS` to clean their output before a
    /// `Threshold` or `Comparator` consumes it.
    ///
    /// `AverageConfig`: byte0 `{output-1:2, input-1:2, _:1, mode=0:1, _:2}`, byte1 `sampleSize`.
    ///
    /// Reference test: `test_freefall` (average of RSS output, sampleSize=4):
    /// config = `[0x05, 0x04]` ✓
    struct Average: MWDataProcessorConfig, Sendable {
        public let sampleSize: UInt8   // averaging window

        public init(sampleSize: UInt8 = 4) { self.sampleSize = sampleSize }

        public let typeID: UInt8 = 0x03
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            let unitSize = inputLength / max(inputChannels, 1)
            let s = (unitSize - 1) & 0x3
            return [s | (s << 2), sampleSize]   // output==input, mode=0 (LPF)
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { inputLength }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { inputChannels }
        public func outputSigned(inputSigned: Bool) -> Bool { inputSigned }
    }
}

// MARK: RMS / RSS  (type 0x07)

public extension MWDataProcessor {

    /// Root-mean-square combiner. Reduces a multi-axis signal to a scalar magnitude.
    ///
    /// Use on a 3-axis sensor (accel/gyro/mag) to collapse it to a single
    /// "energy" value. `RSS` is more common for pure magnitude; `RMS` divides
    /// by N first, which suits power-style metrics.
    ///
    /// `CombinerConfig`: `{output-1:2, input-1:2, channels-1:3, is_signed:1, mode=0}`.
    ///
    /// Reference test: `test_freefall` (accelerometer RSS):
    /// `[0xa5, 0x01]` — output=2, input=2, ch=3, signed=1, mode=RSS ✓
    struct RMS: MWDataProcessorConfig, Sendable {
        public init() {}
        public let typeID: UInt8 = 0x07
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            // RMS/RSS combiner wire layout (2 bytes — same for both modes):
            //   byte 0:  bits [1:0] = output_unit - 1     (size of each output scalar)
            //            bits [3:2] = input_unit  - 1     (size of each input scalar)
            //            bits [6:4] = n_channels - 1      (1..8 channels → 0..7)
            //            bit  [7]   = input_signed flag
            //   byte 1:  mode                              (0 = RMS, 1 = RSS)
            // RMS and RSS share the same combiner type (0x07); only byte 1 differs.
            let unit = inputLength / max(inputChannels, 1)
            let s    = (unit - 1) & 0x3
            let byte0: UInt8 = s | (s << 2) | (((inputChannels - 1) & 0x7) << 4) | (inputSigned ? 0x80 : 0)
            return [byte0, 0x00]   // mode=0 (RMS)
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { inputLength / max(inputChannels, 1) }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { 1 }
        public func outputSigned(inputSigned: Bool) -> Bool { false }
    }

    /// Root-sum-square combiner. Reduces a multi-axis signal to its vector magnitude.
    ///
    /// Computes `sqrt(x² + y² + z²)` on-device — the standard "how much is it
    /// accelerating" or "how strong is the field" value. Chain into `Threshold`
    /// or `Pulse` to detect motion / free-fall / step events without burning BLE.
    struct RSS: MWDataProcessorConfig, Sendable {
        public init() {}
        public let typeID: UInt8 = 0x07
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            // See `RMS.configBytes` for byte 0 layout — RSS uses the same combiner
            // type (0x07) and same per-byte layout; only byte 1 (mode) is 0x01.
            let unit = inputLength / max(inputChannels, 1)
            let s    = (unit - 1) & 0x3
            let byte0: UInt8 = s | (s << 2) | (((inputChannels - 1) & 0x7) << 4) | (inputSigned ? 0x80 : 0)
            return [byte0, 0x01]   // mode=1 (RSS)
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { inputLength / max(inputChannels, 1) }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { 1 }
        public func outputSigned(inputSigned: Bool) -> Bool { false }
    }
}

// MARK: Time delay  (type 0x08)

public extension MWDataProcessor {

    /// Down-samples a stream by emitting at most one sample per `periodMs` milliseconds.
    ///
    /// Drop a high-rate sensor's effective rate (e.g. 100 Hz accel → 10 Hz)
    /// without changing the underlying ODR. `.differential` mode emits the
    /// difference between the current and previous sample instead of the value
    /// itself — useful for computing rate-of-change cheaply on-device.
    ///
    /// `TimeDelayConfig`: `{data_length-1:3, mode:3, _:2, period[4]}`.
    struct Time: MWDataProcessorConfig, Sendable {
        /// How the time-delay stage selects its output value.
        public enum Mode: UInt8, Sendable {
            /// Emit the latest input sample verbatim at each tick.
            case absolute = 0
            /// Emit `current - previous` at each tick (on-device differentiation).
            case differential = 1
        }
        public let periodMs: UInt32
        public let mode: Mode

        public init(periodMs: UInt32, mode: Mode = .absolute) {
            self.periodMs = periodMs
            self.mode     = mode
        }

        public let typeID: UInt8 = 0x08
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            // TimeConfig byte 0 wire layout:
            //   bits [2:0] = input_length - 1   (signal sample size, 1..4 bytes → 0..3)
            //   bits [5:3] = mode               (0 absolute, 1 differential)
            //   bits [7:6] = reserved (must be 0)
            // Followed by `period_ms` as a 32-bit little-endian unsigned int.
            let byte0: UInt8 = ((inputLength - 1) & 0x7) | ((mode.rawValue & 0x7) << 3)
            return [byte0] + littleEndian32(periodMs)
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { inputLength }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { inputChannels }
        public func outputSigned(inputSigned: Bool) -> Bool { inputSigned }
    }
}

// MARK: Math  (type 0x09)

public extension MWDataProcessor {

    /// Arithmetic transform applied per sample — `output = op(input, rhs)`.
    ///
    /// Use to scale, offset, mod, or otherwise reshape a stream before it
    /// reaches a downstream stage. Combined with `Counter` and `.modulo` it
    /// implements a divide-by-N event splitter (see `test_led_controller`).
    ///
    /// `MathConfig`: `{output-1:2, input-1:2, signed:1, _:3, operation, rhs[4], n_channels}`.
    ///
    /// Reference test: `test_led_controller` (counter % 2):
    /// `[0x03, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00]` — output=4, input=1, unsigned, MODULO, rhs=2, ch=0 ✓
    struct Math: MWDataProcessorConfig, Sendable {
        /// Per-sample arithmetic operator. Most take `rhs`; some are unary.
        ///
        /// Raw values are the **firmware op codes**, written to the wire verbatim
        /// (verified against `MblMwMathOperation` in MetaWear-SDK-Cpp, where the
        /// enum starts at 1 and `MathConfig.operation = op` with no translation).
        /// Note the non-obvious ordering: `subtract` is 9, not 1 — an earlier
        /// draft of this enum used a 0-indexed table from a buggy protocol
        /// document, which made `.add` a no-op and `.subtract` perform addition.
        /// There are no negate/floor/ceil/round operations in firmware.
        public enum Operation: UInt8, Sendable, CaseIterable {
            /// `output = input + rhs`.
            case add = 1
            /// `output = input * rhs`.
            case multiply = 2
            /// `output = input / rhs`.
            case divide = 3
            /// `output = input % rhs`.
            case modulo = 4
            /// `output = input ^ rhs`.
            case exponent = 5
            /// `output = sqrt(input)` (rhs ignored).
            case sqrt = 6
            /// Left bit-shift: `output = input << rhs`.
            case lshift = 7
            /// Right bit-shift: `output = input >> rhs`.
            case rshift = 8
            /// `output = input - rhs`.
            case subtract = 9
            /// `output = |input|` (rhs ignored).
            case abs = 10
            /// `output = rhs` (input ignored — emits a constant on every fire).
            case constant = 11
        }

        public let operation: Operation
        /// Right-hand-side operand (treated as signed Int32 on the wire).
        public let rhs: Int32
        public let signed: Bool
        /// Override output size (bytes). `nil` = same as input unit size.
        public let outputSize: UInt8?

        public init(operation: Operation, rhs: Int32 = 0, signed: Bool = true, outputSize: UInt8? = nil) {
            self.operation  = operation
            self.rhs        = rhs
            self.signed     = signed
            self.outputSize = outputSize
        }

        public let typeID: UInt8 = 0x09
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            // MathConfig wire layout (7 bytes):
            //   byte 0:  bits [1:0] = output_unit - 1   (per-channel output byte size, 1..4 → 0..3)
            //            bits [3:2] = input_unit - 1    (per-channel input byte size)
            //            bit  [4]   = signed flag
            //            bits [7:5] = reserved (must be 0)
            //   byte 1:  operation enum (Operation.rawValue)
            //   bytes 2–5: rhs (Int32 little-endian, sign-preserving via bitPattern)
            //   byte 6:  n_channels - 1   (encodes 1..N channels as 0..N-1, but 0 if N == 1)
            let unitIn  = inputLength / max(inputChannels, 1)
            let unitOut = outputSize ?? unitIn
            let byte0: UInt8 = ((unitOut - 1) & 0x3)
                             | (((unitIn - 1) & 0x3) << 2)
                             | ((signed ? 1 : 0) << 4)
            let nch: UInt8 = inputChannels > 1 ? inputChannels - 1 : 0
            return [byte0, operation.rawValue] + littleEndian32(UInt32(bitPattern: rhs)) + [nch]
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 {
            let unitIn  = inputLength / max(inputChannels, 1)
            return (outputSize ?? unitIn) * inputChannels
        }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { inputChannels }
        public func outputSigned(inputSigned: Bool) -> Bool { signed }
    }
}

// MARK: Sample delay  (type 0x0A)

public extension MWDataProcessor {

    /// Buffers `binSize` samples and emits them in one burst when full.
    ///
    /// Useful for ML-style windowing — capture N consecutive samples then ship
    /// them as a single packet for further on-device processing or BLE delivery.
    ///
    /// `SampleDelayConfig`: `{data_length-1, bin_size}`.
    struct Sample: MWDataProcessorConfig, Sendable {
        public let binSize: UInt8

        public init(binSize: UInt8) { self.binSize = binSize }

        public let typeID: UInt8 = 0x0A
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            [inputLength - 1, binSize]
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { inputLength }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { inputChannels }
        public func outputSigned(inputSigned: Bool) -> Bool { inputSigned }
    }
}

// MARK: Comparator  (type 0x06)

public extension MWDataProcessor {

    /// Compares each sample against a fixed reference, passing samples that satisfy the condition.
    ///
    /// On firmware ≥ 1.2.3 (everything shipped to MetaMotion R / RL / S / C since 2017)
    /// the firmware expects the **multi-comparator** config layout — even when there's
    /// only one reference. The legacy single-comparator config (`is_signed(1), op(1),
    /// padding(1), ref[4]`) was deprecated, and modern firmware misreads its bytes,
    /// causing both comparators in a chain to compare against the same value (whichever
    /// happens to land at the position of references[0]). That manifests on hardware as
    /// "isOdd and isEven both fire on every press" — see
    /// `EventTests.events_oddEvenPresses_alternateLEDColors`.
    ///
    /// **Wire format we emit (multi-comparator with a single reference):**
    /// ```
    /// byte 0 (bit-packed, LSB first):
    ///   bit 0      is_signed
    ///   bits 1-2   length     (size_per_ref - 1: 0=1B, 1=2B, 3=4B)
    ///   bits 3-5   operation  (eq=0, neq=1, lt=2, lte=3, gt=4, gte=5)
    ///   bits 6-7   mode       (always 0 = ABSOLUTE — emit input on match)
    /// bytes 1..N: reference[size_per_ref], little-endian
    /// ```
    /// Reference per scalar in/out is `inputLength / max(inputChannels, 1)`.
    ///
    /// Reference test: C++ `TestMultiComparator.test_absolute` on a 2-byte unsigned
    /// temperature signal with EQ + 3 refs (24, 25, 26 °C) yields
    /// `[0x03, 0xC0, 0x00, 0xC8, 0x00, 0xD0, 0x00]` — byte 0 = is_signed(0)
    /// | length(1<<1) | op(0<<3) | mode(0<<6) = 0x02 + the inputSigned bit ANDed in by
    /// the firmware's temperature signal (signed). The bit layout decodes the same way
    /// for our single-reference call — see unit-test bytes in `MWDataProcessorTests`.
    struct Comparator: MWDataProcessorConfig, Sendable {
        /// Comparison predicate applied to each input against the `reference` value.
        public enum Operation: UInt8, Sendable {
            /// Pass samples where `input == reference`.
            case eq = 0
            /// Pass samples where `input != reference`.
            case neq = 1
            /// Pass samples where `input < reference`.
            case lt = 2
            /// Pass samples where `input <= reference`.
            case lte = 3
            /// Pass samples where `input > reference`.
            case gt = 4
            /// Pass samples where `input >= reference`.
            case gte = 5
        }
        public let operation: Operation
        /// Value to compare each input against (already scaled to board units).
        public let reference: Int32
        /// Whether the input values are signed (determines compare semantics).
        public let signed: Bool

        public init(operation: Operation, reference: Int32, signed: Bool = true) {
            self.operation = operation
            self.reference = reference
            self.signed    = signed
        }

        public let typeID: UInt8 = 0x06
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            // Per-scalar size: 1, 2, or 4 bytes. Clamp so totally-unexpected widths
            // don't produce out-of-range length bits.
            let unitSize = max(min(inputLength / max(inputChannels, 1), 4), 1)
            let lengthBits = (unitSize - 1) & 0x3
            let opBits     = operation.rawValue & 0x7
            let byte0: UInt8 = (signed ? 1 : 0)
                             | (lengthBits << 1)
                             | (opBits     << 3)
                             // mode bits 6-7 = 0 (ABSOLUTE)
            let refLE = littleEndian32(UInt32(bitPattern: reference))
            return [byte0] + Array(refLE.prefix(Int(unitSize)))
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { inputLength }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { inputChannels }
        public func outputSigned(inputSigned: Bool) -> Bool { signed }
    }
}

// MARK: Threshold  (type 0x0D)

public extension MWDataProcessor {

    /// Emits a value only when the input crosses a boundary, with optional hysteresis.
    ///
    /// Unlike `Comparator` (which fires for every sample satisfying the
    /// predicate), `Threshold` only fires on the transition across `boundary`.
    /// Pair `.binary` mode with an `Event` to trigger an LED/haptic on crossing.
    /// Use `hysteresis > 0` to debounce noisy inputs near the boundary.
    ///
    /// `ThresholdConfig` (7 bytes): `{data_size-1:2, is_signed:1, mode:3}, boundary[4], hysteresis[2]`.
    ///
    /// Reference test: `test_freefall` (BINARY, boundary=8192, hysteresis=0):
    /// `[0x09, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00]`
    ///  — size=2, unsigned, binary=1, boundary=0x2000=8192, hyst=0 ✓
    struct Threshold: MWDataProcessorConfig, Sendable {
        /// How the threshold stage encodes a boundary crossing.
        public enum Mode: UInt8, Sendable {
            /// Output the raw value (filtered to only when crossing).
            case absolute = 0
            /// Output +1 when above, –1 when below.
            case binary   = 1
        }
        /// Threshold value (already scaled to board units / LSBs).
        public let boundary: Int32
        /// Dead-band around `boundary`: input must move this far past the line to fire again.
        public let hysteresis: UInt16
        public let mode: Mode
        /// Whether the input values are signed.
        public let signed: Bool

        public init(boundary: Int32,
                    hysteresis: UInt16 = 0,
                    mode: Mode = .binary,
                    signed: Bool = true) {
            self.boundary   = boundary
            self.hysteresis = hysteresis
            self.mode       = mode
            self.signed     = signed
        }

        public let typeID: UInt8 = 0x0D
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            // ThresholdConfig wire layout (7 bytes):
            //   byte 0:  bits [1:0] = data_size - 1   (per-scalar bytes, 1..4 → 0..3)
            //            bit  [2]   = is_signed flag
            //            bits [5:3] = mode             (0 absolute, 1 binary)
            //            bits [7:6] = reserved
            //   bytes 1–4: boundary (Int32 little-endian)
            //   bytes 5–6: hysteresis (UInt16 little-endian)
            let unitSize = inputLength / max(inputChannels, 1)
            let byte0: UInt8 = ((unitSize - 1) & 0x3)
                             | ((signed ? 1 : 0) << 2)
                             | ((mode.rawValue  & 0x7) << 3)
            return [byte0]
                 + littleEndian32(UInt32(bitPattern: boundary))
                 + [UInt8(hysteresis & 0xFF), UInt8(hysteresis >> 8)]
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 {
            // BINARY mode outputs Int32 (±1); ABSOLUTE outputs same as input per channel
            mode == .binary ? 4 : inputLength
        }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { 1 }
        public func outputSigned(inputSigned: Bool) -> Bool { mode == .binary ? true : signed }
    }
}

// MARK: Delta  (type 0x0C)

public extension MWDataProcessor {

    /// Emits a sample only when the input has moved at least `magnitude` from
    /// the last value it emitted ("change-on-delta" filter).
    ///
    /// Use to suppress redundant samples from a noisy or slow-moving signal —
    /// e.g. only stream a barometer reading when pressure changes by ≥10 Pa.
    /// Each emission also updates the internal reference so deltas accumulate
    /// from the last fire, not the start of the stream.
    ///
    /// `DeltaConfig` (5 bytes): byte0 `{length-1:2, is_signed:1, mode:3, _:2}`, bytes1-4 `magnitude[int32 LE]`.
    ///
    /// Reference test: `TestDeltaSetPrevious` (barometer pressure, mode DIFFERENTIAL, magnitude 25331.25 Pa).
    /// The magnitude is passed pre-scaled to board units; use your sensor's firmware converter.
    struct Delta: MWDataProcessorConfig, Sendable {
        /// What value the delta stage emits when the threshold is crossed.
        public enum Mode: UInt8, Sendable {
            /// Output the raw input on each threshold crossing.
            case absolute     = 0
            /// Output the raw delta from the last reference.
            case differential = 1
            /// Output +1 when above, -1 when below.
            case binary       = 2
        }
        /// Magnitude expressed in already-scaled board units (LSBs).
        public let magnitude: Int32
        public let mode: Mode

        public init(magnitude: Int32, mode: Mode = .absolute) {
            self.magnitude = magnitude
            self.mode      = mode
        }

        public let typeID: UInt8 = 0x0C
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            // DeltaConfig wire layout (5 bytes):
            //   byte 0:  bits [1:0] = input_length - 1   (per-scalar bytes, 1..4 → 0..3)
            //            bit  [2]   = is_signed flag
            //            bits [5:3] = mode               (0 absolute, 1 differential, 2 binary)
            //            bits [7:6] = reserved
            //   bytes 1–4: magnitude (Int32 little-endian, already in board units)
            let byte0: UInt8 = ((inputLength - 1) & 0x3)
                             | ((inputSigned ? 1 : 0) << 2)
                             | ((mode.rawValue & 0x7) << 3)
            return [byte0] + littleEndian32(UInt32(bitPattern: magnitude))
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 {
            // BINARY emits int8 (±1); otherwise matches input width.
            mode == .binary ? 1 : inputLength
        }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { inputChannels }
        public func outputSigned(inputSigned: Bool) -> Bool { mode == .binary ? true : inputSigned }
    }
}

// MARK: Pulse  (type 0x0B)

public extension MWDataProcessor {

    /// Detects pulses (sustained excursions above `threshold` for ≥ `width` samples)
    /// and emits one summary value per pulse.
    ///
    /// Classic use: a step-detector — RSS-of-accel into a `Pulse` with the right
    /// threshold/width emits one sample per step. The `output` field controls
    /// what each emission represents (duration, area, peak, or just a "happened"
    /// flag), which lets the same processor serve very different downstream goals.
    ///
    /// `PulseDetectorConfig` (9 bytes): `length, trigger_mode=0, output_mode, threshold[4], width[2]`.
    ///
    /// Reference tests:
    ///  - `test_acc_z_pulse_setup` (AREA mode, threshold 2048, width 16) →
    ///    `[0x01, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00, 0x10, 0x00]` ✓
    ///  - `test_pulse_setup` (GPIO ADC PEAK 500, width 10) →
    ///    `[0x01, 0x00, 0x02, 0xF4, 0x01, 0x00, 0x00, 0x0A, 0x00]` ✓
    struct Pulse: MWDataProcessorConfig, Sendable {
        /// What value the pulse-detector emits per detected pulse.
        public enum Output: UInt8, Sendable {
            /// Pulse duration (samples above threshold).
            case width    = 0
            /// Integrated area above threshold.
            case area     = 1
            /// Peak value during the pulse.
            case peak     = 2
            /// Boolean pulse detected indicator (UInt32).
            case onDetect = 3
        }
        /// Threshold in already-scaled board units (LSBs).
        public let threshold: Int32
        /// Minimum number of samples above threshold to qualify as a pulse.
        public let width: UInt16
        public let output: Output

        public init(output: Output, threshold: Int32, width: UInt16) {
            self.output    = output
            self.threshold = threshold
            self.width     = width
        }

        public let typeID: UInt8 = 0x0B
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            [inputLength - 1, 0x00, output.rawValue]
                + littleEndian32(UInt32(bitPattern: threshold))
                + [UInt8(width & 0xFF), UInt8(width >> 8)]
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 {
            // AREA/PEAK preserve input unit width; WIDTH/ON_DETECT emit UInt32.
            (output == .area || output == .peak) ? inputLength : 4
        }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { 1 }
        public func outputSigned(inputSigned: Bool) -> Bool {
            (output == .area || output == .peak) ? inputSigned : false
        }
    }
}

// MARK: Buffer  (type 0x0F)

public extension MWDataProcessor {

    /// Holds the most recent sample without emitting anything on its own.
    ///
    /// The buffered value can be pulled by a separate `Event`/read, or referenced
    /// as a secondary input of a `Fuser` to bundle that sensor's latest reading
    /// alongside another stream — without ever having to subscribe to the
    /// buffered signal directly.
    ///
    /// `BufferConfig` (1 byte): `{length-1:5, _:3}`.
    ///
    /// Reference test: `TestFuserAccounter.test_commands` — gyro buffer emits
    /// `[0x09, 0x02, 0x13, 0x05, 0xFF, 0xA0, 0x0F, 0x05]` (length 6 → byte = 5) ✓
    struct Buffer: MWDataProcessorConfig, Sendable {
        public init() {}
        public let typeID: UInt8 = 0x0F
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            [(inputLength - 1) & 0x1F]
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { inputLength }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { inputChannels }
        public func outputSigned(inputSigned: Bool) -> Bool { inputSigned }
    }
}

// MARK: Packer  (type 0x10)

public extension MWDataProcessor {

    /// Bundles `count` consecutive samples into a single BLE packet to reduce overhead.
    ///
    /// BLE has high per-packet overhead; packing 4–8 samples at a time can
    /// significantly raise sustainable streaming rates. The downstream parser
    /// must split the packet back into individual samples.
    ///
    /// `PackerConfig` (2 bytes): byte0 `{length-1:5, _:3}`, byte1 `{count-1:5, _:3}`.
    ///
    /// Reference test: `TestPacker.test_create` (temperature, count=4, input=2) →
    /// `[0x01, 0x03]` ✓
    struct Packer: MWDataProcessorConfig, Sendable {
        /// Number of samples combined per emission (1-32).
        public let count: UInt8

        public init(count: UInt8) { self.count = count }

        public let typeID: UInt8 = 0x10
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            [(inputLength - 1) & 0x1F, (count - 1) & 0x1F]
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { inputLength }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { inputChannels }
        public func outputSigned(inputSigned: Bool) -> Bool { inputSigned }
    }
}

// MARK: Accounter  (type 0x11)

public extension MWDataProcessor {

    /// Prepends a timestamp or packet counter to each sample so the logger can
    /// reconstruct precise timing when log entries are downloaded out of order.
    ///
    /// Required upstream of `Logger` when multiple signals share a single
    /// logger channel (e.g. a `Fuser`'s output), so the host can disambiguate
    /// which sample came from when. `.time` is the usual choice; `.count` is
    /// for verifying packet ordering / drop detection.
    ///
    /// `AccounterConfig` (2 bytes): byte0 `{mode:4, length-1:2, _:2}`, byte1 `{prescale:4, _:4}`.
    /// Firmware pins length to 4 bytes and prescale to 3 to match the logger's wire format.
    ///
    /// Reference tests:
    ///  - `TestAccounter.test_create` (mode=time) → `[0x31, 0x03]` ✓
    ///  - `TestAccounterCount.test_create` (mode=count) → `[0x30, 0x03]` ✓
    struct Accounter: MWDataProcessorConfig, Sendable {
        /// What value the accounter prepends to each sample.
        public enum Mode: UInt8, Sendable {
            /// Prepend a monotonically-increasing packet counter.
            case count = 0
            /// Prepend a compact epoch offset (ms since boot).
            case time  = 1
        }
        public let mode: Mode
        /// Pinned to 4 bytes as firmware / logger expect.
        public let length: UInt8 = 4
        /// Pinned to 3 (matches C++ logger default).
        public let prescale: UInt8 = 3

        public init(mode: Mode = .time) { self.mode = mode }

        public let typeID: UInt8 = 0x11
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            // AccounterConfig wire layout (2 bytes):
            //   byte 0:  bits [3:0] = mode             (0 count, 1 time)
            //            bits [5:4] = length - 1       (prepended counter/timestamp width, fixed at 4 → bits = 3)
            //            bits [7:6] = reserved
            //   byte 1:  bits [3:0] = prescale         (time-mode tick prescaler, fixed at 3)
            //            bits [7:4] = reserved
            let byte0: UInt8 = (mode.rawValue & 0x0F) | (((length - 1) & 0x3) << 4)
            let byte1: UInt8 = prescale & 0x0F
            return [byte0, byte1]
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { inputLength + length }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { inputChannels }
        public func outputSigned(inputSigned: Bool) -> Bool { inputSigned }
    }
}

// MARK: Fuser  (type 0x1B)

public extension MWDataProcessor {

    /// Bundles the primary source with the latest samples from one or more
    /// `Buffer` stages into a single multi-part packet.
    ///
    /// Use to align time-synchronous data from different sensors (e.g. accel +
    /// gyro arriving in one packet, snapshot together at the host's wake-up
    /// time). Each auxiliary signal must first be wrapped in a `Buffer` so the
    /// fuser has a stable "latest" value to pull on each primary fire.
    ///
    /// `FuseConfig` (13 bytes): byte0 `{count:4, _:4}`, bytes1-12 `references[12]` — the
    /// board-assigned processor IDs of a matching number of `Buffer` stages that hold the
    /// auxiliary signals.
    ///
    /// Reference test: `TestFuserAccounter.test_commands` — acc fused with gyro-via-buffer(id 0) →
    /// `[0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]` ✓
    struct Fuser: MWDataProcessorConfig, Sendable {
        /// Buffer processor IDs (max 12) that feed the secondary inputs, in order.
        public let bufferIDs: [UInt8]

        /// - Throws: `MWError.operationFailed` if more than 12 buffer references
        ///   are supplied. The fuser config has exactly 12 reference slots.
        public init(bufferIDs: [UInt8]) throws {
            guard bufferIDs.count <= 12 else {
                throw MWError.operationFailed("Fuser supports at most 12 buffer references; got \(bufferIDs.count)")
            }
            self.bufferIDs = bufferIDs
        }

        public let typeID: UInt8 = 0x1B
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            let count = UInt8(bufferIDs.count)
            var refs = bufferIDs
            while refs.count < 12 { refs.append(0) }
            return [count & 0x0F] + refs
        }
        // Fuser output is a concatenation of all inputs — the length isn't a single
        // simple scalar, so we report inputLength (primary) and let downstream
        // consumers parse multi-part data. n_channels unchanged.
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { inputLength }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { inputChannels }
        public func outputSigned(inputSigned: Bool) -> Bool { inputSigned }
    }
}

// MARK: - Private helpers

private func littleEndian32(_ value: UInt32) -> [UInt8] {
    [UInt8(value & 0xFF),
     UInt8((value >> 8)  & 0xFF),
     UInt8((value >> 16) & 0xFF),
     UInt8((value >> 24) & 0xFF)]
}

// MARK: - MetaWearDevice data processor API

public extension MetaWearDevice {

    // MARK: Create

    /// Create a data processor on the board and return a handle to it.
    ///
    /// The handle can be passed as the `source` of a subsequent `createProcessor` call to chain
    /// processors, or passed to `streamProcessor` to receive live data.
    ///
    /// - Parameters:
    ///   - config:  The processor type and its configuration.
    ///   - source:  The input signal (a sensor or a previous processor handle).
    /// - Returns: A handle containing the board-assigned processor ID and output metadata.
    func createProcessor(_ config: any MWDataProcessorConfig,
                         source: any MWSignal) async throws -> MWProcessorHandle {
        guard moduleInfo(for: .dataProcessor)?.isPresent == true else {
            throw MWError.operationFailed("Data processor module not present on this board")
        }
        let cmd = buildProcessorAddCommand(source: source, config: config)
        let response = try await sendAndAwaitNotification(
            command: Data(cmd),
            awaitModule: .dataProcessor,
            awaitRegister: 0x02
        )
        guard response.count >= 3 else {
            throw MWError.operationFailed("Data processor ADD response too short (\(response.count) bytes)")
        }
        let pid      = response[2]
        let outLen   = config.outputLength(inputLength: source.dataLength, inputChannels: source.nChannels)
        let outCh    = config.outputChannels(inputLength: source.dataLength, inputChannels: source.nChannels)
        let outSign  = config.outputSigned(inputSigned: source.isSigned)
        let unitSize = outCh > 0 ? outLen / outCh : outLen
        return MWProcessorHandle(id: pid, nChannels: outCh, channelSize: unitSize, isSigned: outSign)
    }

    // MARK: Stream

    /// Enable notifications from a processor and return a stream of raw data packets.
    ///
    /// Each element is a raw BLE packet `[0x09, 0x03, processorID, data...]`.
    /// Parse `data` according to the processor's output type.
    func streamProcessor(_ handle: MWProcessorHandle) async throws -> AsyncThrowingStream<Data, Error> {
        await ensureProcessorDemux()
        let (stream, cont) = AsyncThrowingStream<Data, Error>.makeStream()
        processorContinuations[handle.id] = cont
        // Two enables, mirroring C++ `MblMwDataProcessor::subscribe()`:
        //  1. NOTIFY_ENABLE [0x09, 0x07, proc_id, 0x01] — route this
        //     processor's output to the NOTIFY register.
        //  2. NOTIFY [0x09, 0x03, 0x01] — subscribe the NOTIFY register
        //     itself (the standard per-register notify-enable write).
        // Without #2 the board emits NOTHING for any processor — verified on
        // MMS firmware 1.7.2, where omitting it produced zero notifications
        // from an actively-fed counter.
        try await writeRaw(Data([MWModule.dataProcessor.rawValue, 0x07, handle.id, 0x01]))
        try await writeRaw(Data([MWModule.dataProcessor.rawValue, 0x03, 0x01]))
        return stream
    }

    /// Disable notifications from a processor.
    func stopStreamingProcessor(_ handle: MWProcessorHandle) async throws {
        processorContinuations[handle.id]?.finish()
        processorContinuations.removeValue(forKey: handle.id)
        try await writeRaw(Data([MWModule.dataProcessor.rawValue, 0x07, handle.id, 0x00]))
    }

    // MARK: Remove

    /// Remove one processor from the board.
    func removeProcessor(_ handle: MWProcessorHandle) async throws {
        processorContinuations[handle.id]?.finish()
        processorContinuations.removeValue(forKey: handle.id)
        try await writeRaw(Data([MWModule.dataProcessor.rawValue, 0x06, handle.id]))
    }

    /// Remove all processors from the board.
    func removeAllProcessors() async throws {
        processorContinuations.values.forEach { $0.finish() }
        processorContinuations.removeAll()
        processorDemuxTask?.cancel()
        processorDemuxTask = nil
        try await writeRaw(Data([MWModule.dataProcessor.rawValue, 0x08]))
    }

    // MARK: - Internal helpers

    /// Build the ADD command bytes.
    internal func buildProcessorAddCommand(source: any MWSignal,
                                           config: any MWDataProcessorConfig) -> [UInt8] {
        let header: [UInt8] = [
            MWModule.dataProcessor.rawValue,   // 0x09
            0x02,                              // ADD register
            source.moduleID,
            source.registerID,
            source.dataID,
            source.sourceConfigByte,
            config.typeID
        ]
        let cfgBytes = config.configBytes(
            inputLength: source.dataLength,
            inputChannels: source.nChannels,
            inputSigned: source.isSigned
        )
        return header + cfgBytes
    }

    internal func ensureProcessorDemux() async {
        guard processorDemuxTask == nil else { return }
        let stream = await subscribeRaw(to: .dataProcessor, register: 0x03)
        processorDemuxTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await packet in stream {
                    guard packet.count >= 3 else { continue }
                    let pid = packet[2]
                    await self.deliverProcessorPacket(pid: pid, packet: packet)
                }
            } catch {
                await self.terminateAllProcessorStreams(with: error)
            }
        }
    }

    internal func deliverProcessorPacket(pid: UInt8, packet: Data) {
        processorContinuations[pid]?.yield(packet)
    }

    internal func terminateAllProcessorStreams(with error: Error) {
        processorContinuations.values.forEach { $0.finish(throwing: error) }
        processorContinuations.removeAll()
        processorDemuxTask = nil
    }
}
