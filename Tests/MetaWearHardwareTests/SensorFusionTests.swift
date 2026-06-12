//
//  SensorFusionTests.swift
//  MetaWear
//
//  Hardware-required tests for the BNO055-style sensor-fusion module (0x19).
//  Command-byte / parser / logger tests live in
//  Tests/MetaWearTests/MWSensorFusionLoggingTests.swift.
//
//  Per the reference Combine SDK: `.ndof` (full 9-DoF with magnetometer) auto-
//  downgrades to `.imuPlus` (6-DoF, acc + gyro only) when no magnetometer is
//  present. We mirror that with `fusionMode(for:)` so every test picks the
//  richest mode the hardware supports.
//
//  Only MetaMotion variants ship the sensor-fusion firmware — classic MetaWear
//  boards skip these tests gracefully.
//

import Testing
import MetaWear
import Foundation

// MARK: - Helpers

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

// MARK: - Quaternion
//
// Non-packed quaternion signal — register 0x07.

@Suite("Sensor Fusion — Quaternion", .serialized)
struct SensorFusionQuaternionTests {

    // MARK: subscribe → expected [0x19, 0x07, 0x01]

    @Test @MainActor
    func subscribe_quaternion() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionQuaternion(mode: mode, chip: chip)
            let stream = try await device.startStream(sensor)

            var count = 0
            let collector = Task {
                for try await _ in stream {
                    count += 1
                    if count >= 5 { break }
                }
            }
            // Fusion defaults to ~100 Hz; 5 samples fit comfortably in 2 s
            // even with the filter's warm-up.
            try await Task.sleep(for: .seconds(2))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(count >= 5,
                    "Expected ≥5 quaternion samples after subscribe [0x19, 0x07, 0x01], got \(count)")
            print("\n  Fusion quaternion subscribe (\(mode)): \(count) samples\n")
        }
    }

    // MARK: unsubscribe → expected [0x19, 0x07, 0x00]

    @Test @MainActor
    func unsubscribe_quaternion() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionQuaternion(mode: mode, chip: chip)
            let stream = try await device.startStream(sensor)

            var beforeStop = 0
            let collector = Task {
                for try await _ in stream { beforeStop += 1 }
            }
            try await Task.sleep(for: .seconds(1))

            try await device.stopStreaming(sensor)
            collector.cancel()

            let state = await device.state
            #expect(beforeStop > 0, "Expected quaternion samples before unsubscribe, got 0")
            #expect(state == .idle, "Expected .idle after stopStreaming, got \(state)")
            print("\n  Fusion quaternion unsubscribe: \(beforeStop) samples before stop\n")
        }
    }

    // MARK: - Physics: unit quaternion magnitude
    //
    // The on-chip fusion filter always produces a unit quaternion (|q| = 1).
    // Anything further than 5% off that means the parser is wrong or samples
    // are being dropped mid-struct.

    @Test @MainActor
    func quaternion_unitMagnitude() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionQuaternion(mode: mode, chip: chip)
            let stream = try await device.startStream(sensor)

            var samples: [Quaternion] = []
            var count = 0
            let collector = Task {
                for try await s in stream {
                    count += 1
                    print(formatSample(count, s.value))
                    samples.append(s.value)
                }
            }
            // 100 Hz × 3 s ≈ 300 samples; accept ≥ 30 to cover warmup + BLE jitter.
            try await Task.sleep(for: .seconds(8))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(samples.count > 30,
                    "Expected ≥30 quaternion samples in 3 s, got \(samples.count)")

            if let q = samples.last {
                let mag = (q.w*q.w + q.x*q.x + q.y*q.y + q.z*q.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.05,
                        "Unit quaternion magnitude should be ~1.0, got \(mag)")
                print("\n  Quaternion: \(samples.count) samples, " +
                      "last=(w:\(String(format:"%.3f",q.w)) x:\(String(format:"%.3f",q.x)) " +
                      "y:\(String(format:"%.3f",q.y)) z:\(String(format:"%.3f",q.z))) " +
                      "|q|=\(String(format:"%.4f",mag))\n")
            }
        }
    }
}

// MARK: - Euler angles
//
// Non-packed euler-angle signal — register 0x08.

@Suite("Sensor Fusion — Euler Angles", .serialized)
struct SensorFusionEulerTests {

    // MARK: subscribe → expected [0x19, 0x08, 0x01]

    @Test @MainActor
    func subscribe_euler() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionEuler(mode: mode, chip: chip)
            let stream = try await device.startStream(sensor)

            var count = 0
            let collector = Task {
                for try await _ in stream {
                    count += 1
                    if count >= 5 { break }
                }
            }
            try await Task.sleep(for: .seconds(2))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(count >= 5,
                    "Expected ≥5 euler samples after subscribe [0x19, 0x08, 0x01], got \(count)")
            print("\n  Fusion euler subscribe: \(count) samples\n")
        }
    }

    // MARK: unsubscribe → expected [0x19, 0x08, 0x00]

    @Test @MainActor
    func unsubscribe_euler() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionEuler(mode: mode, chip: chip)
            let stream = try await device.startStream(sensor)

            var beforeStop = 0
            let collector = Task {
                for try await _ in stream { beforeStop += 1 }
            }
            try await Task.sleep(for: .seconds(1))

            try await device.stopStreaming(sensor)
            collector.cancel()

            let state = await device.state
            #expect(beforeStop > 0, "Expected euler samples before unsubscribe, got 0")
            #expect(state == .idle, "Expected .idle after stopStreaming, got \(state)")
            print("\n  Fusion euler unsubscribe: \(beforeStop) samples before stop\n")
        }
    }

    // MARK: - Physics: BNO055 Euler ranges
    //
    // Per the BNO055 data sheet:
    //   heading  0 … 360°
    //   pitch    ±180°
    //   roll     ±90°
    //
    // Relaxed heading to [-5, 365] to tolerate the filter's rounding at the
    // wrap point and any negative epsilon from float serialization.

    @Test @MainActor
    func euler_plausibleRange() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionEuler(mode: mode, chip: chip)
            let stream = try await device.startStream(sensor)

            var samples: [EulerAngles] = []
            var count = 0
            let collector = Task {
                for try await s in stream {
                    count += 1
                    print(formatSample(count, s.value))
                    samples.append(s.value)
                }
            }
            try await Task.sleep(for: .seconds(8))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(samples.count > 30, "Expected ≥30 euler samples in 3 s, got \(samples.count)")

            if let e = samples.last {
                #expect(e.heading >= -5 && e.heading <= 365,
                        "Heading should be ~0–360°, got \(e.heading)")
                #expect(e.pitch >= -180 && e.pitch <= 180,
                        "Pitch should be ±180°, got \(e.pitch)")
                #expect(e.roll  >= -90  && e.roll  <= 90,
                        "Roll should be ±90°, got \(e.roll)")
                print("\n  Euler: \(samples.count) samples, " +
                      "last=(heading:\(String(format:"%.1f",e.heading))° " +
                      "pitch:\(String(format:"%.1f",e.pitch))° " +
                      "roll:\(String(format:"%.1f",e.roll))°)\n")
            }
        }
    }
}

// MARK: - Gravity vector
//
// Non-packed gravity-vector signal — register 0x09. 3×float32 in m/s², scaled
// to g in the parser (÷9.80665). At rest on a flat surface, one axis reads ±1 g
// and the other two read ~0.

@Suite("Sensor Fusion — Gravity", .serialized)
struct SensorFusionGravityTests {

    // MARK: subscribe → expected [0x19, 0x09, 0x01]

    @Test @MainActor
    func subscribe_gravity() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionGravity(mode: mode, chip: chip)
            let stream = try await device.startStream(sensor)

            var count = 0
            let collector = Task {
                for try await _ in stream {
                    count += 1
                    if count >= 5 { break }
                }
            }
            try await Task.sleep(for: .seconds(2))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(count >= 5,
                    "Expected ≥5 gravity samples after subscribe [0x19, 0x09, 0x01], got \(count)")
            print("\n  Fusion gravity subscribe: \(count) samples\n")
        }
    }

    // MARK: unsubscribe → expected [0x19, 0x09, 0x00]

    @Test @MainActor
    func unsubscribe_gravity() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionGravity(mode: mode, chip: chip)
            let stream = try await device.startStream(sensor)

            var beforeStop = 0
            let collector = Task {
                for try await _ in stream { beforeStop += 1 }
            }
            try await Task.sleep(for: .seconds(1))

            try await device.stopStreaming(sensor)
            collector.cancel()

            let state = await device.state
            #expect(beforeStop > 0, "Expected gravity samples before unsubscribe, got 0")
            #expect(state == .idle, "Expected .idle after stopStreaming, got \(state)")
            print("\n  Fusion gravity unsubscribe: \(beforeStop) samples before stop\n")
        }
    }

    // MARK: - Physics: |g| ≈ 1

    @Test @MainActor
    func gravity_magnitudeNearOneG() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionGravity(mode: mode, chip: chip)
            let stream = try await device.startStream(sensor)

            var samples: [CartesianFloat] = []
            var count = 0
            let collector = Task {
                for try await s in stream {
                    count += 1
                    print(formatSample(count, s.value, unit: "g"))
                    samples.append(s.value)
                }
            }
            try await Task.sleep(for: .seconds(8))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(samples.count > 30,
                    "Expected ≥30 gravity samples in 3 s, got \(samples.count)")

            if let g = samples.last {
                let mag = (g.x*g.x + g.y*g.y + g.z*g.z).squareRoot()
                // ±0.2 g window tolerates filter warmup and minor scale drift.
                #expect(abs(Double(mag) - 1.0) < 0.2,
                        "Gravity magnitude should be ~1 g, got \(mag)")
                print("\n  Gravity: \(samples.count) samples, " +
                      "last=(x:\(String(format:"%.3f",g.x)) y:\(String(format:"%.3f",g.y)) " +
                      "z:\(String(format:"%.3f",g.z))) |g|=\(String(format:"%.4f",mag))\n")
            }
        }
    }
}

// MARK: - Linear acceleration
//
// Non-packed linear-acceleration signal — register 0x0A. Same float-32 layout
// as gravity; the firmware subtracts gravity for us, so at rest the vector
// should be ≈ 0.

@Suite("Sensor Fusion — Linear Acceleration", .serialized)
struct SensorFusionLinearAccTests {

    // MARK: subscribe → expected [0x19, 0x0A, 0x01]

    @Test @MainActor
    func subscribe_linearAcc() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionLinearAcceleration(mode: mode, chip: chip)
            let stream = try await device.startStream(sensor)

            var count = 0
            let collector = Task {
                for try await _ in stream {
                    count += 1
                    if count >= 5 { break }
                }
            }
            try await Task.sleep(for: .seconds(2))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(count >= 5,
                    "Expected ≥5 linear-acc samples after subscribe [0x19, 0x0A, 0x01], got \(count)")
            print("\n  Fusion linear-acc subscribe: \(count) samples\n")
        }
    }

    // MARK: unsubscribe → expected [0x19, 0x0A, 0x00]

    @Test @MainActor
    func unsubscribe_linearAcc() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionLinearAcceleration(mode: mode, chip: chip)
            let stream = try await device.startStream(sensor)

            var beforeStop = 0
            let collector = Task {
                for try await _ in stream { beforeStop += 1 }
            }
            try await Task.sleep(for: .seconds(1))

            try await device.stopStreaming(sensor)
            collector.cancel()

            let state = await device.state
            #expect(beforeStop > 0, "Expected linear-acc samples before unsubscribe, got 0")
            #expect(state == .idle, "Expected .idle after stopStreaming, got \(state)")
            print("\n  Fusion linear-acc unsubscribe: \(beforeStop) samples before stop\n")
        }
    }

    // MARK: - Physics: |linear acc| ≈ 0 at rest

    @Test @MainActor
    func linearAcc_nearZeroAtRest() async throws {
        try await withConnectedDevice { device in
            try #require(await device.hasSensorFusion,
                         "sensor fusion not present on this board")
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionLinearAcceleration(mode: mode, chip: chip)
            let stream = try await device.startStream(sensor)

            var samples: [CartesianFloat] = []
            var count = 0
            let collector = Task {
                for try await s in stream {
                    count += 1
                    print(formatSample(count, s.value, unit: "g"))
                    samples.append(s.value)
                }
            }
            try await Task.sleep(for: .seconds(8))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(samples.count > 30,
                    "Expected ≥30 linear-acc samples in 3 s, got \(samples.count)")

            // Drop the first ¼ to avoid counting the filter-convergence transient,
            // then average the remaining magnitudes.
            let settled = samples.dropFirst(samples.count / 4)
            if !settled.isEmpty {
                let avgMag = settled.map { v -> Float in
                    (v.x*v.x + v.y*v.y + v.z*v.z).squareRoot()
                }.reduce(0, +) / Float(settled.count)

                #expect(Double(avgMag) < 0.3,
                        "Linear acceleration at rest should be ~0 g, avg magnitude was \(avgMag)")
                print("\n  Linear acceleration: \(samples.count) samples, " +
                      "settled avg |a|=\(String(format:"%.4f",avgMag)) g\n")
            }
        }
    }
}

// MARK: - Calibration state
//
// Read signal at register 0x0B → firmware responds with
// [0x19, 0x8B, acc, gyro, mag], each byte 0 (uncalibrated) … 3 (high).
//
// Calibration bytes only become meaningful while the fusion algorithm is
// running, so we start a quaternion stream first and let the filter settle
// before reading.
//
// Requires sensor fusion revision ≥ 1 (CALIBRATION_REVISION).

@Suite("Sensor Fusion — Calibration", .serialized)
struct SensorFusionCalibrationTests {

    @Test @MainActor
    func readCalibration_returnsValidBytes() async throws {
        try await withConnectedDevice { device in
            let info = try #require(await device.moduleInfo(for: .sensorFusion),
                                    "sensor fusion module info missing")
            try #require(info.isPresent, "sensor fusion not present on this board")
            try #require(info.revision >= 1,
                         "sensor fusion revision \(info.revision) predates calibration read")

            // Must have fusion running for calibration to update.
            let mode = await fusionMode(for: device)
            let chip = await fusionChip(for: device)
            let sensor = MWSensorFusionQuaternion(mode: mode, chip: chip)
            let stream = try await device.startStream(sensor)
            let collector = Task { for try await _ in stream {} }
            defer { collector.cancel() }

            try await Task.sleep(for: .seconds(2))
            let cal = try await device.readFusionCalibration()
            try await device.stopStreaming(sensor)

            // Each byte must be 0–3 (spec). A value outside that range means
            // the parser or firmware is misbehaving.
            #expect((0...3).contains(cal.accelerometer),
                    "Accel calibration byte out of spec (0–3): \(cal.accelerometer)")
            #expect((0...3).contains(cal.gyroscope),
                    "Gyro calibration byte out of spec (0–3): \(cal.gyroscope)")
            #expect((0...3).contains(cal.magnetometer),
                    "Mag calibration byte out of spec (0–3): \(cal.magnetometer)")
            print("\n  Fusion calibration (\(mode)): " +
                  "acc=\(cal.accelerometer) gyro=\(cal.gyroscope) mag=\(cal.magnetometer)\n")
        }
    }
}
