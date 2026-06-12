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
    func temperature_bmp280Channel_returnsPlausibleValue() async throws {
        try await withConnectedDevice { device in
            // The temperature module's `extra` bytes list the source code per
            // channel (matches MWThermometerSource raw values). Find whichever
            // channel is backed by BMP280 on this board — layouts vary:
            //   MetaWear R    (2 ch): [NRF_DIE, EXT_THERM]           → no BMP280
            //   MetaWear RPro (4 ch): [NRF_DIE, PRESET, EXT, BMP280] → channel 3
            guard let info = await device.moduleInfo(for: .temperature),
                  info.isPresent else {
                print("\n  Skipping BMP280 temp — temperature module not present\n")
                return
            }
            guard let channel = info.extra.firstIndex(of: UInt8(MWThermometerSource.bmp280.rawValue)) else {
                print("\n  Skipping BMP280 temp — no BMP280-backed channel on this board (sources=\(info.extra))\n")
                return
            }

            // BMP280 defaults to sleep mode (ctrl_meas mode=00); the temperature
            // register reads 0 until the chip is running. The multi-channel-temp
            // driver does NOT auto-wake the chip — start the barometer briefly
            // so at least one conversion completes before we issue the read.
            let baro = MWBarometer()
            let stream = try await device.startStream(baro)
            let drain = Task { for try await _ in stream { /* discard */ } }
            try await Task.sleep(for: .milliseconds(200))

            let celsius = try await device.readTemperature(channel: UInt8(channel))

            drain.cancel()
            try await device.stopStreaming(baro)

            #expect(celsius > 10, "BMP280 temp should be > 10 °C, got \(celsius)")
            #expect(celsius < 80, "BMP280 temp should be < 80 °C, got \(celsius)")
            print("\n  Temperature (BMP280, channel \(channel)): \(String(format: "%.2f", celsius)) °C\n")
        }
    }

    @Test @MainActor
    func temperature_presetThermistor_returnsPlausibleValue() async throws {
        try await withConnectedDevice { device in
            // Preconfigured thermistor (driver ID 0x03) — the firmware has
            // already wired up the GPIO pin and pulldown, so no configure is
            // needed. Only present on boards that ship with an on-board
            // thermistor (e.g. RPro at channel 1).
            guard let info = await device.moduleInfo(for: .temperature),
                  info.isPresent else {
                print("\n  Skipping preset thermistor — temperature module not present\n")
                return
            }
            guard let channel = info.extra.firstIndex(of: UInt8(MWThermometerSource.presetThermistor.rawValue)) else {
                print("\n  Skipping preset thermistor — no preset-thermistor channel on this board (sources=\(info.extra))\n")
                return
            }
            let celsius = try await device.readTemperature(channel: UInt8(channel))
            #expect(celsius > 0,  "Preset thermistor should be > 0 °C, got \(celsius)")
            #expect(celsius < 60, "Preset thermistor should be < 60 °C, got \(celsius)")
            print("\n  Temperature (preset thermistor, channel \(channel)): \(String(format: "%.2f", celsius)) °C\n")
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
            let stream = try await device.startStream(sensor)
            var readings: [Float] = []
            var count = 0
            let collector = Task {
                for try await s in stream {
                    count += 1
                    print(formatSample(count, s.value, unit: "Pa"))
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
            let stream = try await device.startStream(sensor)
            var readings: [Float] = []
            var count = 0
            let collector = Task {
                for try await s in stream {
                    count += 1
                    print(formatSample(count, s.value, unit: "m"))
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
            let stream = try await device.startStream(sensor)
            var samples: [CartesianFloat] = []
            var count = 0
            let collector = Task {
                for try await s in stream {
                    count += 1
                    print(formatSample(count, s.value, unit: "µT"))
                    samples.append(s.value)
                }
            }

            try await Task.sleep(for: .seconds(10))
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
