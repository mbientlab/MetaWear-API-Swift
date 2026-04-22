import Foundation

// MARK: - Barometer (BMP280 / BME280)
//
// Mirrors C++ `barometer_bosch.{h,cpp}`. Both chips share the same register map
// and configuration encoding — they differ only in the physical meaning of
// standby indices 6 and 7:
//   * BMP280 → 2000 ms / 4000 ms
//   * BME280 →   10 ms /   20 ms
//
// The `BoschBaroConfig` bitfield on the device (per `barometer_bosch.cpp`):
//
//   byte 0: [xx][p-os:3][t-os:3]
//   byte 1: [xx][iir:3][standby:3]
//
// where `t-os` (temperature oversampling) is kept at `ULTRA_LOW_POWER` (1)
// except when pressure oversampling is `ULTRA_HIGH`, in which case it is set
// to `LOW_POWER` (2).

public struct MWBarometer: MWStreamable {
    public typealias Sample = Float   // Pascals

    /// Chip variant. Matches C++ `MBL_MW_MODULE_BARO_TYPE_*` constants — these
    /// show up in `moduleInfo(for: .barometer)?.implementation`.
    public enum Variant: UInt8, Sendable, CaseIterable {
        case bmp280 = 0
        case bme280 = 1
    }

    /// Pressure oversampling. Temperature oversampling is derived automatically
    /// (ULTRA_LOW_POWER, or LOW_POWER when this is `ultraHigh`).
    public enum Oversampling: UInt8, Sendable, CaseIterable {
        case skip = 0, ultraLowPower, lowPower, standard, high, ultraHigh
    }

    public enum IIRFilter: UInt8, Sendable, CaseIterable {
        case off = 0, avg2, avg4, avg8, avg16
    }

    /// Standby time indices on the BMP280. Raw values 0-7.
    public enum BMPStandbyTime: UInt8, Sendable, CaseIterable {
        case ms0_5 = 0, ms62_5, ms125, ms250, ms500, ms1000, ms2000, ms4000

        public var ms: Double {
            [0.5, 62.5, 125, 250, 500, 1000, 2000, 4000][Int(rawValue)]
        }
    }

    /// Standby time indices on the BME280. Indices 6/7 diverge from BMP280.
    public enum BMEStandbyTime: UInt8, Sendable, CaseIterable {
        case ms0_5 = 0, ms62_5, ms125, ms250, ms500, ms1000, ms10, ms20

        public var ms: Double {
            [0.5, 62.5, 125, 250, 500, 1000, 10, 20][Int(rawValue)]
        }
    }

    public let oversampling: Oversampling
    public let iirFilter: IIRFilter
    /// Raw standby-time index (0-7). Interpretation depends on chip variant.
    public let standbyRaw: UInt8
    public let variant: Variant?

    /// Configure for a BMP280.
    public init(
        oversampling: Oversampling = .standard,
        iirFilter: IIRFilter = .off,
        standbyTime: BMPStandbyTime = .ms0_5
    ) {
        self.oversampling = oversampling
        self.iirFilter    = iirFilter
        self.standbyRaw   = standbyTime.rawValue
        self.variant      = .bmp280
    }

    /// Configure for a BME280.
    public init(
        oversampling: Oversampling,
        iirFilter: IIRFilter,
        bmeStandbyTime: BMEStandbyTime
    ) {
        self.oversampling = oversampling
        self.iirFilter    = iirFilter
        self.standbyRaw   = bmeStandbyTime.rawValue
        self.variant      = .bme280
    }

    // MARK: MWSensor

    public let module: MWModule = .barometer
    public let dataRegister: UInt8 = 0x01           // PRESSURE
    public let packedDataRegister: UInt8? = nil

    // MARK: MWStreamable

    public var configureCommands: [Data] {
        // Temperature oversampling mirrors C++ `mbl_mw_baro_bosch_set_oversampling`:
        // default ULTRA_LOW_POWER (1); LOW_POWER (2) when pressure == ULTRA_HIGH.
        let tempOS: UInt8 = (oversampling == .ultraHigh) ? 2 : 1
        let byte0: UInt8 = (oversampling.rawValue << 2) | (tempOS << 5)
        let byte1: UInt8 = (iirFilter.rawValue << 2) | (standbyRaw << 5)
        return [MWPacket.command(.barometer, 0x03, [byte0, byte1])]
    }

    public var enableCommand:  Data { MWPacket.command(.barometer, 0x04, [0x01, 0x01]) }
    public var startCommand:   Data { MWPacket.command(.barometer, 0x04, [0x01, 0x01]) }
    public var stopCommand:    Data { MWPacket.command(.barometer, 0x04, [0x00, 0x00]) }
    public var disableCommand: Data { MWPacket.command(.barometer, 0x04, [0x00, 0x00]) }

    public func parseSample(from packet: Data) throws -> Float {
        try MWPacketParser.parsePressure(packet)
    }
}

// MARK: - Altitude signal (same hardware, different register)

public struct MWAltimeter: MWStreamable {
    public typealias Sample = Float   // Meters

    public let barometerConfig: MWBarometer

    public init(config: MWBarometer = MWBarometer()) {
        self.barometerConfig = config
    }

    public let module: MWModule = .barometer
    public let dataRegister: UInt8 = 0x02           // ALTITUDE
    public let packedDataRegister: UInt8? = nil

    public var configureCommands: [Data] { barometerConfig.configureCommands }
    public var enableCommand:  Data { barometerConfig.enableCommand }
    public var startCommand:   Data { barometerConfig.startCommand }
    public var stopCommand:    Data { barometerConfig.stopCommand }
    public var disableCommand: Data { barometerConfig.disableCommand }

    public func parseSample(from packet: Data) throws -> Float {
        try MWPacketParser.parseAltitude(packet)
    }
}

// MARK: - One-shot pressure read
//
// Mirrors C++ `mbl_mw_baro_bosch_get_pressure_read_data_signal`. Same register
// as streaming pressure (0x01), but with the READ bit set — the firmware
// returns a single sample rather than enabling cyclic notifications.

public struct MWBarometerPressureRead: MWReadable {
    public typealias Sample = Float   // Pascals

    public init() {}

    public let module: MWModule = .barometer
    public let dataRegister: UInt8 = 0x01
    public let packedDataRegister: UInt8? = nil

    public var readCommand: Data { MWPacket.read(.barometer, 0x01) }

    public func parseSample(from packet: Data) throws -> Float {
        try MWPacketParser.parsePressure(packet)
    }
}
