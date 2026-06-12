import Testing
import Foundation
import MetaWear

@Suite("Hardware — GPIO", .serialized)
struct GPIOTests {

    // MARK: - GPIO digital read

    @Test @MainActor
    func gpio_digitalRead_returnsWithoutError() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .gpio)?.isPresent == true else {
                print("\n  Skipping GPIO — module not present\n")
                return
            }

            // Configure pin 0 with pull-up before reading so it doesn't float
            try await device.send(MWGPIO.SetPull(pin: 0, pull: .up))
            let isHigh = try await device.readDigital(pin: 0)
            // With pull-up, an unconnected pin reads HIGH
            #expect(isHigh == true, "Pull-up pin 0 should read HIGH, got \(isHigh)")
            print("\n  GPIO pin 0 (pull-up): \(isHigh ? "HIGH" : "LOW")\n")
        }
    }

    @Test @MainActor
    func gpio_digitalRead_pullDown_readsLow() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .gpio)?.isPresent == true else {
                print("\n  Skipping GPIO — module not present\n")
                return
            }

            try await device.send(MWGPIO.SetPull(pin: 0, pull: .down))
            let isHigh = try await device.readDigital(pin: 0)
            // With pull-down, an unconnected pin reads LOW
            #expect(isHigh == false, "Pull-down pin 0 should read LOW, got \(isHigh)")
            print("\n  GPIO pin 0 (pull-down): \(isHigh ? "HIGH" : "LOW")\n")

            // Restore pull-up
            try await device.send(MWGPIO.SetPull(pin: 0, pull: .up))
        }
    }

    // MARK: - GPIO analog read

    @Test @MainActor
    func gpio_analogADC_returnsValue() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .gpio)?.isPresent == true else {
                print("\n  Skipping GPIO — module not present\n")
                return
            }

            let adc = try await device.readAnalogADC(pin: 0)
            // Raw 10-bit ADC: 0–1023
            #expect(adc <= 1023, "ADC value should be ≤ 1023, got \(adc)")
            print("\n  GPIO pin 0 ADC: \(adc) (raw 10-bit)\n")
        }
    }

    @Test @MainActor
    func gpio_analogAbsolute_returnsValue() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .gpio)?.isPresent == true else {
                print("\n  Skipping GPIO — module not present\n")
                return
            }

            let mv = try await device.readAnalogAbsolute(pin: 0)
            // Should be 0–3300 mV (3.3 V rail)
            #expect(mv <= 3300, "Analog absolute should be ≤ 3300 mV, got \(mv)")
            print("\n  GPIO pin 0 absolute analog: \(mv) mV\n")
        }
    }

    // MARK: - GPIO pin-change stream

    @Test @MainActor
    func gpio_pinChangeStream_startsWithoutError() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .gpio)?.isPresent == true else {
                print("\n  Skipping GPIO — module not present\n")
                return
            }

            let signal = MWGPIOPinChange(pin: 0, type: .any)
            let stream = try await device.startStream(signal)
            let collector = Task {
                for try await _ in stream { break }
            }
            // Just verify the stream starts — we can't force a pin change in a unit test
            try await Task.sleep(for: .seconds(1))
            collector.cancel()
            try await device.stopStreaming(signal)
            print("\n  ✓ GPIO pin-change stream started and stopped without error\n")
        }
    }
}
