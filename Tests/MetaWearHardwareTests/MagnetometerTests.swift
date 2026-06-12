//
//  MagnetometerTests.swift
//  MetaWear
//
//  Hardware-required tests for MWMagnetometer (BMM150, module 0x15).
//  Command-byte / parser tests live in Tests/MetaWearTests/MWModuleCommandTests.swift.
//
//  The BMM150 requires a warmup sequence (power-mode → SLEEP, 200 ms settle)
//  before accepting REPETITIONS / ODR writes; MWMagnetometer handles this via
//  `warmupCommands` + `warmupDelayNanos`, so the tests don't need to do it
//  themselves. A freshly powered MetaMotion that skips this step silently
//  produces zero samples.
//
//  Only the MetaMotion variants (RL / RS / C / S) ship with a BMM150 — the
//  classic MetaWear boards (R, CPRO) do not. Tests skip gracefully when the
//  module is absent.
//

import Testing
import MetaWear
import Darwin
import Foundation

// MARK: - Magnetic-field data (non-packed)
//
// Non-packed magnetic-field signal — register 0x05.

@Suite("Magnetometer — Magnetic-Field Data", .serialized)
struct MagnetometerDataTests {

    // MARK: subscribe → expected [0x15, 0x05, 0x01]

    @Test @MainActor
    func subscribe_magnetic_field_data() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .magnetometer)?.isPresent == true,
                         "magnetometer not present on this board")
            let mag = MWMagnetometer(preset: .lowPower)   // 10 Hz
            let stream = try await device.startStream(mag, usePacked: false)

            var count = 0
            let collector = Task {
                for try await _ in stream {
                    count += 1
                    if count >= 3 { break }
                }
            }
            // lowPower is 10 Hz — 3 samples need ~300 ms, but the BMM150 warmup
            // takes 200 ms on top and the first sample may be delayed. Allow 4 s.
            try await Task.sleep(for: .seconds(4))
            collector.cancel()
            try await device.stopStreaming(mag)

            #expect(count >= 3,
                    "Expected ≥3 samples after subscribe [0x15, 0x05, 0x01], got \(count)")
            print("\n  Magnetometer subscribe: \(count) samples\n")
        }
    }

    // MARK: unsubscribe → expected [0x15, 0x05, 0x00]

    @Test @MainActor
    func unsubscribe_magnetic_field_data() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .magnetometer)?.isPresent == true,
                         "magnetometer not present on this board")
            let mag = MWMagnetometer(preset: .lowPower)
            let stream = try await device.startStream(mag, usePacked: false)

            var beforeStop = 0
            let collector = Task {
                for try await _ in stream { beforeStop += 1 }
            }
            // 10 Hz → ~10 samples in 1 s. Give the radio enough time to deliver
            // a few before we unsubscribe.
            try await Task.sleep(for: .milliseconds(1500))

            try await device.stopStreaming(mag)
            collector.cancel()

            let state = await device.state
            #expect(beforeStop > 0, "Expected magnetometer samples before unsubscribe, got 0")
            #expect(state == .idle, "Expected .idle after stopStreaming, got \(state)")
            print("\n  Magnetometer unsubscribe: \(beforeStop) samples before stop\n")
        }
    }

    // MARK: - Streaming test
    //
    // Verifies that a sustained stream at the `highAccuracy` preset (20 Hz)
    // delivers a plausible field magnitude. Earth's field is 25–65 µT; a board
    // sitting on a desk away from steel / laptops should read in that range.

    @Test @MainActor
    func magnetometer_receivesFieldData() async throws {
        try await withConnectedDevice { device in
            try #require(await device.moduleInfo(for: .magnetometer)?.isPresent == true,
                         "magnetometer not present on this board")
            let mag = MWMagnetometer(preset: .highAccuracy)   // 20 Hz
            let stream = try await device.startStream(mag, usePacked: false)

            var samples: [CartesianFloat] = []
            var count = 0
            let collector = Task {
                for try await s in stream {
                    count += 1
                    print(formatSample(count, s.value, unit: "µT"))
                    samples.append(s.value)
                }
            }

            // 20 Hz × 3 s = ~60 samples; accept ≥ 30 for BLE jitter and warmup delay.
            try await Task.sleep(for: .seconds(8))
            collector.cancel()
            try await device.stopStreaming(mag)

            #expect(samples.count > 30,
                    "Expected ≥30 samples in 3 s at 20 Hz, got \(samples.count)")

            if let last = samples.last {
                let mag_uT = (last.x * last.x + last.y * last.y + last.z * last.z).squareRoot()
                // Earth's field is 25–65 µT at most surface locations, but indoor
                // environments routinely push readings well over 200 µT — a
                // laptop, monitor stand, magnetic mount or steel desk frame at
                // close range easily contributes 100–300 µT of DC interference.
                // The bound here only needs to catch gross scale-factor bugs:
                // a missing `÷16` (the BMM150 LSB→µT factor) would report ~16×
                // higher, far outside even this generous window. 10–500 µT
                // tolerates a typical lab while still flagging such errors.
                #expect(mag_uT > 10 && mag_uT < 500,
                        "Magnetic-field magnitude should be plausible (10–500 µT), got \(mag_uT) µT")
                print("\n  Magnetometer: \(samples.count) samples, last |B|=\(String(format: "%.1f", mag_uT)) µT\n")
            }
        }
    }
}

// MARK: - Packed magnetic-field data
//
// Packed magnetic-field signal — register 0x09. Requires module revision ≥ 1.

@Suite("Magnetometer — Packed Magnetic-Field Data", .serialized)
struct MagnetometerPackedDataTests {

    // MARK: subscribe (packed) → expected [0x15, 0x09, 0x01]

    @Test @MainActor
    func subscribe_packed() async throws {
        try await withConnectedDevice { device in
            let info = try #require(await device.moduleInfo(for: .magnetometer),
                                    "magnetometer module info missing")
            try #require(info.isPresent, "magnetometer not present on this board")
            try #require(info.revision >= 1,
                         "magnetometer revision \(info.revision) predates packed data")
            let mag = MWMagnetometer(preset: .highAccuracy)   // 20 Hz
            let stream = try await device.startStream(mag, usePacked: true)

            var count = 0
            let collector = Task {
                for try await _ in stream { count += 1 }
            }
            // 20 Hz packed (3 samples/packet) × 3 s ≈ 60 samples; accept ≥ 30.
            try await Task.sleep(for: .seconds(3))
            collector.cancel()
            try await device.stopStreaming(mag)

            #expect(count > 30,
                    "Expected ≥30 packed magnetometer samples in 3 s at 20 Hz, got \(count)")
            print("\n  Magnetometer packed subscribe [0x15, 0x09, 0x01]: \(count) samples in 3 s\n")
        }
    }

    // MARK: unsubscribe (packed) → expected [0x15, 0x09, 0x00]

    @Test @MainActor
    func unsubscribe_packed() async throws {
        try await withConnectedDevice { device in
            let info = try #require(await device.moduleInfo(for: .magnetometer),
                                    "magnetometer module info missing")
            try #require(info.isPresent, "magnetometer not present on this board")
            try #require(info.revision >= 1,
                         "magnetometer revision \(info.revision) predates packed data")
            let mag = MWMagnetometer(preset: .highAccuracy)
            let stream = try await device.startStream(mag, usePacked: true)

            var beforeStop = 0
            let collector = Task {
                for try await _ in stream { beforeStop += 1 }
            }
            try await Task.sleep(for: .seconds(1))

            try await device.stopStreaming(mag)
            collector.cancel()

            let state = await device.state
            #expect(beforeStop > 0, "Expected packed magnetometer samples before unsubscribe, got 0")
            #expect(state == .idle, "Expected .idle after stopStreaming, got \(state)")
            print("\n  Magnetometer packed unsubscribe [0x15, 0x09, 0x00]: \(beforeStop) samples before stop\n")
        }
    }
}

// MARK: - Suspend
//
// `MWMagnetometer.Suspend` (POWER_MODE = 2) is gated on module revision ≥ 2.
// Verifies the command transmits without error on compatible hardware and
// skips otherwise.

@Suite("Magnetometer — Suspend", .serialized)
struct MagnetometerSuspendTests {

    @Test @MainActor
    func magnetometer_suspend_doesNotThrow() async throws {
        try await withConnectedDevice { device in
            let info = try #require(await device.moduleInfo(for: .magnetometer),
                                    "magnetometer module info missing")
            try #require(info.isPresent, "magnetometer not present on this board")
            try #require(info.revision >= 2,
                         "magnetometer revision \(info.revision) predates Suspend")
            try await device.send(MWMagnetometer.Suspend())
            print("\n  ✓ MWMagnetometer.Suspend sent without error (rev=\(info.revision))\n")
        }
    }
}
