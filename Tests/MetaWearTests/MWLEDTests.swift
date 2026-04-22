import Testing
import Foundation
@testable import MetaWear

@Suite("LED Commands")
struct LEDCommandTests {

    // MARK: - SetPattern command

    @Test func setPattern_correctLength() {
        let cmd = MWLED.SetPattern(color: .red, pattern: .blink)
        // [module, register, color, 0x02, highInt, lowInt, rise(2), high(2), fall(2), pulse(2), delay(2), repeat] = 17 bytes
        #expect(cmd.commandData.count == 17)
    }

    @Test func setPattern_moduleAndRegisterBytes() {
        let cmd = MWLED.SetPattern(color: .green, pattern: .blink)
        #expect(cmd.commandData[0] == 0x02)  // LED module
        #expect(cmd.commandData[1] == 0x03)  // LED_CONFIG register
    }

    @Test func setPattern_colorBytes() {
        #expect(MWLED.SetPattern(color: .green, .blink).commandData[2] == 0)
        #expect(MWLED.SetPattern(color: .red,   .blink).commandData[2] == 1)
        #expect(MWLED.SetPattern(color: .blue,  .blink).commandData[2] == 2)
    }

    @Test func setPattern_fixedByte() {
        // Byte index 3 is always 0x02 per protocol spec
        let cmd = MWLED.SetPattern(color: .red, .blink)
        #expect(cmd.commandData[3] == 0x02)
    }

    @Test func setPattern_intensityBytes() {
        let p = MWLEDPattern(highIntensity: 20, lowIntensity: 5,
                             riseTime: 0, highTime: 200, fallTime: 0,
                             pulseDuration: 1000, delay: 0, repeatCount: 3)
        let cmd = MWLED.SetPattern(color: .red, pattern: p)
        #expect(cmd.commandData[4] == 20)  // highIntensity
        #expect(cmd.commandData[5] == 5)   // lowIntensity
    }

    @Test func setPattern_timingBytesLittleEndian() {
        // riseTime=0x0102 (258ms), at offset 6-7
        let p = MWLEDPattern(highIntensity: 31, lowIntensity: 0,
                             riseTime: 0x0102, highTime: 0x0304, fallTime: 0x0506,
                             pulseDuration: 0x0708, delay: 0x090A, repeatCount: 0)
        let cmd = MWLED.SetPattern(color: .green, pattern: p)
        let data = cmd.commandData
        // rise at [6,7]
        #expect(data[6] == 0x02 && data[7] == 0x01)
        // high at [8,9]
        #expect(data[8] == 0x04 && data[9] == 0x03)
        // fall at [10,11]
        #expect(data[10] == 0x06 && data[11] == 0x05)
        // pulse at [12,13]
        #expect(data[12] == 0x08 && data[13] == 0x07)
        // delay at [14,15]
        #expect(data[14] == 0x0A && data[15] == 0x09)
    }

    @Test func setPattern_repeatCountByte() {
        let p = MWLEDPattern(repeatCount: 5)
        let cmd = MWLED.SetPattern(color: .blue, pattern: p)
        #expect(cmd.commandData[16] == 5)
    }

    @Test func setPattern_repeatCountZero_indefinite() {
        // 0 means indefinite per protocol
        let p = MWLEDPattern(repeatCount: 0)
        let cmd = MWLED.SetPattern(color: .red, pattern: p)
        #expect(cmd.commandData[16] == 0)
    }

    // MARK: - Preset patterns

    @Test func solidPreset_noBlink() {
        // Solid: rise=0, fall=0, lowIntensity == highIntensity (never dims between pulses)
        let p = MWLEDPattern.solid
        #expect(p.riseTime == 0)
        #expect(p.fallTime == 0)
        #expect(p.lowIntensity == p.highIntensity)
    }

    @Test func blinkPreset_shortHighTime() {
        let p = MWLEDPattern.blink
        #expect(p.highTime < p.pulseDuration)
        #expect(p.riseTime == 0)
        #expect(p.fallTime == 0)
    }

    @Test func breathePreset_hasRiseAndFall() {
        let p = MWLEDPattern.breathe
        #expect(p.riseTime > 0)
        #expect(p.fallTime > 0)
    }

    @Test func flashPreset_finiteRepeat() {
        #expect(MWLEDPattern.flash.repeatCount > 0)
    }

    // MARK: - Preset exact values (pinned against C++ SDK reference)

    @Test func solidPreset_exactValues() {
        let p = MWLEDPattern.solid
        #expect(p.highIntensity  == 31)
        #expect(p.lowIntensity   == 31)
        #expect(p.riseTime       == 0)
        #expect(p.highTime       == 500)
        #expect(p.fallTime       == 0)
        #expect(p.pulseDuration  == 1000)
        #expect(p.repeatCount    == .max)  // 0xFF = repeat indefinitely (MbientLab Swift SDK convention)
    }

    @Test func blinkPreset_exactValues() {
        let p = MWLEDPattern.blink
        #expect(p.highIntensity  == 31)
        #expect(p.lowIntensity   == 0)
        #expect(p.riseTime       == 0)
        #expect(p.highTime       == 50)
        #expect(p.fallTime       == 0)
        #expect(p.pulseDuration  == 500)
        #expect(p.repeatCount    == .max)
    }

    @Test func breathePreset_exactValues() {
        let p = MWLEDPattern.breathe
        #expect(p.highIntensity  == 31)
        #expect(p.riseTime       == 725)
        #expect(p.highTime       == 500)
        #expect(p.fallTime       == 725)
        #expect(p.pulseDuration  == 2000)
        #expect(p.repeatCount    == .max)
    }

    @Test func flashPreset_exactValues() {
        let p = MWLEDPattern.flash
        #expect(p.highIntensity  == 31)
        #expect(p.lowIntensity   == 0)
        #expect(p.riseTime       == 0)
        #expect(p.highTime       == 100)
        #expect(p.fallTime       == 0)
        #expect(p.pulseDuration  == 500)
        #expect(p.repeatCount    == 3)
    }

    // MARK: - Play / Pause / Stop

    @Test func play_command() {
        let cmd = MWLED.Play()
        #expect(cmd.commandData == Data([0x02, 0x01, 0x01]))
    }

    @Test func autoplay_command() {
        let cmd = MWLED.Autoplay()
        #expect(cmd.commandData == Data([0x02, 0x01, 0x02]))
    }

    @Test func pause_command() {
        let cmd = MWLED.Pause()
        #expect(cmd.commandData == Data([0x02, 0x01, 0x00]))
    }

    @Test func stop_keepPattern() {
        let cmd = MWLED.Stop(clearPattern: false)
        #expect(cmd.commandData == Data([0x02, 0x02, 0x00]))
    }

    @Test func stop_clearPattern() {
        let cmd = MWLED.Stop(clearPattern: true)
        #expect(cmd.commandData == Data([0x02, 0x02, 0x01]))
    }

    @Test func stop_defaultClearsPattern() {
        let cmd = MWLED.Stop()
        #expect(cmd.commandData == Data([0x02, 0x02, 0x01]))
    }

    // MARK: - Reference vectors from test_led.py (MbientLab C++ SDK)
    // Packet layout: [module, register, color, 0x02, highInt, lowInt,
    //                 rise(le16), high(le16), fall(le16), pulse(le16), delay(le16), repeat]

    @Test func blinkPreset_referenceVector_green() {
        // BLINK loaded into green channel; delay=0, repeat=10
        let p = MWLEDPattern(highIntensity: 31, lowIntensity: 0, riseTime: 0, highTime: 50,
                             fallTime: 0, pulseDuration: 500, delay: 0, repeatCount: 10)
        let cmd = MWLED.SetPattern(color: .green, pattern: p)
        #expect(cmd.commandData == Data([0x02, 0x03, 0x00, 0x02,
                                         0x1f, 0x00,
                                         0x00, 0x00,
                                         0x32, 0x00,
                                         0x00, 0x00,
                                         0xf4, 0x01,
                                         0x00, 0x00,
                                         0x0a]))
    }

    @Test func solidPreset_referenceVector_red() {
        // SOLID loaded into red channel; delay=0, repeat=20
        let p = MWLEDPattern(highIntensity: 31, lowIntensity: 31, riseTime: 0, highTime: 500,
                             fallTime: 0, pulseDuration: 1000, delay: 0, repeatCount: 20)
        let cmd = MWLED.SetPattern(color: .red, pattern: p)
        #expect(cmd.commandData == Data([0x02, 0x03, 0x01, 0x02,
                                         0x1f, 0x1f,
                                         0x00, 0x00,
                                         0xf4, 0x01,
                                         0x00, 0x00,
                                         0xe8, 0x03,
                                         0x00, 0x00,
                                         0x14]))
    }

    @Test func pulsePreset_referenceVector_blue() {
        // PULSE (breathe) loaded into blue channel; delay=0, repeat=40
        let p = MWLEDPattern(highIntensity: 31, lowIntensity: 0, riseTime: 725, highTime: 500,
                             fallTime: 725, pulseDuration: 2000, delay: 0, repeatCount: 40)
        let cmd = MWLED.SetPattern(color: .blue, pattern: p)
        #expect(cmd.commandData == Data([0x02, 0x03, 0x02, 0x02,
                                         0x1f, 0x00,
                                         0xd5, 0x02,
                                         0xf4, 0x01,
                                         0xd5, 0x02,
                                         0xd0, 0x07,
                                         0x00, 0x00,
                                         0x28]))
    }

    @Test func blinkPreset_delayedFirmware_referenceVector() {
        // Same as blink test but delay=5000ms (firmware >= 1.2.3)
        let p = MWLEDPattern(highIntensity: 31, lowIntensity: 0, riseTime: 0, highTime: 50,
                             fallTime: 0, pulseDuration: 500, delay: 5000, repeatCount: 10)
        let cmd = MWLED.SetPattern(color: .green, pattern: p)
        #expect(cmd.commandData == Data([0x02, 0x03, 0x00, 0x02,
                                         0x1f, 0x00,
                                         0x00, 0x00,
                                         0x32, 0x00,
                                         0x00, 0x00,
                                         0xf4, 0x01,
                                         0x88, 0x13,   // 5000ms LE16
                                         0x0a]))
    }
}
