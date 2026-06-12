//
//  AccelerometerBMI270Tests.swift
//  MetaWear
//
//  Hardware-required tests for MWAccelerometerBMI270.

import Testing
import MetaWear
import Darwin
import Foundation

// MARK: - TestBmi270AccelerationData
//
// Normal (non-packed) acceleration data signal — register 0x04.

@Suite("BMI270 — Acceleration Data", .serialized)
struct Bmi270AccelerationDataTests {

    // MARK: test_subscribe_acceleration_data
    // mbl_mw_datasignal_subscribe → expected [0x03, 0x04, 0x01]
    // device.startStream() sends [module, dataRegister, 0x01] before enable + start.
    // mbl_mw_datasignal_unsubscribe → expected [0x03, 0x04, 0x00]
    // device.stopStreaming() sends [module, dataRegister, 0x00].
    
    @Test @MainActor
    func subscribe_acceleration_data() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 4,
                         "BMI270 not present on this board")
            let sensor = MWAccelerometerBMI270(odr: .hz100, range: .g2)
            let stream = try await device.startStream(sensor, usePacked: false)

            var count = 0
            let collector = Task {
                for try await sample in stream {
                    count += 1
                    print(formatSample(count, sample.value, unit: "g"))
                    if count >= 5 { break }
                }
            }
            try await Task.sleep(for: .seconds(2))
            collector.cancel()
            try await device.stopStreaming(sensor)

            #expect(count >= 5,
                    "Expected ≥5 samples after subscribe [0x03, 0x04, 0x01], got \(count)")
            print("\n  BMI270 subscribe acceleration: \(count) samples\n")
        }
    }

}

// MARK: - TestBmi270HighFreqAccData
//
// Packed acceleration data signal — register 0x05.

@Suite("BMI270 — Packed Acceleration Data", .serialized)
struct Bmi270PackedAccDataTests {

    // MARK: test_subscribe (packed) → expected [0x03, 0x05, 0x01]
    // device.startStream(usePacked: true) subscribes to register 0x05.

    @Test @MainActor
    func subscribe_packed() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 4,
                         "BMI270 not present on this board")
            let sensor = MWAccelerometerBMI270(odr: .hz100, range: .g2)
            // usePacked: true → uses register 0x05, sends [0x03, 0x05, 0x01]
            let stream = try await device.startStream(sensor, usePacked: true)

            var count = 0
            let collector = Task {
                for try await _ in stream { count += 1 }
            }
            try await Task.sleep(for: .seconds(2))
            collector.cancel()
            try await device.stopStreaming(sensor)

            // 100 Hz packed (3 samples/packet) × 2 s ≈ 200 samples; accept ≥ 120 for BLE jitter
            #expect(count > 120,
                    "Expected ≥120 packed samples in 2 s at 100 Hz, got \(count)")
            print("\n  BMI270 packed subscribe [0x03, 0x05, 0x01]: \(count) samples in 2 s\n")
        }
    }

    // MARK: - Original hardware streaming test (kept from prior file)
    //
    // Verifies ~2000 samples arrive in 20 s at 100 Hz packed mode.

    @Test @MainActor
    func accelerometer_bmi270_receives1000Samples() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .accelerometer)?.implementation == 4,
                         "BMI270 not present on this board")
            let sensor = MWAccelerometerBMI270(odr: .hz100, range: .g2)
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
                print("\n  BMI270 20 s stream: \(samples.count) samples, last mag=\(mag) g\n")
            }
        }
    }
}
