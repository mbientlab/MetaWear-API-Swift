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
public struct MWGPIOAnalogSignal: MWSignal, Sendable {
    public var moduleID: UInt8    { MWModule.gpio.rawValue }
    public var registerID: UInt8  // 0x07 ADC, 0x06 absolute
    public var dataID: UInt8      // pin number
    public var nChannels: UInt8   { 1 }
    public var channelSize: UInt8 { 2 }
    public var offset: UInt8      { 0 }
    public var isSigned: Bool     { false }

    public enum Mode { case adc, absolute }
    public init(pin: UInt8, mode: Mode = .adc) {
        self.dataID      = pin
        self.registerID  = mode == .adc ? 0x07 : 0x06
    }
}

/// Single temperature channel (1 × Int16 = 2 bytes, signed).
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
public enum MWDataProcessor {}

// MARK: Passthrough  (type 0x01)

public extension MWDataProcessor {

    /// Gates data flow — pass all, pass conditionally, or pass N times then stop.
    struct Passthrough: MWDataProcessorConfig, Sendable {
        public enum Mode: UInt8, Sendable {
            case all = 0, conditional = 1, count = 2
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

    /// Computes a rolling average (low-pass filter).
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
    /// `CombinerConfig`: `{output-1:2, input-1:2, channels-1:3, is_signed:1, mode=0}`.
    ///
    /// Reference test: `test_freefall` (accelerometer RSS):
    /// `[0xa5, 0x01]` — output=2, input=2, ch=3, signed=1, mode=RSS ✓
    struct RMS: MWDataProcessorConfig, Sendable {
        public init() {}
        public let typeID: UInt8 = 0x07
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            let unit = inputLength / max(inputChannels, 1)
            let s    = (unit - 1) & 0x3
            let byte0: UInt8 = s | (s << 2) | (((inputChannels - 1) & 0x7) << 4) | (inputSigned ? 0x80 : 0)
            return [byte0, 0x00]   // mode=0 (RMS)
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { inputLength / max(inputChannels, 1) }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { 1 }
        public func outputSigned(inputSigned: Bool) -> Bool { false }
    }

    /// Root-sum-square combiner.
    struct RSS: MWDataProcessorConfig, Sendable {
        public init() {}
        public let typeID: UInt8 = 0x07
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
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

    /// Passes one sample per `periodMs` milliseconds.
    ///
    /// `TimeDelayConfig`: `{data_length-1:3, mode:3, _:2, period[4]}`.
    struct Time: MWDataProcessorConfig, Sendable {
        public enum Mode: UInt8, Sendable {
            case absolute = 0, differential = 1
        }
        public let periodMs: UInt32
        public let mode: Mode

        public init(periodMs: UInt32, mode: Mode = .absolute) {
            self.periodMs = periodMs
            self.mode     = mode
        }

        public let typeID: UInt8 = 0x08
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
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

    /// Arithmetic transform applied per sample.
    ///
    /// `MathConfig`: `{output-1:2, input-1:2, signed:1, _:3, operation, rhs[4], n_channels}`.
    ///
    /// Reference test: `test_led_controller` (counter % 2):
    /// `[0x03, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00]` — output=4, input=1, unsigned, MODULO, rhs=2, ch=0 ✓
    struct Math: MWDataProcessorConfig, Sendable {
        public enum Operation: UInt8, Sendable {
            case add = 0, subtract = 1, multiply = 2, divide = 3, modulo = 4
            case exponent = 5, sqrt = 6, lshift = 7, rshift = 8, abs = 9
            case constant = 10, negate = 11, floor = 12, ceil = 13, round = 14
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

    /// Buffers N samples and emits them as a single burst.
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
    /// `ComparatorConfig` (7 bytes): `is_signed(1), operation(1), padding(1), reference[4]`.
    ///
    /// Reference test: `test_freefall` (EQ -1 and EQ 1 on BINARY threshold output):
    /// `[0x01, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF]` — signed, EQ, ref=-1 ✓
    struct Comparator: MWDataProcessorConfig, Sendable {
        public enum Operation: UInt8, Sendable {
            case eq = 0, neq = 1, lt = 2, lte = 3, gt = 4, gte = 5
        }
        public let operation: Operation
        public let reference: Int32
        public let signed: Bool

        public init(operation: Operation, reference: Int32, signed: Bool = true) {
            self.operation = operation
            self.reference = reference
            self.signed    = signed
        }

        public let typeID: UInt8 = 0x06
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            [signed ? 1 : 0, operation.rawValue, 0x00]
            + littleEndian32(UInt32(bitPattern: reference))
        }
        public func outputLength(inputLength: UInt8, inputChannels: UInt8)  -> UInt8 { inputLength }
        public func outputChannels(inputLength: UInt8, inputChannels: UInt8) -> UInt8 { inputChannels }
        public func outputSigned(inputSigned: Bool) -> Bool { signed }
    }
}

// MARK: Threshold  (type 0x0D)

public extension MWDataProcessor {

    /// Emits a value when the input crosses a boundary.
    ///
    /// `ThresholdConfig` (7 bytes): `{data_size-1:2, is_signed:1, mode:3}, boundary[4], hysteresis[2]`.
    ///
    /// Reference test: `test_freefall` (BINARY, boundary=8192, hysteresis=0):
    /// `[0x09, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00]`
    ///  — size=2, unsigned, binary=1, boundary=0x2000=8192, hyst=0 ✓
    struct Threshold: MWDataProcessorConfig, Sendable {
        public enum Mode: UInt8, Sendable {
            /// Output the raw value (filtered to only when crossing).
            case absolute = 0
            /// Output +1 when above, –1 when below.
            case binary   = 1
        }
        public let boundary: Int32
        public let hysteresis: UInt16
        public let mode: Mode
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

    /// Emits a sample only when the input differs from the last reference by at least `magnitude`.
    ///
    /// `DeltaConfig` (5 bytes): byte0 `{length-1:2, is_signed:1, mode:3, _:2}`, bytes1-4 `magnitude[int32 LE]`.
    ///
    /// Reference test: `TestDeltaSetPrevious` (barometer pressure, mode DIFFERENTIAL, magnitude 25331.25 Pa).
    /// The magnitude is passed pre-scaled to board units; use your sensor's firmware converter.
    struct Delta: MWDataProcessorConfig, Sendable {
        public enum Mode: UInt8, Sendable {
            case absolute     = 0   ///< Output the raw input on each threshold crossing.
            case differential = 1   ///< Output the raw delta from the last reference.
            case binary       = 2   ///< Output +1 when above, -1 when below.
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

    /// Detects pulses in the input stream and emits one sample per pulse.
    ///
    /// `PulseDetectorConfig` (9 bytes): `length, trigger_mode=0, output_mode, threshold[4], width[2]`.
    ///
    /// Reference tests:
    ///  - `test_acc_z_pulse_setup` (AREA mode, threshold 2048, width 16) →
    ///    `[0x01, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00, 0x10, 0x00]` ✓
    ///  - `test_pulse_setup` (GPIO ADC PEAK 500, width 10) →
    ///    `[0x01, 0x00, 0x02, 0xF4, 0x01, 0x00, 0x00, 0x0A, 0x00]` ✓
    struct Pulse: MWDataProcessorConfig, Sendable {
        public enum Output: UInt8, Sendable {
            case width    = 0   ///< Pulse duration (samples above threshold).
            case area     = 1   ///< Integrated area above threshold.
            case peak     = 2   ///< Peak value during the pulse.
            case onDetect = 3   ///< Boolean pulse detected indicator (UInt32).
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

    /// Buffers the most recent sample without emitting anything on its own — the value
    /// is retrieved by an event or read, or referenced by a `Fuser` stage.
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

    /// Combines `count` consecutive samples into a single BLE packet to reduce overhead.
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

    /// Prepends a timestamp or packet counter to each sample, used by the logger to
    /// reconstruct timing for bundled streams.
    ///
    /// `AccounterConfig` (2 bytes): byte0 `{mode:4, length-1:2, _:2}`, byte1 `{prescale:4, _:4}`.
    /// Firmware pins length to 4 bytes and prescale to 3 to match the logger's wire format.
    ///
    /// Reference tests:
    ///  - `TestAccounter.test_create` (mode=time) → `[0x31, 0x03]` ✓
    ///  - `TestAccounterCount.test_create` (mode=count) → `[0x30, 0x03]` ✓
    struct Accounter: MWDataProcessorConfig, Sendable {
        public enum Mode: UInt8, Sendable {
            case count = 0  ///< Prepend a monotonically-increasing packet counter.
            case time  = 1  ///< Prepend a compact epoch offset (ms since boot).
        }
        public let mode: Mode
        /// Pinned to 4 bytes as firmware / logger expect.
        public let length: UInt8 = 4
        /// Pinned to 3 (matches C++ logger default).
        public let prescale: UInt8 = 3

        public init(mode: Mode = .time) { self.mode = mode }

        public let typeID: UInt8 = 0x11
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
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

    /// Combines the latest sample from the primary source with buffered samples from
    /// additional signals into a single multi-part packet.
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

        public init(bufferIDs: [UInt8]) { self.bufferIDs = bufferIDs }

        public let typeID: UInt8 = 0x1B
        public func configBytes(inputLength: UInt8, inputChannels: UInt8, inputSigned: Bool) -> [UInt8] {
            let count = UInt8(min(bufferIDs.count, 12))
            var refs = Array(bufferIDs.prefix(12))
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
        // NOTIFY_ENABLE: [0x09, 0x07, proc_id, 0x01]
        try await writeRaw(Data([MWModule.dataProcessor.rawValue, 0x07, handle.id, 0x01]))
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
