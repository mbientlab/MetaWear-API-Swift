import Foundation

// MARK: - Multi-channel temperature
//
// Mirrors C++ `multichanneltemperature.{h,cpp}`. The temperature module (0x04)
// exposes a variable number of channels, each backed by one of four source
// types. Board layouts vary:
//
//   MetaWear R    (2 channels): [NRF_DIE, EXT_THERM]
//   MetaWear RPro (4 channels): [NRF_DIE, PRESET_THERM, EXT_THERM, BMP280]
//
// Registers:
//   TEMPERATURE = 0x01   read one sample (read bit → 0x81; silent → 0xC1)
//   MODE        = 0x02   configure external thermistor pin mapping

// MARK: - Temperature source enum (matches C++ `MblMwTemperatureSource`)

/// Physical source backing one channel of the multi-channel temperature module.
///
/// Each MetaWear board exposes a fixed number of channels (see `MWThermometer`),
/// and each channel reads from one of these sources. Mirrors C++
/// `MblMwTemperatureSource`.
public enum MWThermometerSource: Int8, Sendable, CaseIterable {
    /// Sentinel for unknown / out-of-range channel indices.
    case invalid          = -1
    /// NRF SoC die temperature (always channel 0).
    case nrfDie           = 0
    /// External thermistor wired to a GPIO pin.
    case extThermistor    = 1
    /// Temperature sensor inside the BMP280 barometer.
    case bmp280           = 2
    /// On-board preset thermistor (RPro only).
    case presetThermistor = 3
}

// MARK: - One-shot channel read (backwards-compatible surface)

/// One-shot temperature read from a specific channel on the temperature module.
/// The physical source at each channel depends on the board — see
/// `MWThermometer.make(channel:source:)` for the verified variant.
public struct MWTemperatureChannel: Sendable {
    /// Thermometer channel index (0–3 depending on board).
    public let channel: UInt8

    public init(channel: UInt8 = 0) {
        self.channel = channel
    }

    /// Read command: `[0x04, 0x81, channel]` (register 0x01 | read bit 0x80).
    public var readCommand: Data {
        Data([MWModule.temperature.rawValue, 0x81, channel])
    }

    /// Silent read command: `[0x04, 0xC1, channel]` (adds the 0x40 silent bit).
    /// Used when issuing a read without an active subscriber — the board
    /// returns the sample exactly once and does not feed the notification
    /// dispatcher.
    public var silentReadCommand: Data {
        Data([MWModule.temperature.rawValue, 0xC1, channel])
    }
}

// MARK: - Temperature channel constants
//
// Convenience aliases for the RPro channel layout. If you are targeting a
// MetaWear R board (2 channels), only `.nrf` and the old `.externalThermistor`
// alias (which is channel 1 on R) apply.

public extension MWTemperatureChannel {
    /// NRF SoC die temperature. Channel 0 on all boards.
    static let nrf = MWTemperatureChannel(channel: 0)

    /// External thermistor. Channel 1 on MetaWear R boards.
    /// On RPro boards the external thermistor is at channel 2 — prefer
    /// `.externalThermistorRPro` there.
    static let externalThermistor = MWTemperatureChannel(channel: 1)

    /// Preset (on-board) thermistor on RPro. Channel 1 on RPro.
    static let presetThermistor = MWTemperatureChannel(channel: 1)

    /// External thermistor on RPro. Channel 2 on RPro.
    static let externalThermistorRPro = MWTemperatureChannel(channel: 2)

    /// BMP280 barometer temperature on RPro. Channel 3.
    static let bmp280 = MWTemperatureChannel(channel: 3)

    /// Legacy alias — prefer `.externalThermistorRPro` or `.presetThermistor`.
    /// Kept for source compatibility. Resolves to channel 2 (RPro ext therm).
    static let bosch = MWTemperatureChannel(channel: 2)
}

// MARK: - MWReadable thermometer
//
// Drop-in `MWReadable` wrapper around a single channel. Use this when you
// want to plug temperature reads into the same read pipeline as other
// `MWReadable` sensors rather than calling `device.readTemperature(channel:)`
// directly.

/// One-shot temperature read from a single channel of the multi-channel
/// temperature module (0x04). Drop-in `MWReadable` wrapper around a channel
/// index; use `silent: true` to issue the read without firing the
/// notification dispatcher.
public struct MWThermometer: MWReadable {
    public typealias Sample = Float   // Celsius

    public let channel: UInt8
    public let silent: Bool

    public init(channel: UInt8, silent: Bool = false) {
        self.channel = channel
        self.silent  = silent
    }

    public let module: MWModule = .temperature
    public let dataRegister: UInt8 = 0x01
    public let packedDataRegister: UInt8? = nil

    public var readCommand: Data {
        // 0x81 = read, 0xC1 = read | silent. Channel ID rides in the payload.
        let register: UInt8 = silent ? 0xC1 : 0x81
        return Data([MWModule.temperature.rawValue, register, channel])
    }

    public func parseSample(from packet: Data) throws -> Float {
        try MWPacketParser.parseTemperature(packet)
    }
}

// MARK: - MWPolledLoggable
//
// Temperature read responses are `[module=0x04, register=0x81, channel, lo, hi]`
// — three bytes of payload after the BLE header: the channel byte plus a signed
// Int16 (Celsius × 8). One 3-byte log chunk fits in a single 4-byte flash entry.
extension MWThermometer: MWPolledLoggable {
    /// Log the 2-byte temperature value at payload offset 0. The firmware
    /// strips the channel data-id byte before logging (the trigger's channel
    /// index already matched it), so the Int16 value IS the payload.
    /// Hardware-verified on MMS fw 1.7.2: offset 1 produced misaligned
    /// values (the high byte plus a garbage byte); offset 0 decodes cleanly.
    public var logDataChunks: [(offset: UInt8, length: UInt8)] {
        [(offset: 0, length: 2)]
    }

    /// The thermometer's responses carry a channel data-id; the logger
    /// trigger must name the channel to match them.
    public var loggerTriggerIndex: UInt8 { channel }

    /// Reassembled log data is the bare Int16 (Celsius × 8) — no channel
    /// byte, so the default header-prepending decode doesn't fit.
    public func parseLogSample(from data: Data) throws -> Float {
        let p = Data(data)
        guard p.count >= 2 else {
            throw MWError.operationFailed("Temperature log chunk too short: \(p.count) bytes")
        }
        return Float(MWPacketParser.parseInt16LE(p, offset: 0)) / 8.0
    }
}

// MARK: - External thermistor configuration
//
// Mirrors C++ `mbl_mw_multi_chnl_temp_configure_ext_thermistor`. Tells the
// firmware which GPIO pin reads the thermistor value and which pin drives
// the pulldown resistor.
//   register 0x02, payload [channel, dataPin, pulldownPin, activeHigh]

/// Command that configures an external thermistor's GPIO pin mapping for one
/// channel of the temperature module. Tells the firmware which pin reads the
/// thermistor voltage and which pin drives the pulldown resistor.
public struct MWThermometerConfigureExt: MWCommand {
    public let channel: UInt8
    public let dataPin: UInt8
    public let pulldownPin: UInt8
    public let activeHigh: Bool

    public init(channel: UInt8, dataPin: UInt8, pulldownPin: UInt8, activeHigh: Bool) {
        self.channel     = channel
        self.dataPin     = dataPin
        self.pulldownPin = pulldownPin
        self.activeHigh  = activeHigh
    }

    public var commandData: Data {
        MWPacket.command(.temperature, 0x02, [channel, dataPin, pulldownPin, activeHigh ? 1 : 0])
    }
}
