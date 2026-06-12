import Foundation

// MARK: - Module opcodes

public enum MWModule: UInt8, CaseIterable, Sendable {
    case switch_       = 0x01
    case led           = 0x02
    case accelerometer = 0x03
    case temperature   = 0x04
    case gpio          = 0x05
    case iBeacon       = 0x07
    case haptic        = 0x08
    case dataProcessor = 0x09
    case event         = 0x0A
    case logging       = 0x0B
    case timer         = 0x0C
    case serial        = 0x0D
    case macro         = 0x0F
    case settings      = 0x11
    case barometer     = 0x12
    case gyro          = 0x13
    case ambientLight  = 0x14
    case magnetometer  = 0x15
    case humidity      = 0x16
    case sensorFusion  = 0x19
    case debug         = 0xFE

    // MARK: - Display

    /// Human-readable module name. Identical to the case name for every
    /// module except `.switch_`, where the trailing underscore (required
    /// because `switch` is a Swift keyword) is stripped.
    public var name: String {
        switch self {
        case .switch_: return "switch"
        default:       return String(describing: self)
        }
    }
}

// MARK: - Packet builder

public enum MWPacket {
    /// Standard write or notify command
    public static func command(_ module: MWModule, _ register: UInt8, _ payload: UInt8...) -> Data {
        Data([module.rawValue, register] + payload)
    }

    /// One-shot read — sets bit 7 of the register byte
    public static func read(_ module: MWModule, _ register: UInt8, _ payload: UInt8...) -> Data {
        Data([module.rawValue, register | 0x80] + payload)
    }

    /// Build a command using a `RawRepresentable` register enum.
    ///
    /// Equivalent to `command(_:_:_:)` with `register.rawValue`, but lets per-module
    /// register enums (e.g. `MWAccelerometerRegister.dataInterruptConfig`) be passed
    /// directly so the call site documents which register is being written.
    public static func command<R: RawRepresentable>(
        _ module: MWModule, _ register: R, _ payload: [UInt8] = []
    ) -> Data where R.RawValue == UInt8 {
        Data([module.rawValue, register.rawValue] + payload)
    }

    /// Variadic overload of the `RawRepresentable`-register `command(_:_:_:)`.
    public static func command<R: RawRepresentable>(
        _ module: MWModule, _ register: R, _ payload: UInt8...
    ) -> Data where R.RawValue == UInt8 {
        Data([module.rawValue, register.rawValue] + payload)
    }

    /// One-shot read using a `RawRepresentable` register enum.
    public static func read<R: RawRepresentable>(
        _ module: MWModule, _ register: R, _ payload: [UInt8] = []
    ) -> Data where R.RawValue == UInt8 {
        Data([module.rawValue, register.rawValue | 0x80] + payload)
    }

    /// Parse the module ID from an incoming notification
    public static func module(from data: Data) -> MWModule? {
        guard let first = data.first else { return nil }
        return MWModule(rawValue: first)
    }

    /// Parse the register byte (strips the read bit if set)
    public static func register(from data: Data) -> UInt8? {
        guard data.count >= 2 else { return nil }
        return data[1] & 0x3F
    }
}
