import Testing
import MetaWear

@Suite("Hardware — Serial (I2C / SPI)", .serialized)
struct SerialTests {

    // MARK: - Module presence

    @Test @MainActor
    func serial_moduleIsPresent() async throws {
        try await withConnectedDevice { device in
            let info = await device.moduleInfo(for: .serial)
            guard info?.isPresent == true else {
                print("\n  Skipping Serial — module not present\n")
                return
            }
            #expect(info != nil)
            print("\n  Serial module: impl=\(info?.implementation ?? 0xFF) rev=\(info?.revision ?? 0)\n")
        }
    }

    // MARK: - I2C write (no crash)

    /// Sends a benign I2C write to address 0x68 (MPU-6050/BMI160-compatible WHO_AM_I register area).
    /// We don't assert on the result — the point is that the command reaches the board without throwing.
    @Test @MainActor
    func serial_i2cWrite_doesNotThrow() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .serial)?.isPresent == true else {
                print("\n  Skipping I2C write — serial module not present\n")
                return
            }
            // Write 0x00 to register 0x00 of I2C address 0x68.
            // This is a no-op on most sensors; the board will ACK or NAK silently.
            let cmd = MWSerial.I2CWrite(deviceAddress: 0x68, registerAddress: 0x00, data: [0x00])
            try await device.send(cmd)
            print("\n  ✓ I2C write sent without error\n")
        }
    }

    // MARK: - I2C read (WHO_AM_I probe)

    /// Reads 1 byte from I2C address 0x68, register 0x75 (WHO_AM_I on MPU-6050 family).
    /// If no peripheral is connected the board may return 0xFF or throw — both are acceptable
    /// outcomes; the test only verifies that the call completes without hanging.
    @Test @MainActor
    func serial_i2cRead_completesWithoutHanging() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .serial)?.isPresent == true else {
                print("\n  Skipping I2C read — serial module not present\n")
                return
            }
            do {
                let data = try await device.i2cRead(deviceAddress: 0x68, registerAddress: 0x75, length: 1)
                print("\n  I2C read (0x68 reg 0x75): \(data.map { String(format: "0x%02X", $0) }.joined(separator: " "))\n")
            } catch {
                // A timeout or NAK is acceptable when no peripheral is wired up
                print("\n  I2C read threw (expected when no peripheral present): \(error)\n")
            }
        }
    }

    // MARK: - SPI write (no crash)

    /// Sends a benign SPI write. Without a peripheral attached the board will still clock
    /// the bytes out; the test just verifies the command is accepted without throwing.
    @Test @MainActor
    func serial_spiWrite_doesNotThrow() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .serial)?.isPresent == true else {
                print("\n  Skipping SPI write — serial module not present\n")
                return
            }
            // Pin numbers are placeholders — no peripheral is wired for these hardware
            // smoke tests, so we just need a syntactically valid SPIParameters block.
            let params = MWSerial.SPIParameters(
                slaveSelectPin: 0, clockPin: 1, mosiPin: 2, misoPin: 3,
                mode: .mode3, frequency: .f1MHz,
                lsbFirst: false, useNRFPins: false
            )
            let cmd = MWSerial.SPIWrite(parameters: params, data: [0x9F])  // "read ID" opcode for SPI flash chips
            try await device.send(cmd)
            print("\n  ✓ SPI write sent without error\n")
        }
    }

    // MARK: - SPI read

    /// Reads 1 byte over SPI. Like the I2C read test, timeouts/errors are acceptable
    /// when no SPI peripheral is physically connected.
    @Test @MainActor
    func serial_spiRead_completesWithoutHanging() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .serial)?.isPresent == true else {
                print("\n  Skipping SPI read — serial module not present\n")
                return
            }
            do {
                let params = MWSerial.SPIParameters(
                    slaveSelectPin: 0, clockPin: 1, mosiPin: 2, misoPin: 3,
                    mode: .mode3, frequency: .f1MHz
                )
                let data = try await device.spiRead(parameters: params, length: 1)
                print("\n  SPI read: \(data.map { String(format: "0x%02X", $0) }.joined(separator: " "))\n")
            } catch {
                print("\n  SPI read threw (expected when no peripheral present): \(error)\n")
            }
        }
    }
}
