import Testing
import Foundation
@testable import MetaWear

// MARK: - Data Processor command byte-layout tests
//
// All expected byte sequences are taken directly from MetaWear-SDK-Cpp/test/:
//   test_processor.py  — test_freefall, test_led_controller
//   test_dataprocessor.py — individual processor config tests
//
// ADD command format:
//   [0x09, 0x02, src_module, src_reg, src_data_id, src_config, proc_type, config_bytes...]
//
// Source config formula (datasignal.cpp get_data_ubyte()):
//   src_config = ((n_channels * channel_size - 1) << 5) | offset

@Suite("Data Processor — Source Config Byte")
struct MWDataProcessorSourceConfigTests {

    // Switch: 1ch × 1B = length 1 → (1-1)<<5 | 0 = 0x00
    @Test func switchSignal_sourceConfigByte() {
        let sig = MWSwitchSignal()
        #expect(sig.sourceConfigByte == 0x00)
    }

    // GPIO ADC: 1ch × 2B = length 2 → (2-1)<<5 | 0 = 0x20
    @Test func gpioAnalogSignal_sourceConfigByte() {
        let sig = MWGPIOAnalogSignal(pin: 0, mode: .adc)
        #expect(sig.sourceConfigByte == 0x20)
    }

    // Accelerometer: 3ch × 2B = length 6 → (6-1)<<5 | 0 = 0xA0
    @Test func accelerometerSignal_sourceConfigByte() {
        let sig = MWAccelerometerSignal()
        #expect(sig.sourceConfigByte == 0xA0)
    }

    // Temperature: 1ch × 2B = length 2 → 0x20
    @Test func temperatureSignal_sourceConfigByte() {
        let sig = MWTemperatureSignal(channel: 0)
        #expect(sig.sourceConfigByte == 0x20)
    }

    // Processor handle (RSS output, 1ch × 2B): 0x20
    @Test func processorHandle_sourceConfigByte() {
        let handle = MWProcessorHandle(id: 0, nChannels: 1, channelSize: 2, isSigned: false)
        #expect(handle.sourceConfigByte == 0x20)
    }
}

// MARK: - buildProcessorAddCommand

@Suite("Data Processor — ADD command layout")
struct MWDataProcessorAddCommandTests {

    let device: MetaWearDevice = {
        let transport = MockBLETransport()
        return MetaWearDevice(identifier: UUID(), transport: transport)
    }()

    // MARK: RSS of accelerometer  (C++ test_freefall, step 1)
    // Expected: [0x09, 0x02, 0x03, 0x04, 0xff, 0xa0, 0x07, 0xa5, 0x01]
    @Test func rss_ofAccelerometer_addCommand() async {
        let source = MWAccelerometerSignal()
        let config = MWDataProcessor.RSS()
        let cmd = await device.buildProcessorAddCommand(source: source, config: config)
        #expect(cmd == [0x09, 0x02, 0x03, 0x04, 0xFF, 0xA0, 0x07, 0xA5, 0x01])
    }

    // RSS config byte breakdown:
    //   unit = 6/3 = 2 → s = (2-1)&0x3 = 1
    //   byte0 = s | (s<<2) | ((ch-1)<<4) | signed
    //         = 1 | 4 | (2<<4) | 0x80 = 0x01 | 0x04 | 0x20 | 0x80 = 0xA5
    //   byte1 = 0x01 (RSS mode)
    @Test func rss_configByteBreakdown() {
        let config = MWDataProcessor.RSS()
        let bytes = config.configBytes(inputLength: 6, inputChannels: 3, inputSigned: true)
        #expect(bytes == [0xA5, 0x01])
    }

    // MARK: Counter of switch (C++ test_led_controller, step 1)
    // Expected: [0x09, 0x02, 0x01, 0x01, 0xff, 0x00, 0x02, 0x10]
    @Test func counter_ofSwitch_addCommand() async {
        let source = MWSwitchSignal()
        let config = MWDataProcessor.Counter(outputSize: 1)
        let cmd = await device.buildProcessorAddCommand(source: source, config: config)
        #expect(cmd == [0x09, 0x02, 0x01, 0x01, 0xFF, 0x00, 0x02, 0x10])
    }

    // Counter config byte: ((outputSize-1)&0x3) | (1<<4)
    //   outputSize=1 → 0 | 0x10 = 0x10 ✓
    @Test func counter_configByte_outputSize1() {
        let config = MWDataProcessor.Counter(outputSize: 1)
        let bytes = config.configBytes(inputLength: 1, inputChannels: 1, inputSigned: false)
        #expect(bytes == [0x10])
    }

    @Test func counter_configByte_outputSize4() {
        let config = MWDataProcessor.Counter(outputSize: 4)
        // ((4-1)&0x3) | (1<<4) = 3 | 0x10 = 0x13
        let bytes = config.configBytes(inputLength: 1, inputChannels: 1, inputSigned: false)
        #expect(bytes == [0x13])
    }

    // MARK: Math (counter % 2)  (C++ test_led_controller, step 2)
    // Expected config: [0x03, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00]
    //   byte0: output=4→3, input=1→0, unsigned=0  → 0x03|(0<<2)|(0<<4) = 0x03
    //   op = modulo = 0x04, rhs=2 LE32, nch=0
    @Test func math_modulo_configBytes() {
        let config = MWDataProcessor.Math(operation: .modulo, rhs: 2, signed: false, outputSize: 4)
        let bytes = config.configBytes(inputLength: 1, inputChannels: 1, inputSigned: false)
        #expect(bytes == [0x03, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00])
    }

    // MARK: Average of RSS output  (C++ test_freefall, step 2)
    // Expected: [0x09, 0x02, 0x09, 0x03, 0x00, 0x20, 0x03, 0x05, 0x04]
    //   src = processor handle id=0, 1ch×2B → src_config=0x20
    //   proc_type=0x03 (Average), sampleSize=4
    //   config byte0: s=1, s|s<<2 = 0x05; byte1=4
    @Test func average_ofProcessorHandle_addCommand() async {
        let source = MWProcessorHandle(id: 0, nChannels: 1, channelSize: 2, isSigned: false)
        let config = MWDataProcessor.Average(sampleSize: 4)
        let cmd = await device.buildProcessorAddCommand(source: source, config: config)
        #expect(cmd == [0x09, 0x02, 0x09, 0x03, 0x00, 0x20, 0x03, 0x05, 0x04])
    }

    @Test func average_configBytes_2byteInput() {
        let config = MWDataProcessor.Average(sampleSize: 4)
        // inputLength=2, inputChannels=1 → unit=2, s=1
        // byte0 = s | (s<<2) = 0x01 | 0x04 = 0x05
        let bytes = config.configBytes(inputLength: 2, inputChannels: 1, inputSigned: false)
        #expect(bytes == [0x05, 0x04])
    }

    // MARK: Threshold BINARY  (C++ test_freefall, step 3)
    // boundary=8192=0x2000, hysteresis=0, mode=binary, signed=false
    // Expected config: [0x09, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00]
    //   byte0: (size-1)&0x3=1, signed=0, mode=binary=1 → (1) | (0<<2) | (1<<3) = 0x09
    //   boundary LE32: 0x00002000 → [0x00, 0x20, 0x00, 0x00]
    //   hysteresis LE16: [0x00, 0x00]
    @Test func threshold_binary_configBytes() {
        let config = MWDataProcessor.Threshold(boundary: 8192, hysteresis: 0, mode: .binary, signed: false)
        let bytes = config.configBytes(inputLength: 2, inputChannels: 1, inputSigned: false)
        #expect(bytes == [0x09, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00])
    }

    // MARK: Comparator EQ -1 (signed) on 4-byte signed input (BINARY threshold output)
    // Expected multi-compare config (5 bytes):
    //   byte 0 bit-packed: is_signed=1 | length=3<<1 | op=EQ=0<<3 | mode=ABS=0<<6 = 0x07
    //   bytes 1-4: reference=-1 LE32 = 0xFF, 0xFF, 0xFF, 0xFF
    // (Replaces the legacy 7-byte ComparatorConfig — see C++ `dataprocessor_config.cpp`,
    //  the firmware-version branch at `MULTI_COMPARE = 1.2.3`. Modern firmware
    //  misreads the legacy layout; we now emit multi-compare unconditionally.)
    @Test func comparator_eq_minusOne_signed_configBytes() {
        let config = MWDataProcessor.Comparator(operation: .eq, reference: -1, signed: true)
        let bytes = config.configBytes(inputLength: 4, inputChannels: 1, inputSigned: true)
        #expect(bytes == [0x07, 0xFF, 0xFF, 0xFF, 0xFF])
    }

    // Comparator EQ +1 (signed) — same shape, different reference.
    @Test func comparator_eq_plusOne_signed_configBytes() {
        let config = MWDataProcessor.Comparator(operation: .eq, reference: 1, signed: true)
        let bytes = config.configBytes(inputLength: 4, inputChannels: 1, inputSigned: true)
        #expect(bytes == [0x07, 0x01, 0x00, 0x00, 0x00])
    }

    // Comparator EQ 1 (unsigned) on a 1-byte input (e.g. modulo-2 of a counter).
    // byte 0 = is_signed=0 | length=0<<1 | op=EQ=0<<3 | mode=ABS=0<<6 = 0x00
    // ref = [0x01]
    // Verifies the events_oddEvenPresses chain: each sub-comparator's reference
    // lands in the right byte so isOdd and isEven match different values.
    @Test func comparator_eq_one_unsigned_oneByte_configBytes() {
        let config = MWDataProcessor.Comparator(operation: .eq, reference: 1, signed: false)
        let bytes = config.configBytes(inputLength: 1, inputChannels: 1, inputSigned: false)
        #expect(bytes == [0x00, 0x01])
    }

    @Test func comparator_eq_zero_unsigned_oneByte_configBytes() {
        let config = MWDataProcessor.Comparator(operation: .eq, reference: 0, signed: false)
        let bytes = config.configBytes(inputLength: 1, inputChannels: 1, inputSigned: false)
        #expect(bytes == [0x00, 0x00])
    }
}

// MARK: - Full pipeline ADD commands

@Suite("Data Processor — Full pipeline byte sequences")
struct MWDataProcessorPipelineTests {

    let device: MetaWearDevice = {
        let transport = MockBLETransport()
        return MetaWearDevice(identifier: UUID(), transport: transport)
    }()

    // C++ test_freefall — five ADD commands in sequence:
    //   1. RSS of accelerometer
    //   2. Average(4) of RSS output (handle id=0)
    //   3. Threshold(binary, boundary=8192) of Average output (handle id=1)
    //   4. Comparator(eq, -1) of Threshold output (handle id=2)
    //   5. Comparator(eq, +1) of Threshold output (handle id=2)

    @Test func freefall_step1_rss() async {
        let cmd = await device.buildProcessorAddCommand(
            source: MWAccelerometerSignal(),
            config: MWDataProcessor.RSS())
        #expect(cmd == [0x09, 0x02, 0x03, 0x04, 0xFF, 0xA0, 0x07, 0xA5, 0x01])
    }

    @Test func freefall_step2_average() async {
        // RSS output: 1ch × 2B unsigned → sourceConfig=0x20, proc_id=0
        let rssHandle = MWProcessorHandle(id: 0, nChannels: 1, channelSize: 2, isSigned: false)
        let cmd = await device.buildProcessorAddCommand(
            source: rssHandle,
            config: MWDataProcessor.Average(sampleSize: 4))
        #expect(cmd == [0x09, 0x02, 0x09, 0x03, 0x00, 0x20, 0x03, 0x05, 0x04])
    }

    @Test func freefall_step3_threshold() async {
        // Average output: 1ch × 2B unsigned → sourceConfig=0x20, proc_id=1
        let avgHandle = MWProcessorHandle(id: 1, nChannels: 1, channelSize: 2, isSigned: false)
        let cmd = await device.buildProcessorAddCommand(
            source: avgHandle,
            config: MWDataProcessor.Threshold(boundary: 8192, hysteresis: 0, mode: .binary, signed: false))
        // Expected: [0x09, 0x02, 0x09, 0x03, 0x01, 0x20, 0x0d, 0x09, 0x00, 0x20, 0x00, 0x00, 0x00, 0x00]
        #expect(cmd[0] == 0x09)
        #expect(cmd[1] == 0x02)
        #expect(cmd[2] == 0x09)   // src module = dataProcessor
        #expect(cmd[3] == 0x03)   // src register = NOTIFY
        #expect(cmd[4] == 0x01)   // src data_id = proc_id 1
        #expect(cmd[5] == 0x20)   // src_config = 0x20
        #expect(cmd[6] == 0x0D)   // proc_type = Threshold
        #expect(cmd[7] == 0x09)   // config byte0
        // boundary = 8192 = 0x00002000
        #expect(cmd[8]  == 0x00)
        #expect(cmd[9]  == 0x20)
        #expect(cmd[10] == 0x00)
        #expect(cmd[11] == 0x00)
        // hysteresis = 0
        #expect(cmd[12] == 0x00)
        #expect(cmd[13] == 0x00)
    }

    @Test func freefall_step4_comparatorEqMinusOne() async {
        // Threshold BINARY output: 1ch × 4B signed → sourceConfig = (4-1)<<5 | 0 = 0x60, proc_id=2
        // Multi-compare config (5 bytes): byte0 packs {signed=1, length=3, op=EQ, mode=ABS} = 0x07,
        // followed by 4-byte LE reference (-1 = 0xFFFFFFFF).
        let threshHandle = MWProcessorHandle(id: 2, nChannels: 1, channelSize: 4, isSigned: true)
        let cmd = await device.buildProcessorAddCommand(
            source: threshHandle,
            config: MWDataProcessor.Comparator(operation: .eq, reference: -1, signed: true))
        #expect(cmd[5] == 0x60)   // src_config = (4-1)<<5 = 0x60
        #expect(cmd[6] == 0x06)   // proc_type = Comparator
        #expect(cmd[7] == 0x07)   // byte0: is_signed=1 | length=3<<1 | op=EQ=0<<3 | mode=ABS=0<<6
        #expect(cmd[8] == 0xFF)   // ref=-1 LE32 byte 0
        #expect(cmd[9] == 0xFF)
        #expect(cmd[10] == 0xFF)
        #expect(cmd[11] == 0xFF)
        #expect(cmd.count == 12)  // header(7) + config(5) — no trailing padding
    }

    // C++ test_led_controller — two ADD commands:
    //   1. Counter(outputSize=1) of switch
    //   2. Math(modulo, rhs=2, unsigned, outputSize=4) of Counter output
    @Test func ledController_step1_counter() async {
        let cmd = await device.buildProcessorAddCommand(
            source: MWSwitchSignal(),
            config: MWDataProcessor.Counter(outputSize: 1))
        #expect(cmd == [0x09, 0x02, 0x01, 0x01, 0xFF, 0x00, 0x02, 0x10])
    }

    @Test func ledController_step2_math_modulo() async {
        // Counter output: 1ch × 1B unsigned → sourceConfig=0x00, proc_id=0
        let counterHandle = MWProcessorHandle(id: 0, nChannels: 1, channelSize: 1, isSigned: false)
        let cmd = await device.buildProcessorAddCommand(
            source: counterHandle,
            config: MWDataProcessor.Math(operation: .modulo, rhs: 2, signed: false, outputSize: 4))
        #expect(cmd[0] == 0x09)
        #expect(cmd[1] == 0x02)
        #expect(cmd[4] == 0x00)   // proc_id
        #expect(cmd[5] == 0x00)   // src_config = (1-1)<<5 = 0x00
        #expect(cmd[6] == 0x09)   // proc_type = Math
        // Math config: [0x03, 0x04, 0x02, 0x00, 0x00, 0x00, 0x00]
        #expect(cmd[7] == 0x03)
        #expect(cmd[8] == 0x04)   // modulo
        #expect(cmd[9] == 0x02)   // rhs=2
        #expect(cmd[10] == 0x00)
        #expect(cmd[11] == 0x00)
        #expect(cmd[12] == 0x00)
        #expect(cmd[13] == 0x00)
    }
}

// MARK: - Processor output metadata

@Suite("Data Processor — Output metadata")
struct MWDataProcessorOutputTests {

    @Test func rss_outputLength_from6byteAccel() {
        let config = MWDataProcessor.RSS()
        #expect(config.outputLength(inputLength: 6, inputChannels: 3) == 2)
        #expect(config.outputChannels(inputLength: 6, inputChannels: 3) == 1)
        #expect(config.outputSigned(inputSigned: true) == false)
    }

    @Test func counter_outputLength() {
        let config = MWDataProcessor.Counter(outputSize: 1)
        #expect(config.outputLength(inputLength: 1, inputChannels: 1) == 1)
        #expect(config.outputChannels(inputLength: 1, inputChannels: 1) == 1)
    }

    @Test func average_outputMatchesInput() {
        let config = MWDataProcessor.Average(sampleSize: 4)
        #expect(config.outputLength(inputLength: 2, inputChannels: 1) == 2)
        #expect(config.outputChannels(inputLength: 2, inputChannels: 1) == 1)
    }

    @Test func threshold_binary_outputLength_is4() {
        let config = MWDataProcessor.Threshold(boundary: 0, mode: .binary)
        #expect(config.outputLength(inputLength: 2, inputChannels: 1) == 4)
        #expect(config.outputChannels(inputLength: 2, inputChannels: 1) == 1)
        #expect(config.outputSigned(inputSigned: false) == true)
    }

    @Test func threshold_absolute_outputMatchesInput() {
        let config = MWDataProcessor.Threshold(boundary: 0, mode: .absolute)
        #expect(config.outputLength(inputLength: 2, inputChannels: 1) == 2)
    }

    @Test func comparator_outputMatchesInput() {
        let config = MWDataProcessor.Comparator(operation: .eq, reference: 0)
        #expect(config.outputLength(inputLength: 4, inputChannels: 1) == 4)
    }

    @Test func math_outputSize_overrideApplied() {
        let config = MWDataProcessor.Math(operation: .modulo, rhs: 2, signed: false, outputSize: 4)
        // input 1ch × 1B, override output to 4B → outputLength = 4 * 1ch = 4
        #expect(config.outputLength(inputLength: 1, inputChannels: 1) == 4)
    }
}

// MARK: - Passthrough config

@Suite("Data Processor — Passthrough")
struct MWDataProcessorPassthroughTests {

    @Test func passthrough_all_configBytes() {
        let config = MWDataProcessor.Passthrough(mode: .all, count: 0)
        let bytes = config.configBytes(inputLength: 1, inputChannels: 1, inputSigned: false)
        #expect(bytes == [0x00, 0x00, 0x00])
    }

    @Test func passthrough_count_configBytes() {
        let config = MWDataProcessor.Passthrough(mode: .count, count: 10)
        let bytes = config.configBytes(inputLength: 1, inputChannels: 1, inputSigned: false)
        #expect(bytes[0] == 0x02)   // mode=count
        #expect(bytes[1] == 0x0A)   // count low byte
        #expect(bytes[2] == 0x00)   // count high byte
    }
}

// MARK: - Time config

@Suite("Data Processor — Time")
struct MWDataProcessorTimeTests {

    @Test func time_absolute_configBytes() {
        // inputLength=6 (accel), mode=absolute, period=500ms
        let config = MWDataProcessor.Time(periodMs: 500, mode: .absolute)
        let bytes = config.configBytes(inputLength: 6, inputChannels: 3, inputSigned: true)
        // byte0: (6-1)&0x7 | (0<<3) = 5 | 0 = 0x05
        #expect(bytes[0] == 0x05)
        // period=500=0x1F4 LE32: [0xF4, 0x01, 0x00, 0x00]
        #expect(bytes[1] == 0xF4)
        #expect(bytes[2] == 0x01)
        #expect(bytes[3] == 0x00)
        #expect(bytes[4] == 0x00)
    }
}

// MARK: - Sample delay config

@Suite("Data Processor — Sample")
struct MWDataProcessorSampleTests {

    @Test func sample_configBytes() {
        let config = MWDataProcessor.Sample(binSize: 3)
        let bytes = config.configBytes(inputLength: 6, inputChannels: 3, inputSigned: true)
        // [inputLength-1, binSize] = [5, 3]
        #expect(bytes == [5, 3])
    }
}

// MARK: - Delta  (type 0x0C)
//
// DeltaConfig wire format (5 bytes):
//   byte 0: length-1 (2 bits) | is_signed (1 bit) | mode (3 bits) | padding (2 bits)
//   bytes 1-4: magnitude (int32 LE)

@Suite("Data Processor — Delta")
struct MWDataProcessorDeltaTests {

    // Barometer pressure signal: 4-byte UInt32 at 0x12/0x01.
    // `TestDeltaSetPrevious`: DIFFERENTIAL, magnitude 25331.25 Pa (scaled by ×256 → 6484800 = 0x62F340).
    @Test func delta_differential_configBytes() {
        let config = MWDataProcessor.Delta(magnitude: 6_484_800, mode: .differential)
        let bytes = config.configBytes(inputLength: 4, inputChannels: 1, inputSigned: false)
        // byte0 = (4-1) & 0x3 | (unsigned<<2) | (DIFFERENTIAL=1 << 3) = 3 | 0 | 8 = 0x0B
        #expect(bytes == [0x0B, 0x40, 0xF3, 0x62, 0x00])
    }

    @Test func delta_absolute_signed_configBytes() {
        // Accelerometer Z (2 bytes, signed), magnitude 1024, ABSOLUTE.
        let config = MWDataProcessor.Delta(magnitude: 1024, mode: .absolute)
        let bytes = config.configBytes(inputLength: 2, inputChannels: 1, inputSigned: true)
        // byte0 = (2-1)&3 | (1<<2) | (0<<3) = 1 | 4 = 0x05
        #expect(bytes == [0x05, 0x00, 0x04, 0x00, 0x00])
    }

    @Test func delta_binary_reducesOutputToInt8() {
        let config = MWDataProcessor.Delta(magnitude: 100, mode: .binary)
        #expect(config.outputLength(inputLength: 4, inputChannels: 1) == 1)
        #expect(config.outputSigned(inputSigned: false) == true)
    }
}

// MARK: - Pulse  (type 0x0B)

@Suite("Data Processor — Pulse")
struct MWDataProcessorPulseTests {

    // MARK: test_acc_z_pulse_setup  (AREA mode, threshold 2048, width 16 on ±16g acc Z axis)
    // Expected: [0x09, 0x02, 0x03, 0x04, 0xFF, 0x24, 0x0B, 0x01, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00, 0x10, 0x00]
    @Test func pulse_area_configBytes() {
        let config = MWDataProcessor.Pulse(output: .area, threshold: 2048, width: 16)
        // Z-axis component has length 2 (single Int16 channel).
        let bytes = config.configBytes(inputLength: 2, inputChannels: 1, inputSigned: true)
        // [length-1=1, trigger=0, output=AREA(1), threshold=0x0800 LE, width=16 LE]
        #expect(bytes == [0x01, 0x00, 0x01, 0x00, 0x08, 0x00, 0x00, 0x10, 0x00])
    }

    // MARK: test_pulse_setup  (GPIO ADC PEAK 500, width 10)
    // Expected: [0x09, 0x02, 0x05, 0xC7, 0x00, 0x20, 0x0B, 0x01, 0x00, 0x02, 0xF4, 0x01, 0x00, 0x00, 0x0A, 0x00]
    @Test func pulse_peak_configBytes_gpioAdc() {
        let config = MWDataProcessor.Pulse(output: .peak, threshold: 500, width: 10)
        let bytes = config.configBytes(inputLength: 2, inputChannels: 1, inputSigned: false)
        #expect(bytes == [0x01, 0x00, 0x02, 0xF4, 0x01, 0x00, 0x00, 0x0A, 0x00])
    }

    @Test func pulse_widthMode_outputIsUInt32() {
        let config = MWDataProcessor.Pulse(output: .width, threshold: 1, width: 1)
        #expect(config.outputLength(inputLength: 2, inputChannels: 1) == 4)
        #expect(config.outputSigned(inputSigned: true) == false)
    }

    @Test func pulse_areaMode_preservesInputSign() {
        let config = MWDataProcessor.Pulse(output: .area, threshold: 1, width: 1)
        #expect(config.outputLength(inputLength: 2, inputChannels: 1) == 2)
        #expect(config.outputSigned(inputSigned: true) == true)
    }
}

// MARK: - Buffer  (type 0x0F)

@Suite("Data Processor — Buffer")
struct MWDataProcessorBufferTests {

    // MARK: test_commands (fuser setup) — gyro buffer on 6-byte signal
    // Expected config byte = (6-1) = 0x05
    @Test func buffer_gyroConfigByte() {
        let config = MWDataProcessor.Buffer()
        let bytes = config.configBytes(inputLength: 6, inputChannels: 3, inputSigned: true)
        #expect(bytes == [0x05])
    }

    @Test func buffer_singleByteInput() {
        let config = MWDataProcessor.Buffer()
        let bytes = config.configBytes(inputLength: 1, inputChannels: 1, inputSigned: false)
        #expect(bytes == [0x00])
    }
}

// MARK: - Packer  (type 0x10)

@Suite("Data Processor — Packer")
struct MWDataProcessorPackerTests {

    // MARK: TestPacker.test_create  (temp signal 2B, count=4)
    // Expected: [0x09, 0x02, 0x04, 0xC1, 0x01, 0x20, 0x10, 0x01, 0x03]
    @Test func packer_tempCount4_configBytes() {
        let config = MWDataProcessor.Packer(count: 4)
        let bytes = config.configBytes(inputLength: 2, inputChannels: 1, inputSigned: true)
        // byte0 = 2-1 = 0x01, byte1 = 4-1 = 0x03
        #expect(bytes == [0x01, 0x03])
    }

    // MARK: TestAccounter.test_count_and_time  (accel 6B, count=2)
    // From expected sequence: packer config bytes = [0x05, 0x01]
    @Test func packer_accCount2_configBytes() {
        let config = MWDataProcessor.Packer(count: 2)
        let bytes = config.configBytes(inputLength: 6, inputChannels: 3, inputSigned: true)
        // byte0 = 6-1 = 0x05, byte1 = 2-1 = 0x01
        #expect(bytes == [0x05, 0x01])
    }
}

// MARK: - Accounter  (type 0x11)

@Suite("Data Processor — Accounter")
struct MWDataProcessorAccounterTests {

    // MARK: TestAccounter.test_create  (time mode, accel signal)
    // Expected full command: [0x09, 0x02, 0x03, 0x04, 0xFF, 0xA0, 0x11, 0x31, 0x03]
    // Config bytes: mode=1, length=4 → byte0 = 1 | ((4-1) << 4) = 0x31, prescale=3 → byte1 = 0x03
    @Test func accounter_time_configBytes() {
        let config = MWDataProcessor.Accounter(mode: .time)
        let bytes = config.configBytes(inputLength: 6, inputChannels: 3, inputSigned: true)
        #expect(bytes == [0x31, 0x03])
    }

    // MARK: TestAccounterCount.test_create  (count mode)
    // Expected: [0x09, 0x02, 0x03, 0x04, 0xFF, 0xA0, 0x11, 0x30, 0x03]
    @Test func accounter_count_configBytes() {
        let config = MWDataProcessor.Accounter(mode: .count)
        let bytes = config.configBytes(inputLength: 6, inputChannels: 3, inputSigned: true)
        // byte0 = 0 | (3 << 4) = 0x30
        #expect(bytes == [0x30, 0x03])
    }

    @Test func accounter_outputLength_includesAccountBytes() {
        let config = MWDataProcessor.Accounter(mode: .time)
        // Accel 6B + 4-byte account = 10B output.
        #expect(config.outputLength(inputLength: 6, inputChannels: 3) == 10)
    }
}

// MARK: - Fuser  (type 0x1B)

@Suite("Data Processor — Fuser")
struct MWDataProcessorFuserTests {

    // MARK: TestFuserAccounter.test_commands  (acc primary, one buffer ref with ID 0)
    // Expected full command:
    //   [0x09, 0x02, 0x03, 0x04, 0xFF, 0xA0, 0x1B, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    // Config: count=1, references[0]=0, rest 0 (13 bytes total).
    @Test func fuser_singleReference_configBytes() {
        let config = MWDataProcessor.Fuser(bufferIDs: [0])
        let bytes = config.configBytes(inputLength: 6, inputChannels: 3, inputSigned: true)
        let expected: [UInt8] = [0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        #expect(bytes == expected)
    }

    @Test func fuser_twoReferences_configBytes() {
        let config = MWDataProcessor.Fuser(bufferIDs: [3, 5])
        let bytes = config.configBytes(inputLength: 6, inputChannels: 3, inputSigned: true)
        // count=2, refs[0]=3, refs[1]=5, rest 0 — 13 bytes total.
        let expected: [UInt8] = [0x02, 0x03, 0x05, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        #expect(bytes == expected)
    }

    @Test func fuser_configBytes_alwaysThirteenBytes() {
        let config = MWDataProcessor.Fuser(bufferIDs: [])
        let bytes = config.configBytes(inputLength: 6, inputChannels: 3, inputSigned: true)
        #expect(bytes.count == 13)
        #expect(bytes[0] == 0)
    }
}
