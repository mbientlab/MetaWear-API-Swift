import Testing
import MetaWear

@Suite("Hardware — Haptic", .serialized)
struct HapticTests {
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
