import Foundation

// MARK: - Ambient Light (LTR329)
//
// Mirrors C++ `ambientlight_ltr329.{h,cpp}`. The ambient-light module (0x14)
// is present on MetaWear RPro / MotionR boards, wrapping a Lite-On LTR329ALS
// ambient-light sensor.
//
// Registers:
//   ENABLE = 0x01    start/stop sampling
//   CONFIG = 0x02    gain / integration-time / measurement-rate bitfield
//   OUTPUT = 0x03    UINT32 illuminance stream
//
// C++ config bitfield (`Ltr329Config`) packs into two bytes:
//   byte 0: bits 2-4 = als_gain     (bits 0-1, 5-7 reserved)
//   byte 1: bits 0-2 = als_measurement_rate
//           bits 3-5 = als_integration_time (bits 6-7 reserved)
//
// Gain encoding has a two-slot gap per the LTR329 datasheet: enum values 0-3
// map directly, but 48X / 96X map to 6 / 7 respectively (C++ adds +2).

public struct MWAmbientLight: MWStreamable {
    public typealias Sample = UInt32   // raw illuminance (milli-lux). Divide by 1000 for lux.

    // MARK: - Gain

    /// LTR329 illuminance gain. Raw values match C++ `MblMwAlsLtr329Gain`
    /// (dense 0-5); the hardware register skips 4-5 and encodes 48X / 96X
    /// as 6 / 7, which `configByte0` handles.
    public enum Gain: UInt8, Sendable, CaseIterable {
        case x1  = 0    ///< [1, 64 k] lux (default)
        case x2  = 1    ///< [0.5, 32 k] lux
        case x4  = 2    ///< [0.25, 16 k] lux
        case x8  = 3    ///< [0.125, 8 k] lux
        case x48 = 4    ///< [0.02, 1.3 k] lux
        case x96 = 5    ///< [0.01, 600] lux

        /// Encoded value for the LTR329 `als_gain` bitfield (3 bits, bits 2-4 of byte 0).
        var registerValue: UInt8 {
            switch self {
            case .x48: return 6
            case .x96: return 7
            default:   return rawValue
            }
        }
    }

    // MARK: - Integration time

    /// Measurement time for each full ALS cycle.
    /// Raw values match C++ `MblMwAlsLtr329IntegrationTime` (enum order is not
    /// sorted by milliseconds on purpose — 100 ms is the default at index 0).
    public enum IntegrationTime: UInt8, Sendable, CaseIterable {
        case ms100 = 0  ///< Default
        case ms50  = 1
        case ms200 = 2
        case ms400 = 3
        case ms150 = 4
        case ms250 = 5
        case ms300 = 6
        case ms350 = 7

        public var milliseconds: Int {
            [100, 50, 200, 400, 150, 250, 300, 350][Int(rawValue)]
        }
    }

    // MARK: - Measurement rate

    /// How frequently the illuminance register is updated.
    /// Raw values match C++ `MblMwAlsLtr329MeasurementRate`.
    public enum MeasurementRate: UInt8, Sendable, CaseIterable {
        case ms50   = 0
        case ms100  = 1
        case ms200  = 2
        case ms500  = 3  ///< Default
        case ms1000 = 4
        case ms2000 = 5

        public var milliseconds: Int {
            [50, 100, 200, 500, 1000, 2000][Int(rawValue)]
        }
    }

    // MARK: - Configuration

    public let gain: Gain
    public let integrationTime: IntegrationTime
    public let measurementRate: MeasurementRate

    /// Default matches the C++ init (`als_measurement_rate = 500ms`, others 0).
    public init(
        gain: Gain = .x1,
        integrationTime: IntegrationTime = .ms100,
        measurementRate: MeasurementRate = .ms500
    ) {
        self.gain = gain
        self.integrationTime = integrationTime
        self.measurementRate = measurementRate
    }

    // MARK: - MWSensor

    public let module: MWModule = .ambientLight
    public let dataRegister: UInt8 = 0x03       // OUTPUT
    public let packedDataRegister: UInt8? = nil

    // MARK: - MWStreamable

    /// Config byte 0: gain in bits 2-4 (`gain.registerValue << 2`).
    var configByte0: UInt8 { gain.registerValue << 2 }

    /// Config byte 1: measurement rate in bits 0-2, integration time in bits 3-5.
    var configByte1: UInt8 {
        measurementRate.rawValue | (integrationTime.rawValue << 3)
    }

    public var configureCommands: [Data] {
        [MWPacket.command(.ambientLight, 0x02, [configByte0, configByte1])]
    }

    /// The LTR329 module has no separate enable/disable interrupt — the start
    /// command doubles as enable. Keep `enableCommand` as a no-op so the
    /// streaming pipeline can emit it harmlessly.
    public var enableCommand: Data { Data() }
    public var disableCommand: Data { Data() }

    public var startCommand: Data { MWPacket.command(.ambientLight, 0x01, [0x01]) }
    public var stopCommand:  Data { MWPacket.command(.ambientLight, 0x01, [0x00]) }

    public func parseSample(from packet: Data) throws -> UInt32 {
        try MWPacketParser.parseIlluminanceRaw(packet)
    }
}

// MARK: - Convenience

public extension MWAmbientLight {
    /// Convert a raw illuminance sample (milli-lux) to lux.
    static func lux(from raw: UInt32) -> Float {
        Float(raw) / 1000.0
    }
}

// MARK: - One-shot configure command
//
// Mirrors C++ `mbl_mw_als_ltr329_write_config`. Useful when the caller owns an
// `MWAmbientLight` value and wants to emit just the CONFIG write (without the
// start/stop lifecycle).
public struct MWAmbientLightWriteConfig: MWCommand, Sendable {
    public let config: MWAmbientLight
    public init(_ config: MWAmbientLight) { self.config = config }
    public var commandData: Data {
        MWPacket.command(.ambientLight, 0x02, [config.configByte0, config.configByte1])
    }
}
