import Testing
import MetaWear
import Foundation

// MARK: - One-shot commands — haptic, rename, power-down, LED variants

@Suite("Hardware — Commands", .serialized)
struct CommandTests {

    // MARK: - powerDownSensors equivalent
    //
    // The legacy `MWPowerDownSensors` was an SDK-level convenience that
    // issued a fan-out of `acc_stop`, `sensor_fusion_stop`, and per-module
    // `loggerCleanup` calls — there's no single firmware register for it.
    // The new SDK gives you the same effect by:
    //   1. `stopLogging(_:)` for whatever you started — turns off the sensor
    //      and removes its logger registration on the board.
    //   2. `clearLog()` — wipes any pending entries from flash and removes
    //      all remaining logger subscriptions in one shot.
    //   3. `read(MWLogLength())` — confirms the flash entry counter is 0.
    //
    // The legacy test asserted `logLength == 0` after the sequence. We do
    // the same here, but additionally print the count *before* clearing to
    // make a partial-failure visible (e.g. if `stopLogging` left entries in
    // flash that `clearLog` was expected to wipe).

    @Test @MainActor
    func command_powerDownSensors_clearsLogState() async throws {
        try await withConnectedDevice { device in
            // Every supported board has an accelerometer — fail loudly if it's
            // missing. The constructor unwrap also fails if the firmware reports
            // an unrecognised implementation byte.
            let info = try #require(await device.moduleInfo(for: .accelerometer),
                                    "accelerometer module info missing")
            try #require(info.isPresent, "accelerometer not present on this board")
            let accel = try #require(
                MWAccelerometer.make(impl: info.implementation, odrHz: 50, rangeG: 16),
                "MWAccelerometer.make returned nil for impl byte \(info.implementation)"
            )

            // Clean slate before we start logging.
            try await device.clearLog()
            try await Task.sleep(for: .seconds(5))

            // Drive the log buffer for 2 s so we can see entries land in flash.
            try await device.startLogging(accel)
            try await Task.sleep(for: .seconds(5))

            // The legacy "powerDownSensors" maps cleanly to stopLogging on the
            // sensor we started — that's the operation that issues the per-
            // module stop + sampling-disable sequence.
            try await device.stopLogging(accel)
            try await device.flushLogPage()    // MMS-only; no-op on MMR
            try await Task.sleep(for: .seconds(5))

            let beforeClear = try await device.read(MWLogLength()).value
            print("\n  Log length after stopLogging: \(beforeClear) entries (expect > 0)")

            // The legacy "deleteLoggedData" maps to clearLog().
            try await device.clearLog()
            try await Task.sleep(for: .seconds(5))

            let afterClear = try await device.read(MWLogLength()).value
            print("  Log length after clearLog:   \(afterClear) entries (expect 0)\n")

            #expect(beforeClear > 0, "Expected entries on flash after 2 s of logging, got \(beforeClear)")
            #expect(afterClear == 0, "Expected 0 entries after clearLog, got \(afterClear)")
        }
    }

    // MARK: - LED visual variants
    //
    // The new SDK's `MWLEDPattern` exposes the raw timing/intensity fields
    // directly, so legacy preset names like `easeInOut` and `pulse` become
    // explicit MWLEDPattern parameter sets here. Composite colors (purple,
    // orange, yellow) ride on the multi-channel `setLED(red:green:blue:)`
    // convenience — the firmware mixes channels in hardware, so a "purple"
    // pattern is a red channel + blue channel running the same waveform.

    /// Purple ease-in-out (red + blue channels with long ramp times).
    /// Legacy: `test_LED_EaseInOut` with `.led(.purple, .easeInOut(repetitions: 5))`.
    @Test @MainActor
    func command_led_purpleBreathe() async throws {
        try await withConnectedDevice { device in
            // 5 breaths with 500 ms ramp each side and a 500 ms hold.
            let breathe = MWLEDPattern(
                highIntensity: 31, lowIntensity: 0,
                riseTime: 500, highTime: 500, fallTime: 500,
                pulseDuration: 2000, delay: 0, repeatCount: 5
            )
            try await device.setLED(red: breathe, blue: breathe, autoPlay: true)
            print("\n  ▶ Purple breathing (5 cycles, ~10 s) — observe the board\n")
            try await Task.sleep(for: .seconds(11))
            try await device.stopLED()
        }
    }

    /// Orange short pulse (red + green channels with brief flash bursts).
    /// Legacy: `test_LED_Pulse` with `.led(.orange, .pulse(repetitions: 5))`.
    @Test @MainActor
    func command_led_orangeFlash() async throws {
        try await withConnectedDevice { device in
            // 5 quick pulses — 100 ms on, 400 ms off.
            let pulse = MWLEDPattern(
                highIntensity: 31, lowIntensity: 0,
                riseTime: 0, highTime: 100, fallTime: 0,
                pulseDuration: 500, delay: 0, repeatCount: 5
            )
            try await device.setLED(red: pulse, green: pulse, autoPlay: true)
            print("\n  ▶ Orange flashes (5 pulses, ~3 s) — observe the board\n")
            try await Task.sleep(for: .seconds(4))
            try await device.stopLED()
        }
    }

    /// Green fast-blink (very short cycle).
    /// Legacy: `test_LED_BlinkQuickly` with `.led(.green, .blinkQuickly(repetitions: 5))`.
    @Test @MainActor
    func command_led_greenFastBlink() async throws {
        try await withConnectedDevice { device in
            // 5 fast blinks — 50 ms on, 50 ms off.
            let fast = MWLEDPattern(
                highIntensity: 31, lowIntensity: 0,
                riseTime: 0, highTime: 50, fallTime: 0,
                pulseDuration: 100, delay: 0, repeatCount: 5
            )
            try await device.send(MWLED.SetPattern(color: .green, pattern: fast))
            try await device.send(MWLED.Play())
            print("\n  ▶ Green fast blink (5 reps, ~0.5 s) — observe the board\n")
            try await Task.sleep(for: .seconds(2))
            try await device.send(MWLED.Stop(clearPattern: true))
        }
    }

    /// Blue infrequent blink (long off-period).
    /// Legacy: `test_LED_BlinkInfrequently` with `.led(.blue, .blinkInfrequently(repetitions: 5))`.
    @Test @MainActor
    func command_led_blueInfrequentBlink() async throws {
        try await withConnectedDevice { device in
            // 5 slow blinks — 100 ms on, ~1.9 s off.
            let infrequent = MWLEDPattern(
                highIntensity: 31, lowIntensity: 0,
                riseTime: 0, highTime: 100, fallTime: 0,
                pulseDuration: 2000, delay: 0, repeatCount: 5
            )
            try await device.send(MWLED.SetPattern(color: .blue, pattern: infrequent))
            try await device.send(MWLED.Play())
            print("\n  ▶ Blue infrequent blink (5 reps, ~10 s) — observe the board\n")
            try await Task.sleep(for: .seconds(11))
            try await device.send(MWLED.Stop(clearPattern: true))
        }
    }

    /// Red blink with raised low-intensity (LED dims rather than goes dark).
    /// Legacy: `test_LED_BlinkSlowly_RaisedLowIntensityMode`
    /// with `.led(.red, .blink(repetitions: 5, lowIntensity: 0.25))`.
    @Test @MainActor
    func command_led_redRaisedLowIntensityBlink() async throws {
        try await withConnectedDevice { device in
            // lowIntensity 8 ≈ 25 % of max (31). The LED never goes fully off.
            let raised = MWLEDPattern(
                highIntensity: 31, lowIntensity: 8,
                riseTime: 0, highTime: 250, fallTime: 0,
                pulseDuration: 1000, delay: 0, repeatCount: 5
            )
            try await device.send(MWLED.SetPattern(color: .red, pattern: raised))
            try await device.send(MWLED.Play())
            print("""

              ▶ Red blink with raised low-intensity (5 cycles, ~5 s)
                LED should dim between bright phases — never fully dark.

            """)
            try await Task.sleep(for: .seconds(6))
            try await device.send(MWLED.Stop(clearPattern: true))
        }
    }

    /// Yellow solid (red + green) → explicit off via `MWLED.Stop`.
    /// Legacy: `testCommand_Solid_LEDOff` with `.led(.yellow, .solid())` then `.ledOff`.
    @Test @MainActor
    func command_led_yellowSolid_thenOff() async throws {
        try await withConnectedDevice { device in
            // Solid yellow = red + green at full brightness, no rise/fall.
            try await device.setLED(red: .solid, green: .solid, autoPlay: true)
            print("\n  ▶ Yellow solid (2 s) → off (2 s) — observe the board\n")
            try await Task.sleep(for: .seconds(2))

            try await device.stopLED()      // sends MWLED.Stop(clearPattern: true)
            try await Task.sleep(for: .seconds(2))
            print("  ✓ Yellow → off cycle complete\n")
        }
    }
}
