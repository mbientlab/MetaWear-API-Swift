import Testing
import Foundation
@testable import MetaWear

// MARK: - Switch

@Suite("Switch Commands")
struct SwitchCommandTests {

    let sensor = MWSwitch()

    @Test func enableCommand() {
        #expect(sensor.enableCommand == Data([0x01, 0x01, 0x01]))
    }

    @Test func disableCommand() {
        #expect(sensor.disableCommand == Data([0x01, 0x01, 0x00]))
    }

    @Test func startCommand_isEmpty() {
        // Switch uses a single subscribe command (enableCommand); startCommand is a no-op
        #expect(sensor.startCommand.isEmpty)
    }

    @Test func stopCommand_isEmpty() {
        // Switch uses a single unsubscribe command (disableCommand); stopCommand is a no-op
        #expect(sensor.stopCommand.isEmpty)
    }

    @Test func module_isSwitch() {
        #expect(sensor.module == .switch_)
    }

    @Test func noPackedRegister() {
        #expect(sensor.packedDataRegister == nil)
    }

    @Test func noConfigureCommands() {
        #expect(sensor.configureCommands.isEmpty)
    }

    @Test func parsesPressed() throws {
        let packet = Data([0x01, 0x01, 0x01])
        #expect(try sensor.parseSample(from: packet) == true)
    }

    @Test func parsesReleased() throws {
        let packet = Data([0x01, 0x01, 0x00])
        #expect(try sensor.parseSample(from: packet) == false)
    }

    @Test func parsesTooShort_throws() {
        let short = Data([0x01, 0x01])
        #expect(throws: (any Error).self) {
            try sensor.parseSample(from: short)
        }
    }

    // Python test_mbl_mw_switch_get_data_pushed — state byte 0x01 → pressed.
    @Test func parsesPressed_pythonVector() throws {
        #expect(try sensor.parseSample(from: Data([0x01, 0x01, 0x01])) == true)
    }

    // Python test_mbl_mw_switch_get_data_released — state byte 0x00 → released.
    @Test func parsesReleased_pythonVector() throws {
        #expect(try sensor.parseSample(from: Data([0x01, 0x01, 0x00])) == false)
    }

    // Any non-zero state byte is treated as "pressed" only when it is exactly 0x01.
    // The firmware never emits other values, but the parser defends the invariant.
    @Test func nonOneStateByte_parsesAsReleased() throws {
        #expect(try sensor.parseSample(from: Data([0x01, 0x01, 0x02])) == false)
    }
}

// MARK: - Switch end-to-end streaming

@Suite("Switch — Live Streaming")
struct SwitchStreamingTests {

    /// Mirrors `GPIOPinChangeStreamTests.pinChangeStream_deliversNotifications` —
    /// spins up a connected mock device, starts streaming, and verifies the two
    /// Python-vector notifications arrive as `true` then `false`.
    @Test func switchStream_deliversPressedThenReleased() async throws {
        let (device, transport) = try await connectedSwitchDevice()

        let stream = try await device.stream(MWSwitch(), usePacked: false)

        let received = SwitchAtomic<[Bool]>([])
        let consumer = Task {
            for try await sample in stream {
                received.update { $0.append(sample.value) }
            }
        }
        defer { consumer.cancel() }

        try await Task.sleep(nanoseconds: 5_000_000)
        // Python test_mbl_mw_switch_get_data_pushed
        await transport.inject(notification: Data([0x01, 0x01, 0x01]), to: MWUUIDs.notify)
        // Python test_mbl_mw_switch_get_data_released
        await transport.inject(notification: Data([0x01, 0x01, 0x00]), to: MWUUIDs.notify)
        try await Task.sleep(nanoseconds: 5_000_000)

        #expect(received.value == [true, false])
    }

    @Test func switchStream_sendsSubscribeAndUnsubscribe() async throws {
        let (device, transport) = try await connectedSwitchDevice()

        // `stream()` issues the subscribe command; `stopStreaming()` issues the unsubscribe.
        let sensor = MWSwitch()
        let stream = try await device.stream(sensor, usePacked: false)
        let consumer = Task {
            for try await _ in stream { }
        }
        defer { consumer.cancel() }

        try await Task.sleep(nanoseconds: 10_000_000)
        try await device.stopStreaming(sensor)
        try await Task.sleep(nanoseconds: 10_000_000)

        let cmds = await transport.writtenCommands
        #expect(cmds.contains(Data([0x01, 0x01, 0x01])),
                "stream() must send subscribe [0x01, 0x01, 0x01]")
        #expect(cmds.contains(Data([0x01, 0x01, 0x00])),
                "stopStreaming() must send unsubscribe [0x01, 0x01, 0x00]")
    }
}

// MARK: - Streaming test helpers (scoped to this file)

private func connectedSwitchDevice() async throws -> (MetaWearDevice, MockBLETransport) {
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
                // Switch is module 0x01 — report it as present.
                let impl: UInt8 = [0x01, 0x03, 0x05, 0x0B, 0x13, 0x12, 0x15, 0x19].contains(cmd[0]) ? 0x01 : 0xFF
                await transport.inject(notification: Data([cmd[0], 0x80, impl, 0x00]), to: MWUUIDs.notify)
            }
        }
    }
    try await device.connect()
    discovery.cancel()
    return (device, transport)
}

private final class SwitchAtomic<T>: @unchecked Sendable {
    private var _value: T
    private let lock = NSLock()
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}

// MARK: - Haptic

@Suite("Haptic Commands")
struct HapticCommandTests {

    @Test func motor_correctBytes() {
        let cmd = MWHaptic.motor(dutyCycle: 80, pulseWidth: 500)
        // dutyCycle 80% → UInt8(min(248, 80*248/100)) = UInt8(198) = 0xC6
        // pulseWidth 500 = 0x01F4 → LE: 0xF4, 0x01
        #expect(cmd.commandData == Data([0x08, 0x01, 0xC6, 0xF4, 0x01, 0x00]))
    }

    @Test func buzzer_correctBytes() {
        let cmd = MWHaptic.buzzer(pulseWidth: 200)
        // Buzzer always uses 0x7F regardless of dutyCycle
        // pulseWidth 200 = 0x00C8 → LE: 0xC8, 0x00
        #expect(cmd.commandData == Data([0x08, 0x01, 0x7F, 0xC8, 0x00, 0x01]))
    }

    @Test func motor_mode_byte() {
        let cmd = MWHaptic.motor(dutyCycle: 100, pulseWidth: 100)
        #expect(cmd.commandData[5] == 0x00)  // mode = motor
    }

    @Test func buzzer_mode_byte() {
        let cmd = MWHaptic.buzzer(pulseWidth: 100)
        #expect(cmd.commandData[5] == 0x01)  // mode = buzzer
    }

    @Test func dutyCycleClamped_at100() {
        let cmd = MWHaptic.Pulse(mode: .motor, dutyCycle: 200, pulseWidth: 100)
        #expect(cmd.dutyCycle == 100)
        // 100% → UInt8(min(248, 100*248/100)) = 248 = 0xF8
        #expect(cmd.commandData[2] == 0xF8)
    }

    @Test func motor_dutyCycle_100percent_scalesToMax() {
        let cmd = MWHaptic.motor(dutyCycle: 100, pulseWidth: 5000)
        // 100% → 248 = 0xF8; pulseWidth 5000 = 0x1388 → LE: 0x88, 0x13
        #expect(cmd.commandData == Data([0x08, 0x01, 0xF8, 0x88, 0x13, 0x00]))
    }

    @Test func motor_dutyCycle_scaling() {
        // 50% → UInt8(min(248, 50*248/100)) = UInt8(124) = 0x7C
        let cmd = MWHaptic.motor(dutyCycle: 50, pulseWidth: 100)
        #expect(cmd.commandData[2] == 0x7C)
    }

    @Test func pulseWidth_littleEndian() {
        let cmd = MWHaptic.motor(dutyCycle: 50, pulseWidth: 0x0102)
        // 0x0102 LE = [0x02, 0x01]
        #expect(cmd.commandData[3] == 0x02)
        #expect(cmd.commandData[4] == 0x01)
    }

    @Test func module_byte() {
        let cmd = MWHaptic.motor()
        #expect(cmd.commandData[0] == 0x08)  // haptic module
        #expect(cmd.commandData[1] == 0x01)  // PULSE register
    }

    @Test func commandLength() {
        // [module, register, dutyCycle, width_lo, width_hi, mode] = 6 bytes
        #expect(MWHaptic.motor().commandData.count == 6)
        #expect(MWHaptic.buzzer().commandData.count == 6)
    }
}
