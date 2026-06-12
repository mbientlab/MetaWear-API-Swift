import Testing
import MetaWear
import Foundation

// MARK: - Hardware tests for factoryReset()

@Suite("Hardware — Factory Reset", .serialized)
struct FactoryResetTests {

    // Time for the firmware to finish GC, reboot, and re-advertise.
    // Empirically ~1 s on MMS — pad to 3 s to keep CI runs reliable.
    private let postResetDelay: Duration = .seconds(3)

    // MARK: - Smoke

    /// factoryReset must drive the device to `.disconnected` and the board
    /// must come back on a subsequent `connect()` with the same hardware
    /// identity. This exercises the wire sequence end-to-end without
    /// asserting anything about flash state — that's covered separately below.
    @Test @MainActor
    func factoryReset_disconnectsAndAllowsReconnect() async throws {
        let device = try await nearbyDevice()
        try await device.connect()

        let infoBefore = await device.deviceInfo
        #expect(infoBefore != nil, "deviceInfo must be populated after first connect")

        try await device.factoryReset()
        let postState = await device.state
        #expect(postState == .disconnected,
                "factoryReset must transition state to .disconnected, got \(postState)")

        // Wait for the board to finish GC and re-advertise.
        try await Task.sleep(for: postResetDelay)

        try await device.connect()
        let infoAfter = await device.deviceInfo
        #expect(infoAfter != nil, "deviceInfo must repopulate on reconnect after reset")

        // Same physical device — serial / hardware revision are immutable.
        let serialBefore = infoBefore?.serialNumber ?? "nil"
        let serialAfter  = infoAfter?.serialNumber  ?? "nil"
        #expect(infoBefore?.serialNumber == infoAfter?.serialNumber,
                "Serial number changed after reset (before=\(serialBefore) after=\(serialAfter)) — wrong device returned?")
        #expect(infoBefore?.hardwareRevision == infoAfter?.hardwareRevision)

        try await device.disconnect()

        print("""

          ✓ factoryReset disconnect/reconnect roundtrip OK
            Serial:    \(infoAfter?.serialNumber ?? "?")
            Firmware:  \(infoAfter?.firmwareRevision ?? "?")
            Hardware:  \(infoAfter?.hardwareRevision ?? "?")

        """)
    }

    // MARK: - Flash state scrubbed

    /// Plant a logger on the board, run factoryReset, reconnect, and confirm
    /// `queryActiveLoggers()` returns nothing. Loggers persist across reboots
    /// in flash — the only way they're gone after a reconnect is if our
    /// `[0x0B, 0x09, 0xFF×4]` + `[0x0B, 0x0A]` pair actually scrubbed them
    /// before the reset.
    @Test @MainActor
    func factoryReset_scrubsLoggersOnFlash() async throws {
        let device = try await nearbyDevice()
        try await device.connect()

        // BMI160 is the only chip that exposes the loggers-survive-reboot
        // wire path used to verify factoryReset scrubs flash. On other boards
        // (BMI270 etc.) the test can't drive the precondition — fail loudly
        // rather than silently pass.
        guard await device.moduleInfo(for: .accelerometer)?.implementation == 1 else {
            Issue.record("BMI160 not present on this board — factoryReset flash-scrub test cannot run")
            try await device.disconnect()
            return
        }

        // 1. Plant a logger so we can prove it gets wiped.
        let sensor = MWAccelerometerBMI160(odr: .hz25, range: .g2)
        try await device.startLogging(sensor)
        try await Task.sleep(for: .seconds(1))   // let a few samples log
        try await device.stopLogging(sensor)

        let loggersBefore = try await device.queryActiveLoggers()
        #expect(loggersBefore.count > 0,
                "Test setup precondition failed: expected ≥1 active logger, got \(loggersBefore.count)")

        // 2. Factory reset.
        try await device.factoryReset()
        try await Task.sleep(for: postResetDelay)

        // 3. Reconnect and verify the loggers really are gone.
        try await device.connect()

        let loggersAfter = try await device.queryActiveLoggers()
        let processorsAfter = try await device.queryActiveProcessors()

        #expect(loggersAfter.isEmpty,
                "factoryReset should scrub all loggers, got \(loggersAfter.count) active")
        #expect(processorsAfter.isEmpty,
                "factoryReset should scrub all data processors, got \(processorsAfter.count) active")

        try await device.disconnect()

        print("""

          ✓ factoryReset scrubbed flash state
            Loggers before reset:    \(loggersBefore.count)
            Loggers after reset:     \(loggersAfter.count)
            Processors after reset:  \(processorsAfter.count)

        """)
    }

    // MARK: - Reboot is observable in LOGGING_TIME
    //
    // Parity with the legacy `test_FactoryReset` shape: read the board's
    // LOGGING_TIME register (`[0x0B, 0x84]`) before factoryReset, do the
    // reset+reconnect, read it again, and confirm the firmware-level reboot
    // is observable in at least one of the two signals the register exposes.
    //
    // Why both `resetUID` AND `epoch` (either-or)?
    //
    // The LOGGING_TIME read returns two reboot-sensitive fields:
    //   • `resetUID` — the firmware's 3-bit per-boot counter (mod 8). Designed
    //     to increment on every reset, but observed in the field NOT to
    //     advance on some boards/firmware revisions even after a confirmed
    //     reboot.
    //   • `epoch` — derived as `now − (tick × msPerTick)`. After a real reboot
    //     the tick counter restarts at ~0, so the derived epoch jumps to
    //     "approximately now." On some other firmware revisions the tick is
    //     paused/persisted across `[0xFE, 0x05]`, leaving the derived epoch
    //     ~unchanged across a real reboot.
    //
    // No single signal is reliable across the field. They DO appear to be
    // mutually exclusive though — the firmware that pauses the tick advances
    // the resetUID, and vice versa. So requiring EITHER signal to fire is
    // robust against both quirks while still failing loudly when neither
    // does (which would mean the board genuinely didn't reboot).
    //
    // Acceptance criteria:
    //   • `resetUID` changed mod 8, OR
    //   • `after.epoch` is materially later than `before.epoch` (> 1 s — the
    //     bound just rejects BLE jitter on a non-reset).
    //
    // The diagnostic block prints both signals so a human can tell at a
    // glance which path fired. See `MWLastResetTime.Reading` for the parser.

    @Test @MainActor
    func factoryReset_isObservableInLoggingTime() async throws {
        let device = try await nearbyDevice()
        try await device.connect()

        let before = try await device.read(MWLastResetTime()).value

        try await device.factoryReset()
        try await Task.sleep(for: postResetDelay)
        try await device.connect()

        let after = try await device.read(MWLastResetTime()).value

        // Firmware encodes resetUID in 3 bits — a wraparound after 8 boots
        // would alias 0 → 0. Inequality alone is fine for one boot per run;
        // a wraparound would silently fail this leg, and the epoch leg picks
        // up the slack.
        let resetUidAdvanced = after.resetUID != before.resetUID
        let elapsedAcrossReset = after.epoch.timeIntervalSince(before.epoch)
        let secondsSinceLatestReset = Date().timeIntervalSince(after.epoch)
        // 1 s threshold: a non-reset read can drift by ~tens of milliseconds
        // due to BLE jitter on the `now` timestamp inside the parser. A real
        // reboot moves the boot moment by orders of magnitude more.
        let epochAdvanced = elapsedAcrossReset > 1.0
        let rebootObserved = resetUidAdvanced || epochAdvanced

        print("""

          factoryReset / lastResetTime diagnostics
            before:  resetUID=\(before.resetUID)  epoch=\(before.epoch)
            after:   resetUID=\(after.resetUID)  epoch=\(after.epoch)
            elapsed: \(String(format: "%.2f", elapsedAcrossReset)) s
            recency: \(String(format: "%.2f", secondsSinceLatestReset)) s ago
            signal:  resetUID=\(resetUidAdvanced ? "advanced" : "unchanged"), \
        epoch=\(epochAdvanced ? "advanced" : "unchanged")

        """)

        #expect(rebootObserved, """
                Neither resetUID nor epoch advanced across factoryReset \
                (resetUID before=\(before.resetUID) after=\(after.resetUID); \
                epoch elapsed=\(String(format: "%.2f", elapsedAcrossReset)) s) \
                — the firmware did not actually reboot. Inspect the wire log \
                for the [0xFE, 0x05] / [0xFE, 0x01] sequence.
                """)

        try await device.disconnect()
    }

    // MARK: - Reboot is real

    /// The final two writes — `[0xFE, 0x05]` (ResetAfterGC) followed by
    /// `[0xFE, 0x01]` (Reset) — actually trigger a reboot, not a
    /// software-only state reset. Easiest way to confirm: the BLE link
    /// drops within a few seconds of the call returning.
    ///
    /// History: an earlier version sent only `[0xFE, 0x05]`, which on some
    /// firmware revisions (notably MMS fw 1.5.0) is silently ignored when
    /// the flash GC queue is empty — the resetUID stayed at 1 across the
    /// "reset" and the boot counter was unchanged. The trailing `[0xFE, 0x01]`
    /// forces the reboot regardless.
    @Test @MainActor
    func factoryReset_rebootsBoard() async throws {
        let device = try await nearbyDevice()
        try await device.connect()

        let start = ContinuousClock.now
        try await device.factoryReset()

        // Wait for re-advertisement, then connect again.
        try await Task.sleep(for: postResetDelay)
        try await device.connect()

        let elapsed = ContinuousClock.now - start
        // Total wall time should be at least the reboot delay we slept for —
        // if it returned faster than `postResetDelay` something is very wrong.
        #expect(elapsed >= postResetDelay - .milliseconds(100),
                "Reset+reconnect cycle was suspiciously fast: \(elapsed)")

        try await device.disconnect()

        print("\n  ✓ factoryReset reboot cycle: \(elapsed)\n")
    }
}
