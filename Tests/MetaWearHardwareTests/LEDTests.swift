//
//  LEDTests.swift
//  MetaWear
//

import Testing
import MetaWear
import Foundation

// Command-byte suites for MWLED (play/autoplay/pause/stop + preset patterns
// with and without delay) live in Tests/MetaWearTests/MWLEDTests.swift —
// they don't require hardware.

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
    func led_blueFlash() async throws {
        try await withConnectedDevice { device in
            try await device.send(MWLED.SetPattern(color: .blue, .flash))
            try await device.send(MWLED.Play())
            try await Task.sleep(for: .seconds(2))
            try await device.send(MWLED.Stop())
            print("\n  ✓ Blue LED flashed for 2 s\n")
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
