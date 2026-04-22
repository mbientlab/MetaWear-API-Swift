//
//  LEDTests.swift
//  MetaWear
//

import Testing
import MetaWear
import Foundation

// MARK: - TestLedControl
//
// Verifies the command bytes for play, autoplay, pause, stop, and stop-and-clear.
// No hardware required.

@Suite("LED — Control Commands")
struct LedControlCommandTests {

    // test_play → expected [0x02, 0x01, 0x01]
    @Test func play() {
        #expect(MWLED.Play().commandData == Data([0x02, 0x01, 0x01]))
    }

    // test_autoplay → expected [0x02, 0x01, 0x02]
    @Test func autoplay() {
        #expect(MWLED.Autoplay().commandData == Data([0x02, 0x01, 0x02]))
    }

    // test_pause → expected [0x02, 0x01, 0x00]
    @Test func pause() {
        #expect(MWLED.Pause().commandData == Data([0x02, 0x01, 0x00]))
    }

    // test_stop_clear → mbl_mw_led_stop_and_clear → expected [0x02, 0x02, 0x01]
    @Test func stop_and_clear() {
        #expect(MWLED.Stop(clearPattern: true).commandData == Data([0x02, 0x02, 0x01]))
    }

    // test_stop_no_clear → mbl_mw_led_stop(board, 0) → expected [0x02, 0x02, 0x00]
    @Test func stop_no_clear() {
        #expect(MWLED.Stop(clearPattern: false).commandData == Data([0x02, 0x02, 0x00]))
    }
}

// MARK: - TestLedPattern
//
// Preset patterns written with no delay (board LED revision 0 in C++ tests).
// Command layout (17 bytes):
//   [module=0x02, reg=0x03, color, 0x02,
//    highIntensity, lowIntensity,
//    riseTime(LE16), highTime(LE16), fallTime(LE16), pulseDuration(LE16),
//    delay(LE16), repeatCount]

@Suite("LED — Preset Patterns (no delay)")
struct LedPatternCommandTests {

    // test_blink_pattern
    // LedPreset.BLINK: high=31, low=0, rise=0ms, highTime=50ms, fall=0ms, pulse=500ms
    // delay_time_ms=5000 → ignored on rev-0 board → delay=0 in command
    // repeat=10, color=GREEN(0x00)
    // expected= [0x02, 0x03, 0x00, 0x02, 0x1f, 0x00, 0x00, 0x00, 0x32, 0x00, 0x00, 0x00, 0xf4, 0x01, 0x00, 0x00, 0x0a]

    @Test func blink_green_repeat10() {
        let pattern = MWLEDPattern(highIntensity: 31, lowIntensity: 0,
                                   riseTime: 0, highTime: 50,
                                   fallTime: 0, pulseDuration: 500,
                                   delay: 0, repeatCount: 10)
        let cmd = MWLED.SetPattern(color: .green, pattern: pattern).commandData
        #expect(cmd == Data([0x02, 0x03, 0x00, 0x02,
                             0x1f, 0x00,
                             0x00, 0x00,   // riseTime=0
                             0x32, 0x00,   // highTime=50
                             0x00, 0x00,   // fallTime=0
                             0xf4, 0x01,   // pulseDuration=500
                             0x00, 0x00,   // delay=0
                             0x0a]))       // repeatCount=10
    }

    // test_solid_pattern
    // LedPreset.SOLID: high=31, low=31, rise=0ms, highTime=500ms, fall=0ms, pulse=1000ms
    // delay_time_ms=10000 → delay=0 (rev-0 board), repeat=20, color=RED(0x01)
    // expected= [0x02, 0x03, 0x01, 0x02, 0x1f, 0x1f, 0x00, 0x00, 0xf4, 0x01, 0x00, 0x00, 0xE8, 0x03, 0x00, 0x00, 0x14]

    @Test func solid_red_repeat20() {
        let pattern = MWLEDPattern(highIntensity: 31, lowIntensity: 31,
                                   riseTime: 0, highTime: 500,
                                   fallTime: 0, pulseDuration: 1000,
                                   delay: 0, repeatCount: 20)
        let cmd = MWLED.SetPattern(color: .red, pattern: pattern).commandData
        #expect(cmd == Data([0x02, 0x03, 0x01, 0x02,
                             0x1f, 0x1f,
                             0x00, 0x00,   // riseTime=0
                             0xf4, 0x01,   // highTime=500
                             0x00, 0x00,   // fallTime=0
                             0xe8, 0x03,   // pulseDuration=1000
                             0x00, 0x00,   // delay=0
                             0x14]))       // repeatCount=20
    }

    // test_pulse_pattern
    // LedPreset.PULSE: high=31, low=0, rise=725ms, highTime=500ms, fall=725ms, pulse=2000ms
    // delay_time_ms=12345 → delay=0 (rev-0 board), repeat=40, color=BLUE(0x02)
    // expected= [0x02, 0x03, 0x02, 0x02, 0x1f, 0x00, 0xd5, 0x02, 0xf4, 0x01, 0xd5, 0x02, 0xd0, 0x07, 0x00, 0x00, 0x28]

    @Test func pulse_blue_repeat40() {
        let pattern = MWLEDPattern(highIntensity: 31, lowIntensity: 0,
                                   riseTime: 725, highTime: 500,
                                   fallTime: 725, pulseDuration: 2000,
                                   delay: 0, repeatCount: 40)
        let cmd = MWLED.SetPattern(color: .blue, pattern: pattern).commandData
        #expect(cmd == Data([0x02, 0x03, 0x02, 0x02,
                             0x1f, 0x00,
                             0xd5, 0x02,   // riseTime=725
                             0xf4, 0x01,   // highTime=500
                             0xd5, 0x02,   // fallTime=725
                             0xd0, 0x07,   // pulseDuration=2000
                             0x00, 0x00,   // delay=0
                             0x28]))       // repeatCount=40
    }
}

// MARK: - TestLedDelayedPattern
//
// Same presets as above but with the delay field populated (board LED revision ≥ 1).
// In Swift the delay is always encoded in the command; no board-revision branching needed.

@Suite("LED — Preset Patterns (with delay)")
struct LedDelayedPatternCommandTests {

    // test_blink_pattern (delayed)
    // BLINK + delay=5000ms (0x1388 LE → [0x88, 0x13]), repeat=10, color=GREEN
    // expected= [0x02, 0x03, 0x00, 0x02, 0x1f, 0x00, 0x00, 0x00, 0x32, 0x00, 0x00, 0x00, 0xf4, 0x01, 0x88, 0x13, 0x0a]

    @Test func blink_green_delay5000_repeat10() {
        let pattern = MWLEDPattern(highIntensity: 31, lowIntensity: 0,
                                   riseTime: 0, highTime: 50,
                                   fallTime: 0, pulseDuration: 500,
                                   delay: 5000, repeatCount: 10)
        let cmd = MWLED.SetPattern(color: .green, pattern: pattern).commandData
        #expect(cmd == Data([0x02, 0x03, 0x00, 0x02,
                             0x1f, 0x00,
                             0x00, 0x00,   // riseTime=0
                             0x32, 0x00,   // highTime=50
                             0x00, 0x00,   // fallTime=0
                             0xf4, 0x01,   // pulseDuration=500
                             0x88, 0x13,   // delay=5000
                             0x0a]))       // repeatCount=10
    }

    // test_solid_pattern (delayed)
    // SOLID + delay=10000ms (0x2710 LE → [0x10, 0x27]), repeat=20, color=RED
    // expected= [0x02, 0x03, 0x01, 0x02, 0x1f, 0x1f, 0x00, 0x00, 0xf4, 0x01, 0x00, 0x00, 0xE8, 0x03, 0x10, 0x27, 0x14]

    @Test func solid_red_delay10000_repeat20() {
        let pattern = MWLEDPattern(highIntensity: 31, lowIntensity: 31,
                                   riseTime: 0, highTime: 500,
                                   fallTime: 0, pulseDuration: 1000,
                                   delay: 10000, repeatCount: 20)
        let cmd = MWLED.SetPattern(color: .red, pattern: pattern).commandData
        #expect(cmd == Data([0x02, 0x03, 0x01, 0x02,
                             0x1f, 0x1f,
                             0x00, 0x00,   // riseTime=0
                             0xf4, 0x01,   // highTime=500
                             0x00, 0x00,   // fallTime=0
                             0xe8, 0x03,   // pulseDuration=1000
                             0x10, 0x27,   // delay=10000
                             0x14]))       // repeatCount=20
    }

    // test_pulse_pattern (delayed)
    // PULSE + delay=12345ms (0x3039 LE → [0x39, 0x30]), repeat=40, color=BLUE
    // expected= [0x02, 0x03, 0x02, 0x02, 0x1f, 0x00, 0xd5, 0x02, 0xf4, 0x01, 0xd5, 0x02, 0xd0, 0x07, 0x39, 0x30, 0x28]

    @Test func pulse_blue_delay12345_repeat40() {
        let pattern = MWLEDPattern(highIntensity: 31, lowIntensity: 0,
                                   riseTime: 725, highTime: 500,
                                   fallTime: 725, pulseDuration: 2000,
                                   delay: 12345, repeatCount: 40)
        let cmd = MWLED.SetPattern(color: .blue, pattern: pattern).commandData
        #expect(cmd == Data([0x02, 0x03, 0x02, 0x02,
                             0x1f, 0x00,
                             0xd5, 0x02,   // riseTime=725
                             0xf4, 0x01,   // highTime=500
                             0xd5, 0x02,   // fallTime=725
                             0xd0, 0x07,   // pulseDuration=2000
                             0x39, 0x30,   // delay=12345
                             0x28]))       // repeatCount=40
    }
}

// MARK: - Hardware LED tests
//
// Visual/functional tests — require a connected MetaWear device.

@Suite("Hardware — LED", .serialized)
struct LedHardwareTests {

    @Test @MainActor
    func led_greenFlash() async throws {
        try await withConnectedDevice { device in
            try await device.send(MWLED.SetPattern(color: .green, .flash))
            try await device.send(MWLED.Play())
            try await Task.sleep(for: .seconds(2))
            try await device.send(MWLED.Stop())
            print("\n  ✓ Green LED flashed for 2 s\n")
        }
    }

    @Test @MainActor
    func led_multiChannel() async throws {
        try await withConnectedDevice { device in
            try await device.setLED(
                red:   MWLEDPattern(highIntensity: 10, lowIntensity: 0, riseTime: 100,
                                    highTime: 200, fallTime: 100, pulseDuration: 800,
                                    delay: 0, repeatCount: 3),
                green: MWLEDPattern(highIntensity: 31, lowIntensity: 0, riseTime: 100,
                                    highTime: 300, fallTime: 100, pulseDuration: 800,
                                    delay: 0, repeatCount: 3),
                autoPlay: true
            )
            try await Task.sleep(for: .seconds(3))
            try await device.stopLED()
            print("\n  ✓ Multi-channel LED (red + green) ran for 3 s\n")
        }
    }

    @Test @MainActor
    func led_stopClearsPattern() async throws {
        try await withConnectedDevice { device in
            try await device.send(MWLED.SetPattern(color: .blue, .blink))
            try await device.send(MWLED.Play())
            try await Task.sleep(for: .seconds(2))
            try await device.send(MWLED.Stop(clearPattern: true))
            try await Task.sleep(for: .seconds(1))
            print("\n  ✓ LED stopped and pattern cleared\n")
        }
    }

    @Test @MainActor
    func led_breathe() async throws {
        try await withConnectedDevice { device in
            try await device.setLED(blue: .breathe, autoPlay: true)
            try await Task.sleep(for: .seconds(4))
            try await device.stopLED()
            print("\n  ✓ Blue LED breathed for 4 s\n")
        }
    }

    @Test @MainActor
    func led_solid_white() async throws {
        try await withConnectedDevice { device in
            try await device.setLED(red: .solid, green: .solid, blue: .solid, autoPlay: true)
            try await Task.sleep(for: .seconds(2))
            try await device.stopLED()
            print("\n  ✓ White (all channels solid) for 2 s\n")
        }
    }

    @Test @MainActor
    func led_autoplay() async throws {
        try await withConnectedDevice { device in
            try await device.send(MWLED.Autoplay())
            try await device.send(MWLED.SetPattern(color: .green, .blink))
            try await Task.sleep(for: .seconds(2))
            try await device.send(MWLED.Stop(clearPattern: true))
            print("\n  ✓ Autoplay: green blink started without explicit Play\n")
        }
    }

    @Test @MainActor
    func led_pause_resume() async throws {
        try await withConnectedDevice { device in
            try await device.send(MWLED.SetPattern(color: .red, .blink))
            try await device.send(MWLED.Play())
            try await Task.sleep(for: .seconds(1))
            try await device.send(MWLED.Pause())
            try await Task.sleep(for: .seconds(1))
            try await device.send(MWLED.Play())
            try await Task.sleep(for: .seconds(1))
            try await device.send(MWLED.Stop(clearPattern: true))
            print("\n  ✓ Red LED played, paused, then resumed\n")
        }
    }
}
