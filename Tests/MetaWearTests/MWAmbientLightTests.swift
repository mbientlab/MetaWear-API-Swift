import Testing
import Foundation
@testable import MetaWear

// MARK: - Ambient Light (LTR329) — Python-vector byte-layout tests
// Expected bytes verified against MetaWear-SDK-Cpp/test/test_ambientlight_ltr329.py

@Suite("Ambient Light — Commands")
struct AmbientLightCommandTests {

    // MARK: Module byte

    @Test func module_byte_is0x14() {
        #expect(MWAmbientLight().startCommand[0] == 0x14)
    }

    // MARK: Enable / Disable  (register 0x01)

    @Test func startCommand_bytes() {
        #expect(MWAmbientLight().startCommand == Data([0x14, 0x01, 0x01]))
    }

    @Test func stopCommand_bytes() {
        #expect(MWAmbientLight().stopCommand == Data([0x14, 0x01, 0x00]))
    }

    // MARK: CONFIG (register 0x02) — Python reference vectors

    // test_set_gain:
    //   gain = 48X, everything else default → [0x14, 0x02, 0x18, 0x03]
    //   48X maps to als_gain=6 in the bitfield (+2 offset vs enum),
    //   byte0 = 6 << 2 = 0x18;
    //   default rate = 500ms (3), default integration = 100ms (0) → byte1 = 3 | 0 = 0x03.
    @Test func configBytes_gain48X_defaults() {
        let als = MWAmbientLight(gain: .x48)
        #expect(als.configureCommands.count == 1)
        #expect(als.configureCommands[0] == Data([0x14, 0x02, 0x18, 0x03]))
    }

    // test_set_integration_time:
    //   integration_time = 400ms (enum 3), defaults otherwise → [0x14, 0x02, 0x00, 0x1b]
    //   byte1 = rate(3) | (IT(3) << 3) = 3 | 24 = 0x1B.
    @Test func configBytes_integrationTime_400ms_defaults() {
        let als = MWAmbientLight(integrationTime: .ms400)
        #expect(als.configureCommands[0] == Data([0x14, 0x02, 0x00, 0x1B]))
    }

    // test_set_measurement_rate:
    //   measurement_rate = 2000ms (enum 5), defaults otherwise → [0x14, 0x02, 0x00, 0x05]
    //   byte1 = rate(5) | (IT(0) << 3) = 0x05.
    @Test func configBytes_measurementRate_2000ms_defaults() {
        let als = MWAmbientLight(measurementRate: .ms2000)
        #expect(als.configureCommands[0] == Data([0x14, 0x02, 0x00, 0x05]))
    }

    // test_set_all_config:
    //   gain=8X, integration=250ms, rate=50ms → [0x14, 0x02, 0x0c, 0x28]
    //   byte0 = gain=3 << 2 = 0x0C;
    //   byte1 = rate(0) | (IT(5) << 3) = 0x28.
    @Test func configBytes_allCustom() {
        let als = MWAmbientLight(gain: .x8, integrationTime: .ms250, measurementRate: .ms50)
        #expect(als.configureCommands[0] == Data([0x14, 0x02, 0x0C, 0x28]))
    }

    // MARK: Standalone write-config command

    @Test func writeConfigCommand_matchesStreamConfig() {
        let als = MWAmbientLight(gain: .x48)
        let cmd = MWAmbientLightWriteConfig(als)
        #expect(cmd.commandData == Data([0x14, 0x02, 0x18, 0x03]))
    }

    // MARK: Gain encoding sanity

    @Test func gainRegisterValue_matchesC() {
        #expect(MWAmbientLight.Gain.x1.registerValue  == 0)
        #expect(MWAmbientLight.Gain.x2.registerValue  == 1)
        #expect(MWAmbientLight.Gain.x4.registerValue  == 2)
        #expect(MWAmbientLight.Gain.x8.registerValue  == 3)
        #expect(MWAmbientLight.Gain.x48.registerValue == 6)  // +2 offset per C++
        #expect(MWAmbientLight.Gain.x96.registerValue == 7)
    }

    @Test func configByte0_usesGainRegisterValue() {
        #expect(MWAmbientLight(gain: .x96).configByte0 == 7 << 2)  // 0x1C
    }
}

// MARK: - Data handler

@Suite("Ambient Light — Data Handler")
struct AmbientLightDataHandlerTests {

    // MARK: Subscribe / unsubscribe

    @Test func subscribeRegister_is0x03() {
        #expect(MWAmbientLight().dataRegister == 0x03)
    }

    @Test func packedDataRegister_isNil() {
        #expect(MWAmbientLight().packedDataRegister == nil)
    }

    // MARK: Parse illuminance — Python reference vector

    // test_get_illuminance_data: b'\x14\x03\xed\x92\xb0\x00' → 11571949 (raw UInt32).
    @Test func parseSample_pythonVector() throws {
        let als = MWAmbientLight()
        let packet = Data([0x14, 0x03, 0xED, 0x92, 0xB0, 0x00])
        let raw = try als.parseSample(from: packet)
        #expect(raw == 11_571_949)
    }

    // Illuminance is UInt32 little-endian at offset 2.
    @Test func parseSample_littleEndian() throws {
        let als = MWAmbientLight()
        let packet = Data([0x14, 0x03, 0x01, 0x02, 0x03, 0x04])
        let raw = try als.parseSample(from: packet)
        #expect(raw == 0x04030201)
    }

    @Test func parseSample_tooShort_throws() {
        let als = MWAmbientLight()
        let packet = Data([0x14, 0x03, 0x01])
        #expect(throws: MWError.self) { try als.parseSample(from: packet) }
    }

    // MARK: Lux conversion

    @Test func lux_convertsMilliLuxToLux() {
        #expect(MWAmbientLight.lux(from: 11_571_949) == 11571.949)
        #expect(MWAmbientLight.lux(from: 0) == 0.0)
        #expect(MWAmbientLight.lux(from: 1000) == 1.0)
    }
}
