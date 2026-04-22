import Foundation

// MARK: - Magnetometer (BMM150)

public struct MWMagnetometer: MWLoggable {
    public typealias Sample = CartesianFloat

    /// Preset power modes recommended by Bosch.
    /// Mirrors C++ `MblMwMagBmm150Preset`.
    public enum Preset: Sendable, CaseIterable {
        case lowPower           // 10 Hz, 170 µA, ~1.0 µT noise (recommended for most use cases)
        case regular            // 10 Hz, 0.5 mA, 0.6 µT
        case enhancedRegular    // 10 Hz, 0.8 mA, 0.5 µT
        case highAccuracy       // 20 Hz, 4.9 mA, 0.3 µT

        var xyReps: UInt8 { [3, 9, 15, 47][index] }
        var zReps:  UInt8 { [3, 15, 27, 83][index] }
        var odr:    ODR   { [.hz10, .hz10, .hz10, .hz20][index] }

        private var index: Int {
            switch self {
            case .lowPower: return 0
            case .regular: return 1
            case .enhancedRegular: return 2
            case .highAccuracy: return 3
            }
        }
    }

    /// Output data rate. Raw values match C++ `MblMwMagBmm150Odr`.
    public enum ODR: UInt8, Sendable, CaseIterable {
        case hz10 = 0
        case hz2  = 1
        case hz6  = 2
        case hz8  = 3
        case hz15 = 4
        case hz20 = 5
        case hz25 = 6
        case hz30 = 7

        public var hz: Double {
            [10, 2, 6, 8, 15, 20, 25, 30][Int(rawValue)]
        }
    }

    public let xyReps: UInt8
    public let zReps: UInt8
    public let odr: ODR
    public let preset: Preset?

    /// Configure from a recommended preset.
    public init(preset: Preset = .lowPower) {
        self.preset = preset
        self.xyReps = preset.xyReps
        self.zReps  = preset.zReps
        self.odr    = preset.odr
    }

    /// Manual configuration, mirrors C++ `mbl_mw_mag_bmm150_configure`.
    /// - Parameters:
    ///   - xyReps: Repetitions on the x/y axis (will be encoded as `(xyReps - 1) / 2`)
    ///   - zReps: Repetitions on the z axis (will be encoded as `zReps - 1`)
    ///   - odr: Output data rate
    public init(xyReps: UInt8, zReps: UInt8, odr: ODR) {
        self.preset = nil
        self.xyReps = xyReps
        self.zReps  = zReps
        self.odr    = odr
    }

    // MARK: MWSensor

    public let module: MWModule = .magnetometer
    public let dataRegister: UInt8 = 0x05           // MAG_DATA
    public let packedDataRegister: UInt8? = 0x09    // PACKED_MAG_DATA (revision >= 1)

    static let scale: Float = 16.0                  // 16 LSB/µT

    // MARK: MWStreamable

    public var configureCommands: [Data] {
        // XY reps byte = (xy_reps - 1) / 2, Z reps byte = z_reps - 1
        let xyByte = (xyReps - 1) / 2
        let zByte  = zReps - 1
        return [
            MWPacket.command(.magnetometer, 0x04, [xyByte, zByte]),
            MWPacket.command(.magnetometer, 0x03, [odr.rawValue])
        ]
    }

    public var enableCommand:  Data { MWPacket.command(.magnetometer, 0x02, [0x01, 0x00]) }
    public var startCommand:   Data { MWPacket.command(.magnetometer, 0x01, [0x01]) }
    public var stopCommand:    Data { MWPacket.command(.magnetometer, 0x01, [0x00]) }
    public var disableCommand: Data { MWPacket.command(.magnetometer, 0x02, [0x00, 0x01]) }

    public let loggerKey = "magnetic-field"

    public func parseSample(from packet: Data) throws -> CartesianFloat {
        try MWPacketParser.parseCartesianFloat(packet, scale: MWMagnetometer.scale)
    }

    public func parsePackedSamples(from packet: Data) throws -> [CartesianFloat] {
        try MWPacketParser.parsePackedCartesianFloat(packet, scale: MWMagnetometer.scale)
    }

    // MARK: Suspend
    //
    // Mirrors C++ `mbl_mw_mag_bmm150_suspend`.
    // Writes POWER_MODE = 2. The C++ implementation gates this on revision >= 2
    // (SUSPEND_REVISION); when the revision is lower, the command is silently
    // dropped. Callers are expected to check `moduleInfo(for:.magnetometer)?.revision`
    // before sending this command.
    public struct Suspend: MWCommand {
        public init() {}
        public var commandData: Data {
            MWPacket.command(.magnetometer, 0x01, 0x02)
        }
    }

    // MARK: Configure
    //
    // Mirrors C++ `mbl_mw_mag_bmm150_configure`. Allows fully manual control
    // of xy/z repetitions and ODR, bypassing the preset helper.
    public struct Configure: MWCommand {
        public let xyReps: UInt8
        public let zReps: UInt8
        public let odr: ODR

        public init(xyReps: UInt8, zReps: UInt8, odr: ODR) {
            self.xyReps = xyReps
            self.zReps  = zReps
            self.odr    = odr
        }

        public var commandData: Data {
            // Single Data containing both register writes concatenated.
            let xyByte = (xyReps - 1) / 2
            let zByte  = zReps - 1
            return MWPacket.command(.magnetometer, 0x04, [xyByte, zByte])
                 + MWPacket.command(.magnetometer, 0x03, [odr.rawValue])
        }
    }
}
