import Testing
import MetaWear
import Foundation

// MARK: - One-shot reads — round-trip every MWReadable on real hardware
//
// Parity port of `MetaWear-Swift-Combine-SDK/Tests/IntegrationTests/MacTests/
// TestSuite/Integration/ReadTests.swift`. The legacy `_testRead` helper just
// proved that each readable returns *something* over a real BLE link without
// asserting anything about the value. We do the same here, plus light value
// validation where it's cheap and unambiguous (battery range, MAC format,
// reset-UID 3-bit mask, etc.) — those checks pay for themselves by catching
// parser regressions that a "did we get bytes back" smoke would miss.
//
// Legacy mapping:
//   test_Read_Temperature   → temperature_eachAvailableChannelReadsCelsius
//   test_Read_BatteryLevel  → battery_readReturnsBatteryState
//   test_Read_LastResetTime → lastResetTime_readReturnsPlausibleEpoch
//   test_Read_LogLength     → logLength_readReturnsCount
//   test_Read_Humidity      → humidity_readReturnsPercent (skips on no-BME280 boards)
//   test_Read_MACAddress    → macAddress_readReturnsColonString
//
// Some of these have value-bound siblings elsewhere (e.g. `EnvironmentSensorTests`
// exercises specific temperature channels, `ConnectivityTests` covers battery
// and MAC). This file's job is the *generic* `device.read(_:)` surface — one
// test per readable, matching the legacy file 1:1.

@Suite("Hardware — Reads", .serialized)
struct ReadTests {

    // MARK: - Temperature (every channel the board reports)
    //
    // The legacy test iterated `[.onboard, .bmp280, .onDie, .external]` and
    // called `try .thermometer(type:, board:)` for each — `thermometer` would
    // resolve the source enum to whatever channel index that board uses, then
    // try a read. Boards that don't expose a given source raise a build-time
    // error ("not supported on this board"); the test treats a per-source
    // failure as a per-source assertion.
    //
    // The Swift 6 SDK exposes channels directly (since the channel→source map
    // is in `info.extra`). Rather than iterate sources and resolve them, we
    // iterate every channel the firmware reports and validate the result. If
    // the board returns 0 channels we skip — same shape as the legacy test on
    // a board with no temperature module.

    @Test @MainActor
    func temperature_eachAvailableChannelReadsCelsius() async throws {
        try await withConnectedDevice { device in
            let info = try #require(await device.moduleInfo(for: .temperature),
                                    "temperature module info missing")
            try #require(info.isPresent, "temperature module not present on this board")
            // `info.extra` is the per-channel source map (one byte per
            // channel; raw values match `MWThermometerSource`).
            let sources = info.extra
            #expect(sources.count > 0,
                    "Temperature module reports zero channels — firmware bug?")

            print("\n  Temperature channels reported: \(sources.count)")
            for (index, raw) in sources.enumerated() {
                let source = MWThermometerSource(rawValue: Int8(bitPattern: raw))
                    .map { String(describing: $0) } ?? "raw=0x\(String(format: "%02X", raw))"
                let channel = UInt8(index)

                // BMP280 sleeps by default — start the barometer briefly so
                // its temperature register has a fresh sample. Other sources
                // (NRF die, preset/external thermistor) read instantly.
                var bmp280Drain: Task<Void, Error>? = nil
                let baro = MWBarometer()
                if raw == UInt8(MWThermometerSource.bmp280.rawValue) {
                    let stream = try await device.startStream(baro)
                    bmp280Drain = Task { for try await _ in stream { /* discard */ } }
                    try await Task.sleep(for: .milliseconds(200))
                }

                let celsius = try await device.read(MWThermometer(channel: channel)).value

                if bmp280Drain != nil {
                    bmp280Drain?.cancel()
                    try await device.stopStreaming(baro)
                }

                // Loose plausibility: not all channels return room-temperature
                // (an unwired external thermistor floats), but the parsed
                // value should still land in a sane Float range. The bound
                // here mirrors the BMI/BME operating envelope.
                #expect(celsius.isFinite, "Channel \(index) returned non-finite \(celsius) °C")
                #expect(celsius > -50,    "Channel \(index) returned implausible \(celsius) °C")
                #expect(celsius < 125,    "Channel \(index) returned implausible \(celsius) °C")
                print(String(format: "    [ch %d  %@]  %+6.2f °C",
                             index, source, celsius))
            }
            print("")
        }
    }

    // MARK: - Battery
    //
    // `MWSettings.ReadBatteryState` returns `BatteryState(charge:voltage:)`.
    // Charge is firmware-reported %, voltage is mV. This exercises the same
    // wire path that `device.readBattery()` covers in `ConnectivityTests`,
    // but goes through the generic `device.read(MWReadable)` surface to keep
    // legacy parity with `_testRead { _ in .batteryLevel }`.

    @Test @MainActor
    func battery_readReturnsBatteryState() async throws {
        try await withConnectedDevice { device in
            let battery = try await device.read(MWSettings.ReadBatteryState()).value
            print("\n  Battery: \(battery.charge) %  (\(battery.voltage) mV)\n")

            #expect(battery.charge <= 100,
                    "Battery charge out of range: \(battery.charge) %")
            #expect(battery.voltage > 0,
                    "Battery voltage must be positive, got \(battery.voltage) mV")
            // Realistic Li-Po envelope: 3.0–4.5 V. Outside this range usually
            // means a parse error, not a depleted battery.
            #expect(battery.voltage > 2_500,
                    "Battery voltage \(battery.voltage) mV is suspiciously low — parser regression?")
            #expect(battery.voltage < 5_000,
                    "Battery voltage \(battery.voltage) mV is suspiciously high — parser regression?")
        }
    }

    // MARK: - Last reset time
    //
    // The legacy test only confirms a value comes back. We additionally check
    // the `epoch` is in the past (it's derived as `now - tickElapsed`) and
    // `resetUID` is masked to 3 bits. `factoryReset_advancesResetUID` in
    // FactoryResetTests exercises the *change* across a reboot — this test
    // covers the read shape on its own.

    @Test @MainActor
    func lastResetTime_readReturnsPlausibleEpoch() async throws {
        try await withConnectedDevice { device in
            let now = Date()
            let reading = try await device.read(MWLastResetTime()).value

            print("""

              Last reset time
                epoch:    \(reading.epoch)
                resetUID: \(reading.resetUID)
                ago:      \(String(format: "%.1f", now.timeIntervalSince(reading.epoch))) s

            """)

            // Reset epoch must not be in the future. Allow 1 s of slop for
            // the BLE round-trip and clock skew.
            #expect(reading.epoch <= now.addingTimeInterval(1),
                    "reset epoch \(reading.epoch) is in the future relative to \(now)")

            // resetUID is the firmware's 3-bit per-boot counter. Anything
            // outside 0...7 means the parser failed to mask correctly.
            #expect(reading.resetUID <= MWLastResetTime.resetUIDMask,
                    "resetUID \(reading.resetUID) escaped the 3-bit mask")
        }
    }

    // MARK: - Log length
    //
    // Returns the number of log entries currently in flash as a UInt32.
    // Any value 0...UInt32.max is valid — a fresh board reads 0, a board
    // mid-session can read in the millions. The smoke is just "did we
    // round-trip the read".

    @Test @MainActor
    func logLength_readReturnsCount() async throws {
        try await withConnectedDevice { device in
            let entries = try await device.read(MWLogLength()).value
            print("\n  Log entries on flash: \(entries)\n")
            // No bound assertion — the legacy SDK's Python reference accepts
            // any UInt32. The mere fact that `.value` produced a UInt32
            // proves the parser handled the 6-byte response correctly.
            _ = entries
        }
    }

    // MARK: - Humidity
    //
    // BME280-only. The humidity module (0x16) is absent on every board except
    // MetaEnvironment, so the legacy test would just succeed with no bytes
    // received on a non-BME board. We skip explicitly here so the operator
    // sees why the test was a no-op.

    @Test @MainActor
    func humidity_readReturnsPercent() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .humidity)?.isPresent == true,
                         "humidity module (BME280) not present on this board")
            let percent = try await device.read(MWHumidity()).value
            print("\n  Humidity: \(String(format: "%.2f", percent)) %\n")

            #expect(percent >= 0,
                    "Humidity \(percent) %% is negative — parser regression?")
            #expect(percent <= 100,
                    "Humidity \(percent) %% exceeds 100 %% — parser regression?")
        }
    }

    // MARK: - MAC address
    //
    // The Settings module exposes the radio's MAC at register 0x0B. The
    // parser formats the response as a colon-separated reverse-byte string
    // (e.g. `E8:C9:8F:52:7B:07`). On boards with old firmware (settings
    // revision < 2) this register is missing — we expect it to be present
    // since the SDK targets firmware 1.5.0+ (which carries settings rev 2).

    @Test @MainActor
    func macAddress_readReturnsColonString() async throws {
        try await withConnectedDevice { device in
            let mac = try await device.read(MWMACAddress()).value
            print("\n  MAC: \(mac)\n")

            // Six 2-hex-digit segments separated by colons.
            let parts = mac.split(separator: ":")
            #expect(parts.count == 6, "MAC has wrong segment count: \(mac)")
            #expect(parts.allSatisfy { $0.count == 2 && $0.allSatisfy(\.isHexDigit) },
                    "MAC segments are not 2-char hex: \(mac)")
        }
    }
}
