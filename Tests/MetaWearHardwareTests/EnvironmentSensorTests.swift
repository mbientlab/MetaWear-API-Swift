import Testing
import MetaWear

@Suite("Hardware — Environment Sensors", .serialized)
struct EnvironmentSensorTests {

    // MARK: - Temperature

    @Test @MainActor
    func temperature_nrfDie_returnsPlausibleValue() async throws {
        try await withConnectedDevice { device in
            let celsius = try await device.readTemperature(channel: 0)
            // NRF die runs warm; expect 15–75 °C
            #expect(celsius > 15, "NRF die temp should be > 15 °C, got \(celsius)")
            #expect(celsius < 75, "NRF die temp should be < 75 °C, got \(celsius)")
            print("\n  Temperature (NRF die): \(String(format: "%.2f", celsius)) °C\n")
        }
    }

    @Test @MainActor
    func temperature_boschChannel_returnsPlausibleValue() async throws {
        try await withConnectedDevice { device in
            // Channel 2 = Bosch IMU on-chip temp; only present if accelerometer is available
            guard await device.moduleInfo(for: .accelerometer)?.isPresent == true else {
                print("\n  Skipping Bosch temp — accelerometer module not present\n")
                return
            }
            let celsius = try await device.readTemperature(channel: 2)
            #expect(celsius > 10, "Bosch temp should be > 10 °C, got \(celsius)")
            #expect(celsius < 80, "Bosch temp should be < 80 °C, got \(celsius)")
            print("\n  Temperature (Bosch IMU): \(String(format: "%.2f", celsius)) °C\n")
        }
    }

    // MARK: - Barometer

    @Test @MainActor
    func barometer_pressure_returnsPlausibleValue() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .barometer)?.isPresent == true else {
                print("\n  Skipping barometer — module not present\n")
                return
            }

            let sensor = MWBarometer()
            let stream = try await device.stream(sensor)
            var readings: [Float] = []
            let collector = Task {
                for try await s in stream {
                    readings.append(s.value)
                }
            }

            try await Task.sleep(for: .seconds(3))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(readings.count > 0, "Should receive at least one pressure reading")
            if let p = readings.last {
                // Sea-level ~101325 Pa; altitude range 0–5000 m → ~54000–101325 Pa
                #expect(p > 54_000, "Pressure should be > 54 kPa, got \(p) Pa")
                #expect(p < 110_000, "Pressure should be < 110 kPa, got \(p) Pa")
                print("\n  Barometer: \(readings.count) readings, last = \(String(format: "%.1f", p)) Pa " +
                      "(\(String(format: "%.2f", p / 1000)) kPa)\n")
            }
        }
    }

    @Test @MainActor
    func altimeter_altitude_returnsPlausibleValue() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .barometer)?.isPresent == true else {
                print("\n  Skipping altimeter — barometer module not present\n")
                return
            }

            let sensor = MWAltimeter()
            let stream = try await device.stream(sensor)
            var readings: [Float] = []
            let collector = Task {
                for try await s in stream {
                    readings.append(s.value)
                }
            }

            try await Task.sleep(for: .seconds(3))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(readings.count > 0, "Should receive at least one altitude reading")
            if let alt = readings.last {
                // Reasonable altitude range: -500 m (Dead Sea) to 5000 m
                #expect(alt > -500, "Altitude should be > -500 m, got \(alt) m")
                #expect(alt < 5_000, "Altitude should be < 5000 m, got \(alt) m")
                print("\n  Altimeter: \(readings.count) readings, last = \(String(format: "%.1f", alt)) m\n")
            }
        }
    }

    // MARK: - Magnetometer

    @Test @MainActor
    func magnetometer_receivesData() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .magnetometer)?.isPresent == true else {
                print("\n  Skipping magnetometer — module not present\n")
                return
            }

            let sensor = MWMagnetometer(preset: .lowPower)
            let stream = try await device.stream(sensor)
            var samples: [CartesianFloat] = []
            let collector = Task {
                for try await s in stream {
                    samples.append(s.value)
                }
            }

            try await Task.sleep(for: .seconds(3))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(samples.count > 0, "Should receive at least one magnetometer sample")
            if let last = samples.last {
                // Earth's field ~25–65 µT; allow 5–100 µT indoors with interference
                let mag = (last.x * last.x + last.y * last.y + last.z * last.z).squareRoot()
                #expect(mag > 5,   "Magnetic field magnitude should be > 5 µT, got \(mag)")
                #expect(mag < 200, "Magnetic field magnitude should be < 200 µT, got \(mag)")
                print("\n  Magnetometer: \(samples.count) samples, " +
                      "last=(x:\(String(format: "%.2f", last.x)) " +
                      "y:\(String(format: "%.2f", last.y)) " +
                      "z:\(String(format: "%.2f", last.z))) µT  |B|=\(String(format: "%.2f", mag)) µT\n")
            }
        }
    }
}
