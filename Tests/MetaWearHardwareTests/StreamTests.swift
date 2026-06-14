import Testing
import MetaWear
import Foundation

// MARK: - Hardware tests for streaming + polling primitives
//
// Parity port of the legacy Combine SDK's
// `Tests/IntegrationTests/MacTests/TestSuite/Integration/StreamTests.swift`.
// We already have rich per-sensor test files (Accelerometer*Tests, Gyroscope*Tests,
// Magnetometer/Sensor-fusion/etc.) — this file only adds coverage for the
// items that legacy file pinned but our suite did not. The mapping:
//
//   Legacy XCTest                              → Our adaptation here
//   ─────────────────────────────────────────────────────────────────────────
//   testStream_AmbientLight                    → ambientLight_streamsData
//   test_Stream_ChargingStatus                 → chargingStatus_streamsTransitions (poll)
//   testStream_Motion_Any                      → anyMotion_firesOnMovement
//   testStream_Motion_None                     → noMotion_firesWhenStill (BMI270 only)
//   testStream_Motion_Significant              → significantMotion_firesOnContinuousMovement
//                                                  (BMI270 only, operator-driven)
//   testStream_Motion_ActivityClassification   → activityClassification_emitsClasses
//   testStream_Orientation_OnSupportedDevice   → orientation_emitsOrientations
//   testStream_Orientation_FailsOnNonBMI160    → orientation_throwsOnBMI270
//   testStream_StepDetection_BMI160 / _BMI270  → stepDetector_BMI160 / _BMI270
//   testStream_StepCounting_BMI160 / _BMI270   → stepCounter_BMI160 / _BMI270
//   testStreamPoll_Temperature (4 channels)    → polls all 4 sources we discover
//   testStreamPoll_Humidity                    → humidity_pollsData
//   testStream_SensorFusion_All                → sensorFusion_allOutputsAllModes
//
// Tests that need operator interaction print clear instructions before the
// observation window opens.

// MARK: - Streamable adapters
//
// Several Bosch features (orientation, any-motion, no-motion, activity,
// step detector, step counter) are exposed as command/parser primitives in
// `MWAccelerometer.swift` but not as `MWStreamable` types. The legacy Combine
// SDK had `.orientation`, `.motionAny`, etc. as streamables; we wrap our
// primitives in small in-test adapters so `device.startStream(_:)` works
// against them. Once the SDK grows public streamable types these will be
// deleted.

/// Generic streamable that subscribes to a feature notification register on
/// the accelerometer module. All commands are passed in directly so a single
/// adapter can serve every Bosch feature regardless of chip variant.
private struct BoschFeatureStream<S: Sendable>: MWStreamable {
    typealias Sample = S

    let module: MWModule = .accelerometer
    let dataRegister: UInt8
    let packedDataRegister: UInt8? = nil

    let configureCommands: [Data]
    let enableCommands:    [Data]
    let startCommands:     [Data]
    let stopCommands:      [Data]
    let disableCommands:   [Data]

    /// `parseSample` requires `Sample: Sendable`; the closure that decodes
    /// notification bytes carries the same constraint.
    let parser: @Sendable (Data) throws -> S

    // The protocol's singular forms aren't used (we route everything through
    // the multi-command lists above) — provide empty defaults so they don't
    // double-write.
    var enableCommand:  Data { Data() }
    var startCommand:   Data { Data() }
    var stopCommand:    Data { Data() }
    var disableCommand: Data { Data() }

    func parseSample(from packet: Data) throws -> S { try parser(packet) }
}

// MARK: Adapter constructors

private extension BoschFeatureStream {

    /// BMI160 orientation interrupt (register 0x11). The accelerometer must
    /// be running for the interrupt source to fire, so the adapter's
    /// enable/start/stop/disable bundle the corresponding accelerometer
    /// commands.
    ///
    /// Throws if the SDK rejects the construction — `EnableOrientation` now
    /// validates the chip variant at init time. This factory hard-codes
    /// `.bmi160`, so it only throws if the implementation regresses.
    static func bmi160Orientation() throws
        -> BoschFeatureStream<MWAccelerometerBosch.SensorOrientation>
    {
        let acc = MWAccelerometerBMI160(odr: .hz50, range: .g2)
        let enable = try MWAccelerometerBosch.EnableOrientation(chip: .bmi160)
        return BoschFeatureStream<MWAccelerometerBosch.SensorOrientation>(
            dataRegister: 0x11,
            configureCommands: acc.configureCommands,
            enableCommands:    [enable.commandData,
                                acc.enableCommand],
            startCommands:     [acc.startCommand],
            stopCommands:      [acc.stopCommand],
            disableCommands:   [MWAccelerometerBosch.DisableOrientation().commandData,
                                acc.disableCommand],
            parser: { try MWAccelerometerBosch.parseOrientation(from: $0) }
        )
    }

    /// BMI160 / BMI270 any-motion interrupt (register 0x0B). The
    /// `ConfigureAnyMotion` payload differs by chip; the accelerometer must be
    /// running to feed the detector.
    static func anyMotion(chip: MWAccelerometerBosch.ChipVariant,
                          rangeG: Float = 8.0)
        -> BoschFeatureStream<MWAccelerometerBosch.AnyMotionEvent>
    {
        let configure = MWAccelerometerBosch.ConfigureAnyMotion(
            chip: chip, count: 4, thresholdG: 0.75, rangeG: rangeG
        )
        let enable  = MWAccelerometerBosch.EnableAnyMotion()
        let disable = MWAccelerometerBosch.DisableAnyMotion()

        // Pick a sensible accelerometer config matching the requested range.
        let accConfigure: [Data]
        let accEnable: Data
        let accStart:  Data
        let accStop:   Data
        let accDisable: Data
        switch chip {
        case .bmi160:
            let bmiRange = MWAccelerometerBMI160.Range.allCases.min {
                abs($0.rangeG - rangeG) < abs($1.rangeG - rangeG)
            } ?? .g2
            let acc = MWAccelerometerBMI160(odr: .hz50, range: bmiRange)
            accConfigure = acc.configureCommands
            accEnable    = acc.enableCommand
            accStart     = acc.startCommand
            accStop      = acc.stopCommand
            accDisable   = acc.disableCommand
        case .bmi270:
            let bmiRange = MWAccelerometerBMI270.Range.allCases.min {
                abs($0.rangeG - rangeG) < abs($1.rangeG - rangeG)
            } ?? .g2
            let acc = MWAccelerometerBMI270(odr: .hz50, range: bmiRange)
            accConfigure = acc.configureCommands
            accEnable    = acc.enableCommand
            accStart     = acc.startCommand
            accStop      = acc.stopCommand
            accDisable   = acc.disableCommand
        }

        return BoschFeatureStream<MWAccelerometerBosch.AnyMotionEvent>(
            dataRegister: 0x0B,
            configureCommands: accConfigure + [configure.commandData],
            enableCommands:    [enable.commandData, accEnable],
            startCommands:     [accStart],
            stopCommands:      [accStop],
            disableCommands:   [disable.commandData, accDisable],
            parser: { try MWAccelerometerBosch.parseAnyMotion(from: $0) }
        )
    }

    /// BMI270 no-motion (register 0x09). The MOTION_INTERRUPT register is
    /// shared with any-motion; the feature-enable bit (`0x20`) selects
    /// no-motion.
    static func noMotionBMI270(rangeG: Float = 2.0)
        throws -> BoschFeatureStream<UInt8>
    {
        let configure = try MWAccelerometerBMI270Features.ConfigureNoMotion()
        let enable    = MWAccelerometerBMI270Features.EnableNoMotion()
        let disable   = MWAccelerometerBMI270Features.DisableNoMotion()

        let bmiRange = MWAccelerometerBMI270.Range.allCases.min {
            abs($0.rangeG - rangeG) < abs($1.rangeG - rangeG)
        } ?? .g2
        let acc = MWAccelerometerBMI270(odr: .hz50, range: bmiRange)

        return BoschFeatureStream<UInt8>(
            dataRegister: 0x09,
            configureCommands: acc.configureCommands + [configure.commandData],
            enableCommands:    enable.commands + [acc.enableCommand],
            startCommands:     [acc.startCommand],
            stopCommands:      [acc.stopCommand],
            disableCommands:   disable.commands + [acc.disableCommand],
            parser: { packet in
                guard packet.count >= 3 else {
                    throw MWError.operationFailed("No-motion packet too short: \(packet.count) bytes")
                }
                return packet[2]
            }
        )
    }

    /// BMI270 significant motion (register 0x09). Shares MOTION_INTERRUPT
    /// with any-motion / no-motion; the feature-enable bit (`0x01`) selects
    /// sig-motion. Notification payload is a single trigger byte — the test
    /// only cares whether anything fires within the observation window, so
    /// we surface it as raw `UInt8` exactly like `noMotionBMI270()`.
    ///
    /// `blocksize` defaults to the firmware's 250 samples (~2.5 s at 100 Hz
    /// ODR); raising it makes the detector more selective.
    static func significantMotionBMI270(blocksize: UInt16 = 250)
        -> BoschFeatureStream<UInt8>
    {
        let configure = MWAccelerometerBMI270Features
            .ConfigureSignificantMotion(blocksize: blocksize)
        let enable    = MWAccelerometerBMI270Features.EnableSignificantMotion()
        let disable   = MWAccelerometerBMI270Features.DisableSignificantMotion()
        let acc       = MWAccelerometerBMI270(odr: .hz100, range: .g2)

        return BoschFeatureStream<UInt8>(
            dataRegister: 0x09,
            configureCommands: acc.configureCommands + [configure.commandData],
            enableCommands:    enable.commands + [acc.enableCommand],
            startCommands:     [acc.startCommand],
            stopCommands:      [acc.stopCommand],
            disableCommands:   disable.commands + [acc.disableCommand],
            parser: { packet in
                guard packet.count >= 3 else {
                    throw MWError.operationFailed(
                        "Significant-motion packet too short: \(packet.count) bytes"
                    )
                }
                return packet[2]
            }
        )
    }

    /// BMI270 activity classification (register 0x0C).
    static func activityClassificationBMI270()
        -> BoschFeatureStream<MWAccelerometerBMI270Features.Activity>
    {
        let enable  = MWAccelerometerBMI270Features.EnableActivityDetection()
        let disable = MWAccelerometerBMI270Features.DisableActivityDetection()
        let acc     = MWAccelerometerBMI270(odr: .hz50, range: .g2)

        return BoschFeatureStream<MWAccelerometerBMI270Features.Activity>(
            dataRegister: MWAccelerometerBMI270Features.activityRegister,
            configureCommands: acc.configureCommands,
            enableCommands:    enable.commands + [acc.enableCommand],
            startCommands:     [acc.startCommand],
            stopCommands:      [acc.stopCommand],
            disableCommands:   disable.commands + [acc.disableCommand],
            parser: { try MWAccelerometerBMI270Features.parseActivity(from: $0) }
        )
    }

    /// BMI160 step detector — one notification per detected step (value 1)
    /// on register 0x19.
    static func stepDetectorBMI160()
        -> BoschFeatureStream<UInt32>
    {
        let acc = MWAccelerometerBMI160(odr: .hz50, range: .g2)
        return BoschFeatureStream<UInt32>(
            dataRegister: MWAccelerometerBMI160Steps.stepDetectorRegister,
            configureCommands: acc.configureCommands,
            enableCommands:    [MWAccelerometerBMI160Steps.EnableStepDetector().commandData,
                                acc.enableCommand],
            startCommands:     [acc.startCommand],
            stopCommands:      [acc.stopCommand],
            disableCommands:   [MWAccelerometerBMI160Steps.DisableStepDetector().commandData,
                                acc.disableCommand],
            parser: { try MWAccelerometerBMI160Steps.parseStepDetection(from: $0) }
        )
    }

    /// BMI160 step counter — cumulative count notification (UInt16 LE in
    /// bytes 2-3) on register 0x1A. Notifications fire when the on-chip
    /// watermark is hit.
    static func stepCounterBMI160(mode: MWAccelerometerBMI160Steps.StepCounterMode = .normal)
        -> BoschFeatureStream<UInt32>
    {
        let acc = MWAccelerometerBMI160(odr: .hz50, range: .g2)
        let configure = MWAccelerometerBMI160Steps.ConfigureStepCounter(mode: mode)
        return BoschFeatureStream<UInt32>(
            dataRegister: 0x1A,
            configureCommands: acc.configureCommands + [configure.commandData],
            enableCommands:    [MWAccelerometerBMI160Steps.EnableStepDetector().commandData,
                                acc.enableCommand],
            startCommands:     [acc.startCommand],
            stopCommands:      [acc.stopCommand],
            disableCommands:   [MWAccelerometerBMI160Steps.DisableStepDetector().commandData,
                                acc.disableCommand],
            parser: { try MWAccelerometerBMI160Steps.parseStepCount(from: $0) }
        )
    }

    /// BMI270 step detector — one notification per detected step (value 1)
    /// on register 0x0B.
    static func stepDetectorBMI270()
        -> BoschFeatureStream<UInt32>
    {
        let acc = MWAccelerometerBMI270(odr: .hz50, range: .g2)
        let enable  = MWAccelerometerBMI270Steps.EnableStepDetector()
        let disable = MWAccelerometerBMI270Steps.DisableStepDetector()
        return BoschFeatureStream<UInt32>(
            dataRegister: MWAccelerometerBMI270Steps.stepRegister,
            configureCommands: acc.configureCommands,
            enableCommands:    enable.commands + [acc.enableCommand],
            startCommands:     [acc.startCommand],
            stopCommands:      [acc.stopCommand],
            disableCommands:   disable.commands + [acc.disableCommand],
            parser: { try MWAccelerometerBMI270Steps.parseStepDetection(from: $0) }
        )
    }

    /// BMI270 step counter — cumulative count notification (UInt16 LE in
    /// bytes 2-3) on register 0x0B, fired every `trigger × 20` steps. Default
    /// trigger of 1 → fire every 20 steps.
    static func stepCounterBMI270(trigger: UInt16 = 1)
        -> BoschFeatureStream<UInt32>
    {
        let acc = MWAccelerometerBMI270(odr: .hz50, range: .g2)
        let configure = MWAccelerometerBMI270Steps.ConfigureStepCounter(trigger: trigger)
        return BoschFeatureStream<UInt32>(
            dataRegister: MWAccelerometerBMI270Steps.stepRegister,
            configureCommands: acc.configureCommands + [configure.configCommand],
            // ConfigureStepCounter's allCommands includes the interrupt + feature
            // enables — emit those as part of `enableCommands` since that's the
            // semantic step the SDK takes after writing the subscribe command.
            enableCommands:    [configure.interruptEnableCommand,
                                configure.featureEnableCommand,
                                acc.enableCommand],
            startCommands:     [acc.startCommand],
            stopCommands:      [acc.stopCommand],
            // No public `DisableStepCounter` exists on the BMI270 step
            // counter side yet (asymmetric with the step-detector enable/
            // disable pair). Hand-roll the matching disable bytes here:
            // FEATURE_INTERRUPT_ENABLE / FEATURE_ENABLE with bit 0x02 cleared.
            disableCommands:   [MWPacket.command(.accelerometer, 0x07, 0x00, 0x02),
                                MWPacket.command(.accelerometer, 0x06, 0x00, 0x02),
                                acc.disableCommand],
            parser: { try MWAccelerometerBMI270Steps.parseStepCount(from: $0) }
        )
    }
}

// MARK: - Stream tests

@Suite("Hardware — Streams (legacy parity)", .serialized)
struct StreamTests {

    // MARK: - Ambient light (LTR329)
    //
    // Parity with `testStream_AmbientLight`. Default config (`x1` gain,
    // 100 ms integration, 500 ms measurement rate) yields ~2 Hz; we wait
    // long enough to receive ≥ 3 samples so the operator can see live data
    // arriving even if a regression slows the rate down.

    @Test @MainActor
    func ambientLight_streamsData() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .ambientLight)?.isPresent == true else {
                print("\n  Skipping ambient light — module not present\n"); return
            }

            let sensor = MWAmbientLight(gain: .x1,
                                        integrationTime: .ms100,
                                        measurementRate: .ms500)
            let stream = try await device.startStream(sensor)

            var samples: [UInt32] = []
            var count = 0
            let collector = Task {
                for try await s in stream {
                    count += 1
                    let lux = MWAmbientLight.lux(from: s.value)
                    print(formatSample(count, lux, unit: "lux"))
                    samples.append(s.value)
                }
            }

            // 500 ms measurement rate × 5 samples ≈ 2.5 s; allow 4 s to absorb
            // BLE jitter and the chip's first-sample latency.
            try await Task.sleep(for: .seconds(4))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(samples.count >= 3,
                    "Expected ≥3 ambient-light samples, got \(samples.count)")
            print("\n  ✓ ambient light: \(samples.count) samples\n")
        }
    }

    // MARK: - Charging status (poll)
    //
    // The legacy `test_Stream_ChargingStatus` was a Combine stream. Our SDK
    // exposes the equivalent via `device.poll(MWSettings.ReadChargeStatus(),
    // every:)` since the firmware register is read-on-demand (no notification
    // register exists for charge state). The test asks the operator to plug /
    // unplug the cable during the observation window — we report every
    // sample so any transition is visible, and pass as long as we receive
    // any samples without error.

    @Test @MainActor
    func chargingStatus_pollsTransitions() async throws {
        try await withConnectedDevice { device in
            // Charge-status register only exists on settings revision ≥ 5.
            guard let info = await device.moduleInfo(for: .settings),
                  info.isPresent,
                  info.revision >= 5,
                  !info.extra.isEmpty,
                  (info.extra[0] & 0x02) != 0 else {
                print("\n  Skipping charge status — settings module too old or no charge bit\n")
                return
            }

            print("""

              ▸ Plug / unplug the USB cable a couple of times during the next
                15 seconds. Any value transitions will print live below.

            """)

            let stream = device.poll(MWSettings.ReadChargeStatus(),
                                     every: .milliseconds(500))
            var samples: [UInt8] = []
            var transitions = 0
            var count = 0
            let collector = Task {
                for try await s in stream {
                    count += 1
                    let label = s.value == 0 ? "not charging" : "charging"
                    print("    [\(count)] \(label) (\(s.value))")
                    if let last = samples.last, last != s.value { transitions += 1 }
                    samples.append(s.value)
                }
            }

            try await Task.sleep(for: .seconds(15))
            collector.cancel()

            #expect(samples.count >= 5,
                    "Expected ≥5 charge-status reads in 15 s, got \(samples.count)")
            print("\n  ✓ charge status: \(samples.count) reads, \(transitions) transition(s)\n")
        }
    }

    // MARK: - Any-motion (operator-driven)
    //
    // Parity with `testStream_Motion_Any`. Configures the chip's any-motion
    // interrupt with the C++ default (4-sample count, 0.75 g threshold at the
    // current accelerometer range). The operator must move the device to
    // trigger events; we observe for ~10 s and pass as long as no error
    // occurs — the exact event count depends on how vigorously the board is
    // moved.

    @Test @MainActor
    func anyMotion_firesOnMovement() async throws {
        try await withConnectedDevice { device in
            guard let accInfo = await device.moduleInfo(for: .accelerometer),
                  accInfo.isPresent,
                  let chip = chipFromAccImpl(accInfo.implementation) else {
                print("\n  Skipping any-motion — Bosch accelerometer not present\n"); return
            }

            print("""

              ▸ Move the device sharply during the next 10 seconds.
                Each detected any-motion event will print live below.

            """)

            let sensor = BoschFeatureStream<MWAccelerometerBosch.AnyMotionEvent>
                .anyMotion(chip: chip)
            let stream = try await device.startStream(sensor)

            var events: [MWAccelerometerBosch.AnyMotionEvent] = []
            let collector = Task {
                var idx = 0
                for try await s in stream {
                    idx += 1
                    let dir = s.value.isPositive ? "+" : "−"
                    let axes = "\(s.value.xAxisActive ? "x" : "·")"
                              + "\(s.value.yAxisActive ? "y" : "·")"
                              + "\(s.value.zAxisActive ? "z" : "·")"
                    print("    [\(idx)] any-motion \(dir) axes=\(axes)")
                    events.append(s.value)
                }
            }

            try await Task.sleep(for: .seconds(10))
            collector.cancel()
            try await device.stopStreaming(sensor)

            // Operator may have left the board still — don't fail on count == 0.
            print("\n  ✓ any-motion: \(events.count) event(s) observed\n")
        }
    }

    // MARK: - No-motion (BMI270 only, operator-driven)
    //
    // Parity with `testStream_Motion_None`. The BMI270 no-motion feature
    // shares register 0x09 with any-motion — distinguished by the
    // feature-enable bit (`0x20` for no-motion vs `0x40` for any-motion).
    // The operator must keep the board still for the configured duration to
    // see events. We accept zero events as a non-failure.

    @Test @MainActor
    func noMotion_firesWhenStill() async throws {
        try await withConnectedDevice { device in
            guard let accInfo = await device.moduleInfo(for: .accelerometer),
                  accInfo.isPresent,
                  chipFromAccImpl(accInfo.implementation) == .bmi270 else {
                print("\n  Skipping no-motion — requires BMI270\n"); return
            }

            print("""

              ▸ Place the device still on a flat surface and DO NOT touch it
                for ~10 seconds. No-motion events will print live below.

            """)

            let sensor = try BoschFeatureStream<UInt8>.noMotionBMI270()
            let stream = try await device.startStream(sensor)

            var count = 0
            let collector = Task {
                for try await _ in stream {
                    count += 1
                    print("    [\(count)] no-motion event")
                }
            }

            try await Task.sleep(for: .seconds(12))
            collector.cancel()
            try await device.stopStreaming(sensor)

            print("\n  ✓ no-motion: \(count) event(s) observed\n")
        }
    }

    // MARK: - Significant motion (BMI270 only, operator-driven)
    //
    // Parity with `testStream_Motion_Significant`. Sig-motion is the third
    // tenant of the MOTION_INTERRUPT register (0x09); the feature-enable bit
    // (`0x01`) selects it. Unlike any-motion and no-motion, sig-motion is a
    // sustained-energy classifier — phone-on-desk or phone-in-pocket-while-
    // still won't trigger; walking / biking / vehicle motion will. The
    // firmware default `blocksize` of 250 samples (≈ 2.5 s at 100 Hz) is
    // generous; we accept zero events as non-failure since the operator may
    // not move continuously enough.

    @Test @MainActor
    func significantMotion_firesOnContinuousMovement() async throws {
        try await withConnectedDevice { device in
            guard let accInfo = await device.moduleInfo(for: .accelerometer),
                  accInfo.isPresent,
                  chipFromAccImpl(accInfo.implementation) == .bmi270 else {
                print("\n  Skipping significant motion — requires BMI270\n"); return
            }

            print("""

              ▸ Walk continuously while holding the device, or vigorously
                shake it for the next 15 seconds. Significant-motion events
                will print live below.

            """)

            let sensor = BoschFeatureStream<UInt8>.significantMotionBMI270()
            let stream = try await device.startStream(sensor)

            var count = 0
            let collector = Task {
                for try await s in stream {
                    count += 1
                    print("    [\(count)] sig-motion event (raw=0x\(String(format: "%02X", s.value)))")
                }
            }

            try await Task.sleep(for: .seconds(15))
            collector.cancel()
            try await device.stopStreaming(sensor)

            print("\n  ✓ significant motion: \(count) event(s) observed\n")
        }
    }

    // MARK: - Activity classification (BMI270 only, operator-driven)
    //
    // Parity with `testStream_Motion_ActivityClassification`. The BMI270
    // activity-output feature classifies movement as still / walking /
    // running. The operator should walk a few steps with the board to
    // see a transition; the test passes regardless of the specific class
    // observed.

    @Test @MainActor
    func activityClassification_emitsClasses() async throws {
        try await withConnectedDevice { device in
            guard let accInfo = await device.moduleInfo(for: .accelerometer),
                  accInfo.isPresent,
                  chipFromAccImpl(accInfo.implementation) == .bmi270 else {
                print("\n  Skipping activity classification — requires BMI270\n"); return
            }

            print("""

              ▸ Walk a few steps holding the device, then stop, during the
                next 15 seconds. Class transitions will print live below.

            """)

            let sensor = BoschFeatureStream<MWAccelerometerBMI270Features.Activity>
                .activityClassificationBMI270()
            let stream = try await device.startStream(sensor)

            var classes: [MWAccelerometerBMI270Features.Activity] = []
            let collector = Task {
                var idx = 0
                for try await s in stream {
                    idx += 1
                    print("    [\(idx)] activity = \(s.value)")
                    classes.append(s.value)
                }
            }

            try await Task.sleep(for: .seconds(15))
            collector.cancel()
            try await device.stopStreaming(sensor)

            print("\n  ✓ activity classification: \(classes.count) class change(s)\n")
        }
    }

    // MARK: - Orientation (BMI160 only, operator-driven)
    //
    // Parity with `testStream_Orientation_OnSupportedDevice`. Orientation
    // detection is BMI160-specific — BMI270 has no equivalent feature. The
    // SDK now enforces that distinction at construction time
    // (`EnableOrientation(chip:)` throws on `.bmi270`), so this test only
    // runs the happy path on BMI160 boards; the BMI270 rejection is pinned
    // separately by `orientation_throwsOnBMI270`.

    @Test @MainActor
    func orientation_emitsOrientations() async throws {
        try await withConnectedDevice { device in
            guard let accInfo = await device.moduleInfo(for: .accelerometer),
                  accInfo.isPresent,
                  chipFromAccImpl(accInfo.implementation) == .bmi160 else {
                print("\n  Skipping orientation — requires BMI160\n"); return
            }

            print("""

              ▸ Rotate the device through several orientations (face up,
                landscape, face down) over the next 12 seconds. Detected
                orientations will print live below.

            """)

            let sensor = try BoschFeatureStream<MWAccelerometerBosch.SensorOrientation>
                .bmi160Orientation()
            let stream = try await device.startStream(sensor)

            var orientations: [MWAccelerometerBosch.SensorOrientation] = []
            let collector = Task {
                var idx = 0
                for try await s in stream {
                    idx += 1
                    print("    [\(idx)] orientation = \(s.value)")
                    orientations.append(s.value)
                }
            }

            try await Task.sleep(for: .seconds(12))
            collector.cancel()
            try await device.stopStreaming(sensor)

            print("\n  ✓ orientation: \(orientations.count) change(s) observed\n")
        }
    }

    // MARK: - Orientation chip guard (BMI270 only)
    //
    // Parity with `testStream_Orientation_FailsOnNonBMI160`. The legacy SDK
    // surfaced the rejection at the streaming layer; our SDK rejects earlier,
    // at `EnableOrientation`'s throwing init. We pin the verbatim error
    // string the legacy XCTest asserted against:
    //
    //   "Orientation requires a BMI160 module, which this device lacks."
    //
    // After `MWError`'s `localizedDescription` prepends `"Operation failed: "`
    // the user-visible form matches the legacy verbatim string byte-for-byte.

    @Test @MainActor
    func orientation_throwsOnBMI270() async throws {
        try await withConnectedDevice { device in
            guard let accInfo = await device.moduleInfo(for: .accelerometer),
                  accInfo.isPresent,
                  chipFromAccImpl(accInfo.implementation) == .bmi270 else {
                print("\n  Skipping orientation chip guard — requires BMI270\n"); return
            }

            // The construction must throw; if it succeeds we want the test
            // to fail loudly so the regression is obvious.
            do {
                _ = try MWAccelerometerBosch.EnableOrientation(chip: .bmi270)
                Issue.record("EnableOrientation(chip: .bmi270) was expected to throw")
            } catch let error as MWError {
                let expectedFragment =
                    "Orientation requires a BMI160 module, which this device lacks."
                #expect(error.localizedDescription.contains(expectedFragment),
                        "Unexpected error message: \(error.localizedDescription)")
                let expectedFull = "Operation failed: " + expectedFragment
                #expect(error.localizedDescription == expectedFull,
                        "Legacy parity: full message must be \"\(expectedFull)\", got \"\(error.localizedDescription)\"")
                print("\n  ✓ orientation guard: rejected on BMI270 with verbatim legacy diagnostic\n")
            } catch {
                Issue.record("Expected MWError, got \(type(of: error)): \(error)")
            }
        }
    }

    // MARK: - Step detector / counter
    //
    // Parity with `testStream_StepDetection_*` and `testStream_StepCounting_*`.
    // The detector fires once per step (value == 1); the counter fires every
    // 20 steps with the cumulative count. Both are operator-driven — the
    // operator must walk / shake the board to generate steps.
    //
    // The legacy BMI160 step counter test had a `#warning("Failing -> no
    // response received")` annotation — same firmware quirk applies here.
    // We don't fail the test if no notification arrives.

    @Test @MainActor
    func stepDetector_BMI160() async throws {
        try await withConnectedDevice { device in
            guard let accInfo = await device.moduleInfo(for: .accelerometer),
                  accInfo.isPresent,
                  chipFromAccImpl(accInfo.implementation) == .bmi160 else {
                print("\n  Skipping step detector BMI160 — requires BMI160\n"); return
            }

            print("""

              ▸ Walk or shake the device for the next 10 seconds. Each
                detected step will print live below.

            """)

            let sensor = BoschFeatureStream<UInt32>.stepDetectorBMI160()
            let stream = try await device.startStream(sensor)

            var values: [UInt32] = []
            let collector = Task {
                var idx = 0
                for try await s in stream {
                    idx += 1
                    print("    [\(idx)] step (value=\(s.value))")
                    values.append(s.value)
                }
            }

            try await Task.sleep(for: .seconds(10))
            collector.cancel()
            try await device.stopStreaming(sensor)

            for v in values {
                #expect(v == 1, "BMI160 step detector value should be 1, got \(v)")
            }
            print("\n  ✓ BMI160 step detector: \(values.count) step(s)\n")
        }
    }

    @Test @MainActor
    func stepDetector_BMI270() async throws {
        try await withConnectedDevice { device in
            guard let accInfo = await device.moduleInfo(for: .accelerometer),
                  accInfo.isPresent,
                  chipFromAccImpl(accInfo.implementation) == .bmi270 else {
                print("\n  Skipping step detector BMI270 — requires BMI270\n"); return
            }

            print("""

              ▸ Walk or shake the device for the next 10 seconds. Each
                detected step will print live below.

            """)

            let sensor = BoschFeatureStream<UInt32>.stepDetectorBMI270()
            let stream = try await device.startStream(sensor)

            var values: [UInt32] = []
            let collector = Task {
                var idx = 0
                for try await s in stream {
                    idx += 1
                    print("    [\(idx)] step (value=\(s.value))")
                    values.append(s.value)
                }
            }

            try await Task.sleep(for: .seconds(10))
            collector.cancel()
            try await device.stopStreaming(sensor)

            for v in values {
                #expect(v == 1, "BMI270 step detector value should be 1, got \(v)")
            }
            print("\n  ✓ BMI270 step detector: \(values.count) step(s)\n")
        }
    }

    @Test @MainActor
    func stepCounter_BMI160() async throws {
        try await withConnectedDevice { device in
            guard let accInfo = await device.moduleInfo(for: .accelerometer),
                  accInfo.isPresent,
                  chipFromAccImpl(accInfo.implementation) == .bmi160 else {
                print("\n  Skipping step counter BMI160 — requires BMI160\n"); return
            }

            print("""

              ▸ Walk ~25 steps over the next 30 seconds so the on-chip
                counter watermark fires.  Note: this test was flagged as
                flaky in the legacy SDK (`#warning("Failing -> no response
                received")`) — a missing notification is not a hard failure.

            """)

            let sensor = BoschFeatureStream<UInt32>.stepCounterBMI160(mode: .sensitive)
            let stream = try await device.startStream(sensor)

            var count: UInt32? = nil
            let collector = Task {
                for try await s in stream {
                    print("    step counter = \(s.value)")
                    count = s.value
                    break
                }
            }

            try await Task.sleep(for: .seconds(30))
            collector.cancel()
            try await device.stopStreaming(sensor)

            if let count {
                print("\n  ✓ BMI160 step counter: first notification = \(count)\n")
            } else {
                print("\n  ⚠ BMI160 step counter: no notification (legacy-flaky)\n")
            }
        }
    }

    @Test @MainActor
    func stepCounter_BMI270() async throws {
        try await withConnectedDevice { device in
            guard let accInfo = await device.moduleInfo(for: .accelerometer),
                  accInfo.isPresent,
                  chipFromAccImpl(accInfo.implementation) == .bmi270 else {
                print("\n  Skipping step counter BMI270 — requires BMI270\n"); return
            }

            print("""

              ▸ Walk ~25 steps over the next 30 seconds. The first
                notification should arrive after 20 steps with value = 20.

            """)

            let sensor = BoschFeatureStream<UInt32>.stepCounterBMI270(trigger: 1)
            let stream = try await device.startStream(sensor)

            var firstValue: UInt32? = nil
            let collector = Task {
                for try await s in stream {
                    print("    step counter = \(s.value)")
                    if firstValue == nil { firstValue = s.value }
                    break
                }
            }

            try await Task.sleep(for: .seconds(30))
            collector.cancel()
            try await device.stopStreaming(sensor)

            if let firstValue {
                #expect(firstValue == 20,
                        "BMI270 step counter first notification should be 20 (one watermark), got \(firstValue)")
                print("\n  ✓ BMI270 step counter: first notification = \(firstValue)\n")
            } else {
                print("\n  ⚠ BMI270 step counter: no notification within 30 s\n")
            }
        }
    }

    // MARK: - Polled temperature across all 4 sources
    //
    // Parity with `testStreamPoll_Temperature`, which mapped over
    // `[onboard, bmp280, onDie, external]`. Our `EnvironmentSensorTests`
    // already covers `.nrfDie`, `.bmp280`, and `.presetThermistor`; this
    // test sweeps every source the board reports it has, polls 5 samples
    // from each, and asserts they fall in a plausible range.

    @Test @MainActor
    func temperature_pollsAllChannels() async throws {
        try await withConnectedDevice { device in
            guard let info = await device.moduleInfo(for: .temperature),
                  info.isPresent else {
                print("\n  Skipping temperature poll — module not present\n"); return
            }

            // `info.extra` lists the source code per channel index.
            for channel in 0..<info.extra.count {
                let sourceRaw = Int8(bitPattern: info.extra[channel])
                let source    = MWThermometerSource(rawValue: sourceRaw) ?? .invalid
                if source == .invalid {
                    print("\n  ▸ channel \(channel): invalid source code 0x\(String(format: "%02X", info.extra[channel])), skipping\n")
                    continue
                }
                if source == .extThermistor {
                    // External thermistor needs a configured GPIO pin; without
                    // it the read returns garbage. Skip rather than fail.
                    print("\n  ▸ channel \(channel) (\(source)): skipped — needs external thermistor wiring\n")
                    continue
                }

                let reader = MWThermometer(channel: UInt8(channel))
                let stream = device.poll(reader, every: .milliseconds(500))

                var samples: [Float] = []
                let collector = Task {
                    var idx = 0
                    for try await s in stream {
                        idx += 1
                        print("    ch\(channel) (\(source))  [\(idx)] \(String(format: "%+6.2f", s.value)) °C")
                        samples.append(s.value)
                        if idx >= 5 { break }
                    }
                }

                try await Task.sleep(for: .seconds(4))
                collector.cancel()

                #expect(samples.count >= 3,
                        "Channel \(channel) (\(source)): expected ≥3 samples, got \(samples.count)")
                if let first = samples.first {
                    #expect(first > -20 && first < 100,
                            "Channel \(channel) (\(source)): expected -20…100 °C, got \(first)")
                }
            }
            print("\n  ✓ temperature poll: all reachable channels read\n")
        }
    }

    // MARK: - Polled humidity
    //
    // Parity with `testStreamPoll_Humidity`. The humidity module fires the
    // BME280's measurement on each read; polling every 500 ms is enough to
    // collect 5 samples in 3 seconds.

    @Test @MainActor
    func humidity_pollsData() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .humidity)?.isPresent == true else {
                print("\n  Skipping humidity — module not present\n"); return
            }

            let stream = device.poll(MWHumidity(), every: .milliseconds(500))

            var samples: [Float] = []
            let collector = Task {
                var idx = 0
                for try await s in stream {
                    idx += 1
                    print(formatSample(idx, s.value, unit: "%"))
                    samples.append(s.value)
                    if idx >= 5 { break }
                }
            }

            try await Task.sleep(for: .seconds(4))
            collector.cancel()

            #expect(samples.count >= 5,
                    "Expected ≥5 humidity samples, got \(samples.count)")
            if let h = samples.last {
                #expect(h > 0 && h < 100,
                        "Humidity should be 0…100%, got \(h)")
            }
            print("\n  ✓ humidity: \(samples.count) samples\n")
        }
    }

    // MARK: - Sensor fusion: every output × every supported mode
    //
    // Parity with `testStream_SensorFusion_{EulerAngles, Gravity, Quaternion,
    // LinearAcceleration}`, which iterated `MWSensorFusion.Mode.allCases` per
    // output. Our existing `SensorFusionTests` covers each output but only at
    // the "best" mode the board supports, so this test pins the legacy intent
    // that *every* mode the hardware can run produces samples for *every*
    // output it actually emits.
    //
    // Not every (mode × output) combination is valid — the Bosch BSX1 fusion
    // algorithm only emits a subset of outputs in each non-NDOF mode, since
    // the missing underlying sensor leaves part of the state vector unsolved:
    //
    //     mode      quat  euler  gravity  linearAcc
    //     ────────  ────  ─────  ───────  ─────────
    //     sleep      ✗     ✗      ✗         ✗       (engine off)
    //     ndof       ✓     ✓      ✓         ✓
    //     imuPlus    ✓     ✓      ✗         ✓       (no mag → no abs gravity ref)
    //     compass    ✓     ✓      ✓         ✗       (no gyro → can't isolate linear acc)
    //     m4g        ✓     ✓      ✓         ✗       (no gyro → can't isolate linear acc)
    //
    // The whitelist below mirrors that table; firmware silently emits zero
    // samples for any (mode × output) combination not listed.

    private enum FusionOutputKind: String {
        case quaternion, euler, gravity, linearAcc
    }

    private static func supportedOutputs(for mode: MWSensorFusionMode) -> Set<FusionOutputKind> {
        switch mode {
        case .sleep:   return []
        case .ndof:    return [.quaternion, .euler, .gravity, .linearAcc]
        case .imuPlus: return [.quaternion, .euler, .linearAcc]
        case .compass: return [.quaternion, .euler, .gravity]
        case .m4g:     return [.quaternion, .euler, .gravity]
        }
    }

    @Test @MainActor
    func sensorFusion_allOutputsAllModes() async throws {
        try await withConnectedDevice { device in
            guard await device.hasSensorFusion else {
                print("\n  Skipping sensor fusion — module not present\n"); return
            }
            let chip: MWSensorFusionChip = await {
                if let impl = await device.moduleInfo(for: .gyro)?.implementation,
                   let c = MWSensorFusionChip(gyroImpl: impl) { return c }
                return .bmi160
            }()
            let hasMag = await device.hasMagnetometer
            // Build the supported mode list for this board.
            // ndof / compass / m4g all need a magnetometer; only imuPlus
            // works without one.
            let supported: [MWSensorFusionMode] = hasMag
                ? MWSensorFusionMode.allCases
                : [.imuPlus]

            // Each test cycles in turn, so store outcomes as we go.
            for mode in supported {
                try await runFusionMode(device, mode: mode, chip: chip)
            }
            print("\n  ✓ sensor fusion all-outputs-all-modes complete\n")
        }
    }

    /// Stream each fusion output supported by `mode` at the given chip pair,
    /// expecting ≥ 5 samples per output within a generous 4 s window.
    /// Outputs not produced by `mode` (per the BSX1 capability table above)
    /// are skipped with an explanatory log line — asserting on them would be
    /// a test-design error, since the firmware never emits those packets.
    @MainActor
    private func runFusionMode(_ device: MetaWearDevice,
                               mode: MWSensorFusionMode,
                               chip: MWSensorFusionChip) async throws {
        print("\n  ▸ mode: \(mode)")

        let supported = Self.supportedOutputs(for: mode)
        guard !supported.isEmpty else {
            print("      skipped — \(mode) does not run the fusion engine")
            return
        }

        if supported.contains(.quaternion) {
            try await runOneFusion(device,
                                   sensor: MWSensorFusionQuaternion(mode: mode, chip: chip),
                                   label: "quaternion")
        }
        if supported.contains(.euler) {
            try await runOneFusion(device,
                                   sensor: MWSensorFusionEuler(mode: mode, chip: chip),
                                   label: "euler")
        }
        if supported.contains(.gravity) {
            try await runOneFusion(device,
                                   sensor: MWSensorFusionGravity(mode: mode, chip: chip),
                                   label: "gravity")
        } else {
            print("      gravity:   skipped — not produced by \(mode)")
        }
        if supported.contains(.linearAcc) {
            try await runOneFusion(device,
                                   sensor: MWSensorFusionLinearAcceleration(mode: mode, chip: chip),
                                   label: "linearAcc")
        } else {
            print("      linearAcc: skipped — not produced by \(mode)")
        }
    }

    @MainActor
    private func runOneFusion<S: MWStreamable>(_ device: MetaWearDevice,
                                               sensor: S,
                                               label: String) async throws {
        let stream = try await device.startStream(sensor)
        var count = 0
        let collector = Task {
            for try await _ in stream {
                count += 1
                if count >= 5 { break }
            }
        }
        // 4 s collection window — generous for 25 Hz Compass; tight for the
        // first packet after a fusion-engine transition (see settle delay below).
        try await Task.sleep(for: .seconds(4))
        collector.cancel()
        try await device.stopStreaming(sensor)

        // Sensor-fusion settle delay between sequential outputs in the same
        // mode. Without it the BSX1 engine sometimes leaks stale packets on
        // the *previous* output's data register and silently ignores the new
        // enable-mask write, producing 0 samples on the next output (observed
        // intermittently for imuPlus → euler and compass → m4g.quaternion).
        // 500 ms lets `stop_fusion` + `clear_mask` + acc/gyro/mag stop drain
        // through the firmware before the next configure → start sequence
        // hits the bus.
        try await Task.sleep(for: .milliseconds(500))

        #expect(count >= 5, "\(label): expected ≥5 samples, got \(count)")
        print("      \(label): \(count) samples")
    }
}

// MARK: - Helpers

/// Map the accelerometer module's `implementation` byte to a chip variant.
/// 1 = BMI160, 4 = BMI270 (per `MblMwAccBoschTypes`).
private func chipFromAccImpl(_ impl: UInt8) -> MWAccelerometerBosch.ChipVariant? {
    switch impl {
    case 1: return .bmi160
    case 4: return .bmi270
    default: return nil
    }
}
