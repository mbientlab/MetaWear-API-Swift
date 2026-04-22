import Testing
import Foundation
@testable import MetaWear

// MARK: - MWLogLength — shape + parsing

@Suite("MWLogLength — Readable")
struct MWLogLengthTests {

    @Test func module_dataRegister() {
        let r = MWLogLength()
        #expect(r.module == .logging)
        #expect(r.dataRegister == 0x05)
        #expect(r.packedDataRegister == nil)
    }

    @Test func readCommand_hasReadBit() {
        #expect(MWLogLength().readCommand == Data([0x0B, 0x85]))
    }

    // Raw UInt32 LE at offset 2 → 0x0000_04D2 = 1234 entries
    @Test func parse_uint32LE() throws {
        let packet = Data([0x0B, 0x85, 0xD2, 0x04, 0x00, 0x00])
        #expect(try MWLogLength().parseSample(from: packet) == 1234)
    }

    @Test func parse_zero() throws {
        let packet = Data([0x0B, 0x85, 0x00, 0x00, 0x00, 0x00])
        #expect(try MWLogLength().parseSample(from: packet) == 0)
    }

    @Test func parse_maxUInt32() throws {
        let packet = Data([0x0B, 0x85, 0xFF, 0xFF, 0xFF, 0xFF])
        #expect(try MWLogLength().parseSample(from: packet) == UInt32.max)
    }

    @Test func parse_shortPacket_throws() {
        let packet = Data([0x0B, 0x85, 0x00, 0x00])
        #expect(throws: MWError.self) {
            _ = try MWLogLength().parseSample(from: packet)
        }
    }
}

// MARK: - MWLastResetTime — shape + parsing

@Suite("MWLastResetTime — Readable")
struct MWLastResetTimeTests {

    @Test func module_dataRegister() {
        let r = MWLastResetTime()
        #expect(r.module == .logging)
        #expect(r.dataRegister == 0x04)
    }

    @Test func readCommand_hasReadBit() {
        #expect(MWLastResetTime().readCommand == Data([0x0B, 0x84]))
    }

    // tick=0 → reset time ≈ now
    @Test func parse_zeroTick_returnsNow() throws {
        let packet = Data([0x0B, 0x84, 0x00, 0x00, 0x00, 0x00])
        let before = Date()
        let parsed = try MWLastResetTime().parseSample(from: packet)
        let after = Date()
        #expect(parsed >= before.addingTimeInterval(-0.1))
        #expect(parsed <= after.addingTimeInterval(0.1))
    }

    // tick=1000 → 1000 * 1.4648 ms ≈ 1.465 s in the past
    @Test func parse_1000tick_returnsPast() throws {
        let packet = Data([0x0B, 0x84, 0xE8, 0x03, 0x00, 0x00])   // 1000 LE
        let now = Date()
        let parsed = try MWLastResetTime().parseSample(from: packet)
        let elapsed = now.timeIntervalSince(parsed)
        let expected = 1000.0 * MWPacketParser.msPerTick / 1000.0   // ≈ 1.4648 s
        #expect(abs(elapsed - expected) < 0.1)
    }

    @Test func parse_shortPacket_throws() {
        let packet = Data([0x0B, 0x84, 0x00])
        #expect(throws: MWError.self) {
            _ = try MWLastResetTime().parseSample(from: packet)
        }
    }
}

// MARK: - MWMACAddress — typealias parity

@Suite("MWMACAddress — Typealias")
struct MWMACAddressTests {

    @Test func aliasIdentity() {
        // The typealias should resolve to MWSettings.ReadMacAddress — the
        // parity name from the old Combine SDK.
        let a: MWMACAddress = MWMACAddress()
        let b: MWSettings.ReadMacAddress = MWSettings.ReadMacAddress()
        #expect(a.readCommand == b.readCommand)
        #expect(a.module == b.module)
        #expect(a.dataRegister == b.dataRegister)
    }
}

// MARK: - MWPollable conformance markers

@Suite("MWPollable — Conformances")
struct MWPollableConformanceTests {

    @Test func logLength_isPollable() {
        let _: any MWPollable = MWLogLength()
    }

    @Test func lastResetTime_isPollable() {
        let _: any MWPollable = MWLastResetTime()
    }

    @Test func batteryState_isPollable() {
        let _: any MWPollable = MWSettings.ReadBatteryState()
    }

    @Test func macAddress_isPollable() {
        let _: any MWPollable = MWMACAddress()
    }

    @Test func humidity_isPollable() {
        let _: any MWPollable = MWHumidity()
    }
}
