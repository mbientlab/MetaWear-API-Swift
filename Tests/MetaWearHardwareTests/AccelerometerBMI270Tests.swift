//
//  AccelerometerBMI270Tests.swift
//  MetaWear
//
//  Swift port of MetaWear-SDK-Cpp/test/test_accelerometer_bmi270.py
//
//  Python class → Swift suite mapping:
//    TestAccBmi270Config            → AccBmi270ConfigTests        (command-byte, no hardware)
//    TestBmi270AccelerationData     → Bmi270AccelerationDataTests  (parsing + hardware subscribe)
//    TestBmi270HighFreqAccData      → Bmi270PackedAccDataTests     (parsing + hardware subscribe)
//    TestBmi270StepCounter*         → not yet implemented in Swift SDK
//    TestBmi270StepDetector*        → not yet implemented in Swift SDK

import Testing
import MetaWear
import Darwin
import Foundation

// MARK: - TestAccBmi270Config
//
// Verifies the command bytes produced by MWAccelerometerBMI270 match
// the C++ SDK reference for every ODR, range, and combined configuration.
// Pure value-type assertions — no hardware required.

@Suite("BMI270 — Config Commands")
struct AccBmi270ConfigTests {

    // MARK: test_set_odr
    // mbl_mw_acc_bmi270_set_odr + mbl_mw_acc_bosch_write_acceleration_config
    // Default range in C++ tests is ±8 g (BMI270 configByte 0x02).
    // acc_conf layout: bits[3:0]=odr, bits[6:4]=bwp(2), bit7=perf(1 if ODR ≥ 12.5 Hz)

    @Test func odr_0_78Hz()  { #expect(cmd(.hz0_78,  .g8) == Data([0x03, 0x03, 0x21, 0x02])) }
    @Test func odr_1_56Hz()  { #expect(cmd(.hz1_56,  .g8) == Data([0x03, 0x03, 0x22, 0x02])) }
    @Test func odr_3_12Hz()  { #expect(cmd(.hz3_12,  .g8) == Data([0x03, 0x03, 0x23, 0x02])) }
    @Test func odr_6_25Hz()  { #expect(cmd(.hz6_25,  .g8) == Data([0x03, 0x03, 0x24, 0x02])) }
    @Test func odr_12_5Hz()  { #expect(cmd(.hz12_5,  .g8) == Data([0x03, 0x03, 0xA5, 0x02])) }
    @Test func odr_25Hz()    { #expect(cmd(.hz25,    .g8) == Data([0x03, 0x03, 0xA6, 0x02])) }
    @Test func odr_50Hz()    { #expect(cmd(.hz50,    .g8) == Data([0x03, 0x03, 0xA7, 0x02])) }
    @Test func odr_100Hz()   { #expect(cmd(.hz100,   .g8) == Data([0x03, 0x03, 0xA8, 0x02])) }
    @Test func odr_200Hz()   { #expect(cmd(.hz200,   .g8) == Data([0x03, 0x03, 0xA9, 0x02])) }
    @Test func odr_400Hz()   { #expect(cmd(.hz400,   .g8) == Data([0x03, 0x03, 0xAA, 0x02])) }
    @Test func odr_800Hz()   { #expect(cmd(.hz800,   .g8) == Data([0x03, 0x03, 0xAB, 0x02])) }
    @Test func odr_1600Hz()  { #expect(cmd(.hz1600,  .g8) == Data([0x03, 0x03, 0xAC, 0x02])) }

    // MARK: test_set_range
    // mbl_mw_acc_bosch_set_range(_16G) with default ODR 100 Hz
    // expected= [0x03, 0x03, 0xA8, 0x03]

    @Test func range_16G() {
        #expect(cmd(.hz100, .g16) == Data([0x03, 0x03, 0xA8, 0x03]))
    }

    // MARK: test_set_odr_and_range
    // mbl_mw_acc_bmi270_set_odr(_200Hz) + mbl_mw_acc_bosch_set_range(_8G)
    // expected= [0x03, 0x03, 0xA9, 0x02]

    @Test func odr_200Hz_range_8G() {
        #expect(cmd(.hz200, .g8) == Data([0x03, 0x03, 0xA9, 0x02]))
    }

    // MARK: test_enable_acceleration_sampling
    // mbl_mw_acc_bosch_enable_acceleration_sampling → expected= [0x03, 0x02, 0x01, 0x00]

    @Test func enableCommand() {
        #expect(MWAccelerometerBMI270().enableCommand == Data([0x03, 0x02, 0x01, 0x00]))
    }

    // MARK: test_disable_acceleration_sampling
    // mbl_mw_acc_bosch_disable_acceleration_sampling → expected= [0x03, 0x02, 0x00, 0x01]

    @Test func disableCommand() {
        #expect(MWAccelerometerBMI270().disableCommand == Data([0x03, 0x02, 0x00, 0x01]))
    }

    // MARK: - Helper

    private func cmd(_ odr: MWAccelerometerBMI270.ODR,
                     _ range: MWAccelerometerBMI270.Range) -> Data {
        MWAccelerometerBMI270(odr: odr, range: range).configureCommands[0]
    }
}

// MARK: - TestBmi270AccelerationData
//
// Normal (non-packed) acceleration data signal — register 0x04.

@Suite("BMI270 — Acceleration Data", .serialized)
struct Bmi270AccelerationDataTests {

    // MARK: test_get_acceleration_data_g
    //
    // response= b'\x03\x04\x16\xc4\x94\xa2\x2a\xd0'
    // range: ±4 g  →  scale = 8192 LSB/g
    // expected= CartesianFloat(x= -1.872, y= -2.919, z= -1.495)
    //
    // x: LE int16 [0x16, 0xC4] = 0xC416 = -15338  →  -15338 / 8192 = -1.872
    // y: LE int16 [0x94, 0xA2] = 0xA294 = -23916  →  -23916 / 8192 = -2.919
    // z: LE int16 [0x2A, 0xD0] = 0xD02A = -12246  →  -12246 / 8192 ≈ -1.495

    @Test func parseSample_4G() throws {
        let packet = Data([0x03, 0x04, 0x16, 0xC4, 0x94, 0xA2, 0x2A, 0xD0])
        let sensor = MWAccelerometerBMI270(odr: .hz100, range: .g4)
        let result = try sensor.parseSample(from: packet)
        let eps: Float = 0.001
        #expect(abs(result.x - (-1.872)) < eps, "x: expected -1.872, got \(result.x)")
        #expect(abs(result.y - (-2.919)) < eps, "y: expected -2.919, got \(result.y)")
        #expect(abs(result.z - (-1.495)) < eps, "z: expected -1.495, got \(result.z)")
    }

    // MARK: test_subscribe_acceleration_data
    // mbl_mw_datasignal_subscribe → expected [0x03, 0x04, 0x01]
    // device.stream() sends [module, dataRegister, 0x01] before enable + start.

    @Test @MainActor
    func subscribe_acceleration_data() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 4 else {
                print("\n  Skipping — BMI270 not present\n"); return
            }
            let sensor = MWAccelerometerBMI270(odr: .hz100, range: .g2)
            let stream = try await device.stream(sensor, usePacked: false)

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
                    "Expected ≥5 samples after subscribe [0x03, 0x04, 0x01], got \(count)")
            print("\n  BMI270 subscribe acceleration: \(count) samples\n")
        }
    }

    // MARK: test_unsubscribe_acceleration_data
    // mbl_mw_datasignal_unsubscribe → expected [0x03, 0x04, 0x00]
    // device.stopStreaming() sends [module, dataRegister, 0x00].

    @Test @MainActor
    func unsubscribe_acceleration_data() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 4 else {
                print("\n  Skipping — BMI270 not present\n"); return
            }
            let sensor = MWAccelerometerBMI270(odr: .hz100, range: .g2)
            let stream = try await device.stream(sensor, usePacked: false)

            var beforeStop = 0
            let collector = Task {
                for try await _ in stream { beforeStop += 1 }
            }
            try await Task.sleep(for: .milliseconds(500))

            // Sends stop + disable + [0x03, 0x04, 0x00]
            try await device.stopStreaming(sensor)
            collector.cancel()

            let state = await device.state
            #expect(beforeStop > 0, "Expected samples before unsubscribe, got 0")
            #expect(state == .idle, "Expected .idle after stopStreaming, got \(state)")
            print("\n  BMI270 unsubscribe acceleration: \(beforeStop) samples before stop\n")
        }
    }
}

// MARK: - TestBmi270HighFreqAccData
//
// Packed acceleration data signal — register 0x05.
// Each BLE packet carries 3 XYZ samples (18 payload bytes after the 2-byte header).

@Suite("BMI270 — Packed Acceleration Data", .serialized)
struct Bmi270PackedAccDataTests {

    // MARK: test_get_acceleration_data_g (packed)
    //
    // response= b'\x03\x05\x62\xb7\x53\x0d\xe9\xfd\x16\xd0\x4d\x0e\x57\x02\x8a\xff\xa1\x05\x0a\x01'
    // range: ±8 g  →  scale = 4096 LSB/g
    // expected= [(-4.539, 0.833, -0.131), (-2.995, 0.894, 0.146), (-0.029, 0.352, 0.065)]
    //
    // sample 0: x=0xB762=-18590→-4.539,  y=0x0D53=3411→0.833,   z=0xFDE9=-535→-0.131
    // sample 1: x=0xD016=-12266→-2.995,  y=0x0E4D=3661→0.894,   z=0x0257=599→0.146
    // sample 2: x=0xFF8A=-118→-0.029,    y=0x05A1=1441→0.352,   z=0x010A=266→0.065

    @Test func parsePackedSamples_8G() throws {
        let packet = Data([
            0x03, 0x05,
            0x62, 0xB7, 0x53, 0x0D, 0xE9, 0xFD,   // sample 0
            0x16, 0xD0, 0x4D, 0x0E, 0x57, 0x02,   // sample 1
            0x8A, 0xFF, 0xA1, 0x05, 0x0A, 0x01    // sample 2
        ])
        let sensor = MWAccelerometerBMI270(odr: .hz100, range: .g8)
        let samples = try sensor.parsePackedSamples(from: packet)

        #expect(samples.count == 3, "Expected 3 packed samples, got \(samples.count)")

        let eps: Float = 0.001
        #expect(abs(samples[0].x - (-4.539)) < eps, "s0.x: expected -4.539, got \(samples[0].x)")
        #expect(abs(samples[0].y -   0.833)  < eps, "s0.y: expected  0.833, got \(samples[0].y)")
        #expect(abs(samples[0].z - (-0.131)) < eps, "s0.z: expected -0.131, got \(samples[0].z)")

        #expect(abs(samples[1].x - (-2.995)) < eps, "s1.x: expected -2.995, got \(samples[1].x)")
        #expect(abs(samples[1].y -   0.894)  < eps, "s1.y: expected  0.894, got \(samples[1].y)")
        #expect(abs(samples[1].z -   0.146)  < eps, "s1.z: expected  0.146, got \(samples[1].z)")

        #expect(abs(samples[2].x - (-0.029)) < eps, "s2.x: expected -0.029, got \(samples[2].x)")
        #expect(abs(samples[2].y -   0.352)  < eps, "s2.y: expected  0.352, got \(samples[2].y)")
        #expect(abs(samples[2].z -   0.065)  < eps, "s2.z: expected  0.065, got \(samples[2].z)")
    }

    // Packed register is 0x05 on BMI270 (vs 0x1C on BMI160)

    @Test func packedDataRegister_is_0x05() {
        #expect(MWAccelerometerBMI270().packedDataRegister == 0x05)
    }

    // MARK: test_subscribe (packed) → expected [0x03, 0x05, 0x01]
    // device.stream(usePacked: true) subscribes to register 0x05.

    @Test @MainActor
    func subscribe_packed() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 4 else {
                print("\n  Skipping — BMI270 not present\n"); return
            }
            let sensor = MWAccelerometerBMI270(odr: .hz100, range: .g2)
            // usePacked: true → uses register 0x05, sends [0x03, 0x05, 0x01]
            let stream = try await device.stream(sensor, usePacked: true)

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

    // MARK: test_unsubscribe (packed) → expected [0x03, 0x05, 0x00]

    @Test @MainActor
    func unsubscribe_packed() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 4 else {
                print("\n  Skipping — BMI270 not present\n"); return
            }
            let sensor = MWAccelerometerBMI270(odr: .hz100, range: .g2)
            let stream = try await device.stream(sensor, usePacked: true)

            var beforeStop = 0
            let collector = Task {
                for try await _ in stream { beforeStop += 1 }
            }
            try await Task.sleep(for: .milliseconds(500))

            // stopStreaming sends [0x03, 0x05, 0x00] for the packed register
            try await device.stopStreaming(sensor)
            collector.cancel()

            let state = await device.state
            #expect(beforeStop > 0, "Expected packed samples before unsubscribe, got 0")
            #expect(state == .idle, "Expected .idle after stopStreaming, got \(state)")
            print("\n  BMI270 packed unsubscribe [0x03, 0x05, 0x00]: \(beforeStop) samples before stop\n")
        }
    }

    // MARK: - Original hardware streaming test (kept from prior file)
    //
    // Verifies ~2000 samples arrive in 20 s at 100 Hz packed mode.

    @Test @MainActor
    func accelerometer_bmi270_receives1000Samples() async throws {
        try await withConnectedDevice { device in
            guard await device.moduleInfo(for: .accelerometer)?.implementation == 4 else {
                print("\n  Skipping — BMI270 not present\n"); return
            }
            let sensor = MWAccelerometerBMI270(odr: .hz100, range: .g2)
            let stream = try await device.stream(sensor, usePacked: true)

            var samples: [CartesianFloat] = []
            let collector = Task {
                for try await s in stream {
                    samples.append(s.value)
                    fputs("  accel x=\(s.value.x) y=\(s.value.y) z=\(s.value.z)\n", stderr)
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

// MARK: - TestBmi270StepCounterSetup
//
// Swift port of TestBmi270StepCounterSetup.
// ConfigureStepCounter(trigger:) combines enable_step_counter + write_step_counter_config.
// The Python test asserts on the LAST command (write_step_counter_config).

@Suite("BMI270 — Step Counter Setup")
struct Bmi270StepCounterSetupTests {

    // test_set_mode (count 20 steps, trigger=1)
    // set_step_counter_trigger(1) + enable_step_counter + write_step_counter_config
    // → last command [0x03, 0x08, 0x07, 0x00, 0x0E, 0x01, 0x00]
    @Test func set_mode_trigger1() {
        let cmd = MWAccelerometerBMI270Steps.ConfigureStepCounter(trigger: 1).configCommand
        #expect(cmd == Data([0x03, 0x08, 0x07, 0x00, 0x0E, 0x01, 0x00]))
    }

    // Verify the enable commands are also correct (not explicitly tested in Python, but verifiable)
    @Test func enable_commands_for_step_counter() {
        let config = MWAccelerometerBMI270Steps.ConfigureStepCounter(trigger: 1)
        #expect(config.interruptEnableCommand == Data([0x03, 0x07, 0x02, 0x00]))
        #expect(config.featureEnableCommand   == Data([0x03, 0x06, 0x02, 0x00]))
    }
}

// MARK: - TestBmi270StepCounterData
//
// Swift port of TestBmi270StepCounterData and TestBmi270StepCounterRead.

@Suite("BMI270 — Step Counter Data")
struct Bmi270StepCounterDataTests {

    // test_get_step_count_value
    // response [0x03, 0x0B, 0x14, 0x00] → 20 steps
    @Test func parse_step_count_20() throws {
        let packet = Data([0x03, 0x0B, 0x14, 0x00])
        let count = try MWAccelerometerBMI270Steps.parseStepCount(from: packet)
        #expect(count == 20)
    }

    // test_read_step_counter → [0x03, 0x8B] = [module, 0x80 | 0x0B]
    @Test func read_step_counter_command() {
        let cmd = MWAccelerometerBMI270Steps.ReadStepCounter().commandData
        #expect(cmd == Data([0x03, 0x8B]))
    }
}

// MARK: - TestBmi270StepDetectorData
//
// Swift port of TestBmi270StepDetectorData.
// Note: step detector and step counter share register 0x0B on BMI270.

@Suite("BMI270 — Step Detector")
struct Bmi270StepDetectorTests {

    // test_subscribe_detector: subscribe sends [0x03, 0x0B, 0x01]
    @Test func subscribe_detector_register() {
        let subscribeCmd = MWPacket.command(.accelerometer, MWAccelerometerBMI270Steps.stepRegister, 0x01)
        #expect(subscribeCmd == Data([0x03, 0x0B, 0x01]))
    }

    // test_enable_detector → last command [0x03, 0x06, 0x80, 0x00] (FEATURE_ENABLE)
    @Test func enable_step_detector_feature_enable() {
        let cmd = MWAccelerometerBMI270Steps.EnableStepDetector().featureEnableCommand
        #expect(cmd == Data([0x03, 0x06, 0x80, 0x00]))
    }

    // Also verify the interrupt enable command
    @Test func enable_step_detector_interrupt_enable() {
        let cmd = MWAccelerometerBMI270Steps.EnableStepDetector().interruptEnableCommand
        #expect(cmd == Data([0x03, 0x07, 0x80, 0x00]))
    }

    // test_disable_detector → last command [0x03, 0x06, 0x00, 0x80] (FEATURE_ENABLE cleared)
    @Test func disable_step_detector_feature_disable() {
        let cmd = MWAccelerometerBMI270Steps.DisableStepDetector().featureDisableCommand
        #expect(cmd == Data([0x03, 0x06, 0x00, 0x80]))
    }

    // Also verify the interrupt disable command
    @Test func disable_step_detector_interrupt_disable() {
        let cmd = MWAccelerometerBMI270Steps.DisableStepDetector().interruptDisableCommand
        #expect(cmd == Data([0x03, 0x07, 0x00, 0x80]))
    }

    // test_get_detection (no step): response [0x03, 0x0B, 0x00] → 0
    @Test func parse_step_detection_0() throws {
        let packet = Data([0x03, 0x0B, 0x00])
        let detected = try MWAccelerometerBMI270Steps.parseStepDetection(from: packet)
        #expect(detected == 0)
    }

    // test_get_detection (step occurred): response [0x03, 0x0B, 0x01] → 1
    @Test func parse_step_detection_1() throws {
        let packet = Data([0x03, 0x0B, 0x01])
        let detected = try MWAccelerometerBMI270Steps.parseStepDetection(from: packet)
        #expect(detected == 1)
    }
}
