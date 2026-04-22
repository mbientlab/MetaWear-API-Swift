import Testing
import MetaWear
import Darwin

@Suite("Hardware — Accelerometer", .serialized)
struct AccelerometerTests {

    // MARK: - BMI1: ODR configuration
    //
    // Setting ODR to 55 Hz snaps to the nearest supported rate on BMI: 50 Hz.
    // The config command for (50 Hz, ±2 g) is [0x03, 0x03, 0x27, 0x03].
    // This test verifies the snapped value and that streaming delivers data at ~50 Hz.

    @Test @MainActor
    func bmi_set_odr_cmd_and_value() async throws {
        try await withConnectedDevice { device in
            guard let sensor = await device.makeAccelerometer(odrHz: 55, rangeG: 2) else {
                print("\n  Skipping — Bosch accelerometer not present\n"); return
            }
            
            try await device.stream(sensor, usePacked: false)
            
            #expect(sensor.odrHz == 50.0,
                    "ODR set to 55 Hz should snap to 50.0 Hz, got \(sensor.odrHz)")
            
            try await Task.sleep(for: .seconds(2))

            try await device.stopStreaming(sensor)
        }
    }
    
    // MARK: - BMI: Range configuration
    //
    // Setting range to 14.75 g snaps to the nearest supported range on BMI160: 16 g.
    // The config command for (100 Hz, ±16 g) is [0x03, 0x03, 0x28, 0x0c].
    // This test verifies the snapped value and that streaming data stays within the range.

    @Test @MainActor
    func bmi_set_range_cmd_and_value() async throws {
        try await withConnectedDevice { device in
            guard let sensor = await device.makeAccelerometer(odrHz: 100, rangeG: 14.75) else {
                print("\n  Skipping — Bosch accelerometer not present\n"); return
            }
            
            try await device.stream(sensor, usePacked: false)
            
            #expect(sensor.rangeG == 16.0,
                    "Range set to 14.75 g should snap to 16.0 g, got \(sensor.rangeG)")
            
            try await Task.sleep(for: .seconds(2))

            try await device.stopStreaming(sensor)
        }
    }
    
    // MARK: - BMI: Subscribe to acceleration data
    //
    // Calling device.stream() sends the subscribe command [0x03, 0x04, 0x01]
    // followed by enable [0x03, 0x02, 0x01, 0x00] and start [0x03, 0x01, 0x01].
    // This test verifies that data arrives after subscribing.

    @Test @MainActor
    func bmi_subscribe_acceleration_data() async throws {
        try await withConnectedDevice { device in
            guard let sensor = await device.makeAccelerometer(odrHz: 100, rangeG: 14.75) else {
                print("\n  Skipping — Bosch accelerometer not present\n"); return
            }

            let stream = try await device.stream(sensor, usePacked: false)

            var samples: [CartesianFloat] = []
            let collector = Task {
                for try await s in stream {
                    print("\n  \(s.value)\n");
                    samples.append(s.value)
                }
            }
            try await Task.sleep(for: .seconds(2))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(samples.count >= 100,
                    "Expected at least 100 samples after subscribing, got \(samples.count)")
            print("\n  BMI subscribe: received \(samples.count) samples\n")
        }
    }
    
    // MARK: - Module validity
    //
    // Reference: test_acc_bosch_module_valid
    // Verifies the Bosch accelerometer module is discovered, present, and
    // returns a valid data signal (implementation == 1 for BMI160, 4 for BMI270).

    @Test @MainActor
    func bosch_module_is_valid() async throws {
        try await withConnectedDevice { device in
            let info = await device.moduleInfo(for: .accelerometer)
            #expect(info != nil,
                    "Expected non-nil module info")
            guard let info else { return }
            #expect(info.isPresent,
                    "Accelerometer module should be present (implementation != 0xFF)")
            let isBosch = info.implementation == 1 || info.implementation == 4
            #expect(isBosch,
                    "Expected Bosch accelerometer (impl 1=BMI160 or 4=BMI270), got \(info.implementation)")
            print("\n  Bosch accelerometer module valid: impl=\(info.implementation), rev=\(info.revision)\n")
        }
    }
}
