import Testing
import Foundation
@testable import MetaWear

// MARK: - Helpers

private func connectedDevice() async throws -> (MetaWearDevice, MockBLETransport) {
    let transport = MockBLETransport()
    await transport.setReadResponse(Data("MbientLab".utf8),   for: MWUUIDs.manufacturerName)
    await transport.setReadResponse(Data("MetaMotionS".utf8), for: MWUUIDs.modelNumber)
    await transport.setReadResponse(Data("A0B1C2".utf8),      for: MWUUIDs.serialNumber)
    await transport.setReadResponse(Data("1.5.0".utf8),       for: MWUUIDs.firmwareRevision)
    await transport.setReadResponse(Data("0.4".utf8),         for: MWUUIDs.hardwareRevision)

    let device = MetaWearDevice(identifier: UUID(), transport: transport)
    var respondedTo = Set<Data>()
    let discovery = Task {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 3_000_000)
            let cmds = await transport.writtenCommands
            for cmd in cmds {
                guard cmd.count >= 2, (cmd[1] & 0x80) != 0, !respondedTo.contains(cmd) else { continue }
                respondedTo.insert(cmd)
                if cmd[0] == 0x0B && cmd[1] == 0x84 {
                    await transport.inject(notification: Data([0x0B, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00]),
                                           to: MWUUIDs.notify)
                    continue
                }
                let impl: UInt8 = [0x03, 0x05, 0x0B, 0x13, 0x12, 0x15, 0x19].contains(cmd[0]) ? 0x01 : 0xFF
                await transport.inject(notification: Data([cmd[0], 0x80, impl, 0x00]), to: MWUUIDs.notify)
            }
        }
    }
    try await device.connect()
    discovery.cancel()
    return (device, transport)
}

// MARK: - GPIO output commands

@Suite("MWGPIO — Output Commands")
struct GPIOOutputCommandTests {

    @Test func setHigh_correctBytes() {
        let cmd = MWGPIO.SetHigh(pin: 2)
        #expect(cmd.commandData == Data([0x05, 0x01, 0x02]))
    }

    @Test func setLow_correctBytes() {
        let cmd = MWGPIO.SetLow(pin: 0)
        #expect(cmd.commandData == Data([0x05, 0x02, 0x00]))
    }

    @Test func setPullUp_correctBytes() {
        let cmd = MWGPIO.SetPull(pin: 1, pull: .up)
        #expect(cmd.commandData == Data([0x05, 0x03, 0x01]))
    }

    @Test func setPullDown_correctBytes() {
        let cmd = MWGPIO.SetPull(pin: 1, pull: .down)
        #expect(cmd.commandData == Data([0x05, 0x04, 0x01]))
    }

    @Test func setNoPull_correctBytes() {
        let cmd = MWGPIO.SetPull(pin: 3, pull: .none)
        #expect(cmd.commandData == Data([0x05, 0x05, 0x03]))
    }

    @Test func configurePinChange_rising() {
        let cmd = MWGPIO.ConfigurePinChange(pin: 0, type: .rising)
        #expect(cmd.commandData == Data([0x05, 0x09, 0x00, 0x01]))
    }

    @Test func configurePinChange_falling() {
        let cmd = MWGPIO.ConfigurePinChange(pin: 0, type: .falling)
        #expect(cmd.commandData == Data([0x05, 0x09, 0x00, 0x02]))
    }

    @Test func configurePinChange_any() {
        let cmd = MWGPIO.ConfigurePinChange(pin: 2, type: .any)
        #expect(cmd.commandData == Data([0x05, 0x09, 0x02, 0x03]))
    }

    // Python test_set_pin_change_type reference vectors.
    @Test func configurePinChange_pin6_falling() {
        #expect(MWGPIO.ConfigurePinChange(pin: 6, type: .falling).commandData
                == Data([0x05, 0x09, 0x06, 0x02]))
    }

    @Test func configurePinChange_pin7_rising() {
        #expect(MWGPIO.ConfigurePinChange(pin: 7, type: .rising).commandData
                == Data([0x05, 0x09, 0x07, 0x01]))
    }

    // Python test_pin_monitor_start / test_pin_monitor_stop reference vectors.
    @Test func startPinMonitor_pin5() {
        #expect(MWGPIO.StartPinMonitor(pin: 5).commandData
                == Data([0x05, 0x0B, 0x05, 0x01]))
    }

    @Test func stopPinMonitor_pin6() {
        #expect(MWGPIO.StopPinMonitor(pin: 6).commandData
                == Data([0x05, 0x0B, 0x06, 0x00]))
    }
}

// MARK: - GPIO read command builders (byte-only, no transport)

@Suite("MWGPIO — Read Command Bytes")
struct GPIOReadCommandTests {

    // Python test_read_digital_input
    @Test func digitalRead_pin4() {
        #expect(MWGPIO.DigitalRead(pin: 4).commandData == Data([0x05, 0x88, 0x04]))
    }

    // Python test_read_digital_input_silent
    @Test func digitalRead_silent_pin4() {
        #expect(MWGPIO.DigitalRead(pin: 4, silent: true).commandData
                == Data([0x05, 0xC8, 0x04]))
    }

    // Python test_read_analog_input (ABS_REF)
    @Test func analogRead_absRef_pin3() {
        #expect(MWGPIO.AnalogRead(mode: .absoluteReference, pin: 3).commandData
                == Data([0x05, 0x86, 0x03]))
    }

    // Python test_read_analog_input (ADC)
    @Test func analogRead_adc_pin2() {
        #expect(MWGPIO.AnalogRead(mode: .adc, pin: 2).commandData
                == Data([0x05, 0x87, 0x02]))
    }

    // Python test_read_analog_input_silent (ABS_REF)
    @Test func analogRead_silent_absRef_pin3() {
        #expect(MWGPIO.AnalogRead(mode: .absoluteReference, pin: 3, silent: true).commandData
                == Data([0x05, 0xC6, 0x03]))
    }

    // Python test_read_analog_input_silent (ADC)
    @Test func analogRead_silent_adc_pin2() {
        #expect(MWGPIO.AnalogRead(mode: .adc, pin: 2, silent: true).commandData
                == Data([0x05, 0xC7, 0x02]))
    }

    // Python TestGpioEnhancedAnalogRead.test_read_analog_no_parameters — defaults expand
    // to [pullup=0xFF, pulldown=0xFF, delay=0x00, virtual=0xFF] with silent bit on.
    @Test func analogRead_enhanced_defaults_absRef_pin3() {
        let cmd = MWGPIO.AnalogRead(
            mode: .absoluteReference, pin: 3,
            silent: true, parameters: .defaults
        ).commandData
        #expect(cmd == Data([0x05, 0xC6, 0x03, 0xFF, 0xFF, 0x00, 0xFF]))
    }

    @Test func analogRead_enhanced_defaults_adc_pin2() {
        let cmd = MWGPIO.AnalogRead(
            mode: .adc, pin: 2,
            silent: true, parameters: .defaults
        ).commandData
        #expect(cmd == Data([0x05, 0xC7, 0x02, 0xFF, 0xFF, 0x00, 0xFF]))
    }

    // Python TestGpioEnhancedAnalogRead.test_read_analog_with_parameters
    // pullup=1, pulldown=2, delay_us=10 (→ 10>>2 = 2), virtual=0x15. Non-silent.
    @Test func analogRead_enhanced_params_absRef_pin3() {
        let p = MWGPIO.AnalogReadParameters(
            pullupPin: 1, pulldownPin: 2, virtualPin: 0x15, delayMicroseconds: 10
        )
        let cmd = MWGPIO.AnalogRead(mode: .absoluteReference, pin: 3, parameters: p).commandData
        #expect(cmd == Data([0x05, 0x86, 0x03, 0x01, 0x02, 0x02, 0x15]))
    }

    @Test func analogRead_enhanced_params_adc_pin2() {
        let p = MWGPIO.AnalogReadParameters(
            pullupPin: 1, pulldownPin: 2, virtualPin: 0x15, delayMicroseconds: 10
        )
        let cmd = MWGPIO.AnalogRead(mode: .adc, pin: 2, parameters: p).commandData
        #expect(cmd == Data([0x05, 0x87, 0x02, 0x01, 0x02, 0x02, 0x15]))
    }

    // Delay encoding — firmware divides by 4. Max 1020 µs clamps to byte 0xFF.
    @Test func analogParameters_delayEncoding() {
        #expect(MWGPIO.AnalogReadParameters(delayMicroseconds: 0).encodedDelay    == 0)
        #expect(MWGPIO.AnalogReadParameters(delayMicroseconds: 4).encodedDelay    == 1)
        #expect(MWGPIO.AnalogReadParameters(delayMicroseconds: 40).encodedDelay   == 10)
        #expect(MWGPIO.AnalogReadParameters(delayMicroseconds: 1020).encodedDelay == 0xFF)
    }

    @Test func analogParameters_delayClampsAt1020() {
        // Over-max values clamp to 1020 before encoding.
        #expect(MWGPIO.AnalogReadParameters(delayMicroseconds: 5000).encodedDelay == 0xFF)
    }

    @Test func analogParameters_unusedPinSentinel() {
        #expect(MWGPIO.AnalogReadParameters.unusedPin == 0xFF)
        let d = MWGPIO.AnalogReadParameters.defaults
        #expect(d.pullupPin   == 0xFF)
        #expect(d.pulldownPin == 0xFF)
        #expect(d.virtualPin  == 0xFF)
        #expect(d.delayMicroseconds == 0)
    }
}

// MARK: - GPIO reads

@Suite("MWGPIO — One-Shot Reads")
struct GPIOReadTests {

    @Test func readDigital_high() async throws {
        let (device, transport) = try await connectedDevice()

        let readTask = Task { try await device.readDigital(pin: 0) }
        try await Task.sleep(nanoseconds: 5_000_000)
        // Response: [0x05, 0x88, 0x00, 0x01]  (pin=0, state=HIGH)
        await transport.inject(notification: Data([0x05, 0x88, 0x00, 0x01]), to: MWUUIDs.notify)
        let isHigh = try await readTask.value
        #expect(isHigh == true)
    }

    @Test func readDigital_low() async throws {
        let (device, transport) = try await connectedDevice()

        let readTask = Task { try await device.readDigital(pin: 1) }
        try await Task.sleep(nanoseconds: 5_000_000)
        await transport.inject(notification: Data([0x05, 0x88, 0x01, 0x00]), to: MWUUIDs.notify)
        let isHigh = try await readTask.value
        #expect(isHigh == false)
    }

    @Test func readDigital_sendsCorrectCommand() async throws {
        let (device, transport) = try await connectedDevice()

        let readTask = Task { try? await device.readDigital(pin: 2) }
        try await Task.sleep(nanoseconds: 3_000_000)
        // Inject a response so the task doesn't hang
        await transport.inject(notification: Data([0x05, 0x88, 0x02, 0x00]), to: MWUUIDs.notify)
        _ = await readTask.value

        let cmds = await transport.writtenCommands
        let readCmd = cmds.first { $0 == Data([0x05, 0x88, 0x02]) }
        #expect(readCmd != nil, "readDigital must send [0x05, 0x88, pin]")
    }

    @Test func readAnalogADC_sendsCorrectCommand() async throws {
        let (device, transport) = try await connectedDevice()

        let readTask = Task { try? await device.readAnalogADC(pin: 1) }
        try await Task.sleep(nanoseconds: 3_000_000)
        await transport.inject(notification: Data([0x05, 0x87, 0x01, 0xE8, 0x03]), to: MWUUIDs.notify)
        _ = await readTask.value

        let cmds = await transport.writtenCommands
        let readCmd = cmds.first { $0 == Data([0x05, 0x87, 0x01]) }
        #expect(readCmd != nil, "readAnalogADC must send [0x05, 0x87, pin]")
    }

    @Test func readAnalogADC_parsesValue() async throws {
        let (device, transport) = try await connectedDevice()

        let readTask = Task { try await device.readAnalogADC(pin: 0) }
        try await Task.sleep(nanoseconds: 5_000_000)
        // 1000 = 0x03E8 LE
        await transport.inject(notification: Data([0x05, 0x87, 0x00, 0xE8, 0x03]), to: MWUUIDs.notify)
        let value = try await readTask.value
        #expect(value == 1000)
    }

    @Test func readAnalogAbsolute_sendsCorrectCommand() async throws {
        let (device, transport) = try await connectedDevice()

        let readTask = Task { try? await device.readAnalogAbsolute(pin: 0) }
        try await Task.sleep(nanoseconds: 3_000_000)
        await transport.inject(notification: Data([0x05, 0x86, 0x00, 0x10, 0x27]), to: MWUUIDs.notify)
        _ = await readTask.value

        let cmds = await transport.writtenCommands
        let readCmd = cmds.first { $0 == Data([0x05, 0x86, 0x00]) }
        #expect(readCmd != nil, "readAnalogAbsolute must send [0x05, 0x86, pin]")
    }
}

// MARK: - GPIO pin-change streaming

@Suite("MWGPIO — Pin Change Stream")
struct GPIOPinChangeStreamTests {

    @Test func pinChangeStream_enableCommand() {
        let sensor = MWGPIOPinChange(pin: 1, type: .rising)
        #expect(sensor.enableCommand == Data([0x05, 0x0B, 0x01, 0x01]))
    }

    @Test func pinChangeStream_disableCommand() {
        let sensor = MWGPIOPinChange(pin: 2, type: .any)
        #expect(sensor.disableCommand == Data([0x05, 0x0B, 0x02, 0x00]))
    }

    @Test func pinChangeStream_configureCommand() {
        let sensor = MWGPIOPinChange(pin: 0, type: .falling)
        #expect(sensor.configureCommands.first == Data([0x05, 0x09, 0x00, 0x02]))
    }

    @Test func pinChangeStream_parseSample_high() throws {
        let sensor = MWGPIOPinChange(pin: 0, type: .any)
        let packet = Data([0x05, 0x0A, 0x00, 0x01])
        let sample = try sensor.parseSample(from: packet)
        #expect(sample.pin == 0)
        #expect(sample.isHigh == true)
    }

    @Test func pinChangeStream_parseSample_low() throws {
        let sensor = MWGPIOPinChange(pin: 2, type: .falling)
        let packet = Data([0x05, 0x0A, 0x02, 0x00])
        let sample = try sensor.parseSample(from: packet)
        #expect(sample.pin == 2)
        #expect(sample.isHigh == false)
    }

    @Test func pinChangeStream_deliversNotifications() async throws {
        let (device, transport) = try await connectedDevice()
        let sensor = MWGPIOPinChange(pin: 0, type: .any)

        let stream = try await device.startStream(sensor, usePacked: false)

        let received = MWAtomic<[MWGPIOSample]>([])
        let consumer = Task {
            for try await sample in stream {
                received.update { $0.append(sample.value) }
            }
        }
        defer { consumer.cancel() }

        try await Task.sleep(nanoseconds: 5_000_000)
        await transport.inject(notification: Data([0x05, 0x0A, 0x00, 0x01]), to: MWUUIDs.notify)
        await transport.inject(notification: Data([0x05, 0x0A, 0x00, 0x00]), to: MWUUIDs.notify)
        try await Task.sleep(nanoseconds: 5_000_000)

        #expect(received.value.count == 2)
        #expect(received.value[0].isHigh == true)
        #expect(received.value[1].isHigh == false)
    }
}

// MARK: - LED multi-channel

@Suite("MWLED — Multi-Channel")
struct LEDMultiChannelTests {

    @Test func setLED_sendsAllChannels() async throws {
        let (device, transport) = try await connectedDevice()

        try await device.setLED(red: .solid, green: .blink, blue: .breathe, autoPlay: true)

        let cmds = await transport.writtenCommands
        // Should have SetPattern for green, red, blue + Play
        let ledCmds = cmds.filter { $0.count >= 2 && $0[0] == 0x02 }
        let patterns = ledCmds.filter { $0[1] == 0x03 }
        let plays    = ledCmds.filter { $0[1] == 0x01 }
        #expect(patterns.count == 3, "setLED(r:g:b:) must send 3 SetPattern commands")
        #expect(plays.count == 1,    "setLED(autoPlay: true) must send Play")
    }

    @Test func setLED_onlySetsNonNilChannels() async throws {
        let (device, transport) = try await connectedDevice()

        try await device.setLED(red: .flash, autoPlay: false)

        let cmds = await transport.writtenCommands
        let ledCmds = cmds.filter { $0.count >= 2 && $0[0] == 0x02 }
        let patterns = ledCmds.filter { $0[1] == 0x03 }
        let plays    = ledCmds.filter { $0[1] == 0x01 }
        #expect(patterns.count == 1, "Only one channel configured")
        #expect(plays.isEmpty, "autoPlay: false must not send Play")
    }

    @Test func setLED_colorBytes() async throws {
        let (device, transport) = try await connectedDevice()

        try await device.setLED(red: .solid, green: .solid, blue: .solid, autoPlay: false)

        let cmds = await transport.writtenCommands
        let patterns = cmds.filter { $0.count >= 4 && $0[0] == 0x02 && $0[1] == 0x03 }
        let colors = Set(patterns.map { $0[2] })
        // Color bytes: green=0, red=1, blue=2
        #expect(colors == Set([0, 1, 2]))
    }

    @Test func stopLED_sendsStopCommand() async throws {
        let (device, transport) = try await connectedDevice()

        try await device.stopLED(clearPattern: true)

        let cmds = await transport.writtenCommands
        let stopCmd = cmds.first { $0 == Data([0x02, 0x02, 0x01]) }
        #expect(stopCmd != nil)
    }
}

// MARK: - Helpers

private final class MWAtomic<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}
