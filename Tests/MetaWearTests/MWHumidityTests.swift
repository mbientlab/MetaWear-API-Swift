import Testing
import Foundation
@testable import MetaWear

// MARK: - Humidity (BME280)
//
// Reference vectors from MetaWear-SDK-Cpp/test/backup/test_humidity_bme280.py

@Suite("Humidity — Commands")
struct HumidityCommandTests {

    // MARK: Module opcode

    @Test func module_is0x16() {
        #expect(MWModule.humidity.rawValue == 0x16)
    }

    // MARK: Oversampling raw values

    // C++ `MblMwHumidityBme280Oversampling` — sequential 1..5
    @Test func oversampling_rawValues() {
        #expect(MWHumidity.Oversampling.x1.rawValue  == 1)
        #expect(MWHumidity.Oversampling.x2.rawValue  == 2)
        #expect(MWHumidity.Oversampling.x4.rawValue  == 3)
        #expect(MWHumidity.Oversampling.x8.rawValue  == 4)
        #expect(MWHumidity.Oversampling.x16.rawValue == 5)
    }

    // MARK: setOversampling byte vectors — Python test_oversampling

    @Test func setOversampling_x1() {
        #expect(MWHumiditySetOversampling(oversampling: .x1).commandData
                == Data([0x16, 0x02, 0x01]))
    }

    @Test func setOversampling_x2() {
        #expect(MWHumiditySetOversampling(oversampling: .x2).commandData
                == Data([0x16, 0x02, 0x02]))
    }

    @Test func setOversampling_x4() {
        #expect(MWHumiditySetOversampling(oversampling: .x4).commandData
                == Data([0x16, 0x02, 0x03]))
    }

    @Test func setOversampling_x8() {
        #expect(MWHumiditySetOversampling(oversampling: .x8).commandData
                == Data([0x16, 0x02, 0x04]))
    }

    @Test func setOversampling_x16() {
        #expect(MWHumiditySetOversampling(oversampling: .x16).commandData
                == Data([0x16, 0x02, 0x05]))
    }

    // MARK: MWReadable surface

    @Test func readCommand_hasReadBit() {
        let reader = MWHumidity()
        #expect(reader.readCommand == Data([0x16, 0x81]))
    }

    @Test func module_dataRegister() {
        let reader = MWHumidity()
        #expect(reader.module == .humidity)
        #expect(reader.dataRegister == 0x01)
        #expect(reader.packedDataRegister == nil)
    }
}

// MARK: - Humidity parsing

@Suite("Humidity — Packet Parsing")
struct HumidityParsingTests {

    // Python test_humidity_data — exact firmware response vector.
    // b'\x16\x81\xc7\xfc\x00\x00' → raw uint32 LE = 0x0000FCC7 = 64711 → 64711/1024 = 63.1943359375%
    @Test func parse_pythonVector_63percent() throws {
        let packet = Data([0x16, 0x81, 0xC7, 0xFC, 0x00, 0x00])
        let percent = try MWHumidity().parseSample(from: packet)
        #expect(percent == 63.1943359375)
    }

    // Same vector via the parser helper directly.
    @Test func parseHumidity_helper() throws {
        let packet = Data([0x16, 0x81, 0xC7, 0xFC, 0x00, 0x00])
        let percent = try MWPacketParser.parseHumidity(packet)
        #expect(percent == 63.1943359375)
    }

    // raw uint32 = 0x0000_C000 = 49152 → 49152/1024 = 48.0%
    @Test func parse_48percent() throws {
        let packet = Data([0x16, 0x81, 0x00, 0xC0, 0x00, 0x00])
        #expect(try MWHumidity().parseSample(from: packet) == 48.0)
    }

    // raw uint32 = 0 → 0%
    @Test func parse_zero() throws {
        let packet = Data([0x16, 0x81, 0x00, 0x00, 0x00, 0x00])
        #expect(try MWHumidity().parseSample(from: packet) == 0.0)
    }

    // raw uint32 = 0x0001_9000 = 102400 → 100.0%
    @Test func parse_100percent() throws {
        let packet = Data([0x16, 0x81, 0x00, 0x90, 0x01, 0x00])
        #expect(try MWHumidity().parseSample(from: packet) == 100.0)
    }

    @Test func parse_shortPacket_throws() {
        // 5-byte packet (missing one raw byte) must be rejected — the BME280
        // payload is a full UInt32, not truncated like temperature.
        let packet = Data([0x16, 0x81, 0x00, 0x00, 0x00])
        #expect(throws: MWError.self) {
            _ = try MWHumidity().parseSample(from: packet)
        }
    }
}
