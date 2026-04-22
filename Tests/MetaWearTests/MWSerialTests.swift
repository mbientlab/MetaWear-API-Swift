import Testing
import Foundation
@testable import MetaWear

// MARK: - MWSerial command byte-layout tests
//
// Reference vectors from:
//   MetaWear-SDK-Cpp/src/metawear/peripheral/cpp/serialpassthrough.cpp
//   MetaWear-SDK-Cpp/test/backup/test_i2c.py
// C++ layouts:
//   I2C write: [0x0D, 0x01, dev, reg, 0xFF, length, data...]
//   I2C read : [0x0D, 0xC1, dev, reg, id,   length]
//   SPI write: [0x0D, 0x02, ss, clk, mosi, miso, bitfield, data...]
//   SPI read : [0x0D, 0xC2, ss, clk, mosi, miso, bitfield, (length-1)|(id<<4), writeData...]
// SPI bitfield: bit0 lsb_first | bits1-2 mode | bits3-5 frequency | bit6 use_nrf | bit7 pad(0)

@Suite("Serial Passthrough — I2C Write")
struct SerialI2CWriteTests {

    @Test func moduleAndRegisterBytes() {
        let cmd = MWSerial.I2CWrite(deviceAddress: 0x68, registerAddress: 0x6B, data: [0xAA])
        #expect(cmd.commandData[0] == 0x0D)  // module
        #expect(cmd.commandData[1] == 0x01)  // register I2C_READ_WRITE
    }

    @Test func addressBytes() {
        let cmd = MWSerial.I2CWrite(deviceAddress: 0x68, registerAddress: 0x6B, data: [0xAA])
        #expect(cmd.commandData[2] == 0x68)  // device address
        #expect(cmd.commandData[3] == 0x6B)  // register address
    }

    // The 0xFF at offset 4 is the firmware's signal-id placeholder for plain
    // writes; it's ignored by firmware on write paths but must be present.
    @Test func placeholderByte_is0xFF() {
        let cmd = MWSerial.I2CWrite(deviceAddress: 0x68, registerAddress: 0x6B, data: [0xAA])
        #expect(cmd.commandData[4] == 0xFF)
    }

    @Test func lengthByte() {
        let cmd = MWSerial.I2CWrite(deviceAddress: 0x68, registerAddress: 0x6B, data: [0xAA, 0xBB])
        #expect(cmd.commandData[5] == 2)
    }

    @Test func dataBytes() {
        let cmd = MWSerial.I2CWrite(deviceAddress: 0x68, registerAddress: 0x6B, data: [0xAA, 0xBB])
        #expect(cmd.commandData[6] == 0xAA)
        #expect(cmd.commandData[7] == 0xBB)
    }

    @Test func totalLength_oneDataByte() {
        let cmd = MWSerial.I2CWrite(deviceAddress: 0x68, registerAddress: 0x6B, data: [0x00])
        // [module, register, dev, reg, 0xFF, length, data] = 7 bytes
        #expect(cmd.commandData.count == 7)
    }

    @Test func totalLength_threeDataBytes() {
        let cmd = MWSerial.I2CWrite(deviceAddress: 0x68, registerAddress: 0x6B, data: [0x01, 0x02, 0x03])
        #expect(cmd.commandData.count == 9)
    }

    @Test func emptyData() {
        let cmd = MWSerial.I2CWrite(deviceAddress: 0x10, registerAddress: 0x00, data: [])
        #expect(cmd.commandData.count == 6)
        #expect(cmd.commandData[4] == 0xFF)  // placeholder still present
        #expect(cmd.commandData[5] == 0)     // length = 0
    }

    // Exact byte-vector check covering the full I2C write shape.
    @Test func fullVector() {
        let cmd = MWSerial.I2CWrite(deviceAddress: 0x68, registerAddress: 0x6B, data: [0xDE, 0xAD])
        #expect(cmd.commandData == Data([0x0D, 0x01, 0x68, 0x6B, 0xFF, 0x02, 0xDE, 0xAD]))
    }
}

@Suite("Serial Passthrough — I2C Read")
struct SerialI2CReadTests {

    // Python `test_i2c.py::test_read_who_am_i` exact vector.
    // [0x0d, 0xc1, 0x1c, 0x0d, 0x0a, 0x01] — dev=0x1C, reg=0x0D, id=0x0A, length=1
    // 0xC1 = 0x01 | 0x80 (read bit) | 0x40 (data_id bit)
    @Test func pythonVector_whoAmI() {
        let expected = Data([0x0D, 0xC1, 0x1C, 0x0D, 0x0A, 0x01])
        let cmd = Data([MWModule.serial.rawValue, UInt8(0x01 | 0x80 | 0x40),
                        0x1C, 0x0D, 0x0A, 0x01] as [UInt8])
        #expect(cmd == expected)
    }

    @Test func registerByte_isC1() {
        // The register byte must be 0xC1 (read + data_id bits set), not 0x81.
        let cmd = Data([MWModule.serial.rawValue, UInt8(0x01 | 0x80 | 0x40),
                        0x68, 0x75, 0, 1] as [UInt8])
        #expect(cmd[1] == 0xC1)
    }

    // Byte order: [dev, reg, id, length] — id BEFORE length, per C++ source.
    @Test func byteOrder_idBeforeLength() {
        let cmd = Data([MWModule.serial.rawValue, 0xC1, 0x1C, 0x0D, 0x0A, 0x01] as [UInt8])
        #expect(cmd[4] == 0x0A)  // id
        #expect(cmd[5] == 0x01)  // length
    }
}

@Suite("Serial Passthrough — SPI Parameters / bitfield")
struct SerialSPIBitfieldTests {

    // Base parameter set used for bitfield-only variations.
    private func base(mode: MWSerial.SPIMode = .mode0,
                      frequency: MWSerial.SPIClock = .f1MHz,
                      lsbFirst: Bool = false,
                      useNRFPins: Bool = false) -> MWSerial.SPIParameters {
        MWSerial.SPIParameters(slaveSelectPin: 10, clockPin: 11,
                               mosiPin: 12, misoPin: 13,
                               mode: mode, frequency: frequency,
                               lsbFirst: lsbFirst, useNRFPins: useNRFPins)
    }

    @Test func defaults_lsbFirstFalse_nrfFalse_mode0_f1MHz() {
        // mode0=0<<1=0, f1MHz=3<<3=0x18, lsbFirst=0, nrf=0 → 0x18
        #expect(base().bitfield == 0x18)
    }

    @Test func lsbFirst_setsBit0() {
        #expect(base(lsbFirst: true).bitfield & 0x01 == 0x01)
    }

    @Test func mode_occupiesBits1and2() {
        #expect(base(mode: .mode0).bitfield & 0x06 == 0x00)
        #expect(base(mode: .mode1).bitfield & 0x06 == 0x02)
        #expect(base(mode: .mode2).bitfield & 0x06 == 0x04)
        #expect(base(mode: .mode3).bitfield & 0x06 == 0x06)
    }

    @Test func frequency_occupiesBits3to5() {
        #expect(base(frequency: .f125kHz).bitfield & 0x38 == 0x00)
        #expect(base(frequency: .f250kHz).bitfield & 0x38 == 0x08)
        #expect(base(frequency: .f500kHz).bitfield & 0x38 == 0x10)
        #expect(base(frequency: .f1MHz).bitfield   & 0x38 == 0x18)
        #expect(base(frequency: .f2MHz).bitfield   & 0x38 == 0x20)
        #expect(base(frequency: .f4MHz).bitfield   & 0x38 == 0x28)
        #expect(base(frequency: .f8MHz).bitfield   & 0x38 == 0x30)
    }

    @Test func useNRFPins_setsBit6() {
        #expect(base(useNRFPins: true).bitfield & 0x40 == 0x40)
    }

    @Test func bit7_alwaysZero() {
        // Any combination of the public options must leave bit 7 clear.
        let p = MWSerial.SPIParameters(slaveSelectPin: 0, clockPin: 0, mosiPin: 0, misoPin: 0,
                                       mode: .mode3, frequency: .f8MHz,
                                       lsbFirst: true, useNRFPins: true)
        #expect(p.bitfield & 0x80 == 0)
    }

    @Test func allBitsSet_combined() {
        // lsbFirst | mode3 | f8MHz | useNRF = 0x01 | 0x06 | 0x30 | 0x40 = 0x77
        let p = MWSerial.SPIParameters(slaveSelectPin: 0, clockPin: 0, mosiPin: 0, misoPin: 0,
                                       mode: .mode3, frequency: .f8MHz,
                                       lsbFirst: true, useNRFPins: true)
        #expect(p.bitfield == 0x77)
    }

    @Test func encodedBytes_layout() {
        let p = MWSerial.SPIParameters(slaveSelectPin: 10, clockPin: 11,
                                       mosiPin: 12, misoPin: 13,
                                       mode: .mode0, frequency: .f1MHz)
        #expect(p.encodedBytes == [10, 11, 12, 13, 0x18])
    }
}

@Suite("Serial Passthrough — SPI Write")
struct SerialSPIWriteTests {

    private let params = MWSerial.SPIParameters(
        slaveSelectPin: 10, clockPin: 11, mosiPin: 12, misoPin: 13,
        mode: .mode0, frequency: .f1MHz
    )

    @Test func moduleAndRegisterBytes() {
        let cmd = MWSerial.SPIWrite(parameters: params, data: [0x9F])
        #expect(cmd.commandData[0] == 0x0D)  // module
        #expect(cmd.commandData[1] == 0x02)  // register SPI_READ_WRITE
    }

    @Test func pinBytes() {
        let cmd = MWSerial.SPIWrite(parameters: params, data: [0x00])
        #expect(cmd.commandData[2] == 10)
        #expect(cmd.commandData[3] == 11)
        #expect(cmd.commandData[4] == 12)
        #expect(cmd.commandData[5] == 13)
    }

    @Test func bitfieldByte() {
        let cmd = MWSerial.SPIWrite(parameters: params, data: [0x00])
        // mode0=0, f1MHz=3, lsbFirst=false, nrf=false → 0x18
        #expect(cmd.commandData[6] == 0x18)
    }

    @Test func dataBytes() {
        let cmd = MWSerial.SPIWrite(parameters: params, data: [0xDE, 0xAD])
        #expect(cmd.commandData[7] == 0xDE)
        #expect(cmd.commandData[8] == 0xAD)
    }

    @Test func totalLength() {
        let cmd = MWSerial.SPIWrite(parameters: params, data: [0x00])
        // [module, register, ss, clk, mosi, miso, bitfield, data] = 8
        #expect(cmd.commandData.count == 8)
    }

    @Test func fullVector() {
        let cmd = MWSerial.SPIWrite(parameters: params, data: [0xAA, 0xBB])
        #expect(cmd.commandData == Data([0x0D, 0x02, 10, 11, 12, 13, 0x18, 0xAA, 0xBB]))
    }
}

@Suite("Serial Passthrough — SPI Read")
struct SerialSPIReadTests {

    @Test func registerByte_isC2() {
        // 0xC2 = 0x02 | 0x80 (read bit) | 0x40 (data_id bit)
        let cmd = Data([MWModule.serial.rawValue, UInt8(0x02 | 0x80 | 0x40),
                        10, 11, 12, 13, 0x18, 0x00] as [UInt8])
        #expect(cmd[1] == 0xC2)
    }

    @Test func packedLengthId_lowNibbleIsLengthMinusOne() {
        // length=4, id=0 → ((4-1) & 0x0F) | (0<<4) = 0x03
        let length: UInt8 = 4
        let id: UInt8 = 0
        let packed: UInt8 = ((length &- 1) & 0x0F) | ((id & 0x0F) << 4)
        #expect(packed == 0x03)
    }

    @Test func packedLengthId_highNibbleIsId() {
        // length=1, id=5 → ((1-1) & 0x0F) | (5<<4) = 0x50
        let length: UInt8 = 1
        let id: UInt8 = 5
        let packed: UInt8 = ((length &- 1) & 0x0F) | ((id & 0x0F) << 4)
        #expect(packed == 0x50)
    }

    @Test func packedLengthId_maxValues() {
        // length=16, id=15 → ((16-1) & 0x0F) | (15<<4) = 0x0F | 0xF0 = 0xFF
        let length: UInt8 = 16
        let id: UInt8 = 15
        let packed: UInt8 = ((length &- 1) & 0x0F) | ((id & 0x0F) << 4)
        #expect(packed == 0xFF)
    }
}

// MARK: - SPI enum raw values

@Suite("Serial Passthrough — Enum raw values")
struct SerialEnumTests {

    @Test func spiClock_rawValues() {
        #expect(MWSerial.SPIClock.f125kHz.rawValue == 0)
        #expect(MWSerial.SPIClock.f250kHz.rawValue == 1)
        #expect(MWSerial.SPIClock.f500kHz.rawValue == 2)
        #expect(MWSerial.SPIClock.f1MHz.rawValue   == 3)
        #expect(MWSerial.SPIClock.f2MHz.rawValue   == 4)
        #expect(MWSerial.SPIClock.f4MHz.rawValue   == 5)
        #expect(MWSerial.SPIClock.f8MHz.rawValue   == 6)
    }

    @Test func spiMode_rawValues() {
        #expect(MWSerial.SPIMode.mode0.rawValue == 0)
        #expect(MWSerial.SPIMode.mode1.rawValue == 1)
        #expect(MWSerial.SPIMode.mode2.rawValue == 2)
        #expect(MWSerial.SPIMode.mode3.rawValue == 3)
    }

    @Test func module_is0x0D() {
        #expect(MWModule.serial.rawValue == 0x0D)
    }
}
