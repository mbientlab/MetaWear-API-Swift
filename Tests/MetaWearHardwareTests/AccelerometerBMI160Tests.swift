//
//  AccelerometerBMI160Tests.swift
//  MetaWear
//
//  Hardware-required tests for MWAccelerometerBMI160.

import Testing
import MetaWear
import Darwin
import Foundation

// MARK: - TestBmi160AccelerationData
//
// Normal (non-packed) acceleration data signal — register 0x04.

@Suite("BMI160 — Acceleration Data", .serialized)
struct Bmi160AccelerationDataTests {

    // MARK: test_subscribe_acceleration_data
    // mbl_mw_datasignal_subscribe → expected [0x03, 0x04, 0x01]
    // device.startStream() sends [module, dataRegister, 0x01] before enable + start.
    // mbl_mw_datasignal_unsubscribe → expected [0x03, 0x04, 0x00]
    // device.stopStreaming() sends [module, dataRegister, 0x00].
    
    @Test @MainActor
    func subscribe_acceleration_data() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 1,
                         "BMI160 not present on this board")
            let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
            let stream = try await device.startStream(sensor, usePacked: false)

            var count = 0
            let collector = Task {
                for try await sample in stream {
                    count += 1
                    print(formatSample(count, sample.value, unit: "g"))
                }
            }
            try await Task.sleep(for: .seconds(5))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(count >= 5,
                    "Expected ≥5 samples after subscribe [0x03, 0x04, 0x01], got \(count)")
            print("\n  BMI160 subscribe acceleration: \(count) samples\n")
        }
    }

    // MARK: - Duplicate-stream rejection
    // The device state machine tracks which modules are actively streaming,
    // so calling `startStream` a second time for the accelerometer while
    // it is already streaming must throw `MWError.invalidState`.

    @Test @MainActor
    func accelerometer_bmi160_duplicateStream_throws() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 1,
                         "BMI160 not present on this board")
            let s1 = MWAccelerometerBMI160(odr: .hz100, range: .g2)
            let s2 = MWAccelerometerBMI160(odr: .hz50, range: .g4)
            _ = try await device.startStream(s1, usePacked: false)
            defer { Task { try? await device.stopStreaming(s1) } }

            do {
                _ = try await device.startStream(s2, usePacked: false)
                Issue.record("Should have thrown invalidState for duplicate accelerometer stream")
            } catch MWError.invalidState {
                // Expected
            }
        }
    }

    // MARK: - Streaming test
    // Verifies ~2000 samples arrive in 20 s at 100 Hz packed mode.

    @Test @MainActor
    func accelerometer_bmi160_receives1000Samples() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 1,
                         "BMI160 not present on this board")
            let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
            let stream = try await device.startStream(sensor, usePacked: true)

            var samples: [CartesianFloat] = []
            var count = 0
            let collector = Task {
                for try await s in stream {
                    count += 1
                    print(formatSample(count, s.value, unit: "g"))
                    samples.append(s.value)
                }
            }
            try await Task.sleep(for: .seconds(20))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(samples.count > 1000,
                    "Expected ~2000 samples in 20 s at 100 Hz, got \(samples.count)")
            if let last = samples.last {
                let mag = (last.x * last.x + last.y * last.y + last.z * last.z).squareRoot()
                #expect(abs(Double(mag) - 1.0) < 0.5,
                        "Magnitude should be ~1 g at rest, got \(mag)")
                print("\n  BMI160 20 s stream: \(samples.count) samples, last mag=\(mag) g\n")
            }
        }
    }
}

// MARK: - TestBmi160HighFreqAccData
//
// Packed acceleration data signal — register 0x1C.
// Each BLE packet carries 3 XYZ samples (18 payload bytes after the 2-byte header).

@Suite("BMI160 — Packed Acceleration Data", .serialized)
struct Bmi160PackedAccDataTests {

    // MARK: test_subscribe (packed) → expected [0x03, 0x1C, 0x01]
    // device.startStream(usePacked: true) subscribes to register 0x1C.

    @Test @MainActor
    func subscribe_packed() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 1,
                         "BMI160 not present on this board")
            let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)
            // usePacked: true → uses register 0x1C, sends [0x03, 0x1C, 0x01]
            let stream = try await device.startStream(sensor, usePacked: true)

            var count = 0
            let collector = Task {
                for try await _ in stream { count += 1 }
            }
            try await Task.sleep(for: .seconds(8))
            collector.cancel()
            try await device.stopStreaming(sensor)

            // 100 Hz packed (3 samples/packet) × 2 s ≈ 200 samples; accept ≥ 120 for BLE jitter
            #expect(count > 120,
                    "Expected ≥120 packed samples in 2 s at 100 Hz, got \(count)")
            print("\n  BMI160 packed subscribe [0x03, 0x1C, 0x01]: \(count) samples in 2 s\n")
        }
    }

}
