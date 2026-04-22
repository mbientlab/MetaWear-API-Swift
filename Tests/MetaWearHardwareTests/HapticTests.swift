import Testing
import MetaWear

@Suite("Hardware — LED & Haptic", .serialized)
struct LEDHapticTests {

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
    func haptic_motorPulse() async throws {
        try await withConnectedDevice { device in
            try await device.send(MWHaptic.motor(dutyCycle: 80, pulseWidth: 300))
            try await Task.sleep(for: .milliseconds(400))
            print("\n  ✓ Haptic motor pulsed 300 ms at 80 % duty cycle\n")
        }
    }

    @Test @MainActor
    func haptic_buzzerPulse() async throws {
        try await withConnectedDevice { device in
            try await device.send(MWHaptic.buzzer(pulseWidth: 200))
            try await Task.sleep(for: .milliseconds(300))
            print("\n  ✓ Buzzer pulsed 200 ms\n")
        }
    }

    @Test @MainActor
    func haptic_motorAtMaxDutyCycle() async throws {
        try await withConnectedDevice { device in
            try await device.send(MWHaptic.motor(dutyCycle: 100, pulseWidth: 500))
            try await Task.sleep(for: .milliseconds(600))
            print("\n  ✓ Haptic motor pulsed 500 ms at 100 % duty cycle\n")
        }
    }
}
