import Foundation

// MARK: - Timestamped

public struct Timestamped<Value: Sendable>: Sendable {
    public let time: Date
    public let value: Value
}

// MARK: - Download progress

public struct Download<Data: Sendable>: Sendable {
    public let data: Data
    public let percentComplete: Double
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

public struct CartesianFloat: Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float
    public init(x: Float, y: Float, z: Float) { self.x = x; self.y = y; self.z = z }
}

public struct Quaternion: Sendable, Equatable {
    public let w: Float
    public let x: Float
    public let y: Float
    public let z: Float
    public init(w: Float, x: Float, y: Float, z: Float) { self.w = w; self.x = x; self.y = y; self.z = z }
}

public struct EulerAngles: Sendable, Equatable {
    public let heading: Float
    public let pitch: Float
    public let roll: Float
    public let yaw: Float
    public init(heading: Float, pitch: Float, roll: Float, yaw: Float) {
        self.heading = heading; self.pitch = pitch; self.roll = roll; self.yaw = yaw
    }
}

public struct CorrectedCartesianFloat: Sendable, Equatable {
    public let x: Float
    public let y: Float
    public let z: Float
    public let accuracy: UInt8
    public init(x: Float, y: Float, z: Float, accuracy: UInt8) {
        self.x = x; self.y = y; self.z = z; self.accuracy = accuracy
    }
}

public struct BatteryState: Sendable {
    public let voltage: UInt16  // mV
    public let charge: UInt8    // %
}

// MARK: - Frequency

public struct MWFrequency: Sendable, CustomStringConvertible {
    public let hz: Double

    public var periodMs: Double { 1000.0 / hz }

    public init(hz: Double) {
        self.hz = hz
    }

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

public struct MWDeviceInformation: Sendable, Equatable, Codable {
    public let manufacturer: String
    public let modelNumber: String
    public let serialNumber: String
    public let firmwareRevision: String
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

public struct MWModuleInfo: Sendable, Equatable, Codable {
    public let module: MWModule
    public let implementation: UInt8
    public let revision: UInt8
    /// Extra bytes following `[module, 0x80, impl, rev]` in the board's discovery
    /// response. Used by several modules (Logging, Temperature multi-channel, GPIO
    /// pin map, DataProcessor processor-list, Timer, SensorFusion algorithm versions,
    /// Macro reset-on-boot). Empty for modules that return only impl+rev.
    public let extra: [UInt8]

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
