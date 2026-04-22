import Testing
import Foundation
@testable import MetaWear

// MARK: - iBeacon command byte-layout tests
// Expected bytes verified against MetaWear-SDK-Cpp/test/test_ibeacon.py

@Suite("iBeacon Commands")
struct iBeaconCommandTests {

    // MARK: - Module byte

    @Test func module_byte() {
        #expect(MWiBeacon.Enable().commandData[0] == 0x07)
    }

    // MARK: - Enable / Disable  (register 0x01)
    // C++ test_enable:  [0x07, 0x01, 0x01]
    // C++ test_disable: [0x07, 0x01, 0x00]

    @Test func enable_correctBytes() {
        #expect(MWiBeacon.Enable().commandData == Data([0x07, 0x01, 0x01]))
    }

    @Test func disable_correctBytes() {
        #expect(MWiBeacon.Disable().commandData == Data([0x07, 0x01, 0x00]))
    }

    // MARK: - UUID  (register 0x02)
    //
    // Per `ibeacon.h`: "ad_uuid — Byte representation of the UUID in little
    // endian ordering". The firmware expects the UUID on the wire with its
    // bytes reversed from the canonical (standard) form; it flips them back
    // when broadcasting over-the-air.

    @Test func setUUID_length() {
        // [module(1), register(1), uuid(16)] = 18 bytes
        let cmd = MWiBeacon.SetUUID(uuid: UUID())
        #expect(cmd.commandData.count == 18)
        #expect(cmd.commandData[0] == 0x07)
        #expect(cmd.commandData[1] == 0x02)
    }

    // Canonical bytes of 12345678-1234-1234-1234-123456789ABC are
    //   [0x12, 0x34, 0x56, 0x78, 0x12, 0x34, 0x12, 0x34,
    //    0x12, 0x34, 0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC]
    // Reversed (wire order):
    //   [0xBC, 0x9A, 0x78, 0x56, 0x34, 0x12, 0x34, 0x12,
    //    0x34, 0x12, 0x34, 0x12, 0x78, 0x56, 0x34, 0x12]
    @Test func setUUID_reversesBytes() {
        let uuid = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
        let cmd = MWiBeacon.SetUUID(uuid: uuid)
        // First wire byte is the last byte of the canonical UUID.
        #expect(cmd.commandData[2]  == 0xBC)
        #expect(cmd.commandData[3]  == 0x9A)
        #expect(cmd.commandData[4]  == 0x78)
        #expect(cmd.commandData[5]  == 0x56)
        // Last wire byte is the first byte of the canonical UUID.
        #expect(cmd.commandData[17] == 0x12)
    }

    // Python `test_set_uuid` — exact firmware wire vector.
    //   UUID(326a9006-85cb-9195-d9dd-464cfbbae75a).bytes[::-1]
    //   → [0x5a, 0xe7, 0xba, 0xfb, 0x4c, 0x46, 0xdd, 0xd9,
    //      0x95, 0x91, 0xcb, 0x85, 0x06, 0x90, 0x6a, 0x32]
    @Test func setUUID_pythonVector() {
        let uuid = UUID(uuidString: "326A9006-85CB-9195-D9DD-464CFBBAE75A")!
        let expected = Data([
            0x07, 0x02,
            0x5A, 0xE7, 0xBA, 0xFB, 0x4C, 0x46, 0xDD, 0xD9,
            0x95, 0x91, 0xCB, 0x85, 0x06, 0x90, 0x6A, 0x32
        ])
        #expect(MWiBeacon.SetUUID(uuid: uuid).commandData == expected)
    }

    // Sanity: feeding the UUID through the command and reversing the wire
    // payload should recover the canonical UUID bytes.
    @Test func setUUID_roundTripsCanonicalForm() {
        let uuid = UUID(uuidString: "326A9006-85CB-9195-D9DD-464CFBBAE75A")!
        let cmd = MWiBeacon.SetUUID(uuid: uuid)
        let payload = Array(cmd.commandData.dropFirst(2))          // 16 wire bytes
        let canonical = payload.reversed()                          // restore canonical
        let (a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p) = uuid.uuid
        #expect(Array(canonical) == [a,b,c,d,e,f,g,h,i,j,k,l,m,n,o,p])
    }

    // MARK: - Major  (register 0x03)
    // C++ test_set_major: [0x07, 0x03, 0x4e, 0x00]  (major = 78 = 0x004E)

    @Test func setMajor_cppReference() {
        // major = 78 → LE: [0x4E, 0x00]
        #expect(MWiBeacon.SetMajor(78).commandData == Data([0x07, 0x03, 0x4E, 0x00]))
    }

    @Test func setMajor_littleEndian() {
        // 0x1234 → LE: [0x34, 0x12]
        let cmd = MWiBeacon.SetMajor(0x1234)
        #expect(cmd.commandData == Data([0x07, 0x03, 0x34, 0x12]))
    }

    @Test func setMajor_zero() {
        #expect(MWiBeacon.SetMajor(0).commandData == Data([0x07, 0x03, 0x00, 0x00]))
    }

    @Test func setMajor_max() {
        #expect(MWiBeacon.SetMajor(0xFFFF).commandData == Data([0x07, 0x03, 0xFF, 0xFF]))
    }

    // MARK: - Minor  (register 0x04)
    // C++ test_set_minor: [0x07, 0x04, 0x1d, 0x1d]  (minor = 0x1D1D = 7453)

    @Test func setMinor_cppReference() {
        // minor = 7453 = 0x1D1D → LE: [0x1D, 0x1D]
        #expect(MWiBeacon.SetMinor(0x1D1D).commandData == Data([0x07, 0x04, 0x1D, 0x1D]))
    }

    @Test func setMinor_littleEndian() {
        // 0xABCD → LE: [0xCD, 0xAB]
        let cmd = MWiBeacon.SetMinor(0xABCD)
        #expect(cmd.commandData == Data([0x07, 0x04, 0xCD, 0xAB]))
    }

    // MARK: - RX Power  (register 0x05)
    // C++ test_set_rx_power: [0x07, 0x05, 0xc9]  (–55 dBm as Int8 → UInt8 0xC9)

    @Test func setRXPower_cppReference() {
        // –55 as UInt8(bitPattern:) = 0xC9
        #expect(MWiBeacon.SetRXPower(-55).commandData == Data([0x07, 0x05, 0xC9]))
    }

    @Test func setRXPower_register() {
        #expect(MWiBeacon.SetRXPower(-55).commandData[1] == 0x05)
    }

    @Test func setRXPower_default_isMinusFiftyFive() {
        #expect(MWiBeacon.SetRXPower().commandData[2] == 0xC9)
    }

    // MARK: - TX Power  (register 0x06)
    // C++ test_set_tx_power: [0x07, 0x06, 0xf4]  (–12 dBm as Int8 → UInt8 0xF4)

    @Test func setTXPower_cppReference() {
        // –12 as UInt8(bitPattern:) = 0xF4
        #expect(MWiBeacon.SetTXPower(-12).commandData == Data([0x07, 0x06, 0xF4]))
    }

    @Test func setTXPower_register() {
        #expect(MWiBeacon.SetTXPower(0).commandData[1] == 0x06)
    }

    @Test func setTXPower_zero() {
        #expect(MWiBeacon.SetTXPower(0).commandData == Data([0x07, 0x06, 0x00]))
    }

    @Test func setTXPower_negative() {
        // –4 as UInt8(bitPattern:) = 0xFC
        #expect(MWiBeacon.SetTXPower(-4).commandData == Data([0x07, 0x06, 0xFC]))
    }

    @Test func setTXPower_default_isZero() {
        #expect(MWiBeacon.SetTXPower().commandData[2] == 0x00)
    }

    // MARK: - Period  (register 0x07)
    // C++ test_set_period: [0x07, 0x07, 0xb3, 0x3a]  (period = 0x3AB3 = 15027 ms)

    @Test func setPeriod_cppReference() {
        // 0x3AB3 = 15027 → LE: [0xB3, 0x3A]
        #expect(MWiBeacon.SetPeriod(0x3AB3).commandData == Data([0x07, 0x07, 0xB3, 0x3A]))
    }

    @Test func setPeriod_700ms() {
        // 700 = 0x02BC → LE: [0xBC, 0x02]
        #expect(MWiBeacon.SetPeriod(700).commandData == Data([0x07, 0x07, 0xBC, 0x02]))
    }

    @Test func setPeriod_default_is700() {
        let cmd = MWiBeacon.SetPeriod()
        let period = UInt16(cmd.commandData[2]) | (UInt16(cmd.commandData[3]) << 8)
        #expect(period == 700)
    }

    @Test func setPeriod_register() {
        #expect(MWiBeacon.SetPeriod(700).commandData[1] == 0x07)
    }

    @Test func setPeriod_littleEndian() {
        // 0x0102 = 258ms → LE: [0x02, 0x01]
        let cmd = MWiBeacon.SetPeriod(0x0102)
        #expect(cmd.commandData[2] == 0x02)
        #expect(cmd.commandData[3] == 0x01)
    }
}
