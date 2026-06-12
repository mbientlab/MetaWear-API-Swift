import Testing
import MetaWear
import Foundation

// MARK: - Legacy parity
//
// Pulls in the on-board logging coverage from the legacy Combine-SDK file
// `MetaWear-Swift-Combine-SDK/Tests/IntegrationTests/MacTests/TestSuite/Integration/LogTests.swift`.
// The original is a flat `LogTests` XCTestCase with ~25 tests; many of them
// duplicate the smoke we already have here, several rely on legacy SDK
// affordances that don't have an equivalent in the Swift 6 SDK yet, and the
// remainder map cleanly onto the new APIs. This file only adds the cleanly
// portable ones; the gaps are listed in the table below for traceability.
//
// Legacy test                                          → New test (or status)
// ─────────────────────────────────────────────────────  ──────────────────────────────────────
// test_LogThenDownload_Accelerometer                   → logging_accelerometer_downloadsSamples (existing)
// test_LogThenDownload_Gryoscope                       → logging_gyroscope_downloadsSamples (existing)
// test_RecoversLoggers                                 → logging_recoverLoggers_afterReconnect (existing)
// test_Read_LogLength_WhenCleared                      → logging_logLength_zeroAfterClear
// test_Read_LogLength_WhenPopulated                    → logging_logLength_increasesWhilePopulating
// test_NotLogging                                      → logging_queryActiveLoggers_emptyWhenIdle
// test_LogThenDownload_Magnetometer                    → logging_magnetometer_downloadsSamples
// test_RecoversLoggersAfterRead                        → logging_recoverLoggers_afterRead
//
// Not ported — SDK API gap (acceptable, may be filled later):
//   test_LogThenDownload_TwoSensors_AccelerometerMagnetometer
//     `startLogging(_:)` requires the device to be `.idle`; chaining a second
//     loggable while the first is active throws. The legacy SDK kept the
//     enable bit idempotent so two `.log()` calls coexisted — porting this
//     needs an SDK change to relax the multi-sensor state guard.
//   test_Logs_SetupWithLazyStart
//     No `startImmediately: false` analogue — `startLogging(_:)` always
//     writes both the per-logger subscription and the global enable bit.
//   test_RemovesSpecificLoggers
//     SDK exposes `clearLog()` (remove all) but not a per-logger remove.
//   test_LogFakeButtonCommands_MechanicalButton
//     `MWSwitch` is `MWStreamable` only; no `MWLoggable` conformance and
//     no `logUserEvent` API yet.
//   test_LogThenDownload_AmbientLight / _Altitude / _ChargingStatus / _Pressure
//     Source sensors are streamables/pollables in the new SDK, not loggables.
//   test_LogThenDownload_MechanicalButton
//     Same as above — `MWSwitch` is streamable only.
//   test_LogThenDownload_Orientation / _Orientation_WhenUnsupported
//     `MWAccelerometerBosch.EnableOrientation` is `MWCommand`, not `MWLoggable`.
//   test_LogThenDownload_StepDetection* / _StepCounter*
//     Bosch step features are commands; logger conformance not implemented.
//   test_LogThenDownload_Temperature / _Humidity (`_testLog(byPolling:)`)
//     SDK has `device.poll(_:every:)` for live polling but no
//     log-by-polling pipeline (timer + log-pollable subscription chain).

// MARK: - Helpers

/// Consume a download stream to completion, returning the final batch of samples.
private func collectLog<Sample: Sendable>(
    _ stream: AsyncThrowingStream<Download<[MWLoggedSample<Sample>]>, Error>
) async throws -> [MWLoggedSample<Sample>] {
    var latest: [MWLoggedSample<Sample>] = []
    for try await progress in stream {
        latest = progress.data
    }
    return latest
}

/// Pick the best fusion mode for the board: `.ndof` if a magnetometer is
/// present (9-DoF, absolute orientation), else `.imuPlus` (6-DoF, relative).
/// Mirrors `MWSensorFusion.configure(...)` in the reference Combine SDK.
@MainActor
private func fusionMode(for device: MetaWearDevice) async -> MWSensorFusionMode {
    await device.hasMagnetometer ? .ndof : .imuPlus
}

/// Detect the underlying acc/gyro chip family. The fusion module is fed by the
/// gyro + accel modules on the same board; their config-byte encodings differ
/// between BMI160 (older MetaMotion R/RL) and BMI270 (newer C/S). We read the
/// gyro module's `implementation` byte (0 = BMI160, 1 = BMI270). Defaults to
/// BMI160 for boards that report something unexpected — that's the dominant
/// in-the-field chip and matches what the original Combine SDK assumed.
@MainActor
private func fusionChip(for device: MetaWearDevice) async -> MWSensorFusionChip {
    if let impl = await device.moduleInfo(for: .gyro)?.implementation,
       let chip = MWSensorFusionChip(gyroImpl: impl) {
        return chip
    }
    return .bmi160
}

/// Raw `[0x03, 0x01, 0x00]` — accelerometer **stop_sampling**. Used by the
/// button-triggered logging test to pause the sensor immediately after
/// `startLogging(_:)` arms the logger, so no samples flow until the on-device
/// event re-issues the start byte. The Bosch start/stop registers are private
/// to `MWSensorFusion`'s lifecycle helpers, so wrap the byte sequence as a
/// minimal `MWCommand` here for direct host-side issue.
private struct AccStopSampling: MWCommand {
    var commandData: Data {
        Data([MWModule.accelerometer.rawValue, 0x01, 0x00])
    }
}

/// Run the button-gated logging body for whichever Bosch accelerometer is
/// present on the connected board. Generic over `MWLoggable` so the same body
/// covers `MWAccelerometerBMI160` (impl byte 1) and `MWAccelerometerBMI270`
/// (impl byte 4) — both produce `CartesianFloat` samples and share the
/// `[0x03, 0x01, 0x01]` start_sampling / `[0x03, 0x01, 0x00]` stop_sampling
/// wire bytes.
///
/// Wiring is *fully* on-board — the host sleeps for 20 s, no I/O during the
/// window. Two comparator processors split the 1-byte switch state into a
/// press-only stream (state == 1) and a release-only stream (state == 0);
/// two events bind those processor outputs to the accelerometer chip's
/// start/stop registers. Net effect: the chip samples only while the user
/// holds the button down. Each press becomes a discrete burst in the log.
@MainActor
private func runButtonTriggeredAccelerometerLogging<L: MWLoggable>(
    device: MetaWearDevice,
    sensor: L
) async throws where L.Sample == CartesianFloat {
    // Arm the logger AND configure the sensor. `startLogging` ends with the
    // accelerometer running at the chosen ODR; we then immediately stop it so
    // the logger sits primed but no samples flow until the user presses the
    // button. Global logging stays enabled — only the underlying sensor is
    // paused, then gated by the on-device events we install next.
    try await device.startLogging(sensor)
    try await device.send(AccStopSampling())

    // Build the gating chain on the board:
    //
    //   [switch.state] ─► pressFilter   (eq 1) ─► startEvent ─► acc.start_sampling
    //                  └► releaseFilter (eq 0) ─► stopEvent  ─► acc.stop_sampling
    //
    // The switch state byte (0x01 = pressed, 0x00 = released) fires on both
    // edges of every press; the comparators split that single signal into
    // edge-specific streams that the events latch onto. No host involvement
    // during the 20 s window.
    let pressFilter = try await device.createProcessor(
        MWDataProcessor.Comparator(operation: .eq, reference: 1, signed: false),
        source: MWSwitchSignal()
    )
    let releaseFilter = try await device.createProcessor(
        MWDataProcessor.Comparator(operation: .eq, reference: 0, signed: false),
        source: MWSwitchSignal()
    )
    let startEvent = try await device.createEvent(
        source: MWEventSource(module: .dataProcessor, register: 0x03, dataID: pressFilter.id),
        action: MWEventAction(
            module: .accelerometer,
            register: 0x01,
            params: Data([0x01])
        )
    )
    let stopEvent = try await device.createEvent(
        source: MWEventSource(module: .dataProcessor, register: 0x03, dataID: releaseFilter.id),
        action: MWEventAction(
            module: .accelerometer,
            register: 0x01,
            params: Data([0x00])
        )
    )

    print("""

      Processor chain:
        pressFilter   (Comparator eq 1) → id \(pressFilter.id)
        releaseFilter (Comparator eq 0) → id \(releaseFilter.id)
      Events:
        startEvent (press   → acc.start_sampling) → id \(startEvent.id)
        stopEvent  (release → acc.stop_sampling)  → id \(stopEvent.id)

      ▶ Press AND HOLD the board's button to log accelerometer samples;
        release to pause. Each press → release becomes a discrete burst
        in the log.
      ▶ Press repeatedly during the 20 s window for several bursts.
      ▶ Test runs 20 s, then downloads whatever was captured.

    """)
    try await Task.sleep(for: .seconds(20))

    // Tear down on the board before the host-side stop. Order matters —
    // events reference processors, so events go first.
    try await device.removeAllEvents()
    try await device.removeAllProcessors()
    try await device.stopLogging(sensor)
    _ = try await device.flushLogPage()   // MMS-only; no-op on MMRL

    let stream = try await device.downloadLogs(sensor)
    let entries = try await collectLog(stream)

    #expect(entries.count > 0,
            "Expected ≥1 accelerometer sample after the 20 s window — was the button pressed at least once? Got \(entries.count).")

    try await device.clearLog()

    print("\n  Button-gated logging: \(entries.count) accelerometer samples\n")
    if let first = entries.first, let last = entries.last {
        let span = last.date.timeIntervalSince(first.date)
        let hz   = span > 0.001 ? Int(Double(entries.count) / span) : 0
        print("  Active span: \(String(format: "%.2f", span)) s ≈ \(hz) Hz\n")
    }
}

// MARK: - Tests

@Suite("Hardware — Logging", .serialized)
struct LoggingTests {

    @Test @MainActor
    func logging_accelerometer_downloadsSamples() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 1,
                         "BMI160 not present on this board")
            let sensor = MWAccelerometerBMI160(odr: .hz50, range: .g2)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(10))
            try await device.stopLogging(sensor)

            let stream = try await device.downloadLogs(sensor)
            let entries = try await collectLog(stream)

            #expect(entries.count > 50,
                    "Expected ≥ 50 samples in 3 s at 50 Hz, got \(entries.count)")

            if let last = entries.last {
                let v = last.value
                let mag = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.5,
                        "Sample magnitude should be ~1 g at rest, got \(mag)")
            }

            try await device.clearLog()

            print("\n  Logging: \(entries.count) accelerometer samples downloaded\n")
            if let first = entries.first, let last = entries.last {
                let span = last.date.timeIntervalSince(first.date)
                print("  Log span: \(String(format: "%.2f", span)) s  " +
                      "(~\(Int(Double(entries.count) / max(span, 1))) Hz)\n")
            }
        }
    }

    @Test @MainActor
    func logging_gyroscope_downloadsSamples() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 1,
                         "BMI160 not present on this board")
            let sensor = MWGyroscopeBMI160(odr: .hz50, range: .dps500)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(2))
            try await device.stopLogging(sensor)

            let stream = try await device.downloadLogs(sensor)
            let entries = try await collectLog(stream)

            #expect(entries.count > 30,
                    "Expected ≥ 30 gyro samples in 2 s at 50 Hz, got \(entries.count)")

            try await device.clearLog()
            print("\n  Logging: \(entries.count) gyroscope samples downloaded\n")
        }
    }

    @Test @MainActor
    func logging_clearLog_removesEntries() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 1,
                         "BMI160 not present on this board")
            let sensor = MWAccelerometerBMI160(odr: .hz50, range: .g2)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(1))
            try await device.stopLogging(sensor)
            try await device.clearLog()

            // After clear, re-register logger to allow download attempt
            try await device.startLogging(sensor)
            try await device.stopLogging(sensor)
            let stream = try await device.downloadLogs(sensor)
            let entries = try await collectLog(stream)

            #expect(entries.count < 10,
                    "After clearLog, download should return ~0 samples, got \(entries.count)")
            try await device.clearLog()
        }
    }

    // MARK: - BMI270

    @Test @MainActor
    func logging_accelerometer_bmi270_downloadsSamples() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 4,
                         "BMI270 not present on this board")
            let sensor = MWAccelerometerBMI270(odr: .hz50, range: .g2)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(10))
            try await device.stopLogging(sensor)

            let stream = try await device.downloadLogs(sensor)
            let entries = try await collectLog(stream)

            #expect(entries.count > 50,
                    "Expected ≥ 50 samples in 3 s at 50 Hz, got \(entries.count)")

            if let last = entries.last {
                let v = last.value
                let mag = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.5,
                        "Sample magnitude should be ~1 g at rest, got \(mag)")
            }

            try await device.clearLog()
            print("\n  Logging BMI270: \(entries.count) accelerometer samples downloaded\n")
        }
    }

    @Test @MainActor
    func logging_gyroscope_bmi270_downloadsSamples() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 4,
                         "BMI270 not present on this board")
            let sensor = MWGyroscopeBMI270(odr: .hz50, range: .dps500)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(2))
            try await device.stopLogging(sensor)

            let stream = try await device.downloadLogs(sensor)
            let entries = try await collectLog(stream)

            #expect(entries.count > 30,
                    "Expected ≥ 30 gyro samples in 2 s at 50 Hz, got \(entries.count)")

            try await device.clearLog()
            print("\n  Logging BMI270: \(entries.count) gyroscope samples downloaded\n")
        }
    }

    // MARK: - Raw (untyped) download

    @Test @MainActor
    func logging_rawDownload_returnsEntries() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 1,
                         "BMI160 not present on this board")
            let sensor = MWAccelerometerBMI160(odr: .hz50, range: .g2)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(2))  // ~100 samples at 50 Hz
            try await device.stopLogging(sensor)

            // Raw download — untyped, returns RawLogEntry
            let stream = try await device.downloadLogs()
            var allEntries: [RawLogEntry] = []
            for try await progress in stream {
                allEntries = progress.data
            }

            #expect(allEntries.count > 0, "Raw download should return at least one entry")

            if let first = allEntries.first {
                // Each entry covers one 4-byte chunk; 50 Hz × 2 s × 2 chunks/sample = ~200 entries
                #expect(first.epochMs >= 0, "epochMs should be non-negative")
                print("\n  Raw download: \(allEntries.count) entries, " +
                      "first tick=\(first.tick) epochMs=\(String(format: "%.1f", first.epochMs))\n")
            }

            try await device.clearLog()
        }
    }

    // MARK: - Magnetometer log/download
    //
    // Standalone single-sensor test; mirrors `test_LogThenDownload_Magnetometer`.
    // Magnetometer uses its own preset-based config (BMM150) rather than an
    // ODR/range pair, so it can't share the existing accel/gyro test bodies.

    @Test @MainActor
    func logging_magnetometer_downloadsSamples() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .magnetometer)?.isPresent == true,
                         "magnetometer not present on this board")
            let sensor = MWMagnetometer(preset: .lowPower)   // 10 Hz preset

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(5))
            try await device.stopLogging(sensor)
            _ = try await device.flushLogPage()

            let stream = try await device.downloadLogs(sensor)
            let entries = try await collectLog(stream)

            // 10 Hz × 5 s ≈ 50 samples. Allow generous slack for startup
            // latency / first-page truncation.
            #expect(entries.count > 20,
                    "Expected ≥20 mag samples in 5 s at 10 Hz, got \(entries.count)")

            // Earth's magnetic field magnitude is ~25–65 µT depending on
            // location; the loose 10–200 µT bound catches parser/scale
            // regressions without flapping with location.
            if let v = entries.last?.value {
                let mag = (v.x * v.x + v.y * v.y + v.z * v.z).squareRoot()
                #expect(mag > 10 && mag < 200,
                        "Magnetometer magnitude should be ~25–65 µT, got \(mag)")
            }

            try await device.clearLog()
            print("\n  Logging: \(entries.count) magnetometer samples downloaded\n")
        }
    }

    // MARK: - Log length reads (related to logging, not loggables themselves)
    //
    // The legacy file paired these with the log/download tests because both
    // exercise the same flash-buffer state machine — the read just observes
    // it from outside. `device.read(MWLogLength())` has no state guard, so
    // it can be called while logging.

    @Test @MainActor
    func logging_logLength_zeroAfterClear() async throws {
        try await withConnectedDevice { device in
            try await device.clearLog()
            // Brief pause so the firmware finishes wiping the flash counter
            // before we read it back. 500 ms matches the legacy 1 s delay
            // halved — the legacy test was generous because Combine has more
            // queueing overhead than direct async/await writes.
            try await Task.sleep(for: .milliseconds(500))

            let count = try await device.read(MWLogLength()).value
            #expect(count == 0,
                    "Expected log length 0 after clearLog, got \(count)")
            print("\n  Log length after clear: \(count)\n")
        }
    }

    @Test @MainActor
    func logging_logLength_increasesWhilePopulating() async throws {
        try await withConnectedDevice { device in
            // Need an accelerometer to drive the log buffer — pick BMI160 if
            // present, fall back to BMI270, skip if neither is around.
            let accImpl = await device.moduleInfo(for: .accelerometer)?.implementation
            try await device.clearLog()
            try await Task.sleep(for: .seconds(5))

            let beforeCount = try await device.read(MWLogLength()).value
            #expect(beforeCount == 0,
                    "Pre-condition: log should be empty after clear, got \(beforeCount)")

            // Drive the log buffer for 2 s at 50 Hz on whichever chip is here.
            switch accImpl {
            case 1:
                let sensor = MWAccelerometerBMI160(odr: .hz50, range: .g2)
                try await device.startLogging(sensor)
                try await Task.sleep(for: .seconds(2))
                let duringCount = try await device.read(MWLogLength()).value
                try await device.stopLogging(sensor)

                #expect(duringCount > 1,
                        "Expected log length > 1 after 2 s of 50 Hz logging, got \(duringCount)")
                print("\n  Log length while populating (BMI160): \(duringCount)\n")

            case 4:
                let sensor = MWAccelerometerBMI270(odr: .hz50, range: .g2)
                try await device.startLogging(sensor)
                try await Task.sleep(for: .seconds(2))
                let duringCount = try await device.read(MWLogLength()).value
                try await device.stopLogging(sensor)

                #expect(duringCount > 1,
                        "Expected log length > 1 after 2 s of 50 Hz logging, got \(duringCount)")
                print("\n  Log length while populating (BMI270): \(duringCount)\n")

            default:
                Issue.record("Unrecognised accelerometer chip (impl byte \(accImpl ?? 0xFF)) — cannot drive log buffer")
                return
            }

            try await device.clearLog()
        }
    }

    // MARK: - Active-logger inventory
    //
    // Mirrors `test_NotLogging`. The new SDK exposes the inventory directly
    // via `queryActiveLoggers()` (one entry per chunk-id the board reports);
    // a freshly-cleared board returns an empty array.

    @Test @MainActor
    func logging_queryActiveLoggers_emptyWhenIdle() async throws {
        try await withConnectedDevice { device in
            try await device.clearLog()
            try await Task.sleep(for: .milliseconds(500))
            let loggers = try await device.queryActiveLoggers()
            #expect(loggers.isEmpty,
                    "Expected no active loggers after clear, got IDs \(loggers.map(\.loggerID))")
            print("\n  Active loggers when idle: \(loggers.count)\n")
        }
    }

    // MARK: - Diagnostic: dump whatever loggers are on the board
    //
    // Read-only probe — does NOT clear state, does NOT modify the board.
    // Connect, query, print whatever's there, disconnect. Useful when a prior
    // run crashed mid-test or a previous session left logger subscriptions
    // behind, and you want to see what the board is currently holding before
    // deciding whether to clear it. Always passes — the assertion is just a
    // smoke check that the query round-tripped.

    @Test @MainActor
    func logging_dumpActiveLoggers() async throws {
        try await withConnectedDevice { device in
            let loggers = try await device.queryActiveLoggers()

            if loggers.isEmpty {
                print("\n  ✓ No active loggers on the board — flash is clean.\n")
            } else {
                print("\n  Active loggers on the board: \(loggers.count)")
                for logger in loggers {
                    let modName  = String(describing: logger.module)
                    let modByte  = String(format: "0x%02X", logger.module.rawValue)
                    let regByte  = String(format: "0x%02X", logger.register)
                    let chanByte = String(format: "0x%02X", logger.channel)
                    print("""
                        [id \(logger.loggerID)] \
                        module=\(modName) (\(modByte))  \
                        register=\(regByte)  \
                        channel=\(chanByte)  \
                        chunk=\(logger.chunkLength)B@offset \(logger.chunkOffset)
                    """)
                }
                print("")
            }

            // Smoke: the query returned without throwing. If we reached this
            // line at all, the wire round-trip worked — no functional claim
            // about the count itself.
            #expect(loggers.count >= 0)
        }
    }

    // MARK: - Logger recovery after reconnect

    @Test @MainActor
    func logging_recoverLoggers_afterReconnect() async throws {
        // Phase 1: start logging, stop, disconnect (without clearing)
        let device = try await nearbyDevice()
        try await device.connect()

        guard await device.moduleInfo(for: .accelerometer)?.implementation == 1 else {
            Issue.record("BMI160 not present on this board — recover-loggers test cannot run")
            try await device.disconnect()
            return
        }

        let sensor = MWAccelerometerBMI160(odr: .hz25, range: .g2)
        try await device.startLogging(sensor)
        try await Task.sleep(for: .seconds(2))  // ~50 samples at 25 Hz
        try await device.stopLogging(sensor)
        // Disconnect without clearing — loggers remain active on the board
        try await device.disconnect()

        // Phase 2: reconnect, recover loggers, download
        try await Task.sleep(for: .seconds(1))  // let the board re-advertise
        try await device.connect()
        try await device.recoverLoggers(for: sensor)

        let stream = try await device.downloadLogs(sensor)
        var entries: [MWLoggedSample<CartesianFloat>] = []
        for try await progress in stream {
            entries = progress.data
        }

        #expect(entries.count > 20,
                "Expected ≥ 20 recovered samples after reconnect, got \(entries.count)")

        try await device.clearLog()
        try await device.disconnect()

        print("\n  Logger recovery: \(entries.count) samples recovered after reconnect\n")
    }

    /// Variant of the above that interleaves an unrelated read before the
    /// `recoverLoggers(for:)` call. Mirrors `test_RecoversLoggersAfterRead`
    /// — the legacy concern was that an interleaved read might disturb the
    /// trigger-register query path that `recoverLoggers` relies on. This
    /// regression-protects that path.
    @Test @MainActor
    func logging_recoverLoggers_afterRead() async throws {
        let device = try await nearbyDevice()
        try await device.connect()

        guard await device.moduleInfo(for: .accelerometer)?.implementation == 1 else {
            Issue.record("BMI160 not present on this board — recover-loggers test cannot run")
            try await device.disconnect()
            return
        }

        let sensor = MWAccelerometerBMI160(odr: .hz25, range: .g2)
        try await device.startLogging(sensor)
        try await Task.sleep(for: .seconds(2))
        try await device.stopLogging(sensor)
        try await device.disconnect()

        try await Task.sleep(for: .seconds(1))
        try await device.connect()

        // The "after read" variant: an unrelated read between reconnect and
        // recovery, to prove the protocol layer's continuation routing for
        // logging-module reads doesn't get confused by intervening traffic.
        let logLength = try await device.read(MWLogLength()).value
        #expect(logLength > 0,
                "Expected log to retain entries across disconnect, got \(logLength)")

        try await device.recoverLoggers(for: sensor)
        let stream = try await device.downloadLogs(sensor)
        var entries: [MWLoggedSample<CartesianFloat>] = []
        for try await progress in stream { entries = progress.data }

        #expect(entries.count > 20,
                "Expected ≥ 20 recovered samples after read, got \(entries.count)")

        try await device.clearLog()
        try await device.disconnect()

        print("\n  Logger recovery (after read of logLength=\(logLength)): " +
              "\(entries.count) samples\n")
    }
}

// MARK: - Logging & download
//
// Logs a handful of seconds of quaternion / gravity data, flushes the MMS
// logging page (no-op on MMRL), downloads, and verifies the decoded samples
// still satisfy the physical plausibility checks.

@Suite("Sensor Fusion — Logging", .serialized)
struct SensorFusionLoggingHardwareTests {

    @Test @MainActor
    func quaternion_logsAndDownloads() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionQuaternion(mode: mode, chip: chip)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(5))
            try await device.stopLogging(sensor)
            _ = try await device.flushLogPage()   // MMS-only; no-op on MMRL

            let stream = try await device.downloadLogs(sensor)
            var entries: [MWLoggedSample<Quaternion>] = []
            for try await progress in stream { entries = progress.data }

            #expect(entries.count > 10,
                    "Expected ≥10 quaternion log samples after 5 s, got \(entries.count)")

            if let q = entries.last?.value {
                let mag = (q.w*q.w + q.x*q.x + q.y*q.y + q.z*q.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.1,
                        "Logged quaternion magnitude should be ~1, got \(mag)")
            }

            try await device.clearLog()
            print("\n  Fusion logging (\(mode)): \(entries.count) quaternion samples downloaded\n")
        }
    }

    @Test @MainActor
    func gravity_logsAndDownloads() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionGravity(mode: mode, chip: chip)

            try await device.startLogging(sensor)
            try await Task.sleep(for: .seconds(5))
            try await device.stopLogging(sensor)
            _ = try await device.flushLogPage()

            let stream = try await device.downloadLogs(sensor)
            var entries: [MWLoggedSample<CartesianFloat>] = []
            for try await progress in stream { entries = progress.data }

            #expect(entries.count > 10,
                    "Expected ≥10 gravity log samples after 5 s, got \(entries.count)")

            if let g = entries.last?.value {
                let mag = (g.x*g.x + g.y*g.y + g.z*g.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.2,
                        "Logged gravity magnitude should be ~1 g, got \(mag)")
            }

            try await device.clearLog()
            print("\n  Fusion logging (\(mode)): \(entries.count) gravity samples downloaded\n")
        }
    }

    // MARK: - Button-gated accelerometer logging
    //
    // Exercises the on-device event + data-processor pipeline: bind the
    // on-board push-button so samples are logged ONLY while the button is
    // held. The test runs for 20 s — generous enough that the operator can
    // press, hold, release, and repeat several times. After the window we
    // tear down the events + processors, stop logging, and pull whatever
    // flash-resident samples the presses actually captured.
    //
    // Wiring (board side, no host involvement during the 20 s window):
    //
    //   [switch.state] ─► pressFilter   (eq 1) ─► startEvent ─► acc.start_sampling
    //                  └► releaseFilter (eq 0) ─► stopEvent  ─► acc.stop_sampling
    //
    // The switch state byte fires on BOTH edges of every press; two
    // comparators split it into press-only / release-only streams, and two
    // events latch those onto the accelerometer's start/stop registers.
    // Each press → release pair becomes a discrete burst in the log.
    //
    // Asserts only `count > 0` because the window is operator-driven — a 0
    // result means either the button was never pressed (operator error) or
    // the event/processor/logger plumbing is broken (real failure). The
    // pretty-printed span + Hz at the end gives an at-a-glance sanity check.

    @Test @MainActor
    func logging_buttonTriggered_accelerometerSamples() async throws {
        try await withConnectedDevice { device in
            // Reset board state — leftover events / processors / macros from a
            // prior run could fire stray actions during our 20 s window or
            // consume firmware slots this test needs.
            try await resetBoardState(device)

            let accImpl = try #require(await device.moduleInfo(for: .accelerometer)?.implementation,
                                       "accelerometer not present on this board")

            // Both Bosch chips ship `CartesianFloat` samples and share the
            // `[0x03, 0x01, 0x01]` start_sampling wire byte, so the helper
            // body is identical — only the loggable struct differs.
            switch accImpl {
            case 1:
                try await runButtonTriggeredAccelerometerLogging(
                    device: device,
                    sensor: MWAccelerometerBMI160(odr: .hz50, range: .g2)
                )
            case 4:
                try await runButtonTriggeredAccelerometerLogging(
                    device: device,
                    sensor: MWAccelerometerBMI270(odr: .hz50, range: .g2)
                )
            default:
                Issue.record("Unknown accelerometer impl byte \(accImpl) — cannot determine chip family")
            }
        }
    }
}
