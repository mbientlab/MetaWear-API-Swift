import Foundation

// MARK: - Core sensor protocols (pure Swift — no C++ dependencies)

/// A sensor that produces typed samples from raw BLE notification bytes.
public protocol MWSensor: Sendable {
    var module: MWModule { get }
    var dataRegister: UInt8 { get }
    var packedDataRegister: UInt8? { get }
}

/// A sensor that can stream data continuously (~100 Hz max over BLE).
public protocol MWStreamable: MWSensor {
    associatedtype Sample: Sendable

    /// Commands sent once to configure the sensor before streaming.
    var configureCommands: [Data] { get }
    /// Enable the data interrupt / output.
    var enableCommand: Data { get }
    /// Start the sensor hardware.
    var startCommand: Data { get }
    /// Stop the sensor hardware.
    var stopCommand: Data { get }
    /// Disable the data interrupt / output.
    var disableCommand: Data { get }

    /// Multi-command form of `enableCommand`. Override when a sensor needs to
    /// issue more than one BLE write to enable its data path — e.g. sensor
    /// fusion enables interrupts on the underlying acc/gyro/mag chips.
    /// Default: `[enableCommand]` (empty Data filtered out).
    var enableCommands: [Data] { get }

    /// Multi-command form of `startCommand`. Override when a sensor needs
    /// more than one BLE write to start its data path. Default: `[startCommand]`.
    var startCommands: [Data] { get }

    /// Multi-command form of `stopCommand`. Override when a sensor needs more
    /// than one BLE write to stop. Default: `[stopCommand]`.
    var stopCommands: [Data] { get }

    /// Multi-command form of `disableCommand`. Override when a sensor needs
    /// more than one BLE write to disable. Default: `[disableCommand]`.
    var disableCommands: [Data] { get }

    /// Optional commands issued *before* `configureCommands` to wake a
    /// cold-booted sensor out of a suspend/off state. Default: empty.
    var warmupCommands: [Data] { get }

    /// Nanoseconds to sleep after `warmupCommands` and before `configureCommands`.
    /// Default: 0. Override for sensors whose chip needs time to transition
    /// (e.g. BMM150 SUSPEND → SLEEP).
    var warmupDelayNanos: UInt64 { get }

    /// Parse a single XYZ / scalar notification packet into a typed sample.
    func parseSample(from packet: Data) throws -> Sample

    /// Parse a packed notification (3 samples in one BLE packet).
    /// Default implementation returns an empty array (not all sensors support packed mode).
    func parsePackedSamples(from packet: Data) throws -> [Sample]
}

public extension MWStreamable {
    var packedDataRegister: UInt8? { nil }

    var warmupCommands: [Data] { [] }
    var warmupDelayNanos: UInt64 { 0 }

    /// Default: wrap the single Data in an array, dropping empties so a sensor
    /// that has no enable/disable command (e.g. switch) still reports `[]`.
    var enableCommands:  [Data] { enableCommand.isEmpty  ? [] : [enableCommand]  }
    var startCommands:   [Data] { startCommand.isEmpty   ? [] : [startCommand]   }
    var stopCommands:    [Data] { stopCommand.isEmpty    ? [] : [stopCommand]    }
    var disableCommands: [Data] { disableCommand.isEmpty ? [] : [disableCommand] }

    func parsePackedSamples(from packet: Data) throws -> [Sample] { [] }
}

/// A streaming sensor whose data can also be logged to on-device flash.
public protocol MWLoggable: MWStreamable {
    /// Unique string identifying this signal type (e.g. "acceleration", "rotation").
    var loggerKey: String { get }

    /// How to split the sensor's data payload into 4-byte flash entries.
    /// Each element is (byteOffset, byteCount) within the signal's data payload
    /// (i.e. the bytes *after* the 2-byte module/register BLE header).
    /// The MetaWear encodes these as one logger per chunk; during download the
    /// chunks are reassembled in order to reconstruct the full sample.
    var logDataChunks: [(offset: UInt8, length: UInt8)] { get }

    /// Decode one complete sample from the bytes reassembled from all log chunks.
    /// `data` contains exactly `sum(chunk.length)` bytes in chunk order.
    func parseLogSample(from data: Data) throws -> Sample
}

public extension MWLoggable {
    /// Default chunk layout for 6-byte (XYZ int16) sensors: first 4 bytes then last 2.
    var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(offset: 0, length: 4), (offset: 4, length: 2)]
    }

    /// Default decoder: prepend a fake [module, register] header so `parseSample` works normally.
    func parseLogSample(from data: Data) throws -> Sample {
        try parseSample(from: Data([module.rawValue, dataRegister]) + data)
    }
}

/// A sensor that is read once on demand rather than streamed.
public protocol MWReadable: MWSensor {
    associatedtype Sample: Sendable

    /// Command to trigger a read.
    var readCommand: Data { get }

    /// Parse the response packet.
    func parseSample(from packet: Data) throws -> Sample
}

/// A fire-and-forget board command.
public protocol MWCommand: Sendable {
    var commandData: Data { get }
}

/// A fire-and-forget board action that requires more than one BLE write.
///
/// Used by feature enable/disable pairs (e.g. the BMI270 step detector writes
/// both `FEATURE_INTERRUPT_ENABLE` and `FEATURE_ENABLE`) and by long-payload
/// commands that split across multiple registers (e.g. `SetScanResponse`).
/// Pass directly to `device.send(_:)` — writes are issued in order.
public protocol MWCommandSequence: Sendable {
    var commands: [Data] { get }
}

/// A readable sensor that is meaningful to poll on an interval rather than
/// stream. Any `MWReadable` trivially satisfies this — the protocol exists
/// as a marker so `device.poll(_:every:)` can be discovered by type and so
/// individual readables can opt in with a default interval later if needed.
///
/// Pair with `MetaWearDevice.poll(_:every:)` to get an
/// `AsyncThrowingStream<Timestamped<Sample>, Error>`.
public protocol MWPollable: MWReadable {}
