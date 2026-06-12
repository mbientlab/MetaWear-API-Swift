//
//  MWAccelerometerBMI160Tests.swift
//  MetaWear
//
//  Pure command-byte / parser tests for MWAccelerometerBMI160 and
//  MWAccelerometerBMI160Steps. Ported from
//  MetaWear-SDK-Cpp/test/test_accelerometer_bmi160.py — no hardware required.
//
//  Live-streaming / subscribe / unsubscribe tests live alongside the real
//  device in Tests/MetaWearHardwareTests/AccelerometerBMI160Tests.swift.

import Testing
import Foundation
@testable import MetaWear

// MARK: - TestAccBmi160Config
//
// Verifies the command bytes produced by MWAccelerometerBMI160 match
// the C++ SDK reference for every ODR, range, and combined configuration.

@Suite("BMI160 — Config Commands")
struct AccBmi160ConfigTests {

    // MARK: test_set_odr
    // mbl_mw_acc_bmi160_set_odr + mbl_mw_acc_bosch_write_acceleration_config
    // Default range in C++ tests is ±2 g (BMI160 configByte 0x03).
    // acc_conf layout: bits[3:0]=odr, bits[6:4]=bwp(2 normal / 0 under-sampling), bit7=acc_us

    @Test func odr_0_78Hz()  { #expect(cmd(.hz0_78,  .g2) == Data([0x03, 0x03, 0x81, 0x03])) }
    @Test func odr_1_56Hz()  { #expect(cmd(.hz1_56,  .g2) == Data([0x03, 0x03, 0x82, 0x03])) }
    @Test func odr_3_12Hz()  { #expect(cmd(.hz3_12,  .g2) == Data([0x03, 0x03, 0x83, 0x03])) }
    @Test func odr_6_25Hz()  { #expect(cmd(.hz6_25,  .g2) == Data([0x03, 0x03, 0x84, 0x03])) }
    @Test func odr_12_5Hz()  { #expect(cmd(.hz12_5,  .g2) == Data([0x03, 0x03, 0x25, 0x03])) }
    @Test func odr_25Hz()    { #expect(cmd(.hz25,    .g2) == Data([0x03, 0x03, 0x26, 0x03])) }
    @Test func odr_50Hz()    { #expect(cmd(.hz50,    .g2) == Data([0x03, 0x03, 0x27, 0x03])) }
    @Test func odr_100Hz()   { #expect(cmd(.hz100,   .g2) == Data([0x03, 0x03, 0x28, 0x03])) }
    @Test func odr_200Hz()   { #expect(cmd(.hz200,   .g2) == Data([0x03, 0x03, 0x29, 0x03])) }
    @Test func odr_400Hz()   { #expect(cmd(.hz400,   .g2) == Data([0x03, 0x03, 0x2A, 0x03])) }
    @Test func odr_800Hz()   { #expect(cmd(.hz800,   .g2) == Data([0x03, 0x03, 0x2B, 0x03])) }
    @Test func odr_1600Hz()  { #expect(cmd(.hz1600,  .g2) == Data([0x03, 0x03, 0x2C, 0x03])) }

    // MARK: test_set_range
    // mbl_mw_acc_bosch_set_range(_16G) with default ODR 100 Hz
    // expected= [0x03, 0x03, 0x28, 0x0C]

    @Test func range_16G() {
        #expect(cmd(.hz100, .g16) == Data([0x03, 0x03, 0x28, 0x0C]))
    }

    // MARK: test_set_odr_and_range
    // mbl_mw_acc_bmi160_set_odr(_200Hz) + mbl_mw_acc_bosch_set_range(_8G)
    // expected= [0x03, 0x03, 0x29, 0x08]

    @Test func odr_200Hz_range_8G() {
        #expect(cmd(.hz200, .g8) == Data([0x03, 0x03, 0x29, 0x08]))
    }

    // MARK: test_enable_acceleration_sampling
    // mbl_mw_acc_bosch_enable_acceleration_sampling → expected= [0x03, 0x02, 0x01, 0x00]

    @Test func enableCommand() {
        #expect(MWAccelerometerBMI160().enableCommand == Data([0x03, 0x02, 0x01, 0x00]))
    }

    // MARK: test_disable_acceleration_sampling
    // mbl_mw_acc_bosch_disable_acceleration_sampling → expected= [0x03, 0x02, 0x00, 0x01]

    @Test func disableCommand() {
        #expect(MWAccelerometerBMI160().disableCommand == Data([0x03, 0x02, 0x00, 0x01]))
    }

    // MARK: - Helper

    private func cmd(_ odr: MWAccelerometerBMI160.ODR,
                     _ range: MWAccelerometerBMI160.Range) -> Data {
        MWAccelerometerBMI160(odr: odr, range: range).configureCommands[0]
    }
}

// MARK: - TestBmi160AccelerationData (parser only)

@Suite("BMI160 — Acceleration Data Parsing")
struct Bmi160AccelerationDataParseTests {

    // MARK: test_get_acceleration_data_g
    //
    // response= b'\x03\x04\x16\xc4\x94\xa2\x2a\xd0'
    // range: ±4 g  →  scale = 8192 LSB/g
    // expected= CartesianFloat(x= -1.872, y= -2.919, z= -1.495)

    @Test func parseSample_4G() throws {
        let packet = Data([0x03, 0x04, 0x16, 0xC4, 0x94, 0xA2, 0x2A, 0xD0])
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g4)
        let result = try sensor.parseSample(from: packet)
        let eps: Float = 0.001
        #expect(abs(result.x - (-1.872)) < eps, "x: expected -1.872, got \(result.x)")
        #expect(abs(result.y - (-2.919)) < eps, "y: expected -2.919, got \(result.y)")
        #expect(abs(result.z - (-1.495)) < eps, "z: expected -1.495, got \(result.z)")
    }
}

// MARK: - TestBmi160HighFreqAccData (parser only)
//
// Packed acceleration data signal — register 0x1C.

@Suite("BMI160 — Packed Acceleration Data Parsing")
struct Bmi160PackedAccDataParseTests {

    // MARK: test_get_acceleration_data_g (packed)
    //
    // range: ±8 g  →  scale = 4096 LSB/g
    // expected= [(-4.539, 0.833, -0.131), (-2.995, 0.894, 0.146), (-0.029, 0.352, 0.065)]

    @Test func parsePackedSamples_8G() throws {
        let packet = Data([
            0x03, 0x1C,
            0x62, 0xB7, 0x53, 0x0D, 0xE9, 0xFD,   // sample 0
            0x16, 0xD0, 0x4D, 0x0E, 0x57, 0x02,   // sample 1
            0x8A, 0xFF, 0xA1, 0x05, 0x0A, 0x01    // sample 2
        ])
        let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g8)
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

    // Packed register is 0x1C on BMI160 (vs 0x05 on BMI270)

    @Test func packedDataRegister_is_0x1C() {
        #expect(MWAccelerometerBMI160().packedDataRegister == 0x1C)
    }
}

// MARK: - TestBmi160StepCounterSetup
//
// Swift port of TestBmi160StepCounterSetup.
// ConfigureStepCounter(mode:) combines set_mode + enable + write_config into one command.

@Suite("BMI160 — Step Counter Setup")
struct Bmi160StepCounterSetupTests {

    // test_set_mode NORMAL: set_mode + enable + write_config → [0x03, 0x18, 0x15, 0x0B]
    @Test func set_mode_normal() {
        let cmd = MWAccelerometerBMI160Steps.ConfigureStepCounter(mode: .normal).commandData
        #expect(cmd == Data([0x03, 0x18, 0x15, 0x0B]))
    }

    // test_set_mode SENSITIVE → [0x03, 0x18, 0x2D, 0x08]
    @Test func set_mode_sensitive() {
        let cmd = MWAccelerometerBMI160Steps.ConfigureStepCounter(mode: .sensitive).commandData
        #expect(cmd == Data([0x03, 0x18, 0x2D, 0x08]))
    }

    // test_set_mode ROBUST → [0x03, 0x18, 0x1D, 0x0F]
    @Test func set_mode_robust() {
        let cmd = MWAccelerometerBMI160Steps.ConfigureStepCounter(mode: .robust).commandData
        #expect(cmd == Data([0x03, 0x18, 0x1D, 0x0F]))
    }
}

// MARK: - TestBmi160StepCounterData
//
// Swift port of TestBmi160StepCounterData.

@Suite("BMI160 — Step Counter Data")
struct Bmi160StepCounterDataTests {

    // test_get_step_count_value
    // response [0x03, 0x9A, 0x2B, 0x00] → 43 steps
    @Test func parse_step_count_43() throws {
        let packet = Data([0x03, 0x9A, 0x2B, 0x00])
        let count = try MWAccelerometerBMI160Steps.parseStepCount(from: packet)
        #expect(count == 43)
    }

    // test_read_step_counter: subscribe then read → [0x03, 0x9A]
    @Test func read_step_counter_command() {
        let cmd = MWAccelerometerBMI160Steps.ReadStepCounter().commandData
        #expect(cmd == Data([0x03, 0x9A]))
    }

    // test_read_step_counter_silent: read without subscriber → [0x03, 0xDA]
    @Test func read_step_counter_silent_command() {
        let cmd = MWAccelerometerBMI160Steps.ReadStepCounterSilent().commandData
        #expect(cmd == Data([0x03, 0xDA]))
    }
}

// MARK: - TestBmi160StepDetectorData
//
// Swift port of TestBmi160StepDetectorData.

@Suite("BMI160 — Step Detector")
struct Bmi160StepDetectorTests {

    // test_subscribe_detector: subscribe sends [0x03, 0x19, 0x01]
    @Test func subscribe_detector_register() {
        let subscribeCmd = MWPacket.command(.accelerometer, MWAccelerometerBMI160Steps.stepDetectorRegister, 0x01)
        #expect(subscribeCmd == Data([0x03, 0x19, 0x01]))
    }

    // test_enable_detector → [0x03, 0x17, 0x01, 0x00]
    @Test func enable_step_detector() {
        let cmd = MWAccelerometerBMI160Steps.EnableStepDetector().commandData
        #expect(cmd == Data([0x03, 0x17, 0x01, 0x00]))
    }

    // test_disable_detector → [0x03, 0x17, 0x00, 0x01]
    @Test func disable_step_detector() {
        let cmd = MWAccelerometerBMI160Steps.DisableStepDetector().commandData
        #expect(cmd == Data([0x03, 0x17, 0x00, 0x01]))
    }

    // test_get_detection: response [0x03, 0x19, 0x01] → 1
    @Test func parse_step_detection_1() throws {
        let packet = Data([0x03, 0x19, 0x01])
        let detected = try MWAccelerometerBMI160Steps.parseStepDetection(from: packet)
        #expect(detected == 1)
    }

    // test_get_detection (no step): response [0x03, 0x19, 0x00] → 0
    @Test func parse_step_detection_0() throws {
        let packet = Data([0x03, 0x19, 0x00])
        let detected = try MWAccelerometerBMI160Steps.parseStepDetection(from: packet)
        #expect(detected == 0)
    }
}
