import Foundation

// MARK: - iBeacon (module 0x07)

/// Commands for configuring the MetaWear as a Bluetooth iBeacon advertiser.
///
/// Typical usage:
/// ```swift
/// try await device.send(MWiBeacon.SetUUID(uuid: UUID()))
/// try await device.send(MWiBeacon.SetMajor(1))
/// try await device.send(MWiBeacon.SetMinor(2))
/// try await device.send(MWiBeacon.Enable())
/// // ...
/// try await device.send(MWiBeacon.Disable())
/// ```
public enum MWiBeacon {

    // MARK: - Enable / Disable  (register 0x01)

    /// Start iBeacon advertising.
    public struct Enable: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.iBeacon, 0x01, [0x01]) }
    }

    /// Stop iBeacon advertising.
    public struct Disable: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.iBeacon, 0x01, [0x00]) }
    }

    // MARK: - UUID  (register 0x02)

    /// Set the iBeacon proximity UUID.
    ///
    /// The MetaWear firmware expects the UUID payload in **little-endian** byte
    /// order (per `ibeacon.h`: *"Byte representation of the UUID in little endian
    /// ordering"*). The firmware reverses the bytes again when broadcasting so
    /// they appear on-air in standard (big-endian) UUID form.
    ///
    /// Python reference vector (`test_ibeacon.py::test_set_uuid`):
    /// ```
    /// UUID(326A9006-85CB-9195-D9DD-464CFBBAE75A)
    ///   → [0x07, 0x02,
    ///      0x5A, 0xE7, 0xBA, 0xFB, 0x4C, 0x46, 0xDD, 0xD9,
    ///      0x95, 0x91, 0xCB, 0x85, 0x06, 0x90, 0x6A, 0x32]
    /// ```
    public struct SetUUID: MWCommand, Sendable {
        public let uuid: UUID

        public init(uuid: UUID = UUID()) {
            self.uuid = uuid
        }

        public var commandData: Data {
            // Swift's `UUID.uuid` tuple is big-endian (standard) order. Reverse
            // to little-endian for the MetaWear wire format.
            let (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p) = uuid.uuid
            // Reversed order (p…a) is the little-endian wire format.
            let littleEndian: [UInt8] = [p,o,n,m,l,k,j,i,h,g,f,e,d,c,b,a]
            return MWPacket.command(.iBeacon, 0x02, littleEndian)
        }
    }

    // MARK: - Major / Minor  (registers 0x03, 0x04)

    /// Set the iBeacon major value (0–65535).
    public struct SetMajor: MWCommand, Sendable {
        public let major: UInt16
        public init(_ major: UInt16) { self.major = major }
        public var commandData: Data {
            MWPacket.command(.iBeacon, 0x03, [UInt8(major & 0xFF), UInt8(major >> 8)])
        }
    }

    /// Set the iBeacon minor value (0–65535).
    public struct SetMinor: MWCommand, Sendable {
        public let minor: UInt16
        public init(_ minor: UInt16) { self.minor = minor }
        public var commandData: Data {
            MWPacket.command(.iBeacon, 0x04, [UInt8(minor & 0xFF), UInt8(minor >> 8)])
        }
    }

    // MARK: - RX / TX power  (registers 0x05, 0x06)

    /// Set the received signal power at 1 metre, broadcast in the advertisement payload.
    /// Used by receivers for ranging. Typical value: –55 dBm (0xC9 when cast to UInt8).
    public struct SetRXPower: MWCommand, Sendable {
        public let power: Int8
        public init(_ power: Int8 = -55) { self.power = power }
        public var commandData: Data {
            MWPacket.command(.iBeacon, 0x05, [UInt8(bitPattern: power)])
        }
    }

    /// Set the actual BLE TX power used during iBeacon advertisements.
    /// Typical values: 0, –4, –8, –12, –16, –20 dBm.
    public struct SetTXPower: MWCommand, Sendable {
        public let power: Int8
        public init(_ power: Int8 = 0) { self.power = power }
        public var commandData: Data {
            MWPacket.command(.iBeacon, 0x06, [UInt8(bitPattern: power)])
        }
    }

    // MARK: - Advertisement period  (register 0x07)

    /// Set the iBeacon advertisement period in milliseconds (default 700 ms).
    public struct SetPeriod: MWCommand, Sendable {
        public let periodMs: UInt16
        public init(_ periodMs: UInt16 = 700) { self.periodMs = periodMs }
        public var commandData: Data {
            MWPacket.command(.iBeacon, 0x07, [UInt8(periodMs & 0xFF), UInt8(periodMs >> 8)])
        }
    }
}
