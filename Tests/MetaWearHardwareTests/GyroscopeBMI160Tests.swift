//
//  GyroscopeBMI160Tests.swift
//  MetaWear
//
//  Hardware-required tests for MWGyroscopeBMI160.
//  Command-byte / parser tests live in Tests/MetaWearTests.
//

import Testing
import MetaWear
import Darwin
import Foundation

// MARK: - Gyroscope data (BMI160)
//
// Non-packed rotation data signal — register 0x05.

@Suite("BMI160 — Gyroscope Data", .serialized)
struct Bmi160GyroscopeDataTests {

    // MARK: subscribe → expected [0x13, 0x05, 0x01]

    @Test @MainActor
    func subscribe_rotation_data() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 1,
                         "BMI160 not present on this board")
            let gyro = MWGyroscopeBMI160(odr: .hz50, range: .dps500)
            let stream = try await device.startStream(gyro, usePacked: false)

            var count = 0
            let collector = Task {
                for try await _ in stream {
                    count += 1
                    if count >= 5 { break }
                }
            }
            try await Task.sleep(for: .seconds(2))
            collector.cancel()
            try await device.stopStreaming(gyro)

            #expect(count >= 5,
                    "Expected ≥5 gyro samples after subscribe [0x13, 0x05, 0x01], got \(count)")
            print("\n  BMI160 subscribe rotation: \(count) samples\n")
        }
    }

    // MARK: unsubscribe → expected [0x13, 0x05, 0x00]

    @Test @MainActor
    func unsubscribe_rotation_data() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 1,
                         "BMI160 not present on this board")
            let gyro = MWGyroscopeBMI160(odr: .hz50, range: .dps500)
            let stream = try await device.startStream(gyro, usePacked: false)

            var beforeStop = 0
            let collector = Task {
                for try await _ in stream { beforeStop += 1 }
            }
            try await Task.sleep(for: .milliseconds(500))

            try await device.stopStreaming(gyro)
            collector.cancel()

            let state = await device.state
            #expect(beforeStop > 0, "Expected gyro samples before unsubscribe, got 0")
            #expect(state == .idle, "Expected .idle after stopStreaming, got \(state)")
            print("\n  BMI160 unsubscribe rotation: \(beforeStop) samples before stop\n")
        }
    }

    // MARK: - Streaming test
    // Verifies >50 samples arrive in 2 s at 50 Hz.

    @Test @MainActor
    func gyroscope_bmi160_receivesData() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 1,
                         "BMI160 not present on this board")
            let gyro = MWGyroscopeBMI160(odr: .hz50, range: .dps500)
            let stream = try await device.startStream(gyro, usePacked: false)

            var samples: [CartesianFloat] = []
            var count = 0
            let collector = Task {
                for try await s in stream {
                    count += 1
                    print(formatSample(count, s.value, unit: "dps"))
                    samples.append(s.value)
                }
            }

            try await Task.sleep(for: .seconds(10))
            collector.cancel()
            try await device.stopStreaming(gyro)

            #expect(count > 50, "Expected ≥50 gyro samples in 10 s at 50 Hz, got \(count)")
            print("\n  Gyroscope BMI160: \(count) samples in 10 s (~\(count / 10) Hz)\n")
        }
    }
}

// MARK: - Packed gyroscope data (BMI160)
//
// Packed rotation data signal — register 0x07.

@Suite("BMI160 — Packed Gyroscope Data", .serialized)
struct Bmi160PackedGyroDataTests {

    // MARK: subscribe (packed) → expected [0x13, 0x07, 0x01]

    @Test @MainActor
    func subscribe_packed() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 1,
                         "BMI160 not present on this board")
            let gyro = MWGyroscopeBMI160(odr: .hz100, range: .dps500)
            let stream = try await device.startStream(gyro, usePacked: true)

            var count = 0
            let collector = Task {
                for try await _ in stream { count += 1 }
            }
            try await Task.sleep(for: .seconds(2))
            collector.cancel()
            try await device.stopStreaming(gyro)

            // 100 Hz packed (3 samples/packet) × 2 s ≈ 200; accept ≥ 120 for BLE jitter
            #expect(count > 120,
                    "Expected ≥120 packed gyro samples in 2 s at 100 Hz, got \(count)")
            print("\n  BMI160 packed subscribe [0x13, 0x07, 0x01]: \(count) samples in 2 s\n")
        }
    }

    // MARK: unsubscribe (packed) → expected [0x13, 0x07, 0x00]

    @Test @MainActor
    func unsubscribe_packed() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 1,
                         "BMI160 not present on this board")
            let gyro = MWGyroscopeBMI160(odr: .hz100, range: .dps500)
            let stream = try await device.startStream(gyro, usePacked: true)

            var beforeStop = 0
            let collector = Task {
                for try await _ in stream { beforeStop += 1 }
            }
            try await Task.sleep(for: .milliseconds(500))

            try await device.stopStreaming(gyro)
            collector.cancel()

            let state = await device.state
            #expect(beforeStop > 0, "Expected packed gyro samples before unsubscribe, got 0")
            #expect(state == .idle, "Expected .idle after stopStreaming, got \(state)")
            print("\n  BMI160 packed unsubscribe [0x13, 0x07, 0x00]: \(beforeStop) samples before stop\n")
        }
    }
}
