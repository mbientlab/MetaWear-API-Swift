import Foundation

// MARK: - Humidity (BME280)
//
// Mirrors C++ `humidity_bme280.{h,cpp}`. The humidity module (0x16) is only
// present on MetaEnvironment boards, which carry a BME280 chip exposing
// relative humidity as a BME280_HUMIDITY fixed-point value (raw UInt32 / 1024).
//
// Registers:
//   HUMIDITY = 0x01   one-shot read (read bit → 0x81)
//   MODE     = 0x02   set oversampling mode
//
// Legacy Combine SDK called this `MWHumidity` (with alias "Hygrometer"). The
// Swift 6 SDK keeps the `MWHumidity` name; module-id discovery uses the 0x16
// opcode as `MWModule.humidity`.

// MARK: - Oversampling (matches C++ `MblMwHumidityBme280Oversampling`)

public extension MWHumidity {
    /// Humidity oversampling mode. Raw values match the C++
    /// `MBL_MW_HUMIDITY_BME280_OVERSAMPLING_*` constants (sequential 1–5).
    enum Oversampling: UInt8, Sendable, CaseIterable {
        case x1  = 1
        case x2  = 2
        case x4  = 3
        case x8  = 4
        case x16 = 5
    }
}

// MARK: - MWReadable humidity

/// One-shot read of the BME280 relative-humidity signal.
///
/// Usage:
/// ```swift
/// let percent = try await device.readHumidity()
/// ```
///
/// Or as a drop-in `MWReadable` in a generic read pipeline:
/// ```swift
/// let reader = MWHumidity()
/// let packet = try await device.sendRead(
///     command: reader.readCommand,
///     awaitModule: .humidity, awaitRegister: 0x01
/// )
/// let percent = try reader.parseSample(from: packet)
/// ```
public struct MWHumidity: MWReadable {
    public typealias Sample = Float   // relative humidity, %

    public init() {}

    // MARK: MWSensor

    public let module: MWModule = .humidity
    public let dataRegister: UInt8 = 0x01
    public let packedDataRegister: UInt8? = nil

    // MARK: MWReadable

    /// `[0x16, 0x81]` — register 0x01 with the read bit set.
    public var readCommand: Data { MWPacket.read(.humidity, 0x01) }

    public func parseSample(from packet: Data) throws -> Float {
        try MWPacketParser.parseHumidity(packet)
    }
}

// MARK: - MWPolledLoggable
//
// BME280 humidity read response is `[module=0x16, register=0x81, b0,b1,b2,b3]`
// — four bytes of payload after the BLE header (UInt32 LE raw / 1024). One
// 4-byte log chunk fills exactly one flash entry.
extension MWHumidity: MWPolledLoggable {
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(offset: 0, length: 4)]
    }
}

// MARK: - Set oversampling command
//
// Mirrors C++ `mbl_mw_humidity_bme280_set_oversampling`.
//   register 0x02, payload [oversampling_raw]

/// Configure the humidity sensor's oversampling mode.
///
/// Python reference vectors (from `test_humidity_bme280.py`):
/// ```
/// _1X  → [0x16, 0x02, 0x01]
/// _2X  → [0x16, 0x02, 0x02]
/// _4X  → [0x16, 0x02, 0x03]
/// _8X  → [0x16, 0x02, 0x04]
/// _16X → [0x16, 0x02, 0x05]
/// ```
public struct MWHumiditySetOversampling: MWCommand, Sendable {
    public let oversampling: MWHumidity.Oversampling

    public init(oversampling: MWHumidity.Oversampling) {
        self.oversampling = oversampling
    }

    public var commandData: Data {
        MWPacket.command(.humidity, 0x02, [oversampling.rawValue])
    }
}

// MARK: - MetaWearDevice humidity convenience

public extension MetaWearDevice {

    /// Read the current relative humidity from the BME280 sensor.
    /// - Returns: Relative humidity as a percentage (0–100).
    /// - Throws: `MWError.operationFailed` if the humidity module is not present
    ///   or the response packet is malformed.
    func readHumidity() async throws -> Float {
        let reader = MWHumidity()
        let packet = try await sendRead(
            command: reader.readCommand,
            awaitModule: .humidity, awaitRegister: 0x01
        )
        return try reader.parseSample(from: packet)
    }

    /// Set the BME280 humidity oversampling mode.
    /// Higher oversampling reduces noise at the cost of measurement latency.
    func setHumidityOversampling(_ oversampling: MWHumidity.Oversampling) async throws {
        try await send(MWHumiditySetOversampling(oversampling: oversampling))
    }
}
