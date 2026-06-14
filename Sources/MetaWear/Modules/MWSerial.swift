import Foundation

// MARK: - Serial Passthrough (module 0x0D)
//
// Mirrors C++ `serialpassthrough.cpp` (declared across `i2c.h` + `spi.h`).
// The module id is 0x0D (`MBL_MW_MODULE_I2C` — shared I2C/SPI passthrough).
//
// Registers:
//   I2C_READ_WRITE = 0x01   write / read-with-id (read bit → 0xC1)
//   SPI_READ_WRITE = 0x02   write / read-with-id (read bit → 0xC2)
//
// Write shape:
//   I2C  [0x0D, 0x01, dev_addr, reg_addr, 0xFF, length, data...]
//   SPI  [0x0D, 0x02, ss_pin, clock_pin, mosi_pin, miso_pin, bitfield, data...]
//
// Read shape:
//   I2C  [0x0D, 0xC1, dev_addr, reg_addr, id, length]
//   SPI  [0x0D, 0xC2, ss_pin, clock_pin, mosi_pin, miso_pin, bitfield, (length-1)|(id<<4), optional_write_data...]
//
// SPI bitfield (1 byte, little-endian bit order, matches C++ `SpiBitFields`):
//   bit 0      lsb_first
//   bits 1–2   mode
//   bits 3–5   frequency
//   bit 6      use_nrf_pins
//   bit 7      reserved (0)

/// Commands and read helpers for the MetaWear serial passthrough module.
///
/// Supports two buses:
/// - **I2C** — up to 400 kHz; addressed by 7-bit device address + register address.
/// - **SPI** — configurable clock (125 kHz–8 MHz), mode (0–3), pin set, bit order.
///
/// Use the `MetaWearDevice` convenience methods for reads; use the command structs
/// for writes:
/// ```swift
/// try await device.send(try MWSerial.I2CWrite(deviceAddress: 0x68, registerAddress: 0x6B, data: [0x00]))
/// let bytes = try await device.i2cRead(deviceAddress: 0x68, registerAddress: 0x75, length: 1, id: 0)
/// ```
public enum MWSerial {

    // MARK: - I2C

    /// Write bytes to an I2C peripheral.
    ///
    /// Command format matches C++ `mbl_mw_i2c_write`:
    ///   `[0x0D, 0x01, dev_addr, reg_addr, 0xFF, length, data...]`
    ///
    /// The `0xFF` byte is a fixed signal-id placeholder the firmware ignores for
    /// plain writes (it only matters when linking a read signal). Writes are
    /// fire-and-forget — there is no `id` field.
    public struct I2CWrite: MWCommand, Sendable {
        /// 7-bit I2C device address.
        public let deviceAddress: UInt8
        /// Register (sub-address) to write to.
        public let registerAddress: UInt8
        /// Payload bytes to send after the register address.
        public let data: [UInt8]

        /// Firmware payload limit for a single I2C write. The register table
        /// documents "Data Length (max 10)" — the on-wire length field is a byte,
        /// but the firmware only buffers 10 data bytes per write.
        public static let maxPayloadLength = 10

        /// - Throws: `MWError.operationFailed` if `data` exceeds
        ///   ``maxPayloadLength``. Bad input is surfaced as a recoverable error
        ///   rather than a `precondition` so a malformed call cannot crash the
        ///   host app.
        public init(deviceAddress: UInt8, registerAddress: UInt8, data: [UInt8]) throws {
            guard data.count <= Self.maxPayloadLength else {
                throw MWError.operationFailed(
                    "I2C write payload is \(data.count) bytes; firmware maximum is \(Self.maxPayloadLength)"
                )
            }
            self.deviceAddress = deviceAddress
            self.registerAddress = registerAddress
            self.data = data
        }

        public var commandData: Data {
            Data([MWModule.serial.rawValue, 0x01,
                  deviceAddress, registerAddress,
                  0xFF,
                  UInt8(data.count)]
                 + data)
        }
    }

    // MARK: - SPI

    /// Clock frequency for SPI transactions. Raw value is packed into 3 bits of
    /// the SPI bitfield byte.
    public enum SPIClock: UInt8, Sendable {
        case f125kHz = 0
        case f250kHz = 1
        case f500kHz = 2
        case f1MHz   = 3
        case f2MHz   = 4
        case f4MHz   = 5
        case f8MHz   = 6
    }

    /// SPI mode (CPOL/CPHA). Raw value is packed into 2 bits of the SPI bitfield byte.
    public enum SPIMode: UInt8, Sendable {
        /// CPOL=0, CPHA=0 — idle low, sample on rising edge.
        case mode0 = 0
        /// CPOL=0, CPHA=1 — idle low, sample on falling edge.
        case mode1 = 1
        /// CPOL=1, CPHA=0 — idle high, sample on falling edge.
        case mode2 = 2
        /// CPOL=1, CPHA=1 — idle high, sample on rising edge.
        case mode3 = 3
    }

    /// Pin/mode/frequency parameter block matching C++ `MblMwSpiParameters` (the
    /// subset that is actually sent on the wire).
    public struct SPIParameters: Sendable {
        public let slaveSelectPin: UInt8
        public let clockPin: UInt8
        public let mosiPin: UInt8
        public let misoPin: UInt8
        public let mode: SPIMode
        public let frequency: SPIClock
        /// When `true`, the least-significant bit is transmitted first.
        public let lsbFirst: Bool
        /// When `true`, use the nRF SPI pins instead of the board expansion header.
        public let useNRFPins: Bool

        public init(slaveSelectPin: UInt8,
                    clockPin: UInt8,
                    mosiPin: UInt8,
                    misoPin: UInt8,
                    mode: SPIMode,
                    frequency: SPIClock,
                    lsbFirst: Bool = false,
                    useNRFPins: Bool = false) {
            self.slaveSelectPin = slaveSelectPin
            self.clockPin       = clockPin
            self.mosiPin        = mosiPin
            self.misoPin        = misoPin
            self.mode           = mode
            self.frequency      = frequency
            self.lsbFirst       = lsbFirst
            self.useNRFPins     = useNRFPins
        }

        /// Packed bitfield byte (matches C++ `SpiBitFields` memory layout):
        ///   bit 0 lsb_first | bits 1-2 mode | bits 3-5 frequency | bit 6 use_nrf_pins | bit 7 pad(0)
        public var bitfield: UInt8 {
            var b: UInt8 = 0
            if lsbFirst   { b |= 0x01 }
            b |= (mode.rawValue      & 0x03) << 1
            b |= (frequency.rawValue & 0x07) << 3
            if useNRFPins { b |= 0x40 }
            return b
        }

        /// The 5-byte pin/bitfield prefix: `[ss, clk, mosi, miso, bitfield]`.
        public var encodedBytes: [UInt8] {
            [slaveSelectPin, clockPin, mosiPin, misoPin, bitfield]
        }
    }

    /// Write bytes over SPI.
    ///
    /// Command format matches C++ `mbl_mw_spi_write`:
    ///   `[0x0D, 0x02, ss, clk, mosi, miso, bitfield, data...]`
    public struct SPIWrite: MWCommand, Sendable {
        public let parameters: SPIParameters
        public let data: [UInt8]

        public init(parameters: SPIParameters, data: [UInt8]) {
            self.parameters = parameters
            self.data = data
        }

        public var commandData: Data {
            Data([MWModule.serial.rawValue, 0x02]
                 + parameters.encodedBytes
                 + data)
        }
    }
}

// MARK: - MetaWearDevice serial convenience

public extension MetaWearDevice {

    /// Read bytes from an I2C peripheral.
    ///
    /// Sends `[0x0D, 0xC1, dev_addr, reg_addr, id, length]` (matches C++
    /// `MblMwI2cSignal::read` byte order). The board replies on register 0x01
    /// with `[0x0D, 0x81, id, byte0, byte1, ...]`; we strip the 3-byte prefix.
    ///
    /// - Parameters:
    ///   - deviceAddress: 7-bit I2C address of the peripheral.
    ///   - registerAddress: Register (sub-address) to read from.
    ///   - length: Number of bytes to read (1–255).
    ///   - id: Caller-assigned identifier (echoed in the response).
    /// - Returns: The bytes returned by the peripheral.
    func i2cRead(deviceAddress: UInt8,
                 registerAddress: UInt8,
                 length: UInt8,
                 id: UInt8 = 0) async throws -> Data {
        guard length > 0 else {
            throw MWError.operationFailed("I2C read length must be in 1...255")
        }
        // Request: [0x0D, 0xC1, dev, reg, id, length]
        // 0xC1 = 0x01 | 0x80 (read bit) | 0x40 (data_id bit)
        let cmd = Data([MWModule.serial.rawValue, UInt8(0x01 | 0x80 | 0x40),
                        deviceAddress, registerAddress, id, length])
        // Response arrives on register 0x01 (plain) — `writeAndAwaitNotification`
        // masks the read bit so this matches both 0x01 and 0x81 replies.
        let packet = try await sendAndAwaitNotification(
            command: cmd, awaitModule: .serial, awaitRegister: 0x01
        )
        guard packet.count >= 3 else {
            throw MWError.operationFailed("I2C read response too short (\(packet.count) bytes)")
        }
        return packet.dropFirst(3)  // strip [module, register, id]
    }

    /// Read bytes from an SPI peripheral.
    ///
    /// Sends `[0x0D, 0xC2, ss, clk, mosi, miso, bitfield, (length-1)|(id<<4), writeData...]`.
    /// The optional `writeData` bytes are transmitted before the read clocks
    /// data back out.
    ///
    /// - Parameters:
    ///   - parameters: Pin/mode/frequency parameter block.
    ///   - length: Number of bytes to read (1–16 — fits in 4 bits).
    ///   - id: Caller-assigned identifier (0–15 — fits in 4 bits).
    ///   - writeData: Optional bytes to transmit before the read clocks data out.
    /// - Returns: The bytes returned by the peripheral.
    func spiRead(parameters: MWSerial.SPIParameters,
                 length: UInt8,
                 id: UInt8 = 0,
                 writeData: [UInt8] = []) async throws -> Data {
        guard (1...16).contains(length) else {
            throw MWError.operationFailed("SPI read length must be in 1...16")
        }
        guard id <= 0x0F else {
            throw MWError.operationFailed("SPI read id must be in 0...15")
        }
        // length and id share one byte: (length-1) in low nibble, id in high nibble.
        let packedLenId: UInt8 = (length - 1) | (id << 4)
        // Request: [0x0D, 0xC2, fields(5), packedLenId, writeData...]
        let cmd = Data([MWModule.serial.rawValue, UInt8(0x02 | 0x80 | 0x40)]
                       + parameters.encodedBytes
                       + [packedLenId]
                       + writeData)
        // Response: [0x0D, 0x02, id, byte0, byte1, ...] (register 0x02 with or without read bit)
        let packet = try await sendAndAwaitNotification(
            command: cmd, awaitModule: .serial, awaitRegister: 0x02
        )
        guard packet.count >= 3 else {
            throw MWError.operationFailed("SPI read response too short (\(packet.count) bytes)")
        }
        return packet.dropFirst(3)
    }
}
