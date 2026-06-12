import Foundation

// MARK: - Timestamped

/// A value paired with the host wall-clock time it was received at.
///
/// Used as the element type of streamed and read sensor samples. The
/// timestamp is taken by the SDK at packet-arrival time on the host —
/// it is not a hardware timestamp. For high-rate streams the inter-sample
/// interval is more accurate than the absolute time, since BLE delivery
/// of a notification is subject to host scheduling jitter.
///
/// For logged samples (which include a tick-based device timestamp) see
/// `MWLoggedSample`.
public struct Timestamped<Value: Sendable>: Sendable {
    /// Host wall-clock time when the SDK observed this value.
    public let time: Date
    /// The decoded sensor / command value.
    public let value: Value
}

// MARK: - Download progress

/// A progress update yielded during a long-running download.
///
/// `MetaWearDevice.downloadLogs(_:)` produces an `AsyncThrowingStream` of
/// `Download<[…]>` values. Each yield carries the samples decoded so far
/// (cumulative, not delta) and an approximate completion fraction reported
/// by the firmware via the logging-progress register.
public struct Download<Data: Sendable>: Sendable {
    /// All samples decoded so far. Each yield is cumulative — the final
    /// element contains the complete download.
    public let data: Data
    /// `0.0` to `1.0`, monotonically non-decreasing. Driven by the firmware's
    /// log-readout-progress register, so granularity depends on log length.
    public let percentComplete: Double
    /// Total raw log entries the board reported via `LOG_LENGTH` at the
    /// start of this readout. `nil` only when the stream wasn't initiated
    /// through `downloadLogs()` (e.g. a future test fixture); every real
    /// download yields a concrete value.
    public let totalEntries: UInt32?
    /// Number of raw entries received so far on the wire. Independent of
    /// how many *typed samples* have been decoded — multi-chunk loggers
    /// produce N entries per sample, so this counter is the truth for
    /// "how close to done are we" while the sample count tracks payload.
    public let entriesDownloaded: UInt32?

    public init(
        data: Data,
        percentComplete: Double,
        totalEntries: UInt32? = nil,
        entriesDownloaded: UInt32? = nil
    ) {
        self.data = data
        self.percentComplete = percentComplete
        self.totalEntries = totalEntries
        self.entriesDownloaded = entriesDownloaded
    }
}

// MARK: - Decoded log sample

/// A typed sensor sample recovered from the on-device flash log.
public struct MWLoggedSample<Sample: Sendable>: Sendable {
    /// Wall-clock timestamp. Accurate when the device's time reference was read
    /// during `connect()`. Falls back to `Date(timeIntervalSince1970: tickMs/1000)`
    /// if no reference was available.
    public let date: Date
    /// Elapsed milliseconds since the MetaWear last reset (raw tick time).
    /// Useful for computing inter-sample intervals regardless of wall time.
    public let tickMs: Double
    public let value: Sample

    public init(date: Date, tickMs: Double, value: Sample) {
        self.date   = date
        self.tickMs = tickMs
        self.value  = value
    }
}

// MARK: - Active logger entry

/// A single logger subscription active on the MetaWear, as returned by
/// `MetaWearDevice.queryActiveLoggers()`.
public struct ActiveLogger: Sendable {
    public let loggerID: UInt8
    public let module: MWModule
    public let register: UInt8
    /// Raw channel byte (response[5]). For per-channel sources (e.g. multi-thermistor
    /// temperature) this is the channel index. For packed IMU sources this is 0xFF.
    public let channel: UInt8
    /// Byte offset of this chunk within the parent signal's payload. Low 5 bits
    /// of the packed byte.
    public let chunkOffset: UInt8
    /// Byte length of this chunk. `((packed >> 5) & 0x7) + 1`.
    public let chunkLength: UInt8
}

// MARK: - Active data-processor entry

/// A single data processor on-device, as returned by `MetaWearDevice.queryActiveProcessors()`.
/// Used to reconstruct the processor graph behind an anonymous signal.
public struct ActiveProcessor: Sendable, Equatable {
    /// The firmware-assigned processor ID (0x00..0x1F).
    public let processorID: UInt8
    /// The module that feeds this processor. When equal to `.dataProcessor`,
    /// the parent is another processor and `parentProcessorID` is meaningful.
    public let parentModule: MWModule
    /// Parent register. For a sensor root this is the data-register; for a
    /// processor chain it's the NOTIFY register (0x03).
    public let parentRegister: UInt8
    /// When `parentModule == .dataProcessor`, this is the parent processor's ID.
    /// Otherwise it's the raw offset/channel byte from the response (commonly 0xFF).
    public let parentProcessorID: UInt8
    /// Byte offset into the parent's output data.
    public let chunkOffset: UInt8
    /// Byte length of the processor's input chunk within the parent's output.
    public let chunkLength: UInt8
    /// Processor type code (see `MWProcessorType` table in the C++ SDK).
    /// Examples: 0x02 = accumulate/count, 0x07 = RMS/RSS, 0x08 = time, 0x1B = fuser.
    public let processorType: UInt8
    /// Processor-specific config bytes, stripped of the response header.
    public let configBytes: [UInt8]

    /// True when this processor reads its input from another processor (as
    /// opposed to a root sensor signal).
    public var parentIsProcessor: Bool {
        parentModule == .dataProcessor && parentRegister == 0x03
    }
}

// MARK: - Sensor value types

/// A 3-axis floating-point vector in the sensor's local frame.
///
/// Units depend on the sensor that produced it:
/// - accelerometer: `g` (1 g = 9.80665 m/s²)
/// - gyroscope: degrees per second (dps)
/// - magnetometer: microtesla (µT)
/// - sensor-fusion gravity / linear acceleration: `g`
public struct CartesianFloat: Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float
    public init(x: Float, y: Float, z: Float) { self.x = x; self.y = y; self.z = z }
}

/// A unit quaternion produced by the sensor-fusion algorithm.
///
/// Components are in the range `[-1, 1]`. The convention is Hamilton (w first,
/// then x/y/z imaginary parts) to match the BMM150 / BMI fusion library.
public struct Quaternion: Sendable, Equatable {
    /// Real (scalar) component.
    public let w: Float
    public let x: Float
    public let y: Float
    public let z: Float
    public init(w: Float, x: Float, y: Float, z: Float) { self.w = w; self.x = x; self.y = y; self.z = z }
}

/// Orientation expressed as Euler angles by the sensor-fusion algorithm.
///
/// All four fields are in degrees. `heading` is the magnetometer-anchored compass
/// heading (0–360°); `yaw` is the gyroscope-integrated rotation about the vertical
/// axis (unbounded). Pitch and roll follow the standard aerospace convention.
public struct EulerAngles: Sendable, Equatable {
    /// Magnetometer-anchored compass heading, 0..360°.
    public let heading: Float
    /// Pitch about the device's lateral axis, -90..+90°.
    public let pitch: Float
    /// Roll about the device's longitudinal axis, -180..+180°.
    public let roll: Float
    /// Gyroscope-integrated rotation about the vertical axis. Unbounded; drifts
    /// without magnetometer correction.
    public let yaw: Float
    public init(heading: Float, pitch: Float, roll: Float, yaw: Float) {
        self.heading = heading; self.pitch = pitch; self.roll = roll; self.yaw = yaw
    }
}

/// A 3-axis floating-point vector paired with the fusion algorithm's
/// confidence in its calibration.
///
/// Produced by sensor-fusion outputs that report calibration accuracy alongside
/// magnitude (corrected-acceleration, corrected-angular-velocity, corrected-magnetic-field).
public struct CorrectedCartesianFloat: Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float
    /// Calibration accuracy reported by the fusion algorithm:
    /// `0` = uncalibrated, `1` = low, `2` = medium, `3` = high.
    public let accuracy: UInt8
    public init(x: Float, y: Float, z: Float, accuracy: UInt8) {
        self.x = x; self.y = y; self.z = z; self.accuracy = accuracy
    }
}

/// The board's battery state, returned by `MWSettings.ReadBatteryState`.
public struct BatteryState: Sendable {
    /// Battery voltage in millivolts (a fully charged LiPo reads ~4200 mV).
    public let voltage: UInt16  // mV
    /// Remaining capacity as a percentage, 0–100.
    public let charge: UInt8    // %
}

// MARK: - Frequency

/// A bidirectional Hz ↔ ms value type, used to express sensor output data rates
/// without forcing callers to pick a unit.
///
/// Prefer the named constants (`MWFrequency.hz100`, etc.) where they exist.
public struct MWFrequency: Sendable, CustomStringConvertible {
    /// The frequency in hertz.
    public let hz: Double

    /// The period in milliseconds, derived from `hz`.
    public var periodMs: Double { 1000.0 / hz }

    /// Initialise from a frequency in hertz.
    public init(hz: Double) {
        self.hz = hz
    }

    /// Initialise from a period in milliseconds.
    public init(periodMs: Double) {
        self.hz = 1000.0 / periodMs
    }

    public var description: String { "\(hz) Hz" }

    public static let hz12_5  = MWFrequency(hz: 12.5)
    public static let hz25    = MWFrequency(hz: 25)
    public static let hz50    = MWFrequency(hz: 50)
    public static let hz100   = MWFrequency(hz: 100)
    public static let hz200   = MWFrequency(hz: 200)
    public static let hz400   = MWFrequency(hz: 400)
    public static let hz800   = MWFrequency(hz: 800)
    public static let hz1600  = MWFrequency(hz: 1600)
}

// MARK: - Device information

/// The board's identity, read from the standard BLE Device Information service
/// (`0x180A`) during `connect()`.
///
/// All fields are populated from the corresponding 16-bit GATT characteristic.
/// The model derived from `modelNumber` is available via `MWDeviceInformation.model`
/// (see `MWModel.swift`).
public struct MWDeviceInformation: Sendable, Equatable, Codable {
    /// Manufacturer Name String (`0x2A29`). "MbientLab Inc" on genuine boards.
    public let manufacturer: String
    /// Model Number String (`0x2A24`). Decoded via `MWModel(modelNumber:)`.
    public let modelNumber: String
    /// Serial Number String (`0x2A25`).
    public let serialNumber: String
    /// Firmware Revision String (`0x2A26`), e.g. `"1.7.3"`.
    public let firmwareRevision: String
    /// Hardware Revision String (`0x2A27`), e.g. `"r0.4"` or `"0.4"`.
    public let hardwareRevision: String

    public init(manufacturer: String,
                modelNumber: String,
                serialNumber: String,
                firmwareRevision: String,
                hardwareRevision: String) {
        self.manufacturer = manufacturer
        self.modelNumber = modelNumber
        self.serialNumber = serialNumber
        self.firmwareRevision = firmwareRevision
        self.hardwareRevision = hardwareRevision
    }
}

// MARK: - Module info (from board discovery)

/// One row from the board's module discovery handshake.
///
/// Built from the response to `[module_id, 0x80]`. Cached on the `MetaWearDevice`
/// after `connect()` and serialised into `MWBoardState` for fast reconnect.
public struct MWModuleInfo: Sendable, Equatable, Codable {
    /// The module the board reported for this opcode.
    public let module: MWModule
    /// Implementation byte — the specific hardware revision of the module.
    /// `0xFF` is the firmware's sentinel for "module not present" (see `isPresent`).
    /// For accelerometer / gyroscope this distinguishes BMI160 (0) from BMI270 (1).
    public let implementation: UInt8
    /// Revision byte. Several modules guard feature availability on a minimum
    /// revision (e.g. Settings rev 3 for battery reads, Logging rev 3 for MMS flush).
    public let revision: UInt8
    /// Extra bytes following `[module, 0x80, impl, rev]` in the board's discovery
    /// response. Used by several modules (Logging, Temperature multi-channel, GPIO
    /// pin map, DataProcessor processor-list, Timer, SensorFusion algorithm versions,
    /// Macro reset-on-boot). Empty for modules that return only impl+rev.
    public let extra: [UInt8]

    /// `true` when the firmware reports this module exists on the board.
    /// Modules with `implementation == 0xFF` are absent and must not be commanded.
    public var isPresent: Bool { implementation != 0xFF }

    public init(module: MWModule, implementation: UInt8, revision: UInt8, extra: [UInt8] = []) {
        self.module = module
        self.implementation = implementation
        self.revision = revision
        self.extra = extra
    }
}

// MARK: - MWModule Codable

extension MWModule: Codable {}
