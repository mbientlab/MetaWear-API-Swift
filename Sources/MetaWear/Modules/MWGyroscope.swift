import Foundation

// MARK: - Gyroscope (BMI160 / BMI270)
// Both chips use the same config encoding; only the register map and data register differ.

public struct MWGyroscopeBMI160: MWLoggable {
    public typealias Sample = CartesianFloat

    public enum ODR: UInt8, Sendable, CaseIterable {
        // Raw enum values match MblMwGyroBoschOdr (starts at 6)
        case hz25   = 6
        case hz50   = 7
        case hz100  = 8
        case hz200  = 9
        case hz400  = 10
        case hz800  = 11
        case hz1600 = 12
        case hz3200 = 13

        public var hz: Double {
            [6: 25, 7: 50, 8: 100, 9: 200, 10: 400, 11: 800, 12: 1600, 13: 3200][rawValue]!
        }
    }

    public enum Range: UInt8, Sendable, CaseIterable {
        case dps2000 = 0, dps1000, dps500, dps250, dps125

        public var scale: Float { [16.4, 32.8, 65.6, 131.2, 262.4][Int(rawValue)] }

        /// Full-scale range in degrees per second.
        public var rangeDPS: Float { [2000, 1000, 500, 250, 125][Int(rawValue)] }
    }

    public let odr: ODR
    public let range: Range

    public init(odr: ODR = .hz100, range: Range = .dps2000) {
        self.odr = odr
        self.range = range
    }

    // MARK: MWSensor

    public let module: MWModule = .gyro
    public let dataRegister: UInt8 = 0x05           // DATA (BMI160)
    public let packedDataRegister: UInt8? = 0x07    // PACKED_GYRO_DATA (BMI160)

    // MARK: MWStreamable

    public var configureCommands: [Data] {
        let bwp: UInt8 = 2
        let confByte: UInt8 = (bwp << 4) | odr.rawValue
        return [MWPacket.command(.gyro, 0x03, [confByte, range.rawValue])]
    }

    public var enableCommand:  Data { MWPacket.command(.gyro, 0x02, [0x01, 0x00]) }
    public var startCommand:   Data { MWPacket.command(.gyro, 0x01, [0x01]) }
    public var stopCommand:    Data { MWPacket.command(.gyro, 0x01, [0x00]) }
    public var disableCommand: Data { MWPacket.command(.gyro, 0x02, [0x00, 0x01]) }

    public let loggerKey = "angular-velocity"

    public func parseSample(from packet: Data) throws -> CartesianFloat {
        try MWPacketParser.parseCartesianFloat(packet, scale: range.scale)
    }

    public func parsePackedSamples(from packet: Data) throws -> [CartesianFloat] {
        try MWPacketParser.parsePackedCartesianFloat(packet, scale: range.scale)
    }
}

// MARK: BMI270

public struct MWGyroscopeBMI270: MWLoggable {
    public typealias Sample = CartesianFloat

    public typealias ODR   = MWGyroscopeBMI160.ODR
    public typealias Range = MWGyroscopeBMI160.Range

    public let odr: ODR
    public let range: Range

    public init(odr: ODR = .hz100, range: Range = .dps2000) {
        self.odr = odr
        self.range = range
    }

    // MARK: MWSensor

    public let module: MWModule = .gyro
    public let dataRegister: UInt8 = 0x04           // DATA (BMI270)
    public let packedDataRegister: UInt8? = 0x05    // PACKED_GYRO_DATA (BMI270)

    // MARK: MWStreamable

    public var configureCommands: [Data] {
        let bwp: UInt8 = 2
        let confByte: UInt8 = (bwp << 4) | odr.rawValue
        return [MWPacket.command(.gyro, 0x03, [confByte, range.rawValue])]
    }

    public var enableCommand:  Data { MWPacket.command(.gyro, 0x02, [0x01, 0x00]) }
    public var startCommand:   Data { MWPacket.command(.gyro, 0x01, [0x01]) }
    public var stopCommand:    Data { MWPacket.command(.gyro, 0x01, [0x00]) }
    public var disableCommand: Data { MWPacket.command(.gyro, 0x02, [0x00, 0x01]) }

    public let loggerKey = "angular-velocity"

    public func parseSample(from packet: Data) throws -> CartesianFloat {
        try MWPacketParser.parseCartesianFloat(packet, scale: range.scale)
    }

    public func parsePackedSamples(from packet: Data) throws -> [CartesianFloat] {
        try MWPacketParser.parsePackedCartesianFloat(packet, scale: range.scale)
    }

    // MARK: BMI270 offsets
    //
    // Mirrors C++ `mbl_mw_gyro_bmi270_offsets(board, x, y, z)`.
    // Writes signed offsets to OFFSET register 0x06.
    public struct Offsets: MWCommand {
        public let x: UInt8
        public let y: UInt8
        public let z: UInt8
        public init(x: UInt8, y: UInt8, z: UInt8) {
            self.x = x; self.y = y; self.z = z
        }
        public var commandData: Data {
            MWPacket.command(.gyro, 0x06, x, y, z)
        }
    }
}

// MARK: - Type-erased gyroscope (chosen at runtime from module info)

public enum MWGyroscope: Sendable {
    case bmi160(MWGyroscopeBMI160)
    case bmi270(MWGyroscopeBMI270)

    public static func make(
        impl: UInt8,
        odrHz: Double = 100,
        rangeDPS: Float = 2000
    ) -> MWGyroscope? {
        switch impl {
        case 0:  // BMI160
            let odr   = MWGyroscopeBMI160.ODR.allCases.min { abs($0.hz - odrHz) < abs($1.hz - odrHz) }!
            let range = MWGyroscopeBMI160.Range.allCases.min { abs($0.rangeDPS - rangeDPS) < abs($1.rangeDPS - rangeDPS) } ?? .dps2000
            return .bmi160(MWGyroscopeBMI160(odr: odr, range: range))
        case 1:  // BMI270
            let odr   = MWGyroscopeBMI270.ODR.allCases.min { abs($0.hz - odrHz) < abs($1.hz - odrHz) }!
            let range = MWGyroscopeBMI270.Range.allCases.min { abs($0.rangeDPS - rangeDPS) < abs($1.rangeDPS - rangeDPS) } ?? .dps2000
            return .bmi270(MWGyroscopeBMI270(odr: odr, range: range))
        default:
            return nil
        }
    }

    /// Actual ODR after snapping to nearest supported value.
    public var odrHz: Double {
        switch self {
        case .bmi160(let s): return s.odr.hz
        case .bmi270(let s): return s.odr.hz
        }
    }

    /// Actual range after snapping to nearest supported value (dps).
    public var rangeDPS: Float {
        switch self {
        case .bmi160(let s): return s.range.rangeDPS
        case .bmi270(let s): return s.range.rangeDPS
        }
    }

    @discardableResult
    public func withODR(_ odrHz: Double) -> MWGyroscope {
        switch self {
        case .bmi160(let s):
            let odr = MWGyroscopeBMI160.ODR.allCases.min { abs($0.hz - odrHz) < abs($1.hz - odrHz) }!
            return .bmi160(MWGyroscopeBMI160(odr: odr, range: s.range))
        case .bmi270(let s):
            let odr = MWGyroscopeBMI270.ODR.allCases.min { abs($0.hz - odrHz) < abs($1.hz - odrHz) }!
            return .bmi270(MWGyroscopeBMI270(odr: odr, range: s.range))
        }
    }

    @discardableResult
    public func withRange(_ rangeDPS: Float) -> MWGyroscope {
        switch self {
        case .bmi160(let s):
            let range = MWGyroscopeBMI160.Range.allCases.min { abs($0.rangeDPS - rangeDPS) < abs($1.rangeDPS - rangeDPS) } ?? .dps2000
            return .bmi160(MWGyroscopeBMI160(odr: s.odr, range: range))
        case .bmi270(let s):
            let range = MWGyroscopeBMI270.Range.allCases.min { abs($0.rangeDPS - rangeDPS) < abs($1.rangeDPS - rangeDPS) } ?? .dps2000
            return .bmi270(MWGyroscopeBMI270(odr: s.odr, range: range))
        }
    }
}

// MARK: - MWLoggable conformance (forwards to chip)

extension MWGyroscope: MWLoggable {
    public typealias Sample = CartesianFloat

    public var module: MWModule { .gyro }

    public var dataRegister: UInt8 {
        switch self {
        case .bmi160(let s): return s.dataRegister
        case .bmi270(let s): return s.dataRegister
        }
    }

    public var packedDataRegister: UInt8? {
        switch self {
        case .bmi160(let s): return s.packedDataRegister
        case .bmi270(let s): return s.packedDataRegister
        }
    }

    public var configureCommands: [Data] {
        switch self {
        case .bmi160(let s): return s.configureCommands
        case .bmi270(let s): return s.configureCommands
        }
    }

    public var enableCommand: Data {
        switch self {
        case .bmi160(let s): return s.enableCommand
        case .bmi270(let s): return s.enableCommand
        }
    }

    public var startCommand: Data {
        switch self {
        case .bmi160(let s): return s.startCommand
        case .bmi270(let s): return s.startCommand
        }
    }

    public var stopCommand: Data {
        switch self {
        case .bmi160(let s): return s.stopCommand
        case .bmi270(let s): return s.stopCommand
        }
    }

    public var disableCommand: Data {
        switch self {
        case .bmi160(let s): return s.disableCommand
        case .bmi270(let s): return s.disableCommand
        }
    }

    public var loggerKey: String { "angular-velocity" }

    public func parseSample(from packet: Data) throws -> CartesianFloat {
        switch self {
        case .bmi160(let s): return try s.parseSample(from: packet)
        case .bmi270(let s): return try s.parseSample(from: packet)
        }
    }

    public func parsePackedSamples(from packet: Data) throws -> [CartesianFloat] {
        switch self {
        case .bmi160(let s): return try s.parsePackedSamples(from: packet)
        case .bmi270(let s): return try s.parsePackedSamples(from: packet)
        }
    }
}
