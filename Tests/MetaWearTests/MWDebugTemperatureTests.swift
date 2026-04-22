import Testing
import Foundation
@testable import MetaWear

// MARK: - Debug commands
//
// Reference vectors from MetaWear-SDK-Cpp/test/test_debug.py

@Suite("Debug Commands")
struct DebugCommandTests {

    // MARK: Simple lifecycle commands

    @Test func reset_command() {
        #expect(MWDebug.Reset().commandData == Data([0xFE, 0x01]))
    }

    @Test func jumpToBootloader_command() {
        #expect(MWDebug.JumpToBootloader().commandData == Data([0xFE, 0x02]))
    }

    @Test func disconnect_command() {
        #expect(MWDebug.Disconnect().commandData == Data([0xFE, 0x06]))
    }

    @Test func resetAfterGC_command() {
        #expect(MWDebug.ResetAfterGC().commandData == Data([0xFE, 0x05]))
    }

    @Test func enablePowerSave_command() {
        #expect(MWDebug.EnablePowerSave().commandData == Data([0xFE, 0x07]))
    }

    @Test func reset_moduleAndRegister() {
        let data = MWDebug.Reset().commandData
        #expect(data[0] == 0xFE)  // debug module
        #expect(data[1] == 0x01)  // RESET register
    }

    // MARK: Stack overflow assertion — Python test_stack_overflow / test_stack_overflow_disable

    @Test func setStackOverflowAssertion_disable() {
        #expect(MWDebug.SetStackOverflowAssertion(false).commandData
                == Data([0xFE, 0x09, 0x00]))
    }

    @Test func setStackOverflowAssertion_enable() {
        #expect(MWDebug.SetStackOverflowAssertion(true).commandData
                == Data([0xFE, 0x09, 0x01]))
    }

    // MARK: Spoof button event — Python test_switch_spoof

    @Test func spoofButtonEvent_value7() {
        // Python test_switch_spoof: value=0x07 → [0xFE, 0x03, 0x01, 0x01, 0x00, 0x07]
        #expect(MWDebug.SpoofButtonEvent(0x07).commandData
                == Data([0xFE, 0x03, 0x01, 0x01, 0x00, 0x07]))
    }

    @Test func spoofButtonEvent_fixedPrefix() {
        // The firmware-facing spoof payload always starts with [switch module, reg 1, data_id 0].
        for value: UInt8 in [0x00, 0x01, 0xAB, 0xFF] {
            let data = MWDebug.SpoofButtonEvent(value).commandData
            #expect(data[0] == 0xFE)
            #expect(data[1] == 0x03)
            #expect(data[2] == 0x01)  // switch module id
            #expect(data[3] == 0x01)  // switch state register
            #expect(data[4] == 0x00)  // data_id
            #expect(data[5] == value)
        }
    }

    // MARK: Stack overflow read — Python test_read_overflow_state

    @Test func readStackOverflowState_command() {
        // [0xFE, 0x89] — register 0x09 with the read bit set.
        #expect(MWDebug.ReadStackOverflowState().readCommand
                == Data([0xFE, 0x89]))
    }

    // MARK: Schedule queue read — Python test_read_schedule_queue_state

    @Test func readScheduleQueueUsage_command() {
        // [0xFE, 0x8A] — register 0x0A with the read bit set.
        #expect(MWDebug.ReadScheduleQueueUsage().readCommand
                == Data([0xFE, 0x8A]))
    }

    @Test func readables_moduleAndRegister() {
        let overflow = MWDebug.ReadStackOverflowState()
        #expect(overflow.module == .debug)
        #expect(overflow.dataRegister == 0x09)
        #expect(overflow.packedDataRegister == nil)

        let schedule = MWDebug.ReadScheduleQueueUsage()
        #expect(schedule.module == .debug)
        #expect(schedule.dataRegister == 0x0A)
        #expect(schedule.packedDataRegister == nil)
    }
}

// MARK: - Debug packet parsing
//
// Reference vectors from MetaWear-SDK-Cpp/test/test_debug.py

@Suite("Debug Packet Parsing")
struct DebugParsingTests {

    // Python test_handle_overflow_state:
    //   notify_mw_char([0xfe, 0x89, 0x00, 0x94, 0x0c])
    //   → OverflowState(length=0x0C94, assert_en=0)
    @Test func parseOverflowState_pythonVector() throws {
        let packet = Data([0xFE, 0x89, 0x00, 0x94, 0x0C])
        let state = try MWDebug.ReadStackOverflowState().parseSample(from: packet)
        #expect(state.length == 0x0C94)
        #expect(state.assertEnabled == false)
    }

    @Test func parseOverflowState_assertEnabled() throws {
        // Any non-zero assert byte → assertEnabled == true
        let packet = Data([0xFE, 0x89, 0x01, 0x00, 0x00])
        let state = try MWDebug.ReadStackOverflowState().parseSample(from: packet)
        #expect(state.assertEnabled == true)
        #expect(state.length == 0)
    }

    @Test func parseOverflowState_lengthIsLittleEndian() throws {
        // length_lo=0xCD, length_hi=0xAB → 0xABCD
        let packet = Data([0xFE, 0x89, 0x00, 0xCD, 0xAB])
        let state = try MWDebug.ReadStackOverflowState().parseSample(from: packet)
        #expect(state.length == 0xABCD)
    }

    @Test func parseOverflowState_shortPacket_throws() {
        // 4-byte packet — missing length high byte.
        let packet = Data([0xFE, 0x89, 0x00, 0x94])
        #expect(throws: MWError.self) {
            _ = try MWDebug.ReadStackOverflowState().parseSample(from: packet)
        }
    }

    // Python test_handle_schedule_queue_state:
    //   notify_mw_char([0xfe, 0x8a, 0x03, 0x02, 0x01, 0x00, 0x10, 0x01, 0x01, 0x00, 0x00, 0x00, 0x1b, 0x00, 0x1e])
    //   → [0x03, 0x02, 0x01, 0x00, 0x10, 0x01, 0x01, 0x00, 0x00, 0x00, 0x1B, 0x00, 0x1E]
    @Test func parseScheduleQueueUsage_pythonVector() throws {
        let packet = Data([0xFE, 0x8A,
                           0x03, 0x02, 0x01, 0x00, 0x10, 0x01, 0x01,
                           0x00, 0x00, 0x00, 0x1B, 0x00, 0x1E])
        let bytes = try MWDebug.ReadScheduleQueueUsage().parseSample(from: packet)
        #expect(bytes == [0x03, 0x02, 0x01, 0x00, 0x10, 0x01, 0x01,
                          0x00, 0x00, 0x00, 0x1B, 0x00, 0x1E])
    }

    @Test func parseScheduleQueueUsage_emptyPayload() throws {
        // Exactly-2-byte packet (just the header) should parse to an empty array.
        let packet = Data([0xFE, 0x8A])
        let bytes = try MWDebug.ReadScheduleQueueUsage().parseSample(from: packet)
        #expect(bytes == [])
    }

    @Test func parseScheduleQueueUsage_shortPacket_throws() {
        // 1-byte packet — not enough to even contain the header.
        let packet = Data([0xFE])
        #expect(throws: MWError.self) {
            _ = try MWDebug.ReadScheduleQueueUsage().parseSample(from: packet)
        }
    }
}

// MARK: - Temperature channel

@Suite("Temperature Channel")
struct TemperatureChannelTests {

    @Test func readCommand_channel0() {
        let ch = MWTemperatureChannel(channel: 0)
        // [0x04, 0x81, 0x00] — module=0x04, register=0x01|0x80=0x81, channel=0
        #expect(ch.readCommand == Data([0x04, 0x81, 0x00]))
    }

    @Test func readCommand_channel2() {
        let ch = MWTemperatureChannel(channel: 2)
        #expect(ch.readCommand == Data([0x04, 0x81, 0x02]))
    }

    @Test func nrf_isChannel0() {
        #expect(MWTemperatureChannel.nrf.channel == 0)
        #expect(MWTemperatureChannel.nrf.readCommand == Data([0x04, 0x81, 0x00]))
    }

    @Test func bosch_isChannel2() {
        #expect(MWTemperatureChannel.bosch.channel == 2)
    }

    @Test func bmp280_isChannel3() {
        #expect(MWTemperatureChannel.bmp280.channel == 3)
    }

    @Test func readCommand_hasReadBit() {
        // Byte 1 must have bit 7 set (read bit)
        let ch = MWTemperatureChannel(channel: 1)
        #expect((ch.readCommand[1] & 0x80) != 0)
    }

    @Test func silentReadCommand_hasReadAndSilentBits() {
        let ch = MWTemperatureChannel(channel: 0)
        // 0xC1 = 0x80 (read) | 0x40 (silent) | 0x01 (register)
        #expect(ch.silentReadCommand == Data([0x04, 0xC1, 0x00]))
    }
}

// MARK: - Multi-channel temperature (MWThermometer)
//
// Reference vectors from MetaWear-SDK-Cpp/test/test_multichanneltemperature.py

@Suite("Multi-Channel Temperature Commands")
struct MultiChannelTemperatureCommandTests {

    // Python: test_read_temperature (MetaWear R) — channels 0 and 1.
    @Test func readCommand_metawearR_onDie() {
        #expect(MWThermometer(channel: 0).readCommand == Data([0x04, 0x81, 0x00]))
    }

    @Test func readCommand_metawearR_extThermistor() {
        #expect(MWThermometer(channel: 1).readCommand == Data([0x04, 0x81, 0x01]))
    }

    // Python: test_read_temperature (RPro) — all 4 channels.
    @Test func readCommand_rpro_allChannels() {
        let expected: [(UInt8, [UInt8])] = [
            (0, [0x04, 0x81, 0x00]),
            (1, [0x04, 0x81, 0x01]),
            (2, [0x04, 0x81, 0x02]),
            (3, [0x04, 0x81, 0x03]),
        ]
        for (ch, bytes) in expected {
            #expect(MWThermometer(channel: ch).readCommand == Data(bytes))
        }
    }

    // Python: test_read_temperature_silent — silent bit 0x40 sets 0x81 → 0xC1.
    @Test func silentReadCommand_rpro_allChannels() {
        let expected: [(UInt8, [UInt8])] = [
            (0, [0x04, 0xC1, 0x00]),
            (1, [0x04, 0xC1, 0x01]),
            (2, [0x04, 0xC1, 0x02]),
            (3, [0x04, 0xC1, 0x03]),
        ]
        for (ch, bytes) in expected {
            #expect(MWThermometer(channel: ch, silent: true).readCommand == Data(bytes))
        }
    }

    @Test func dataRegister_is1() {
        #expect(MWThermometer(channel: 0).dataRegister == 0x01)
    }

    // Python: test_configure_ext_thermistor (MetaWear R, channel 1)
    // expected = [0x04, 0x02, 0x01, 0x00, 0x01, 0x00]
    @Test func configureExt_metawearR() {
        let cmd = MWThermometerConfigureExt(
            channel: 1, dataPin: 0, pulldownPin: 1, activeHigh: false
        )
        #expect(cmd.commandData == Data([0x04, 0x02, 0x01, 0x00, 0x01, 0x00]))
    }

    // Python: test_configure_ext_thermistor (RPro, channel 2)
    // expected = [0x04, 0x02, 0x02, 0x00, 0x01, 0x00]
    @Test func configureExt_rpro() {
        let cmd = MWThermometerConfigureExt(
            channel: 2, dataPin: 0, pulldownPin: 1, activeHigh: false
        )
        #expect(cmd.commandData == Data([0x04, 0x02, 0x02, 0x00, 0x01, 0x00]))
    }

    @Test func configureExt_activeHighEncodesAs1() {
        let cmd = MWThermometerConfigureExt(
            channel: 2, dataPin: 3, pulldownPin: 4, activeHigh: true
        )
        #expect(cmd.commandData == Data([0x04, 0x02, 0x02, 0x03, 0x04, 0x01]))
    }

    // MARK: Source enum raw values — match C++ MBL_MW_TEMPERATURE_SOURCE_*

    @Test func source_rawValues() {
        #expect(MWThermometerSource.invalid.rawValue == -1)
        #expect(MWThermometerSource.nrfDie.rawValue == 0)
        #expect(MWThermometerSource.extThermistor.rawValue == 1)
        #expect(MWThermometerSource.bmp280.rawValue == 2)
        #expect(MWThermometerSource.presetThermistor.rawValue == 3)
    }
}

// MARK: - Multi-channel temperature data handler
//
// Reference vectors from MetaWear-SDK-Cpp/test/test_multichanneltemperature.py

@Suite("Multi-Channel Temperature Data Handler")
struct MultiChannelTemperatureDataHandlerTests {

    // Python TestMultiChannelTemperatureMwr.test_get_temperature_data

    @Test func parse_mwR_onDie_32C() throws {
        // b'\x04\x81\x00\x00\x01' → 32.0 (raw 256 / 8)
        let packet = Data([0x04, 0x81, 0x00, 0x00, 0x01])
        let c = try MWThermometer(channel: 0).parseSample(from: packet)
        #expect(c == 32.0)
    }

    @Test func parse_mwR_extThermistor_21_5C() throws {
        // b'\x04\x81\x01\xac\x00' → 21.5 (raw 172 / 8)
        let packet = Data([0x04, 0x81, 0x01, 0xac, 0x00])
        let c = try MWThermometer(channel: 1).parseSample(from: packet)
        #expect(c == 21.5)
    }

    // Python TestMultiChannelTemperatureMwrPro.test_get_temperature_data

    @Test func parse_rpro_onDie_31_75C() throws {
        // b'\x04\x81\x00\xfe\x00' → 31.75 (raw 254 / 8)
        let packet = Data([0x04, 0x81, 0x00, 0xfe, 0x00])
        let c = try MWThermometer(channel: 0).parseSample(from: packet)
        #expect(c == 31.75)
    }

    @Test func parse_rpro_preset_21C() throws {
        // b'\x04\x81\x01\xa8\x00' → 21.00 (raw 168 / 8)
        let packet = Data([0x04, 0x81, 0x01, 0xa8, 0x00])
        let c = try MWThermometer(channel: 1).parseSample(from: packet)
        #expect(c == 21.00)
    }

    @Test func parse_rpro_ext_negative10_5C() throws {
        // b'\x04\x81\x02\xac\xff' → -10.5 (raw int16 = -84, /8 = -10.5)
        let packet = Data([0x04, 0x81, 0x02, 0xac, 0xff])
        let c = try MWThermometer(channel: 2).parseSample(from: packet)
        #expect(c == -10.5)
    }

    @Test func parse_rpro_bmp280_0C() throws {
        // b'\x04\x81\x03\x00\x00' → 0
        let packet = Data([0x04, 0x81, 0x03, 0x00, 0x00])
        let c = try MWThermometer(channel: 3).parseSample(from: packet)
        #expect(c == 0.0)
    }

    @Test func parse_shortPacket_throws() {
        // 4-byte packet (no channel byte) must be rejected.
        let packet = Data([0x04, 0x81, 0xC8, 0x00])
        #expect(throws: MWError.self) {
            _ = try MWThermometer(channel: 0).parseSample(from: packet)
        }
    }
}
