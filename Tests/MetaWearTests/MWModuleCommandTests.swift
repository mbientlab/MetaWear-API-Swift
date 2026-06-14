import Testing
import Foundation
@testable import MetaWear

// MARK: - Packet builder

@Suite("Packet Builder")
struct PacketBuilderTests {

    @Test func commandPacket() {
        let data = MWPacket.command(.accelerometer, 0x01, [0x01])
        #expect(data == Data([0x03, 0x01, 0x01]))
    }

    @Test func readPacket_setsReadBit() {
        let data = MWPacket.read(.accelerometer, 0x01, [])
        #expect(data[1] == 0x81)   // 0x01 | 0x80
    }

    @Test func parseModuleId() {
        let packet = Data([0x03, 0x04, 0xAA, 0xBB])
        #expect(MWPacket.module(from: packet) == .accelerometer)
    }

    @Test func parseRegister_stripsReadBit() {
        let packet = Data([0x03, 0x84, 0x00])  // register 0x04 with read bit
        #expect(MWPacket.register(from: packet) == 0x04)
    }
}

// MARK: - Accelerometer BMI160 commands

@Suite("Accelerometer BMI160 Commands")
struct AccBMI160CommandTests {

    let sensor = MWAccelerometerBMI160(odr: .hz100, range: .g2)

    @Test func startCommand() {
        #expect(sensor.startCommand   == Data([0x03, 0x01, 0x01]))
    }

    @Test func stopCommand() {
        #expect(sensor.stopCommand    == Data([0x03, 0x01, 0x00]))
    }

    @Test func enableCommand() {
        #expect(sensor.enableCommand  == Data([0x03, 0x02, 0x01, 0x00]))
    }

    @Test func disableCommand() {
        #expect(sensor.disableCommand == Data([0x03, 0x02, 0x00, 0x01]))
    }

    @Test func configCommand_odr100_g2() {
        // ODR 100Hz enum = 7, configByte = 8 (7+1)
        // bwp = 2 → (2 << 4) = 0x20
        // us = 0 (ODR >= 12.5Hz)
        // confByte = 0x00 | 0x20 | 0x08 = 0x28
        // rangeByte for ±2g BMI160 = 0x03
        let cmds = sensor.configureCommands
        #expect(cmds.count == 1)
        #expect(cmds[0] == Data([0x03, 0x03, 0x28, 0x03]))
    }

    @Test func configCommand_odr25_g16() {
        let s = MWAccelerometerBMI160(odr: .hz25, range: .g16)
        // ODR 25Hz enum = 5, configByte = 6
        // confByte = 0x20 | 0x06 = 0x26
        // rangeByte for ±16g BMI160 = 0x0C
        let cmds = s.configureCommands
        #expect(cmds[0] == Data([0x03, 0x03, 0x26, 0x0C]))
    }

    // Reference vectors from test_accelerometer_bmi160.py (MbientLab C++ SDK)
    // Under-sampling ODRs: us=0x80, bwp=0. Normal ODRs: us=0, bwp=2.

    @Test func configCommand_odr0_78_underSampling() {
        // 0.78125Hz: us=0x80, bwp=0, odr=0x01 → 0x81
        #expect(MWAccelerometerBMI160(odr: .hz0_78,  range: .g2).configureCommands[0][2] == 0x81)
    }

    @Test func configCommand_odr6_25_underSampling() {
        // 6.25Hz: us=0x80, bwp=0, odr=0x04 → 0x84
        #expect(MWAccelerometerBMI160(odr: .hz6_25,  range: .g2).configureCommands[0][2] == 0x84)
    }

    @Test func configCommand_odr12_5_normalMode() {
        // 12.5Hz: us=0, bwp=2, odr=0x05 → 0x25
        #expect(MWAccelerometerBMI160(odr: .hz12_5,  range: .g2).configureCommands[0][2] == 0x25)
    }

    @Test func configCommand_odr200_g8() {
        // 200Hz + ±8g: confByte=0x29, rangeByte=0x08
        #expect(MWAccelerometerBMI160(odr: .hz200, range: .g8).configureCommands[0] == Data([0x03, 0x03, 0x29, 0x08]))
    }

    @Test func configCommand_odr100_g16() {
        // 100Hz + ±16g: confByte=0x28, rangeByte=0x0C
        #expect(MWAccelerometerBMI160(odr: .hz100, range: .g16).configureCommands[0] == Data([0x03, 0x03, 0x28, 0x0C]))
    }

    @Test func dataRegister() {
        #expect(sensor.dataRegister == 0x04)
    }

    @Test func packedDataRegister() {
        #expect(sensor.packedDataRegister == 0x1C)
    }
}

// MARK: - Accelerometer BMI270 commands

@Suite("Accelerometer BMI270 Commands")
struct AccBMI270CommandTests {

    let sensor = MWAccelerometerBMI270(odr: .hz100, range: .g2)

    // Reference vectors from test_accelerometer_bmi270.py (MbientLab C++ SDK)
    // acc_conf: bits[3:0]=odr, bits[6:4]=bwp(always 2), bit7=acc_filter_perf(1 for ODR≥12.5Hz)

    @Test func configCommand_odr100_g2() {
        // 100Hz: odr=0x08, bwp=0x20, perf=0x80 → confByte=0xA8; range ±2g = 0x00
        #expect(sensor.configureCommands[0] == Data([0x03, 0x03, 0xA8, 0x00]))
    }

    @Test func configCommand_odr200_g8() {
        let s = MWAccelerometerBMI270(odr: .hz200, range: .g8)
        // 200Hz: odr=0x09, bwp=0x20, perf=0x80 → 0xA9; range ±8g = 0x02
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0xA9, 0x02]))
    }

    @Test func configCommand_odr6_25_g2() {
        let s = MWAccelerometerBMI270(odr: .hz6_25, range: .g2)
        // 6.25Hz: odr=0x04, bwp=0x20, perf=0x00 → 0x24; range ±2g = 0x00
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0x24, 0x00]))
    }

    @Test func configCommand_odr0_78_g2() {
        let s = MWAccelerometerBMI270(odr: .hz0_78, range: .g2)
        // 0.78125Hz: odr=0x01, bwp=0x20, perf=0x00 → 0x21; range ±2g = 0x00
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0x21, 0x00]))
    }

    @Test func configCommand_g16_rangeByte() {
        let s = MWAccelerometerBMI270(odr: .hz100, range: .g16)
        // BMI270 ±16g = 0x03
        #expect(s.configureCommands[0][3] == 0x03)
    }

    @Test func packedDataRegister_differentFromBMI160() {
        // BMI270 packed register = 0x05, BMI160 = 0x1C
        #expect(sensor.packedDataRegister == 0x05)
    }
}

// MARK: - BMI270 Python reference vectors
//
// Exact byte-vector ports from MetaWear-SDK-Cpp/test/test_accelerometer_bmi270.py.
// The Python tests all run against the MotionS board whose C++ default range is
// ±8g (configByte 0x02), so `test_set_odr` expects the trailing range byte to be
// 0x02 without explicitly calling `set_range`.

@Suite("Accelerometer BMI270 — Python Vectors")
struct AccBMI270PythonVectorTests {

    // MARK: test_set_odr — all 12 ODR values with default range 8G

    @Test func setOdr_0_78Hz_defaultRange8G() {
        let s = MWAccelerometerBMI270(odr: .hz0_78, range: .g8)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0x21, 0x02]))
    }

    @Test func setOdr_1_5625Hz_defaultRange8G() {
        let s = MWAccelerometerBMI270(odr: .hz1_56, range: .g8)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0x22, 0x02]))
    }

    @Test func setOdr_3_125Hz_defaultRange8G() {
        let s = MWAccelerometerBMI270(odr: .hz3_12, range: .g8)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0x23, 0x02]))
    }

    @Test func setOdr_6_25Hz_defaultRange8G() {
        let s = MWAccelerometerBMI270(odr: .hz6_25, range: .g8)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0x24, 0x02]))
    }

    @Test func setOdr_12_5Hz_defaultRange8G() {
        let s = MWAccelerometerBMI270(odr: .hz12_5, range: .g8)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0xA5, 0x02]))
    }

    @Test func setOdr_25Hz_defaultRange8G() {
        let s = MWAccelerometerBMI270(odr: .hz25, range: .g8)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0xA6, 0x02]))
    }

    @Test func setOdr_50Hz_defaultRange8G() {
        let s = MWAccelerometerBMI270(odr: .hz50, range: .g8)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0xA7, 0x02]))
    }

    @Test func setOdr_100Hz_defaultRange8G() {
        let s = MWAccelerometerBMI270(odr: .hz100, range: .g8)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0xA8, 0x02]))
    }

    @Test func setOdr_200Hz_defaultRange8G() {
        let s = MWAccelerometerBMI270(odr: .hz200, range: .g8)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0xA9, 0x02]))
    }

    @Test func setOdr_400Hz_defaultRange8G() {
        let s = MWAccelerometerBMI270(odr: .hz400, range: .g8)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0xAA, 0x02]))
    }

    @Test func setOdr_800Hz_defaultRange8G() {
        let s = MWAccelerometerBMI270(odr: .hz800, range: .g8)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0xAB, 0x02]))
    }

    @Test func setOdr_1600Hz_defaultRange8G() {
        let s = MWAccelerometerBMI270(odr: .hz1600, range: .g8)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0xAC, 0x02]))
    }

    // MARK: test_set_range — explicit 16G (default ODR = 100 Hz on the C++ side)

    @Test func setRange_16G_defaultOdr100() {
        let s = MWAccelerometerBMI270(odr: .hz100, range: .g16)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0xA8, 0x03]))
    }

    // MARK: test_set_odr_and_range

    @Test func setOdrAndRange_200Hz_8G() {
        let s = MWAccelerometerBMI270(odr: .hz200, range: .g8)
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0xA9, 0x02]))
    }

    // MARK: test_enable/disable_acceleration_sampling

    @Test func enableAccelerationSampling() {
        let s = MWAccelerometerBMI270(odr: .hz100, range: .g2)
        #expect(s.enableCommand == Data([0x03, 0x02, 0x01, 0x00]))
    }

    @Test func disableAccelerationSampling() {
        let s = MWAccelerometerBMI270(odr: .hz100, range: .g2)
        #expect(s.disableCommand == Data([0x03, 0x02, 0x00, 0x01]))
    }

    // MARK: test_subscribe/unsubscribe — data register 0x04

    @Test func dataSignal_register_is0x04() {
        #expect(MWAccelerometerBMI270(odr: .hz100, range: .g2).dataRegister == 0x04)
    }

    // MARK: test_subscribe/unsubscribe — packed data register 0x05

    @Test func packedDataSignal_register_is0x05() {
        #expect(MWAccelerometerBMI270(odr: .hz100, range: .g2).packedDataRegister == 0x05)
    }

    // MARK: TestBmi270AccelerationData.test_get_acceleration_data_g
    //
    // Python sets range=4G then notifies with:
    //   b'\x03\x04\x16\xc4\x94\xa2\x2a\xd0'
    // Expected CartesianFloat(x=-1.872, y=-2.919, z=-1.495)

    @Test func parseSample_4G_pythonVector() throws {
        let s = MWAccelerometerBMI270(odr: .hz100, range: .g4)
        let packet = Data([0x03, 0x04, 0x16, 0xC4, 0x94, 0xA2, 0x2A, 0xD0])
        let sample = try s.parseSample(from: packet)
        #expect(abs(sample.x - -1.872) < 0.001)
        #expect(abs(sample.y - -2.919) < 0.001)
        #expect(abs(sample.z - -1.495) < 0.001)
    }

    // MARK: TestBmi270HighFreqAccData.test_get_acceleration_data_g
    //
    // Python sets range=8G then notifies a 20-byte packed packet:
    //   b'\x03\x05\x62\xb7\x53\x0d\xe9\xfd\x16\xd0\x4d\x0e\x57\x02\x8a\xff\xa1\x05\x0a\x01'
    // Expected three samples:
    //   (-4.539, 0.833, -0.131), (-2.995, 0.894, 0.146), (-0.029, 0.352, 0.065)

    @Test func parsePackedSamples_8G_pythonVector() throws {
        let s = MWAccelerometerBMI270(odr: .hz100, range: .g8)
        let packet = Data([
            0x03, 0x05,
            0x62, 0xB7, 0x53, 0x0D, 0xE9, 0xFD,
            0x16, 0xD0, 0x4D, 0x0E, 0x57, 0x02,
            0x8A, 0xFF, 0xA1, 0x05, 0x0A, 0x01
        ])
        let samples = try s.parsePackedSamples(from: packet)
        #expect(samples.count == 3)
        #expect(abs(samples[0].x - -4.539) < 0.001)
        #expect(abs(samples[0].y -  0.833) < 0.001)
        #expect(abs(samples[0].z - -0.131) < 0.001)
        #expect(abs(samples[1].x - -2.995) < 0.001)
        #expect(abs(samples[1].y -  0.894) < 0.001)
        #expect(abs(samples[1].z -  0.146) < 0.001)
        #expect(abs(samples[2].x - -0.029) < 0.001)
        #expect(abs(samples[2].y -  0.352) < 0.001)
        #expect(abs(samples[2].z -  0.065) < 0.001)
    }

    // MARK: TestBmi270StepCounterSetup.test_set_mode
    //
    // Python sequence: set_step_counter_trigger(1) + enable_step_counter +
    // write_step_counter_config. The final wire byte-vector asserted is
    //   [3, 8, 7, 0, 14, 1, 0]  ⇒  [0x03, 0x08, 0x07, 0x00, 0x0E, 0x01, 0x00]

    @Test func stepCounter_writeConfig_trigger1() {
        let cfg = MWAccelerometerBMI270Steps.ConfigureStepCounter(trigger: 1)
        #expect(cfg.configCommand == Data([0x03, 0x08, 0x07, 0x00, 0x0E, 0x01, 0x00]))
    }

    @Test func stepCounter_interruptEnable() {
        // Python flow enables step-counter interrupt via FEATURE_INTERRUPT_ENABLE (0x07).
        let cfg = MWAccelerometerBMI270Steps.ConfigureStepCounter(trigger: 1)
        #expect(cfg.interruptEnableCommand == Data([0x03, 0x07, 0x02, 0x00]))
    }

    @Test func stepCounter_featureEnable() {
        let cfg = MWAccelerometerBMI270Steps.ConfigureStepCounter(trigger: 1)
        #expect(cfg.featureEnableCommand == Data([0x03, 0x06, 0x02, 0x00]))
    }

    // MARK: TestBmi270StepCounterData.test_get_step_count_value
    //
    // Python notifies b'\x03\x0b\x14\x00' → expected = 20.

    @Test func stepCounter_parse_20() throws {
        let packet = Data([0x03, 0x0B, 0x14, 0x00])
        let count = try MWAccelerometerBMI270Steps.parseStepCount(from: packet)
        #expect(count == 20)
    }

    // MARK: TestBmi270StepCounterRead.test_read_step_counter

    @Test func stepCounter_readCommand() {
        #expect(MWAccelerometerBMI270Steps.ReadStepCounter().commandData == Data([0x03, 0x8B]))
    }

    // MARK: TestBmi270StepDetectorData — subscribe/unsubscribe/enable/disable/get

    @Test func stepDetector_register_is0x0B() {
        #expect(MWAccelerometerBMI270Steps.stepRegister == 0x0B)
    }

    @Test func stepDetector_subscribeCommand() {
        // subscribe sends [0x03, 0x0B, 0x01]
        let cmd = MWPacket.command(.accelerometer, MWAccelerometerBMI270Steps.stepRegister, 0x01)
        #expect(cmd == Data([0x03, 0x0B, 0x01]))
    }

    @Test func stepDetector_enable() {
        // Python test_enable_detector: [0x03, 0x06, 0x80, 0x00]
        let cmd = MWAccelerometerBMI270Steps.EnableStepDetector()
        #expect(cmd.featureEnableCommand == Data([0x03, 0x06, 0x80, 0x00]))
    }

    @Test func stepDetector_enable_interruptEnable() {
        let cmd = MWAccelerometerBMI270Steps.EnableStepDetector()
        #expect(cmd.interruptEnableCommand == Data([0x03, 0x07, 0x80, 0x00]))
    }

    @Test func stepDetector_disable() {
        // Python test_disable_detector: [0x03, 0x06, 0x00, 0x80]
        let cmd = MWAccelerometerBMI270Steps.DisableStepDetector()
        #expect(cmd.featureDisableCommand == Data([0x03, 0x06, 0x00, 0x80]))
    }

    @Test func stepDetector_disable_interruptDisable() {
        let cmd = MWAccelerometerBMI270Steps.DisableStepDetector()
        #expect(cmd.interruptDisableCommand == Data([0x03, 0x07, 0x00, 0x80]))
    }

    @Test func stepDetector_parseDetection_zero() throws {
        // Python test_get_detection: b'\x03\x0b\x00' → 0
        let packet = Data([0x03, 0x0B, 0x00])
        let value = try MWAccelerometerBMI270Steps.parseStepDetection(from: packet)
        #expect(value == 0)
    }

    @Test func stepDetector_parseDetection_one() throws {
        let packet = Data([0x03, 0x0B, 0x01])
        #expect(try MWAccelerometerBMI270Steps.parseStepDetection(from: packet) == 1)
    }
}

// MARK: - BMI270 Activity / Wrist / No-motion / Downsampling

@Suite("BMI270 Feature Commands")
struct BMI270FeatureCommandTests {

    // MARK: Activity

    @Test func activity_enable() {
        let cmd = MWAccelerometerBMI270Features.EnableActivityDetection()
        #expect(cmd.interruptEnableCommand == Data([0x03, 0x07, 0x04, 0x00]))
        #expect(cmd.featureEnableCommand   == Data([0x03, 0x06, 0x04, 0x00]))
        #expect(cmd.commands.count == 2)
    }

    @Test func activity_disable() {
        let cmd = MWAccelerometerBMI270Features.DisableActivityDetection()
        #expect(cmd.interruptDisableCommand == Data([0x03, 0x07, 0x00, 0x04]))
        #expect(cmd.featureDisableCommand   == Data([0x03, 0x06, 0x00, 0x04]))
    }

    @Test func activity_register() {
        #expect(MWAccelerometerBMI270Features.activityRegister == 0x0C)
    }

    @Test func activity_parse_still() throws {
        // payload byte 0x00 → (0x00 >> 1) = 0 = still
        let packet = Data([0x03, 0x0C, 0x00])
        #expect(try MWAccelerometerBMI270Features.parseActivity(from: packet) == .still)
    }

    @Test func activity_parse_walking() throws {
        // payload byte 0x02 → (0x02 >> 1) = 1 = walking
        let packet = Data([0x03, 0x0C, 0x02])
        #expect(try MWAccelerometerBMI270Features.parseActivity(from: packet) == .walking)
    }

    @Test func activity_parse_running() throws {
        // payload byte 0x04 → (0x04 >> 1) = 2 = running
        let packet = Data([0x03, 0x0C, 0x04])
        #expect(try MWAccelerometerBMI270Features.parseActivity(from: packet) == .running)
    }

    @Test func activity_parse_unknown() throws {
        // payload byte 0x06 → (0x06 >> 1) = 3 = unknown
        let packet = Data([0x03, 0x0C, 0x06])
        #expect(try MWAccelerometerBMI270Features.parseActivity(from: packet) == .unknown)
    }

    @Test func activity_parse_tooShort_throws() {
        let packet = Data([0x03, 0x0C])
        #expect(throws: MWError.self) {
            try MWAccelerometerBMI270Features.parseActivity(from: packet)
        }
    }

    // MARK: Wrist events (shared parser)

    @Test func wrist_register() {
        #expect(MWAccelerometerBMI270Features.wristEventRegister == 0x0A)
    }

    @Test func wrist_parse_wakeup() throws {
        // byte b: type = b & 0x03, code = b >> 2
        // b = 0x00 → kind=wakeup, code=unknown
        let packet = Data([0x03, 0x0A, 0x00])
        let e = try MWAccelerometerBMI270Features.parseWristEvent(from: packet)
        #expect(e.kind == .wakeup)
        #expect(e.gestureCode == .unknown)
    }

    @Test func wrist_parse_gesture_pivotUp() throws {
        // type=1 (gesture), code=2 (pivotUp) → byte = (2 << 2) | 1 = 0x09
        let packet = Data([0x03, 0x0A, 0x09])
        let e = try MWAccelerometerBMI270Features.parseWristEvent(from: packet)
        #expect(e.kind == .gesture)
        #expect(e.gestureCode == .pivotUp)
    }

    @Test func wrist_parse_gesture_armFlickOut() throws {
        // type=1, code=5 → byte = (5 << 2) | 1 = 0x15
        let packet = Data([0x03, 0x0A, 0x15])
        let e = try MWAccelerometerBMI270Features.parseWristEvent(from: packet)
        #expect(e.kind == .gesture)
        #expect(e.gestureCode == .armFlickOut)
    }

    @Test func wrist_parse_tooShort_throws() {
        let packet = Data([0x03, 0x0A])
        #expect(throws: MWError.self) {
            try MWAccelerometerBMI270Features.parseWristEvent(from: packet)
        }
    }

    // MARK: Wrist gesture configure

    @Test func wristGesture_defaults_leftArm() {
        // arm=left → armByte=0x00; peak=0x0332, samples=0x0050, duration=0x0064
        let cfg = MWAccelerometerBMI270Features.ConfigureWristGesture()
        #expect(cfg.commandData == Data([
            0x03, 0x08, 0x08,
            0x00, 0x00,
            0x32, 0x03,  // peak LE
            0x50, 0x00,  // samples LE
            0x64, 0x00,  // duration LE
        ]))
    }

    @Test func wristGesture_rightArm_customValues() {
        let cfg = MWAccelerometerBMI270Features.ConfigureWristGesture(
            arm: .right, peak: 0x1234, samples: 0x00AB, duration: 0x0200
        )
        #expect(cfg.commandData == Data([
            0x03, 0x08, 0x08,
            0x10, 0x00,
            0x34, 0x12,
            0xAB, 0x00,
            0x00, 0x02,
        ]))
    }

    @Test func wristGesture_enable() {
        let cmd = MWAccelerometerBMI270Features.EnableWristGesture()
        #expect(cmd.interruptEnableCommand == Data([0x03, 0x07, 0x10, 0x00]))
        #expect(cmd.featureEnableCommand   == Data([0x03, 0x06, 0x10, 0x00]))
    }

    @Test func wristGesture_disable() {
        let cmd = MWAccelerometerBMI270Features.DisableWristGesture()
        #expect(cmd.interruptDisableCommand == Data([0x03, 0x07, 0x00, 0x10]))
        #expect(cmd.featureDisableCommand   == Data([0x03, 0x06, 0x00, 0x10]))
    }

    // MARK: Wrist wakeup configure

    @Test func wristWakeup_defaults_matchCppDefaults() {
        // C++ initializer bytes: A8 05 EE 06 00 04 BC 02 B3 00 85 07
        let cfg = MWAccelerometerBMI270Features.ConfigureWristWakeup()
        #expect(cfg.commandData == Data([
            0x03, 0x08, 0x09,
            0xA8, 0x05,
            0xEE, 0x06,
            0x00, 0x04,
            0xBC, 0x02,
            0xB3, 0x00,
            0x85, 0x07,
        ]))
    }

    @Test func wristWakeup_custom() {
        let cfg = MWAccelerometerBMI270Features.ConfigureWristWakeup(
            minAngleFocus:    0x0001,
            minAngleNonFocus: 0x0002,
            maxTiltLR:        0x0003,
            maxTiltLL:        0x0004,
            maxTiltPD:        0x0005,
            maxTiltPU:        0x0006
        )
        #expect(cfg.commandData == Data([
            0x03, 0x08, 0x09,
            0x01, 0x00,
            0x02, 0x00,
            0x03, 0x00,
            0x04, 0x00,
            0x05, 0x00,
            0x06, 0x00,
        ]))
    }

    @Test func wristWakeup_enable() {
        let cmd = MWAccelerometerBMI270Features.EnableWristWakeup()
        #expect(cmd.interruptEnableCommand == Data([0x03, 0x07, 0x08, 0x00]))
        #expect(cmd.featureEnableCommand   == Data([0x03, 0x06, 0x08, 0x00]))
    }

    @Test func wristWakeup_disable() {
        let cmd = MWAccelerometerBMI270Features.DisableWristWakeup()
        #expect(cmd.interruptDisableCommand == Data([0x03, 0x07, 0x00, 0x08]))
        #expect(cmd.featureDisableCommand   == Data([0x03, 0x06, 0x00, 0x08]))
    }

    // MARK: No-motion

    @Test func noMotion_configure_defaults() throws {
        // duration=5 → d0=0x05, d1 (hi=0) | xyz select bits = 0xE0
        // threshold=0xAA → t0=0xAA, t1=0x00
        let cfg = try MWAccelerometerBMI270Features.ConfigureNoMotion()
        #expect(cfg.commandData == Data([0x03, 0x08, 0x02, 0x05, 0xE0, 0xAA, 0x00]))
    }

    @Test func noMotion_configure_largeDuration_andThreshold() throws {
        // duration=0x0123 → d0=0x23, d1 hi=0x01 | 0xE0 = 0xE1
        // threshold=0x0456 → t0=0x56, t1=0x04
        let cfg = try MWAccelerometerBMI270Features.ConfigureNoMotion(
            duration: 0x0123, threshold: 0x0456
        )
        #expect(cfg.commandData == Data([0x03, 0x08, 0x02, 0x23, 0xE1, 0x56, 0x04]))
    }

    @Test func noMotion_configure_noAxisSelect() throws {
        // all axes off → d1 hi bits zero
        let cfg = try MWAccelerometerBMI270Features.ConfigureNoMotion(
            duration: 5, threshold: 0xAA,
            selectX: false, selectY: false, selectZ: false
        )
        #expect(cfg.commandData == Data([0x03, 0x08, 0x02, 0x05, 0x00, 0xAA, 0x00]))
    }

    @Test func noMotion_enable() {
        let cmd = MWAccelerometerBMI270Features.EnableNoMotion()
        #expect(cmd.interruptEnableCommand == Data([0x03, 0x07, 0x20, 0x00]))
        #expect(cmd.featureEnableCommand   == Data([0x03, 0x06, 0x20, 0x00]))
    }

    @Test func noMotion_disable() {
        let cmd = MWAccelerometerBMI270Features.DisableNoMotion()
        #expect(cmd.interruptDisableCommand == Data([0x03, 0x07, 0x00, 0x20]))
        #expect(cmd.featureDisableCommand   == Data([0x03, 0x06, 0x00, 0x20]))
    }

    // MARK: Significant motion

    @Test func sigMotion_configure_defaultBlocksize() {
        // blocksize default = 250 (0x00FA) → lo=0xFA hi=0x00
        // FEATURE_CONFIG index for sig_motion = 3
        let cfg = MWAccelerometerBMI270Features.ConfigureSignificantMotion()
        #expect(cfg.commandData == Data([0x03, 0x08, 0x03, 0xFA, 0x00]))
    }

    @Test func sigMotion_configure_largeBlocksize() {
        // 0x1234 → lo=0x34 hi=0x12
        let cfg = MWAccelerometerBMI270Features
            .ConfigureSignificantMotion(blocksize: 0x1234)
        #expect(cfg.commandData == Data([0x03, 0x08, 0x03, 0x34, 0x12]))
    }

    @Test func sigMotion_enable() {
        // FEATURE_ENABLE / FEATURE_INTERRUPT_ENABLE bit 0x01.
        let cmd = MWAccelerometerBMI270Features.EnableSignificantMotion()
        #expect(cmd.interruptEnableCommand == Data([0x03, 0x07, 0x01, 0x00]))
        #expect(cmd.featureEnableCommand   == Data([0x03, 0x06, 0x01, 0x00]))
    }

    @Test func sigMotion_disable() {
        let cmd = MWAccelerometerBMI270Features.DisableSignificantMotion()
        #expect(cmd.interruptDisableCommand == Data([0x03, 0x07, 0x00, 0x01]))
        #expect(cmd.featureDisableCommand   == Data([0x03, 0x06, 0x00, 0x01]))
    }

    // MARK: Downsampling

    @Test func downsampling_allZeros() throws {
        let cmd = try MWAccelerometerBMI270Features.SetDownsampling()
        #expect(cmd.commandData == Data([0x03, 0x11, 0x00]))
    }

    @Test func downsampling_gyroOrdinalOnly() throws {
        let cmd = try MWAccelerometerBMI270Features.SetDownsampling(gyroOrdinal: 3)
        // bits 0-2 = 0b011
        #expect(cmd.commandData == Data([0x03, 0x11, 0x03]))
    }

    @Test func downsampling_accOrdinalOnly() throws {
        let cmd = try MWAccelerometerBMI270Features.SetDownsampling(accOrdinal: 5)
        // bits 4-6 = 0b101 → 0x50
        #expect(cmd.commandData == Data([0x03, 0x11, 0x50]))
    }

    @Test func downsampling_allFieldsSet() throws {
        // gyroOrdinal=7 → bits 0-2 = 0x07
        // gyroFilter   → bit 3 = 0x08
        // accOrdinal=7 → bits 4-6 = 0x70
        // accFilter    → bit 7 = 0x80
        let cmd = try MWAccelerometerBMI270Features.SetDownsampling(
            gyroOrdinal: 7, gyroFilterData: true,
            accOrdinal: 7,  accFilterData: true
        )
        #expect(cmd.commandData == Data([0x03, 0x11, 0xFF]))
    }

    @Test func downsampling_onlyFilters() throws {
        let cmd = try MWAccelerometerBMI270Features.SetDownsampling(
            gyroFilterData: true, accFilterData: true
        )
        #expect(cmd.commandData == Data([0x03, 0x11, 0x88]))
    }
}

// MARK: - Gyroscope commands

@Suite("Gyroscope Commands")
struct GyroCommandTests {

    let sensor = MWGyroscopeBMI160(odr: .hz100, range: .dps2000)

    @Test func startCommand() {
        #expect(sensor.startCommand   == Data([0x13, 0x01, 0x01]))
    }

    @Test func stopCommand() {
        #expect(sensor.stopCommand    == Data([0x13, 0x01, 0x00]))
    }

    @Test func enableCommand() {
        #expect(sensor.enableCommand  == Data([0x13, 0x02, 0x01, 0x00]))
    }

    @Test func disableCommand() {
        #expect(sensor.disableCommand == Data([0x13, 0x02, 0x00, 0x01]))
    }

    @Test func configCommand_odr100_2000dps() {
        // ODR 100Hz = rawValue 8, bwp = 2 → (2 << 4) | 8 = 0x28
        // range 2000dps = rawValue 0
        let cmd = sensor.configureCommands[0]
        #expect(cmd == Data([0x13, 0x03, 0x28, 0x00]))
    }

    @Test func configCommand_odr200_500dps() {
        let s = MWGyroscopeBMI160(odr: .hz200, range: .dps500)
        // ODR 200Hz = rawValue 9 → 0x29, range 500dps = rawValue 2
        #expect(s.configureCommands[0] == Data([0x13, 0x03, 0x29, 0x02]))
    }

    @Test func bmi160_dataRegister() {
        #expect(sensor.dataRegister == 0x05)
    }

    @Test func bmi270_dataRegister_differs() {
        let bmi270 = MWGyroscopeBMI270(odr: .hz100, range: .dps2000)
        #expect(bmi270.dataRegister == 0x04)
    }

    // --- Reference vectors from MetaWear-SDK-Cpp/test/test_gyro_bmi160.py ---

    @Test func configCommand_odr200_default_range_matches_python() {
        // test_set_odr: set ODR = 200Hz with default range dps2000
        // Expected byte stream from Python: [0x13, 0x03, 0x29, 0x00]
        let s = MWGyroscopeBMI160(odr: .hz200, range: .dps2000)
        #expect(s.configureCommands[0] == Data([0x13, 0x03, 0x29, 0x00]))
    }

    @Test func configCommand_default_odr_250dps_matches_python() {
        // test_set_fsr: default ODR = 100Hz, range = 250dps
        // Expected: [0x13, 0x03, 0x28, 0x03]
        let s = MWGyroscopeBMI160(odr: .hz100, range: .dps250)
        #expect(s.configureCommands[0] == Data([0x13, 0x03, 0x28, 0x03]))
    }

    @Test func configCommand_odr50_125dps_matches_python() {
        // test_set_all_config: ODR=50Hz, range=125dps
        // Expected: [0x13, 0x03, 0x27, 0x04]
        let s = MWGyroscopeBMI160(odr: .hz50, range: .dps125)
        #expect(s.configureCommands[0] == Data([0x13, 0x03, 0x27, 0x04]))
    }

    @Test func bmi270_offsets_command() {
        // Writes to OFFSET register 0x06 with [x, y, z]
        let cmd = MWGyroscopeBMI270.Offsets(x: 0x11, y: 0x22, z: 0x33)
        #expect(cmd.commandData == Data([0x13, 0x06, 0x11, 0x22, 0x33]))
    }

    @Test func bmi160_packedDataRegister() {
        #expect(sensor.packedDataRegister == 0x07)
    }

    @Test func bmi270_packedDataRegister_differs() {
        let bmi270 = MWGyroscopeBMI270(odr: .hz100, range: .dps2000)
        #expect(bmi270.packedDataRegister == 0x05)
    }
}

// MARK: - Gyroscope data handler

@Suite("Gyroscope BMI160 Data Handler")
struct GyroBMI160DataHandlerTests {

    // Reference vector: test_data_handler_bmi160.py at 500dps → (262.409, 499.497, -499.512)
    // Raw packet: [0x13, 0x05, 0x3e, 0x43, 0xff, 0x7f, 0x00, 0x80]
    @Test func parseSample_500dps_matchesPythonReference() throws {
        let s = MWGyroscopeBMI160(odr: .hz100, range: .dps500)
        let packet = Data([0x13, 0x05, 0x3e, 0x43, 0xff, 0x7f, 0x00, 0x80])
        let sample = try s.parseSample(from: packet)
        // scale = 65.6  →  x = 0x433e(17214)/65.6, y = 0x7fff(32767)/65.6, z = 0x8000(-32768)/65.6
        #expect(abs(sample.x -  262.409) < 0.01)
        #expect(abs(sample.y -  499.497) < 0.01)
        #expect(abs(sample.z - -499.512) < 0.01)
    }

    @Test func parsePackedSamples_1000dps_threeSamples() throws {
        // Packed layout: [module, register, (x,y,z) × 3] — 20 bytes total.
        // Construct a known packet; check all three samples decode correctly.
        let s = MWGyroscopeBMI160(odr: .hz100, range: .dps1000)
        var bytes: [UInt8] = [0x13, 0x07]
        // sample 0: (0x0100, 0x0200, 0x0300)
        bytes += [0x00, 0x01, 0x00, 0x02, 0x00, 0x03]
        // sample 1: (0x0400, 0x0500, 0x0600)
        bytes += [0x00, 0x04, 0x00, 0x05, 0x00, 0x06]
        // sample 2: (-0x0001, -0x0001, -0x0001) = (-1, -1, -1)
        bytes += [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        let samples = try s.parsePackedSamples(from: Data(bytes))
        #expect(samples.count == 3)
        // scale = 32.8
        #expect(abs(samples[0].x - Float(0x0100) / 32.8) < 0.01)
        #expect(abs(samples[1].y - Float(0x0500) / 32.8) < 0.01)
        #expect(abs(samples[2].z - Float(-1)     / 32.8) < 0.01)
    }

    @Test func subscribeRegister_unpacked_is0x05() {
        // Unpacked stream register for BMI160 = 0x05
        let s = MWGyroscopeBMI160()
        #expect(s.dataRegister == 0x05)
    }

    @Test func subscribeRegister_packed_is0x07() {
        // Packed high-freq stream register for BMI160 = 0x07
        let s = MWGyroscopeBMI160()
        #expect(s.packedDataRegister == 0x07)
    }

    // Reference vector: test_gyro_bmi160.py::TestGyroBmi160HighFreqDataHandler::test_rotation_data_handler
    // 1000dps range, packet = b'\x13\x07\x09\x15\xad\x26\x08\xde\x8a\x1a\x0d\x26\x65\xe4\x8d\x20\xac\x27\x73\xec'
    // Expected three samples:
    //   (164.177, 301.860, -265.122)
    //   (207.134, 296.982, -215.457)
    //   (254.055, 309.634, -152.591)
    @Test func parsePackedSamples_1000dps_pythonReference() throws {
        let s = MWGyroscopeBMI160(odr: .hz100, range: .dps1000)
        let packet = Data([
            0x13, 0x07,
            0x09, 0x15, 0xAD, 0x26, 0x08, 0xDE,  // sample 0
            0x8A, 0x1A, 0x0D, 0x26, 0x65, 0xE4,  // sample 1
            0x8D, 0x20, 0xAC, 0x27, 0x73, 0xEC   // sample 2
        ])
        let samples = try s.parsePackedSamples(from: packet)
        #expect(samples.count == 3)
        #expect(abs(samples[0].x -  164.177) < 0.01)
        #expect(abs(samples[0].y -  301.860) < 0.01)
        #expect(abs(samples[0].z - -265.122) < 0.01)
        #expect(abs(samples[1].x -  207.134) < 0.01)
        #expect(abs(samples[1].y -  296.982) < 0.01)
        #expect(abs(samples[1].z - -215.457) < 0.01)
        #expect(abs(samples[2].x -  254.055) < 0.01)
        #expect(abs(samples[2].y -  309.634) < 0.01)
        #expect(abs(samples[2].z - -152.591) < 0.01)
    }
}

// MARK: - Type-erased gyroscope

@Suite("Gyroscope Type-Erased")
struct GyroTypeErasedTests {

    @Test func make_bmi160_impl0_producesBMI160() {
        let g = MWGyroscope.make(impl: 0, odrHz: 100, rangeDPS: 2000)
        #expect(g != nil)
        if case .bmi160 = g { /* ok */ } else { Issue.record("expected .bmi160 for impl=0") }
    }

    @Test func make_bmi270_impl1_producesBMI270() {
        let g = MWGyroscope.make(impl: 1, odrHz: 100, rangeDPS: 2000)
        #expect(g != nil)
        if case .bmi270 = g { /* ok */ } else { Issue.record("expected .bmi270 for impl=1") }
    }

    @Test func make_unknownImpl_returnsNil() {
        #expect(MWGyroscope.make(impl: 99) == nil)
    }

    @Test func odrSnapping_snapsToNearest() {
        // 123 Hz → nearest supported is 100 Hz
        let g = MWGyroscope.make(impl: 0, odrHz: 123, rangeDPS: 2000)!
        #expect(g.odrHz == 100)
    }

    @Test func rangeSnapping_snapsToNearest() {
        // 600 dps → nearest supported is 500 dps
        let g = MWGyroscope.make(impl: 0, odrHz: 100, rangeDPS: 600)!
        #expect(g.rangeDPS == 500)
    }

    @Test func withODR_returnsUpdated() {
        let g = MWGyroscope.make(impl: 0, odrHz: 100, rangeDPS: 2000)!
        #expect(g.withODR(400).odrHz == 400)
    }

    @Test func withRange_returnsUpdated() {
        let g = MWGyroscope.make(impl: 1, odrHz: 100, rangeDPS: 2000)!
        #expect(g.withRange(250).rangeDPS == 250)
    }

    @Test func loggerKey_isAngularVelocity() {
        let g = MWGyroscope.make(impl: 0)!
        #expect(g.loggerKey == "angular-velocity")
    }

    @Test func forwarding_startCommand_usesGyroModule() {
        let g = MWGyroscope.make(impl: 0)!
        #expect(g.startCommand == Data([0x13, 0x01, 0x01]))
    }
}

// MARK: - Magnetometer commands

@Suite("Magnetometer Commands")
struct MagCommandTests {

    let sensor = MWMagnetometer(preset: .lowPower)

    @Test func startCommand() {
        #expect(sensor.startCommand == Data([0x15, 0x01, 0x01]))
    }

    @Test func stopCommand() {
        #expect(sensor.stopCommand == Data([0x15, 0x01, 0x00]))
    }

    @Test func lowPowerPreset_configBytes() {
        // LOW_POWER: xy=3, z=3, odr=0
        // xyByte = (3-1)/2 = 1, zByte = 3-1 = 2
        let cmds = sensor.configureCommands
        #expect(cmds.count == 2)
        #expect(cmds[0] == Data([0x15, 0x04, 0x01, 0x02]))
        #expect(cmds[1] == Data([0x15, 0x03, 0x00]))
    }

    @Test func highAccuracyPreset_configBytes() {
        let s = MWMagnetometer(preset: .highAccuracy)
        // HIGH_ACCURACY: xy=47, z=83, odr=5(20Hz)
        // xyByte = (47-1)/2 = 23 = 0x17, zByte = 83-1 = 82 = 0x52
        let cmds = s.configureCommands
        #expect(cmds[0] == Data([0x15, 0x04, 0x17, 0x52]))
        #expect(cmds[1] == Data([0x15, 0x03, 0x05]))
    }

    @Test func enableBFieldSampling() {
        // test_enable_b_field_sampling: [0x15, 0x02, 0x01, 0x00]
        #expect(sensor.enableCommand  == Data([0x15, 0x02, 0x01, 0x00]))
    }

    @Test func disableBFieldSampling() {
        // test_disable_b_field_sampling: [0x15, 0x02, 0x00, 0x01]
        #expect(sensor.disableCommand == Data([0x15, 0x02, 0x00, 0x01]))
    }

    // --- Reference vectors from test_magnetometer_bmm150.py test_preset ---

    @Test func regularPreset_configBytes_matchesPython() {
        // REGULAR: xy=9, z=15, odr=10Hz → [0x15, 0x04, 0x04, 0x0e], [0x15, 0x03, 0x00]
        let s = MWMagnetometer(preset: .regular)
        let cmds = s.configureCommands
        #expect(cmds[0] == Data([0x15, 0x04, 0x04, 0x0e]))
        #expect(cmds[1] == Data([0x15, 0x03, 0x00]))
    }

    @Test func enhancedRegularPreset_configBytes_matchesPython() {
        // ENHANCED_REGULAR: xy=15, z=27, odr=10Hz → [0x15, 0x04, 0x07, 0x1a], [0x15, 0x03, 0x00]
        let s = MWMagnetometer(preset: .enhancedRegular)
        let cmds = s.configureCommands
        #expect(cmds[0] == Data([0x15, 0x04, 0x07, 0x1a]))
        #expect(cmds[1] == Data([0x15, 0x03, 0x00]))
    }

    // --- Manual configuration ---

    @Test func manualConfigure_customRepsAndODR() {
        // Manual init with custom reps & ODR bypasses preset mapping.
        let s = MWMagnetometer(xyReps: 9, zReps: 15, odr: .hz30)
        #expect(s.preset == nil)
        let cmds = s.configureCommands
        #expect(cmds[0] == Data([0x15, 0x04, 0x04, 0x0e]))
        #expect(cmds[1] == Data([0x15, 0x03, 0x07]))  // 30Hz = 7
    }

    @Test func manualConfigureCommand_bytes() {
        // MWMagnetometer.Configure is a standalone command; mirrors mbl_mw_mag_bmm150_configure.
        let cmd = MWMagnetometer.Configure(xyReps: 3, zReps: 3, odr: .hz10)
        #expect(cmd.commandData == Data([0x15, 0x04, 0x01, 0x02,
                                         0x15, 0x03, 0x00]))
    }

    // --- Suspend ---

    @Test func suspendCommand_rev2_matchesPython() {
        // test_suspend on revision >= 2: [0x15, 0x01, 0x02]
        let cmd = MWMagnetometer.Suspend()
        #expect(cmd.commandData == Data([0x15, 0x01, 0x02]))
    }

    // --- ODR enum raw values match C++ MblMwMagBmm150Odr ---

    @Test func odrRawValues_matchCpp() {
        #expect(MWMagnetometer.ODR.hz10.rawValue == 0)
        #expect(MWMagnetometer.ODR.hz2.rawValue  == 1)
        #expect(MWMagnetometer.ODR.hz6.rawValue  == 2)
        #expect(MWMagnetometer.ODR.hz8.rawValue  == 3)
        #expect(MWMagnetometer.ODR.hz15.rawValue == 4)
        #expect(MWMagnetometer.ODR.hz20.rawValue == 5)
        #expect(MWMagnetometer.ODR.hz25.rawValue == 6)
        #expect(MWMagnetometer.ODR.hz30.rawValue == 7)
    }

    // --- Data register / packed register ---

    @Test func dataRegisters() {
        #expect(sensor.dataRegister       == 0x05)
        #expect(sensor.packedDataRegister == 0x09)
    }
}

// MARK: - Magnetometer data handler

@Suite("Magnetometer Data Handler")
struct MagDataHandlerTests {

    // Reference from test_b_field_data: parse b'\x15\x05\x4e\xf0\x53\x0a\x75\x04'
    // → (-251.125, 165.1875, 71.3125) µT at 16 LSB/µT
    @Test func parseSample_matchesPythonReference() throws {
        let s = MWMagnetometer()
        let packet = Data([0x15, 0x05, 0x4e, 0xf0, 0x53, 0x0a, 0x75, 0x04])
        let sample = try s.parseSample(from: packet)
        #expect(abs(sample.x - -251.1250) < 0.001)
        #expect(abs(sample.y -  165.1875) < 0.001)
        #expect(abs(sample.z -   71.3125) < 0.001)
    }

    // Reference from test_packed_bfield_data: 20-byte packet → 3 samples
    @Test func parsePackedSamples_matchesPythonReference() throws {
        let s = MWMagnetometer()
        let packet = Data([
            0x15, 0x09,
            0xb6, 0x0c, 0x72, 0xf7, 0x89, 0xee,   // sample 0
            0xb6, 0x0b, 0x5a, 0xf8, 0x32, 0xee,   // sample 1
            0xe6, 0x0a, 0xa2, 0xf7, 0x25, 0xef    // sample 2
        ])
        let samples = try s.parsePackedSamples(from: packet)
        #expect(samples.count == 3)
        // sample 0: (203.375, -136.875, -279.4375)
        #expect(abs(samples[0].x -  203.375) < 0.01)
        #expect(abs(samples[0].y - -136.875) < 0.01)
        #expect(abs(samples[0].z - -279.437) < 0.01)
        // sample 1: (187.375, -122.375, -284.875)
        #expect(abs(samples[1].x -  187.375) < 0.01)
        #expect(abs(samples[1].y - -122.375) < 0.01)
        #expect(abs(samples[1].z - -284.874) < 0.01)
        // sample 2: (174.375, -133.875, -269.6875)
        #expect(abs(samples[2].x -  174.375) < 0.01)
        #expect(abs(samples[2].y - -133.875) < 0.01)
        #expect(abs(samples[2].z - -269.687) < 0.01)
    }
}

// MARK: - Sensor fusion commands

@Suite("Sensor Fusion Commands")
struct SensorFusionCommandTests {

    @Test func quaternion_enableBit() {
        let s = MWSensorFusionQuaternion()
        // bit 3 = 0x08
        #expect(s.enableCommand == Data([0x19, 0x03, 0x08, 0x00]))
    }

    @Test func euler_enableBit() {
        let s = MWSensorFusionEuler()
        // bit 4 = 0x10
        #expect(s.enableCommand == Data([0x19, 0x03, 0x10, 0x00]))
    }

    @Test func gravity_enableBit() {
        let s = MWSensorFusionGravity()
        // bit 5 = 0x20
        #expect(s.enableCommand == Data([0x19, 0x03, 0x20, 0x00]))
    }

    @Test func linearAcc_enableBit() {
        let s = MWSensorFusionLinearAcceleration()
        // bit 6 = 0x40
        #expect(s.enableCommand == Data([0x19, 0x03, 0x40, 0x00]))
    }

    @Test func ndof_configCommand() {
        let s = MWSensorFusionQuaternion(mode: .ndof, accRange: 0, gyroRange: 0)
        // mode = 1 (NDOF), rangeByte = 0 | (1 << 4) = 0x10
        #expect(s.configureCommands[0] == Data([0x19, 0x02, 0x01, 0x10]))
    }

    @Test func start_stop() {
        let s = MWSensorFusionQuaternion()
        #expect(s.startCommand == Data([0x19, 0x01, 0x01]))
        #expect(s.stopCommand  == Data([0x19, 0x01, 0x00]))
    }

    // --- Corrected data signals (bits 0/1/2, registers 0x04/0x05/0x06) ---

    @Test func correctedAcc_registersAndBit() {
        let s = MWSensorFusionCorrectedAcc()
        #expect(s.dataRegister == 0x04)
        // bit 0 = 0x01
        #expect(s.enableCommand  == Data([0x19, 0x03, 0x01, 0x00]))
        #expect(s.disableCommand == Data([0x19, 0x03, 0x00, 0x01]))
    }

    @Test func correctedGyro_registersAndBit() {
        let s = MWSensorFusionCorrectedGyro()
        #expect(s.dataRegister == 0x05)
        // bit 1 = 0x02
        #expect(s.enableCommand  == Data([0x19, 0x03, 0x02, 0x00]))
        #expect(s.disableCommand == Data([0x19, 0x03, 0x00, 0x02]))
    }

    @Test func correctedMag_registersAndBit() {
        let s = MWSensorFusionCorrectedMag()
        #expect(s.dataRegister == 0x06)
        // bit 2 = 0x04
        #expect(s.enableCommand  == Data([0x19, 0x03, 0x04, 0x00]))
        #expect(s.disableCommand == Data([0x19, 0x03, 0x00, 0x04]))
    }

    // --- Mode/range matrix: reference config bytes from test_sensor_fusion_config.py ---
    //   config_byte = (gyroRange + 1) << 4 | accRange
    //   gr=0 (2000dps): [0x10, 0x11, 0x12, 0x13]
    //   gr=1 (1000dps): [0x20, 0x21, 0x22, 0x23]
    //   gr=2 (500dps):  [0x30, 0x31, 0x32, 0x33]
    //   gr=3 (250dps):  [0x40, 0x41, 0x42, 0x43]

    @Test func ndof_acc2g_gyro2000_config() {
        // NDOF (mode=1), acc=2g (0), gyro=2000dps (0) → [0x19, 0x02, 0x01, 0x10]
        let s = MWSensorFusionQuaternion(mode: .ndof, accRange: .g2, gyroRange: .dps2000)
        #expect(s.configureCommands[0] == Data([0x19, 0x02, 0x01, 0x10]))
    }

    @Test func imuPlus_acc16g_gyro250_config() {
        // IMU_PLUS (mode=2), acc=16g (3), gyro=250dps (3) → config_byte = (3+1)<<4 | 3 = 0x43
        let s = MWSensorFusionEuler(mode: .imuPlus, accRange: .g16, gyroRange: .dps250)
        #expect(s.configureCommands[0] == Data([0x19, 0x02, 0x02, 0x43]))
    }

    @Test func compass_acc8g_gyro500_config() {
        // COMPASS (mode=3), acc=8g (2), gyro=500dps (2) → (2+1)<<4 | 2 = 0x32
        let s = MWSensorFusionGravity(mode: .compass, accRange: .g8, gyroRange: .dps500)
        #expect(s.configureCommands[0] == Data([0x19, 0x02, 0x03, 0x32]))
    }

    @Test func m4g_acc4g_gyro1000_config() {
        // M4G (mode=4), acc=4g (1), gyro=1000dps (1) → (1+1)<<4 | 1 = 0x21
        let s = MWSensorFusionLinearAcceleration(mode: .m4g, accRange: .g4, gyroRange: .dps1000)
        #expect(s.configureCommands[0] == Data([0x19, 0x02, 0x04, 0x21]))
    }

    @Test func configMatrix_exhaustive_matchesPython() {
        // Exhaust the 4×4 config_masks matrix from test_sensor_fusion_config.py.
        let accCases:  [MWSensorFusionAccRange]  = [.g2, .g4, .g8, .g16]
        let gyroCases: [MWSensorFusionGyroRange] = [.dps2000, .dps1000, .dps500, .dps250]
        let expectedMatrix: [[UInt8]] = [
            [0x10, 0x11, 0x12, 0x13],   // gyro index 0
            [0x20, 0x21, 0x22, 0x23],   // gyro index 1
            [0x30, 0x31, 0x32, 0x33],   // gyro index 2
            [0x40, 0x41, 0x42, 0x43]    // gyro index 3
        ]
        for (gi, gr) in gyroCases.enumerated() {
            for (ai, ar) in accCases.enumerated() {
                let s = MWSensorFusionQuaternion(mode: .ndof, accRange: ar, gyroRange: gr)
                let cmd = s.configureCommands[0]
                #expect(cmd == Data([0x19, 0x02, 0x01, expectedMatrix[gi][ai]]),
                        "config byte mismatch at gyro=\(gr), acc=\(ar)")
            }
        }
    }

    // --- Standalone fire-and-forget commands ---

    @Test func clearEnabledMask_command() {
        // Mirrors mbl_mw_sensor_fusion_clear_enabled_mask → [0x19, 0x03, 0x00, 0x7F]
        let cmd = MWSensorFusionClearEnabledMask()
        #expect(cmd.commandData == Data([0x19, 0x03, 0x00, 0x7F]))
    }

    @Test func resetOrientation_command_matchesRev3Python() {
        // test_sensor_fusion.py::TestSensorFusionRev3 → [0x19, 0x0f, 0x01]
        let cmd = MWSensorFusionResetOrientation()
        #expect(cmd.commandData == Data([0x19, 0x0F, 0x01]))
    }

    @Test func writeAccCalibration_command_matchesRev2Python() throws {
        // test_sensor_fusion.py::TestSensorFusionRev2::test_write_calibration_data (NDOF)
        let bytes: [UInt8] = [0xf6, 0xff, 0x00, 0x00, 0x0a, 0x00, 0xe8, 0x03, 0x03, 0x00]
        let cmd = try MWSensorFusionWriteAccCalibration(bytes)
        #expect(cmd.commandData == Data([0x19, 0x0C] + bytes))
    }

    @Test func writeGyroCalibration_command_matchesRev2Python() throws {
        let bytes: [UInt8] = [0x04, 0x00, 0x08, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x00]
        let cmd = try MWSensorFusionWriteGyroCalibration(bytes)
        #expect(cmd.commandData == Data([0x19, 0x0D] + bytes))
    }

    @Test func writeMagCalibration_command_matchesRev2Python() throws {
        let bytes: [UInt8] = [0x66, 0x00, 0x17, 0xfd, 0x8a, 0xfc, 0x7f, 0x03, 0x01, 0x00]
        let cmd = try MWSensorFusionWriteMagCalibration(bytes)
        #expect(cmd.commandData == Data([0x19, 0x0E] + bytes))
    }

    // --- Calibration state read signal ---

    @Test func calibrationState_readCommand_matchesRev1Python() {
        // test_sensor_fusion.py::TestSensorFusionRev1::test_read_calibration → [0x19, 0x8b]
        let sig = MWSensorFusionCalibrationState()
        #expect(sig.readCommand == Data([0x19, 0x8B]))
    }

    @Test func calibrationState_parseResponse_matchesRev1Python() throws {
        // Response: [0x19, 0x8b, 0x00, 0x01, 0x02]
        //   acc=UNRELIABLE(0), gyro=LOW(1), mag=MEDIUM(2)
        let sig = MWSensorFusionCalibrationState()
        let state = try sig.parseSample(from: Data([0x19, 0x8B, 0x00, 0x01, 0x02]))
        #expect(state.accelerometer == 0)
        #expect(state.gyroscope     == 1)
        #expect(state.magnetometer  == 2)
    }

    // --- Typed-range raw values match C++ ---

    @Test func accRange_rawValues_matchCpp() {
        #expect(MWSensorFusionAccRange.g2.rawValue  == 0)
        #expect(MWSensorFusionAccRange.g4.rawValue  == 1)
        #expect(MWSensorFusionAccRange.g8.rawValue  == 2)
        #expect(MWSensorFusionAccRange.g16.rawValue == 3)
    }

    @Test func gyroRange_rawValues_matchCpp() {
        #expect(MWSensorFusionGyroRange.dps2000.rawValue == 0)
        #expect(MWSensorFusionGyroRange.dps1000.rawValue == 1)
        #expect(MWSensorFusionGyroRange.dps500.rawValue  == 2)
        #expect(MWSensorFusionGyroRange.dps250.rawValue  == 3)
    }
}

// MARK: - Sensor fusion data handler

@Suite("Sensor Fusion Data Handler")
struct SensorFusionDataHandlerTests {

    // All reference vectors from test_sensor_fusion.py::test_received_data.

    @Test func correctedAcc_parse() throws {
        // Expected: (-3.3799, 15.9995, -15.9995, accuracy=0)
        // Raw float values in bytes: x=-3379.86, y=15999.5, z=-15999.5 → scaled ÷1000
        let s = MWSensorFusionCorrectedAcc()
        let packet = Data([0x19, 0x04,
                           0x20, 0x3e, 0x53, 0xc5,   // x
                           0x0c, 0xfe, 0x79, 0x46,   // y
                           0x0c, 0xfe, 0x79, 0xc6,   // z
                           0x00])                    // accuracy
        let out = try s.parseSample(from: packet)
        #expect(abs(out.x - -3.3799) < 0.01)
        #expect(abs(out.y -  15.9995) < 0.01)
        #expect(abs(out.z - -15.9995) < 0.01)
        #expect(out.accuracy == 0)
    }

    @Test func correctedGyro_parse() throws {
        // Expected: (72.669, -56.096, 528.820, accuracy=0) — no scaling
        let s = MWSensorFusionCorrectedGyro()
        let packet = Data([0x19, 0x05,
                           0x7a, 0x56, 0x91, 0x42,   // x = 72.669
                           0xb4, 0x62, 0x60, 0xc2,   // y = -56.096
                           0x73, 0x34, 0x04, 0x44,   // z = 528.820
                           0x00])
        let out = try s.parseSample(from: packet)
        #expect(abs(out.x -   72.669) < 0.01)
        #expect(abs(out.y -  -56.096) < 0.01)
        #expect(abs(out.z -  528.820) < 0.01)
        #expect(out.accuracy == 0)
    }

    @Test func correctedMag_parse() throws {
        // Expected: (32.500, -14.800, 29.700, accuracy=3)
        let s = MWSensorFusionCorrectedMag()
        let packet = Data([0x19, 0x06,
                           0x00, 0x00, 0x02, 0x42,   // x = 32.5
                           0xcd, 0xcc, 0x6c, 0xc1,   // y = -14.8
                           0x9a, 0x99, 0xed, 0x41,   // z = 29.7
                           0x03])                    // accuracy = HIGH
        let out = try s.parseSample(from: packet)
        #expect(abs(out.x -  32.500) < 0.01)
        #expect(abs(out.y - -14.800) < 0.01)
        #expect(abs(out.z -  29.700) < 0.01)
        #expect(out.accuracy == 3)
    }

    @Test func quaternion_parse() throws {
        // Expected: w=0.940, x=-0.050, y=-0.154, z=-0.301
        let s = MWSensorFusionQuaternion()
        let packet = Data([0x19, 0x07,
                           0x1b, 0x9b, 0x70, 0x3f,   // w
                           0x8c, 0x5e, 0x4d, 0xbd,   // x
                           0x07, 0x7f, 0x1d, 0xbe,   // y
                           0x78, 0x02, 0x9a, 0xbe])  // z
        let q = try s.parseSample(from: packet)
        #expect(abs(q.w -  0.940) < 0.01)
        #expect(abs(q.x - -0.050) < 0.01)
        #expect(abs(q.y - -0.154) < 0.01)
        #expect(abs(q.z - -0.301) < 0.01)
    }

    @Test func euler_parse() throws {
        // Expected: heading=24.747, pitch=-120.862, roll=-33.046, yaw=24.747
        // Python stores order heading, pitch, yaw, roll in the struct.
        let s = MWSensorFusionEuler()
        let packet = Data([0x19, 0x08,
                           0xb1, 0xf9, 0xc5, 0x41,   // heading = 24.747
                           0x44, 0xb9, 0xf1, 0xc2,   // pitch = -120.862
                           0x1a, 0x2f, 0x04, 0xc2,   // roll = -33.046
                           0xb1, 0xf9, 0xc5, 0x41])  // yaw = 24.747
        let e = try s.parseSample(from: packet)
        #expect(abs(e.heading -   24.747) < 0.01)
        #expect(abs(e.pitch   - -120.862) < 0.01)
        #expect(abs(e.yaw     -   24.747) < 0.01)
    }

    @Test func gravity_parse() throws {
        // Expected: (0.042, 0.826, -0.562)
        let s = MWSensorFusionGravity()
        let packet = Data([0x19, 0x09,
                           0xee, 0x20, 0xd3, 0x3e,
                           0xb2, 0x93, 0x01, 0x41,
                           0x04, 0x59, 0xb0, 0xc0])
        let g = try s.parseSample(from: packet)
        #expect(abs(g.x -  0.042) < 0.01)
        #expect(abs(g.y -  0.826) < 0.01)
        #expect(abs(g.z - -0.562) < 0.01)
    }

    @Test func linearAcc_parse() throws {
        // Expected: (0.296, 1.439, -0.380)
        let s = MWSensorFusionLinearAcceleration()
        let packet = Data([0x19, 0x0a,
                           0x2f, 0xca, 0x39, 0x40,
                           0x86, 0xd4, 0x61, 0x41,
                           0x80, 0x4c, 0x6e, 0xc0])
        let l = try s.parseSample(from: packet)
        #expect(abs(l.x -  0.296) < 0.01)
        #expect(abs(l.y -  1.439) < 0.01)
        #expect(abs(l.z - -0.380) < 0.01)
    }
}

// MARK: - Sensor fusion lifecycle (start / stop sequences)
//
// Reference: MetaWear-SDK-Cpp/test/test_sensor_fusion.py::test_sensor_control.
// The C++ test asserts that start + stop produces a fixed byte sequence per mode,
// with the OUTPUT_ENABLE byte (`[0x19, 0x03, mask, 0x00]`) carrying the bit for
// whichever signal was enabled. Our SDK splits this across four properties:
//   configureCommands → fusion.config + underlying acc/gyro/mag configs
//   enableCommands    → underlying enable_sampling commands
//   startCommands     → underlying start + fusion.enable_mask + fusion.start
//   stopCommands      → fusion.stop + fusion.clear_mask + underlying stops
//   disableCommands   → underlying disable_sampling commands
// The concatenation of these four arrays (in start/stop order) must equal the
// 8-command (or 6-command for sensor-light modes) sequence the Python test asserts.

@Suite("Sensor Fusion Lifecycle (BMI160)")
struct SensorFusionLifecycleBMI160Tests {

    // MARK: NDOF — acc + gyro + mag (8 start commands, 8 stop commands)

    @Test func ndof_quaternion_startSequence() {
        let s = MWSensorFusionQuaternion(mode: .ndof)
        #expect(s.enableCommands == [
            Data([0x03, 0x02, 0x01, 0x00]),
            Data([0x13, 0x02, 0x01, 0x00]),
            Data([0x15, 0x02, 0x01, 0x00]),
        ])
        #expect(s.startCommands == [
            Data([0x03, 0x01, 0x01]),
            Data([0x13, 0x01, 0x01]),
            Data([0x15, 0x01, 0x01]),
            Data([0x19, 0x03, 0x08, 0x00]),  // QUATERNION = bit 3
            Data([0x19, 0x01, 0x01]),
        ])
    }

    @Test func ndof_quaternion_stopSequence() {
        let s = MWSensorFusionQuaternion(mode: .ndof)
        #expect(s.stopCommands == [
            Data([0x19, 0x01, 0x00]),
            Data([0x19, 0x03, 0x00, 0x7F]),
            Data([0x03, 0x01, 0x00]),
            Data([0x13, 0x01, 0x00]),
            Data([0x15, 0x01, 0x00]),
        ])
        #expect(s.disableCommands == [
            Data([0x03, 0x02, 0x00, 0x01]),
            Data([0x13, 0x02, 0x00, 0x01]),
            Data([0x15, 0x02, 0x00, 0x01]),
        ])
    }

    /// Verifies that each of the 7 signals plugs the correct bit into the
    /// OUTPUT_ENABLE byte at index 6 of the Python expected sequence.
    @Test func ndof_outputEnableMask_perSignal() {
        // (signal builder, expected mask bit)
        let cases: [(any MWStreamable, UInt8)] = [
            (MWSensorFusionCorrectedAcc(mode:  .ndof), 0x01),    // bit 0
            (MWSensorFusionCorrectedGyro(mode: .ndof), 0x02),    // bit 1
            (MWSensorFusionCorrectedMag(mode:  .ndof), 0x04),    // bit 2
            (MWSensorFusionQuaternion(mode:    .ndof), 0x08),    // bit 3
            (MWSensorFusionEuler(mode:         .ndof), 0x10),    // bit 4
            (MWSensorFusionGravity(mode:       .ndof), 0x20),    // bit 5
            (MWSensorFusionLinearAcceleration(mode: .ndof), 0x40), // bit 6
        ]
        for (signal, expectedBit) in cases {
            // Index 3 of the 5-element startCommands: [acc, gyro, mag, enable_mask, fusion_start]
            let cmd = signal.startCommands[3]
            #expect(cmd == Data([0x19, 0x03, expectedBit, 0x00]),
                    "OUTPUT_ENABLE mask wrong for signal with bit \(String(expectedBit, radix: 16))")
        }
    }

    // MARK: IMU_PLUS — acc + gyro (no mag)

    @Test func imuPlus_quaternion_startSequence() {
        let s = MWSensorFusionQuaternion(mode: .imuPlus)
        #expect(s.enableCommands == [
            Data([0x03, 0x02, 0x01, 0x00]),
            Data([0x13, 0x02, 0x01, 0x00]),
        ])
        #expect(s.startCommands == [
            Data([0x03, 0x01, 0x01]),
            Data([0x13, 0x01, 0x01]),
            Data([0x19, 0x03, 0x08, 0x00]),
            Data([0x19, 0x01, 0x01]),
        ])
    }

    @Test func imuPlus_quaternion_stopSequence() {
        let s = MWSensorFusionQuaternion(mode: .imuPlus)
        #expect(s.stopCommands == [
            Data([0x19, 0x01, 0x00]),
            Data([0x19, 0x03, 0x00, 0x7F]),
            Data([0x03, 0x01, 0x00]),
            Data([0x13, 0x01, 0x00]),
        ])
        #expect(s.disableCommands == [
            Data([0x03, 0x02, 0x00, 0x01]),
            Data([0x13, 0x02, 0x00, 0x01]),
        ])
    }

    // MARK: COMPASS — acc + mag (no gyro)

    @Test func compass_quaternion_startSequence() {
        let s = MWSensorFusionQuaternion(mode: .compass)
        #expect(s.enableCommands == [
            Data([0x03, 0x02, 0x01, 0x00]),
            Data([0x15, 0x02, 0x01, 0x00]),
        ])
        #expect(s.startCommands == [
            Data([0x03, 0x01, 0x01]),
            Data([0x15, 0x01, 0x01]),
            Data([0x19, 0x03, 0x08, 0x00]),
            Data([0x19, 0x01, 0x01]),
        ])
    }

    @Test func compass_quaternion_stopSequence() {
        let s = MWSensorFusionQuaternion(mode: .compass)
        #expect(s.stopCommands == [
            Data([0x19, 0x01, 0x00]),
            Data([0x19, 0x03, 0x00, 0x7F]),
            Data([0x03, 0x01, 0x00]),
            Data([0x15, 0x01, 0x00]),
        ])
        #expect(s.disableCommands == [
            Data([0x03, 0x02, 0x00, 0x01]),
            Data([0x15, 0x02, 0x00, 0x01]),
        ])
    }

    // MARK: M4G — acc + mag (no gyro)

    @Test func m4g_quaternion_startSequence() {
        let s = MWSensorFusionQuaternion(mode: .m4g)
        #expect(s.enableCommands == [
            Data([0x03, 0x02, 0x01, 0x00]),
            Data([0x15, 0x02, 0x01, 0x00]),
        ])
        #expect(s.startCommands == [
            Data([0x03, 0x01, 0x01]),
            Data([0x15, 0x01, 0x01]),
            Data([0x19, 0x03, 0x08, 0x00]),
            Data([0x19, 0x01, 0x01]),
        ])
    }

    @Test func m4g_quaternion_stopSequence() {
        let s = MWSensorFusionQuaternion(mode: .m4g)
        #expect(s.stopCommands == [
            Data([0x19, 0x01, 0x00]),
            Data([0x19, 0x03, 0x00, 0x7F]),
            Data([0x03, 0x01, 0x00]),
            Data([0x15, 0x01, 0x00]),
        ])
        #expect(s.disableCommands == [
            Data([0x03, 0x02, 0x00, 0x01]),
            Data([0x15, 0x02, 0x00, 0x01]),
        ])
    }

    // MARK: Single-Data forms preserve fusion-only meaning (regression check)

    @Test func singleDataForms_areFusionOnly() {
        // The single Data forms keep their fusion-only meaning so existing unit
        // tests in `SensorFusionCommandTests` continue to pass.
        let s = MWSensorFusionQuaternion(mode: .ndof)
        #expect(s.enableCommand  == Data([0x19, 0x03, 0x08, 0x00]))
        #expect(s.startCommand   == Data([0x19, 0x01, 0x01]))
        #expect(s.stopCommand    == Data([0x19, 0x01, 0x00]))
        #expect(s.disableCommand == Data([0x19, 0x03, 0x00, 0x08]))
    }
}

// MARK: - Sensor fusion configure (full BLE write sequence)
//
// Reference: MetaWear-SDK-Cpp/test/test_sensor_fusion_config.py::test_configure_*.
// `mbl_mw_sensor_fusion_write_config` issues fusion-config + underlying configs
// per (mode, chip). Our SDK exposes this via `configureCommands`, which the
// device flushes before `enableCommands`/`startCommands`.

@Suite("Sensor Fusion Configure (BMI160)")
struct SensorFusionConfigureBMI160Tests {

    // MARK: NDOF — fusion + acc(100Hz) + gyro(100Hz) + mag

    @Test func ndof_2g_2000dps_configure() {
        // From test_configure_ndof — gr=0, ar=0:
        //   fusion config_byte = 0x10, acc range_byte = 0x03, gyro range_byte = 0x00
        let s = MWSensorFusionQuaternion(mode: .ndof,
                                         accRange:  .g2,
                                         gyroRange: .dps2000,
                                         chip: .bmi160)
        #expect(s.configureCommands == [
            Data([0x19, 0x02, 0x01, 0x10]),     // fusion: NDOF, gr=0, ar=0
            Data([0x03, 0x03, 0x28, 0x03]),     // acc:  100Hz, ±2g
            Data([0x13, 0x03, 0x28, 0x00]),     // gyro: 100Hz, 2000dps
            Data([0x15, 0x04, 0x04, 0x0E]),     // mag:  xy_reps=9, z_reps=15
            Data([0x15, 0x03, 0x06]),           // mag:  ODR=25Hz
        ])
    }

    @Test func ndof_16g_250dps_configure() {
        // gr=3, ar=3 → fusion config_byte = (3+1)<<4 | 3 = 0x43,
        //              acc range_byte = 0x0C, gyro range_byte = 0x03
        let s = MWSensorFusionEuler(mode: .ndof,
                                    accRange:  .g16,
                                    gyroRange: .dps250,
                                    chip: .bmi160)
        #expect(s.configureCommands == [
            Data([0x19, 0x02, 0x01, 0x43]),
            Data([0x03, 0x03, 0x28, 0x0C]),
            Data([0x13, 0x03, 0x28, 0x03]),
            Data([0x15, 0x04, 0x04, 0x0E]),
            Data([0x15, 0x03, 0x06]),
        ])
    }

    @Test func ndof_configMatrix_exhaustive_matchesPython() {
        // Mirrors test_configure_ndof's full 4×4 matrix.
        let accCases:  [(MWSensorFusionAccRange, UInt8)] = [
            (.g2,  0x03), (.g4,  0x05), (.g8,  0x08), (.g16, 0x0C),
        ]
        let gyroCases: [(MWSensorFusionGyroRange, UInt8)] = [
            (.dps2000, 0x00), (.dps1000, 0x01), (.dps500, 0x02), (.dps250, 0x03),
        ]
        let configMasks: [[UInt8]] = [
            [0x10, 0x11, 0x12, 0x13],
            [0x20, 0x21, 0x22, 0x23],
            [0x30, 0x31, 0x32, 0x33],
            [0x40, 0x41, 0x42, 0x43],
        ]
        for (gi, (gr, gByte)) in gyroCases.enumerated() {
            for (ai, (ar, aByte)) in accCases.enumerated() {
                let s = MWSensorFusionQuaternion(mode: .ndof,
                                                 accRange: ar,
                                                 gyroRange: gr,
                                                 chip: .bmi160)
                #expect(s.configureCommands == [
                    Data([0x19, 0x02, 0x01, configMasks[gi][ai]]),
                    Data([0x03, 0x03, 0x28, aByte]),
                    Data([0x13, 0x03, 0x28, gByte]),
                    Data([0x15, 0x04, 0x04, 0x0E]),
                    Data([0x15, 0x03, 0x06]),
                ], "matrix mismatch at gyro=\(gr), acc=\(ar)")
            }
        }
    }

    // MARK: IMU_PLUS — fusion + acc(100Hz) + gyro(100Hz) — no mag

    @Test func imuPlus_2g_2000dps_configure() {
        let s = MWSensorFusionQuaternion(mode: .imuPlus,
                                         accRange:  .g2,
                                         gyroRange: .dps2000,
                                         chip: .bmi160)
        #expect(s.configureCommands == [
            Data([0x19, 0x02, 0x02, 0x10]),     // fusion: IMU_PLUS
            Data([0x03, 0x03, 0x28, 0x03]),     // acc:  100Hz, ±2g
            Data([0x13, 0x03, 0x28, 0x00]),     // gyro: 100Hz, 2000dps
        ])
    }

    // MARK: COMPASS — fusion + acc(25Hz) + mag — no gyro

    @Test func compass_2g_configure() {
        let s = MWSensorFusionQuaternion(mode: .compass,
                                         accRange:  .g2,
                                         gyroRange: .dps2000,
                                         chip: .bmi160)
        #expect(s.configureCommands == [
            Data([0x19, 0x02, 0x03, 0x10]),     // fusion: COMPASS
            Data([0x03, 0x03, 0x26, 0x03]),     // acc: 25Hz, ±2g  (confByte = 0x26)
            Data([0x15, 0x04, 0x04, 0x0E]),
            Data([0x15, 0x03, 0x06]),
        ])
    }

    // MARK: M4G — fusion + acc(50Hz) + mag — no gyro

    @Test func m4g_2g_configure() {
        let s = MWSensorFusionQuaternion(mode: .m4g,
                                         accRange:  .g2,
                                         gyroRange: .dps2000,
                                         chip: .bmi160)
        #expect(s.configureCommands == [
            Data([0x19, 0x02, 0x04, 0x10]),     // fusion: M4G
            Data([0x03, 0x03, 0x27, 0x03]),     // acc: 50Hz, ±2g  (confByte = 0x27)
            Data([0x15, 0x04, 0x04, 0x0E]),
            Data([0x15, 0x03, 0x06]),
        ])
    }

    // MARK: SLEEP — fusion config only (parity with C++ — no underlying writes)

    @Test func sleep_writesOnlyFusionConfig() {
        let s = MWSensorFusionQuaternion(mode: .sleep,
                                         accRange:  .g2,
                                         gyroRange: .dps2000,
                                         chip: .bmi160)
        #expect(s.configureCommands == [
            Data([0x19, 0x02, 0x00, 0x10]),
        ])
    }
}

// MARK: - Sensor fusion configure (BMI270)
//
// On BMI270 boards the gyro module reports `implementation = 1`, the acc reports
// `implementation = 4`. Our SDK takes a `chip` parameter on each fusion struct.
// The acc config byte differs from BMI160: bit[7]=filter_perf=1 for ODR>=12.5 Hz
// (so acc_conf becomes 0xA8 / 0xA6 / 0xA7), and the range byte is 0-based
// (0/1/2/3 instead of 0x03/0x05/0x08/0x0C). Gyro and mag bytes are unchanged.

@Suite("Sensor Fusion Configure (BMI270)")
struct SensorFusionConfigureBMI270Tests {

    @Test func ndof_2g_2000dps_configure_bmi270() {
        let s = MWSensorFusionQuaternion(mode: .ndof,
                                         accRange:  .g2,
                                         gyroRange: .dps2000,
                                         chip: .bmi270)
        #expect(s.configureCommands == [
            Data([0x19, 0x02, 0x01, 0x10]),     // fusion: NDOF (unchanged)
            Data([0x03, 0x03, 0xA8, 0x00]),     // acc: 100Hz, ±2g (BMI270: confByte=0xA8, range=0)
            Data([0x13, 0x03, 0x28, 0x00]),     // gyro: 100Hz, 2000dps (unchanged)
            Data([0x15, 0x04, 0x04, 0x0E]),
            Data([0x15, 0x03, 0x06]),
        ])
    }

    @Test func ndof_16g_250dps_configure_bmi270() {
        let s = MWSensorFusionEuler(mode: .ndof,
                                    accRange:  .g16,
                                    gyroRange: .dps250,
                                    chip: .bmi270)
        #expect(s.configureCommands == [
            Data([0x19, 0x02, 0x01, 0x43]),
            Data([0x03, 0x03, 0xA8, 0x03]),     // BMI270: range 16g = 0x03
            Data([0x13, 0x03, 0x28, 0x03]),
            Data([0x15, 0x04, 0x04, 0x0E]),
            Data([0x15, 0x03, 0x06]),
        ])
    }

    @Test func compass_2g_configure_bmi270() {
        let s = MWSensorFusionQuaternion(mode: .compass,
                                         accRange:  .g2,
                                         gyroRange: .dps2000,
                                         chip: .bmi270)
        #expect(s.configureCommands == [
            Data([0x19, 0x02, 0x03, 0x10]),
            Data([0x03, 0x03, 0xA6, 0x00]),     // BMI270 25Hz confByte = 0xA6
            Data([0x15, 0x04, 0x04, 0x0E]),
            Data([0x15, 0x03, 0x06]),
        ])
    }

    @Test func m4g_2g_configure_bmi270() {
        let s = MWSensorFusionQuaternion(mode: .m4g,
                                         accRange:  .g2,
                                         gyroRange: .dps2000,
                                         chip: .bmi270)
        #expect(s.configureCommands == [
            Data([0x19, 0x02, 0x04, 0x10]),
            Data([0x03, 0x03, 0xA7, 0x00]),     // BMI270 50Hz confByte = 0xA7
            Data([0x15, 0x04, 0x04, 0x0E]),
            Data([0x15, 0x03, 0x06]),
        ])
    }
}

// MARK: - Chip-detection helpers

@Suite("Sensor Fusion Chip Detection")
struct SensorFusionChipTests {

    @Test func chip_fromGyroImpl_matchesCpp() {
        #expect(MWSensorFusionChip(gyroImpl: 0) == .bmi160)
        #expect(MWSensorFusionChip(gyroImpl: 1) == .bmi270)
        #expect(MWSensorFusionChip(gyroImpl: 7) == nil)
    }

    @Test func chip_fromAccImpl_matchesCpp() {
        #expect(MWSensorFusionChip(accImpl: 1) == .bmi160)
        #expect(MWSensorFusionChip(accImpl: 4) == .bmi270)
        #expect(MWSensorFusionChip(accImpl: 0) == nil)
    }
}

// MARK: - Barometer commands
//
// Reference vectors from MetaWear-SDK-Cpp/test/test_barometer_bmp280.py and
// barometer_bosch_base.py. All bytes verified against the C++ `BoschBaroConfig`
// bitfield in barometer_bosch.cpp.

@Suite("Barometer Commands")
struct BarometerCommandTests {

    @Test func start_stop() {
        let b = MWBarometer()
        #expect(b.startCommand == Data([0x12, 0x04, 0x01, 0x01]))
        #expect(b.stopCommand  == Data([0x12, 0x04, 0x00, 0x00]))
    }

    // MARK: Oversampling — Python test_set_oversampling

    @Test func config_oversampling_ultraLowPower() {
        let b = MWBarometer(oversampling: .ultraLowPower, iirFilter: .off, standbyTime: .ms0_5)
        // byte0 = 0x24: pressure=1 (bits 2-4), temp=ULTRA_LOW_POWER=1 (bits 5-7)
        #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x24, 0x00]))
    }

    @Test func config_oversampling_lowPower() {
        let b = MWBarometer(oversampling: .lowPower, iirFilter: .off, standbyTime: .ms0_5)
        #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x28, 0x00]))
    }

    @Test func config_oversampling_standard() {
        let b = MWBarometer(oversampling: .standard, iirFilter: .off, standbyTime: .ms0_5)
        #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x2c, 0x00]))
    }

    @Test func config_oversampling_high() {
        let b = MWBarometer(oversampling: .high, iirFilter: .off, standbyTime: .ms0_5)
        #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x30, 0x00]))
    }

    @Test func config_oversampling_ultraHigh_bumpsTemperatureToLowPower() {
        // ULTRA_HIGH pressure forces temperature oversampling to LOW_POWER (2).
        // byte0 = 0x54: pressure=5 (bits 2-4), temp=2 (bits 5-7)
        let b = MWBarometer(oversampling: .ultraHigh, iirFilter: .off, standbyTime: .ms0_5)
        #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x54, 0x00]))
    }

    // MARK: IIR filter — Python test_set_filter
    // All filter tests use default oversampling=standard, so byte0 == 0x2C.

    @Test func config_filter_off() {
        let b = MWBarometer(oversampling: .standard, iirFilter: .off, standbyTime: .ms0_5)
        #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x2c, 0x00]))
    }

    @Test func config_filter_avg2() {
        let b = MWBarometer(oversampling: .standard, iirFilter: .avg2, standbyTime: .ms0_5)
        #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x2c, 0x04]))
    }

    @Test func config_filter_avg4() {
        let b = MWBarometer(oversampling: .standard, iirFilter: .avg4, standbyTime: .ms0_5)
        #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x2c, 0x08]))
    }

    @Test func config_filter_avg8() {
        let b = MWBarometer(oversampling: .standard, iirFilter: .avg8, standbyTime: .ms0_5)
        #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x2c, 0x0c]))
    }

    @Test func config_filter_avg16() {
        let b = MWBarometer(oversampling: .standard, iirFilter: .avg16, standbyTime: .ms0_5)
        #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x2c, 0x10]))
    }

    // MARK: BMP280 standby matrix — Python test_set_standby (BMP280)

    @Test func config_bmp_standby_matrix() {
        let expected: [(MWBarometer.BMPStandbyTime, UInt8)] = [
            (.ms0_5,   0x00),
            (.ms62_5,  0x20),
            (.ms125,   0x40),
            (.ms250,   0x60),
            (.ms500,   0x80),
            (.ms1000,  0xa0),
            (.ms2000,  0xc0),
            (.ms4000,  0xe0),
        ]
        for (standby, byte1) in expected {
            let b = MWBarometer(oversampling: .standard, iirFilter: .off, standbyTime: standby)
            #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x2c, byte1]),
                    "standby \(standby) should encode byte1 = \(String(byte1, radix: 16))")
        }
    }

    // MARK: Composite — Python test_set_all_config
    // LOW_POWER + AVG_16 + 500ms → [0x12, 0x03, 0x28, 0x90]

    @Test func config_composite_lowPower_avg16_500ms() {
        let b = MWBarometer(oversampling: .lowPower, iirFilter: .avg16, standbyTime: .ms500)
        #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x28, 0x90]))
    }

    // MARK: BME280 — same encoding, different interpretation at indices 6/7

    @Test func config_bme_standby_10ms_encodesAs6() {
        let b = MWBarometer(oversampling: .standard, iirFilter: .off, bmeStandbyTime: .ms10)
        // BME raw 6 << 5 = 0xC0
        #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x2c, 0xc0]))
        #expect(b.variant == .bme280)
    }

    @Test func config_bme_standby_20ms_encodesAs7() {
        let b = MWBarometer(oversampling: .standard, iirFilter: .off, bmeStandbyTime: .ms20)
        #expect(b.configureCommands[0] == Data([0x12, 0x03, 0x2c, 0xe0]))
        #expect(b.variant == .bme280)
    }

    // MARK: Registers

    @Test func pressure_register() {
        #expect(MWBarometer().dataRegister == 0x01)
    }

    @Test func altitude_register() {
        #expect(MWAltimeter().dataRegister == 0x02)
    }

    @Test func altimeter_reusesBarometerConfig() {
        let baro = MWBarometer(oversampling: .high, iirFilter: .avg8, standbyTime: .ms250)
        let alt  = MWAltimeter(config: baro)
        #expect(alt.configureCommands == baro.configureCommands)
        #expect(alt.startCommand == baro.startCommand)
        #expect(alt.stopCommand == baro.stopCommand)
    }

    // MARK: Variant raw values — match C++ MBL_MW_MODULE_BARO_TYPE_*

    @Test func variant_rawValues() {
        #expect(MWBarometer.Variant.bmp280.rawValue == 0)
        #expect(MWBarometer.Variant.bme280.rawValue == 1)
    }

    // MARK: One-shot pressure read

    @Test func pressureRead_command() {
        // Register 0x01 with READ bit → 0x81
        #expect(MWBarometerPressureRead().readCommand == Data([0x12, 0x81]))
    }
}

// MARK: - Barometer data handler
//
// Reference vectors from MetaWear-SDK-Cpp/test/barometer_bosch_base.py

@Suite("Barometer Data Handler")
struct BarometerDataHandlerTests {

    @Test func pressure_parse_referenceVector() throws {
        // b'\x12\x01\xd3\x35\x8b\x01' → 101173.828125 Pa
        let packet = Data([0x12, 0x01, 0xd3, 0x35, 0x8b, 0x01])
        let p = try MWBarometer().parseSample(from: packet)
        #expect(abs(p - 101173.828125) < 0.001)
    }

    @Test func altitude_parse_referenceVector() throws {
        // b'\x12\x02\x1e\x1f\xfe\xff' → -480.8828125 m
        let packet = Data([0x12, 0x02, 0x1e, 0x1f, 0xfe, 0xff])
        let a = try MWAltimeter().parseSample(from: packet)
        #expect(abs(a - -480.8828125) < 0.001)
    }

    @Test func pressureRead_parse_sameAsStream() throws {
        // One-shot read uses the same packet shape; divide by 256.
        let packet = Data([0x12, 0x01, 0xd3, 0x35, 0x8b, 0x01])
        let p = try MWBarometerPressureRead().parseSample(from: packet)
        #expect(abs(p - 101173.828125) < 0.001)
    }
}

// MARK: - MWAccelerometer.make (generic snapping API)

@Suite("MWAccelerometer Generic API")
struct MWAccelerometerGenericAPITests {

    // Reference: test_accelerometer.py (MbientLab C++ SDK)
    // mbl_mw_acc_set_odr / mbl_mw_acc_set_range snap to the nearest supported value.

    // MARK: BMI160

    @Test func bmi160_odr_snapsToNearest_55Hz() {
        // 55 Hz is between 50 and 100; nearest is 50 Hz → confByte 0x27
        let acc = MWAccelerometer.make(impl: 1, odrHz: 55, rangeG: 2)
        guard case .bmi160(let s) = acc else { Issue.record("Expected bmi160"); return }
        #expect(s.configureCommands[0][2] == 0x27)
    }

    @Test func bmi160_odr_snappedValue_is50Hz() {
        let acc = MWAccelerometer.make(impl: 1, odrHz: 55, rangeG: 2)
        guard case .bmi160(let s) = acc else { Issue.record("Expected bmi160"); return }
        #expect(s.odr.hz == 50.0)
    }

    @Test func bmi160_range_snapsToNearest_14_75G() {
        // 14.75 g → nearest supported is 16 g → rangeByte 0x0C
        let acc = MWAccelerometer.make(impl: 1, odrHz: 100, rangeG: 14.75)
        guard case .bmi160(let s) = acc else { Issue.record("Expected bmi160"); return }
        #expect(s.configureCommands[0][3] == 0x0C)
    }

    @Test func bmi160_range_snappedValue_is16G() {
        let acc = MWAccelerometer.make(impl: 1, odrHz: 100, rangeG: 14.75)
        guard case .bmi160(let s) = acc else { Issue.record("Expected bmi160"); return }
        #expect(s.range.rangeG == 16.0)
    }

    @Test func bmi160_fullCommand_odr55_range14_75() {
        // Combined: 50 Hz (0x27) + 16 g (0x0C)
        let acc = MWAccelerometer.make(impl: 1, odrHz: 55, rangeG: 14.75)
        guard case .bmi160(let s) = acc else { Issue.record("Expected bmi160"); return }
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0x27, 0x0C]))
    }

    @Test func bmi160_unknownImpl_returnsNil() {
        #expect(MWAccelerometer.make(impl: 99) == nil)
    }

    // MARK: BMI270

    @Test func bmi270_odr_snapsToNearest_55Hz() {
        // 55 Hz → nearest is 50 Hz → confByte 0xA7
        let acc = MWAccelerometer.make(impl: 4, odrHz: 55, rangeG: 2)
        guard case .bmi270(let s) = acc else { Issue.record("Expected bmi270"); return }
        #expect(s.configureCommands[0][2] == 0xA7)
    }

    @Test func bmi270_range_snapsToNearest_14_75G() {
        // 14.75 g → nearest is 16 g → rangeByte 0x03
        let acc = MWAccelerometer.make(impl: 4, odrHz: 100, rangeG: 14.75)
        guard case .bmi270(let s) = acc else { Issue.record("Expected bmi270"); return }
        #expect(s.configureCommands[0][3] == 0x03)
    }

    @Test func bmi270_fullCommand_odr100_range2G() {
        // 100 Hz (0xA8) + 2 g (0x00)
        let acc = MWAccelerometer.make(impl: 4, odrHz: 100, rangeG: 2)
        guard case .bmi270(let s) = acc else { Issue.record("Expected bmi270"); return }
        #expect(s.configureCommands[0] == Data([0x03, 0x03, 0xA8, 0x00]))
    }
}

// MARK: - Bosch orientation detection commands

// Reference: test_accelerometer_bosch.py (MbientLab C++ SDK), class TestOrientation

@Suite("Accelerometer Bosch — Orientation Detection")
struct AccBoschOrientationTests {

    @Test func enableCommand_bmi160() throws {
        // Happy path: orientation detection is BMI160-only.
        let cmd = try MWAccelerometerBosch.EnableOrientation(chip: .bmi160)
        #expect(cmd.commandData == Data([0x03, 0x0f, 0x01, 0x00]))
    }

    @Test func enableCommand_throwsOnBMI270() {
        // Chip guard: constructing on BMI270 must throw with the legacy
        // verbatim error string — `Tests/MetaWearHardwareTests/StreamTests.swift`
        // pins the same diagnostic against a real BMI270 board.
        do {
            _ = try MWAccelerometerBosch.EnableOrientation(chip: .bmi270)
            Issue.record("EnableOrientation(chip: .bmi270) should throw")
        } catch let error as MWError {
            #expect(error.localizedDescription ==
                    "Operation failed: Orientation requires a BMI160 module, which this device lacks.")
        } catch {
            Issue.record("Expected MWError, got \(type(of: error)): \(error)")
        }
    }

    @Test func disableCommand() {
        // Disable is unguarded — writing zero bits to a register the BMI270
        // doesn't react to is harmless.
        #expect(MWAccelerometerBosch.DisableOrientation().commandData == Data([0x03, 0x0f, 0x00, 0x01]))
    }

    // All 8 orientations from test_handle_response
    // Parse index = (responseByte >> 1) & 0x07

    @Test func parse_faceUpLandscapeRight()      throws { #expect(try MWAccelerometerBosch.parseOrientation(from: Data([0x03, 0x11, 0x07])) == .faceUpLandscapeRight)      }
    @Test func parse_faceUpPortraitUpright()     throws { #expect(try MWAccelerometerBosch.parseOrientation(from: Data([0x03, 0x11, 0x01])) == .faceUpPortraitUpright)     }
    @Test func parse_faceUpPortraitUpsideDown()  throws { #expect(try MWAccelerometerBosch.parseOrientation(from: Data([0x03, 0x11, 0x03])) == .faceUpPortraitUpsideDown)  }
    @Test func parse_faceUpLandscapeLeft()       throws { #expect(try MWAccelerometerBosch.parseOrientation(from: Data([0x03, 0x11, 0x05])) == .faceUpLandscapeLeft)       }
    @Test func parse_faceDownLandscapeRight()    throws { #expect(try MWAccelerometerBosch.parseOrientation(from: Data([0x03, 0x11, 0x0f])) == .faceDownLandscapeRight)    }
    @Test func parse_faceDownLandscapeLeft()     throws { #expect(try MWAccelerometerBosch.parseOrientation(from: Data([0x03, 0x11, 0x0d])) == .faceDownLandscapeLeft)     }
    @Test func parse_faceDownPortraitUpright()   throws { #expect(try MWAccelerometerBosch.parseOrientation(from: Data([0x03, 0x11, 0x09])) == .faceDownPortraitUpright)   }
    @Test func parse_faceDownPortraitUpsideDown()throws { #expect(try MWAccelerometerBosch.parseOrientation(from: Data([0x03, 0x11, 0x0b])) == .faceDownPortraitUpsideDown)}
}

// MARK: - Bosch any-motion detection commands

// Reference: test_accelerometer_bosch.py (MbientLab C++ SDK), class TestAnyMotion

@Suite("Accelerometer Bosch — Any-Motion Detection")
struct AccBoschAnyMotionTests {

    // Config: range=8g, count=4, threshold=0.75g, noMotionDefault=0x14
    // threshold_byte = round(0.75 * 512 / 8) - 1 = round(48) - 1 = 47 = 0x2f

    @Test func configCommand_bmi160() {
        // BMI160 gets 4 payload bytes (extra noMotion byte)
        let cmd = MWAccelerometerBosch.ConfigureAnyMotion(chip: .bmi160, count: 4, thresholdG: 0.75, rangeG: 8.0)
        #expect(cmd.commandData == Data([0x03, 0x0a, 0x03, 0x2f, 0x14, 0x14]))
    }

    @Test func configCommand_bmi270() {
        // BMI270 gets 3 payload bytes
        let cmd = MWAccelerometerBosch.ConfigureAnyMotion(chip: .bmi270, count: 4, thresholdG: 0.75, rangeG: 8.0)
        #expect(cmd.commandData == Data([0x03, 0x0a, 0x03, 0x2f, 0x14]))
    }

    @Test func enableCommand() {
        #expect(MWAccelerometerBosch.EnableAnyMotion().commandData == Data([0x03, 0x09, 0x07, 0x00]))
    }

    @Test func disableCommand() {
        #expect(MWAccelerometerBosch.DisableAnyMotion().commandData == Data([0x03, 0x09, 0x00, 0x7f]))
    }

    // Response parsing: byte layout — bit6=sign(0=positive), bit5=z, bit4=y, bit3=x

    @Test func parse_positiveZ() throws {
        let e = try MWAccelerometerBosch.parseAnyMotion(from: Data([0x03, 0x0b, 0x22]))
        #expect(e == .init(isPositive: true,  xAxisActive: false, yAxisActive: false, zAxisActive: true))
    }

    @Test func parse_negativeZ() throws {
        let e = try MWAccelerometerBosch.parseAnyMotion(from: Data([0x03, 0x0b, 0x62]))
        #expect(e == .init(isPositive: false, xAxisActive: false, yAxisActive: false, zAxisActive: true))
    }

    @Test func parse_negativeY() throws {
        let e = try MWAccelerometerBosch.parseAnyMotion(from: Data([0x03, 0x0b, 0x52]))
        #expect(e == .init(isPositive: false, xAxisActive: false, yAxisActive: true,  zAxisActive: false))
    }

    @Test func parse_positiveY() throws {
        let e = try MWAccelerometerBosch.parseAnyMotion(from: Data([0x03, 0x0b, 0x12]))
        #expect(e == .init(isPositive: true,  xAxisActive: false, yAxisActive: true,  zAxisActive: false))
    }

    @Test func parse_positiveX() throws {
        let e = try MWAccelerometerBosch.parseAnyMotion(from: Data([0x03, 0x0b, 0x0a]))
        #expect(e == .init(isPositive: true,  xAxisActive: true,  yAxisActive: false, zAxisActive: false))
    }

    @Test func parse_negativeX() throws {
        let e = try MWAccelerometerBosch.parseAnyMotion(from: Data([0x03, 0x0b, 0x4a]))
        #expect(e == .init(isPositive: false, xAxisActive: true,  yAxisActive: false, zAxisActive: false))
    }
}

// MARK: - Bosch tap detection commands

// Reference: test_accelerometer_bosch.py (MbientLab C++ SDK), class TestTapDetector

@Suite("Accelerometer Bosch — Tap Detection")
struct AccBoschTapTests {

    // Timing byte = (shock << 7) | (quiet << 6) | window
    // tap_th = round(threshold * 32 / range)

    @Test func configureSingleTap() {
        // range=16g, threshold=2.0g, shock=50ms(0), quiet=30ms(0), window=250ms(4, default)
        // timingByte = (0<<7)|(0<<6)|4 = 0x04; tapTh = round(2.0*32/16) = 4 = 0x04
        let cmd = MWAccelerometerBosch.ConfigureTap(shockTime: .ms50, thresholdG: 2.0, rangeG: 16.0)
        #expect(cmd.commandData == Data([0x03, 0x0d, 0x04, 0x04]))
    }

    @Test func configureDoubleTap() {
        // range=8g, threshold=1.0g, window=50ms(0), quiet=20ms(1), shock=75ms(1)
        // timingByte = (1<<7)|(1<<6)|0 = 0xc0; tapTh = round(1.0*32/8) = 4 = 0x04
        let cmd = MWAccelerometerBosch.ConfigureTap(
            shockTime: .ms75, quietTime: .ms20, doubleTapWindow: .ms50,
            thresholdG: 1.0, rangeG: 8.0)
        #expect(cmd.commandData == Data([0x03, 0x0d, 0xc0, 0x04]))
    }

    @Test func enableSingleTap() {
        // bit1 = single
        #expect(MWAccelerometerBosch.EnableTap(single: true, double: false).commandData == Data([0x03, 0x0c, 0x02, 0x00]))
    }

    @Test func enableDoubleTap() {
        // bit0 = double
        #expect(MWAccelerometerBosch.EnableTap(single: false, double: true).commandData == Data([0x03, 0x0c, 0x01, 0x00]))
    }

    @Test func disableTap() {
        #expect(MWAccelerometerBosch.DisableTap().commandData == Data([0x03, 0x0c, 0x00, 0x03]))
    }

    // Response parsing: type = byte & 0x03  (1=double, 2=single),  isPositive = ((byte>>5)&1)==0

    @Test func parseSingleTap_positive() throws {
        let t = try MWAccelerometerBosch.parseTap(from: Data([0x03, 0x0e, 0x12]))
        #expect(t == .init(type: .single, isPositive: true))
    }

    @Test func parseSingleTap_negative() throws {
        let t = try MWAccelerometerBosch.parseTap(from: Data([0x03, 0x0e, 0x32]))
        #expect(t == .init(type: .single, isPositive: false))
    }

    @Test func parseDoubleTap_positive() throws {
        let t = try MWAccelerometerBosch.parseTap(from: Data([0x03, 0x0e, 0x11]))
        #expect(t == .init(type: .double, isPositive: true))
    }

    @Test func parseDoubleTap_negative() throws {
        let t = try MWAccelerometerBosch.parseTap(from: Data([0x03, 0x0e, 0x31]))
        #expect(t == .init(type: .double, isPositive: false))
    }
}
