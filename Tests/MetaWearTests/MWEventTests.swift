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
                    await transport.inject(notification: Data([0x0B, 0x84, 0,0,0,0,0]), to: MWUUIDs.notify)
                    continue
                }
                let impl: UInt8 = [0x03, 0x0A, 0x0B, 0x0C, 0x13, 0x12, 0x15, 0x19].contains(cmd[0]) ? 0x01 : 0xFF
                await transport.inject(notification: Data([cmd[0], 0x80, impl, 0x00]), to: MWUUIDs.notify)
            }
        }
    }
    try await device.connect()
    discovery.cancel()
    return (device, transport)
}

/// Create a timer injecting the board's ID-assignment response.
private func makeTimer(
    on device: MetaWearDevice,
    transport: MockBLETransport,
    timerID: UInt8 = 0
) async throws -> MWTimer {
    let injector = Task {
        try? await Task.sleep(nanoseconds: 5_000_000)
        // Real firmware replies with [0x0C, 0x02, timer_id] — plain notification,
        // NOT a read response. Mirror that here so the SDK's notify-side
        // awaiter resumes correctly.
        await transport.inject(notification: Data([0x0C, 0x02, timerID]), to: MWUUIDs.notify)
    }
    defer { injector.cancel() }
    return try await device.createTimer(periodMs: 1000)
}

/// Create an event injecting the board's assigned event ID.
private func makeEvent(
    on device: MetaWearDevice,
    transport: MockBLETransport,
    source: MWEventSource,
    action: MWEventAction,
    boardEventID: UInt8 = 0
) async throws -> MWEvent {
    let injector = Task {
        try? await Task.sleep(nanoseconds: 5_000_000)
        // Real firmware replies with [0x0A, 0x02, event_id] — plain notification,
        // NOT a read response. Mirror that here so the SDK's notify-side
        // awaiter resumes correctly.
        await transport.inject(notification: Data([0x0A, 0x02, boardEventID]), to: MWUUIDs.notify)
    }
    defer { injector.cancel() }
    return try await device.createEvent(source: source, action: action)
}

// MARK: - MWEventSource

@Suite("MWEventSource — Convenience Constructors")
struct EventSourceTests {

    @Test func timerFired_correctRegisters() {
        let timer = MWTimer(id: 2, periodMs: 1000, repetitions: MWTimer.infinite, immediate: false)
        let src = MWEventSource.timerFired(timer)
        #expect(src.module == .timer)
        #expect(src.register == 0x06)   // NOTIFY register
        #expect(src.dataID == 2)        // timer.id
    }

    @Test func buttonChanged_correctRegisters() {
        let src = MWEventSource.buttonChanged()
        #expect(src.module == .switch_)
        #expect(src.register == 0x01)
        #expect(src.dataID == 0xFF)     // any instance
    }

    @Test func gpioChanged_correctRegisters() {
        let src = MWEventSource.gpioChanged(pin: 3)
        #expect(src.module == .gpio)
        #expect(src.register == 0x0A)   // PIN_CHANGE_NOTIFY
        #expect(src.dataID == 3)
    }
}

// MARK: - MWEventAction

@Suite("MWEventAction — From Command")
struct EventActionTests {

    @Test func ledPlay_extractsCorrectly() throws {
        let action = try MWEventAction(command: MWLED.Play())
        #expect(action.module == .led)
        #expect(action.register == 0x01)
        #expect(action.params == Data([0x01]))
    }

    @Test func ledStop_extractsCorrectly() throws {
        let action = try MWEventAction(command: MWLED.Stop(clearPattern: true))
        #expect(action.module == .led)
        #expect(action.register == 0x02)
        #expect(action.params == Data([0x01]))
    }

    @Test func gpioSetHigh_extractsCorrectly() throws {
        let action = try MWEventAction(command: MWGPIO.SetHigh(pin: 2))
        #expect(action.module == .gpio)
        #expect(action.register == 0x01)
        #expect(action.params == Data([0x02]))
    }

    @Test func noParams_emptyData() {
        // A command with only module+register bytes
        let action = MWEventAction(module: .debug, register: 0x01, params: Data())
        #expect(action.params.isEmpty)
    }
}

// MARK: - createEvent command format

@Suite("MetaWearDevice — createEvent Commands")
struct CreateEventCommandTests {

    @Test func createEvent_entryCommandFormat() async throws {
        let (device, transport) = try await connectedDevice()
        let timer = try await makeTimer(on: device, transport: transport, timerID: 0)

        _ = try await makeEvent(
            on: device, transport: transport,
            source: .timerFired(timer),
            action: try MWEventAction(command: MWLED.Play()),
            boardEventID: 0
        )

        let cmds = await transport.writtenCommands
        // ENTRY: [0x0A, 0x02, src_mod, src_reg, src_dataID, dst_mod, dst_reg, param_len]
        let entry = cmds.first {
            $0.count == 8 && $0[0] == 0x0A && $0[1] == 0x02
        }
        #expect(entry != nil, "createEvent must send [0x0A, 0x02, ...] ENTRY command")
        // src = timer(0x0C), notify reg(0x06), dataID=timer.id=0
        #expect(entry![2] == 0x0C)   // timer module
        #expect(entry![3] == 0x06)   // NOTIFY register
        #expect(entry![4] == 0x00)   // timer.id
        // dst = LED(0x02), PLAY reg(0x01)
        #expect(entry![5] == 0x02)   // LED module
        #expect(entry![6] == 0x01)   // LED_PLAY register
        // param_length = 1 (MWLED.Play sends [0x01])
        #expect(entry![7] == 0x01)
    }

    @Test func createEvent_sendsParamsAfterEntry() async throws {
        let (device, transport) = try await connectedDevice()
        let timer = try await makeTimer(on: device, transport: transport, timerID: 0)

        _ = try await makeEvent(
            on: device, transport: transport,
            source: .timerFired(timer),
            action: try MWEventAction(command: MWLED.Play()),
            boardEventID: 0
        )

        let cmds = await transport.writtenCommands
        // CMD_PARAMETERS: [0x0A, 0x03, ...params...]
        let cmdParams = cmds.first { $0.count >= 3 && $0[0] == 0x0A && $0[1] == 0x03 }
        #expect(cmdParams != nil, "createEvent must send [0x0A, 0x03, ...] CMD_PARAMETERS")
        #expect(cmdParams![2] == 0x01)   // LED Play param = 0x01
    }

    @Test func createEvent_noParams_skipsCmdParameters() async throws {
        let (device, transport) = try await connectedDevice()

        // Action with no params
        let action = MWEventAction(module: .led, register: 0x01, params: Data())
        _ = try await makeEvent(
            on: device, transport: transport,
            source: .buttonChanged(),
            action: action,
            boardEventID: 1
        )

        let cmds = await transport.writtenCommands
        let cmdParams = cmds.first { $0.count >= 2 && $0[0] == 0x0A && $0[1] == 0x03 }
        #expect(cmdParams == nil, "No CMD_PARAMETERS when action has no params")
    }

    @Test func createEvent_returnsAssignedID() async throws {
        let (device, transport) = try await connectedDevice()

        let event = try await makeEvent(
            on: device, transport: transport,
            source: .buttonChanged(),
            action: try MWEventAction(command: MWLED.Play()),
            boardEventID: 5
        )
        #expect(event.id == 5)
    }

    @Test func createEvent_buttonSource_correctBytes() async throws {
        let (device, transport) = try await connectedDevice()

        _ = try await makeEvent(
            on: device, transport: transport,
            source: .buttonChanged(),
            action: try MWEventAction(command: MWGPIO.SetHigh(pin: 0)),
            boardEventID: 0
        )

        let cmds = await transport.writtenCommands
        let entry = cmds.first { $0.count == 8 && $0[0] == 0x0A && $0[1] == 0x02 }!
        #expect(entry[2] == 0x01)   // switch module
        #expect(entry[3] == 0x01)   // register
        #expect(entry[4] == 0xFF)   // dataID = any
    }
}

// MARK: - removeEvent / removeAllEvents

@Suite("MetaWearDevice — removeEvent")
struct RemoveEventTests {

    @Test func removeEvent_correctCommand() async throws {
        let (device, transport) = try await connectedDevice()
        let event = MWEvent(id: 3)
        try await device.removeEvent(event)

        let cmds = await transport.writtenCommands
        #expect(cmds.contains(Data([0x0A, 0x04, 0x03])),
                "removeEvent must send [0x0A, 0x04, event_id]")
    }

    @Test func removeAllEvents_correctCommand() async throws {
        let (device, transport) = try await connectedDevice()
        try await device.removeAllEvents()

        let cmds = await transport.writtenCommands
        #expect(cmds.contains(Data([0x0A, 0x05])),
                "removeAllEvents must send [0x0A, 0x05]")
    }
}

// MARK: - Integration: timer → LED

@Suite("MWEvent — Integration")
struct EventIntegrationTests {

    @Test func timerFiredLedsPlay_fullCommandSequence() async throws {
        let (device, transport) = try await connectedDevice()
        let timer = try await makeTimer(on: device, transport: transport, timerID: 0)

        let event = try await makeEvent(
            on: device, transport: transport,
            source: .timerFired(timer),
            action: try MWEventAction(command: MWLED.Play()),
            boardEventID: 0
        )

        try await device.startTimer(timer)
        // ... later, tear down
        try await device.removeEvent(event)
        try await device.stopTimer(timer)
        try await device.removeTimer(timer)

        let cmds = await transport.writtenCommands
        #expect(cmds.contains(Data([0x0C, 0x03, 0x00])), "startTimer")
        #expect(cmds.contains(Data([0x0A, 0x04, 0x00])), "removeEvent")
        #expect(cmds.contains(Data([0x0C, 0x04, 0x00])), "stopTimer")
        #expect(cmds.contains(Data([0x0C, 0x05, 0x00])), "removeTimer")
    }
}

// MARK: - MWEventDataToken

@Suite("MWEventDataToken — bit-packing")
struct EventDataTokenTests {

    // encodedBytes = [0x01 | (length << 1) | (sourceOffset << 4), destOffset]
    // length=1, sourceOffset=0, destOffset=0 → [0x01 | 0x02 | 0x00, 0x00] = [0x03, 0x00]
    @Test func minimal_lengthOne() throws {
        let t = try MWEventDataToken(length: 1)
        #expect(t.encodedBytes == [0x03, 0x00])
    }

    // length=4, sourceOffset=2, destOffset=3
    //   byte0 = 0x01 | (4 << 1) | (2 << 4) = 0x01 | 0x08 | 0x20 = 0x29
    //   byte1 = 0x03
    @Test func midRange_bitsLineUp() throws {
        let t = try MWEventDataToken(length: 4, sourceOffset: 2, destOffset: 3)
        #expect(t.encodedBytes == [0x29, 0x03])
    }

    // Max legal values: length=7 (bits 1-3 full), sourceOffset=15 (bits 4-7 full)
    //   byte0 = 0x01 | (7 << 1) | (15 << 4) = 0x01 | 0x0E | 0xF0 = 0xFF
    @Test func maxValues_packIntoAllHigherBits() throws {
        let t = try MWEventDataToken(length: 7, sourceOffset: 15, destOffset: 0xAB)
        #expect(t.encodedBytes == [0xFF, 0xAB])
    }

    // Bit 0 is always set — it's the "token present" marker.
    @Test func bitZero_alwaysSet() throws {
        for length in UInt8(1)...UInt8(7) {
            for srcOff in UInt8(0)...UInt8(15) {
                let t = try MWEventDataToken(length: length, sourceOffset: srcOff, destOffset: 0)
                #expect(t.encodedBytes[0] & 0x01 == 0x01)
            }
        }
    }

    // destOffset is written verbatim (no packing).
    @Test func destOffset_verbatim() throws {
        for d in UInt8(0)...UInt8(16) {
            let t = try MWEventDataToken(length: 1, sourceOffset: 0, destOffset: d)
            #expect(t.encodedBytes[1] == d)
        }
    }

    // Out-of-range length / sourceOffset throw rather than crashing via precondition.
    @Test func outOfRange_throws() {
        #expect(throws: MWError.self) { _ = try MWEventDataToken(length: 0) }
        #expect(throws: MWError.self) { _ = try MWEventDataToken(length: 8) }
        #expect(throws: MWError.self) { _ = try MWEventDataToken(length: 1, sourceOffset: 16) }
    }
}

// MARK: - createEvent with data token

@Suite("MetaWearDevice — createEvent with dataToken")
struct CreateEventDataTokenTests {

    // When no token is passed, the ENTRY command length stays at 8 bytes
    // (the baseline "straight passthrough" case — regression guard).
    @Test func noToken_entryLengthUnchanged() async throws {
        let (device, transport) = try await connectedDevice()
        _ = try await makeEvent(
            on: device, transport: transport,
            source: .buttonChanged(),
            action: try MWEventAction(command: MWLED.Play()),
            boardEventID: 0
        )
        let cmds = await transport.writtenCommands
        let entry = cmds.first { $0.count >= 2 && $0[0] == 0x0A && $0[1] == 0x02 }
        #expect(entry?.count == 8, "ENTRY must be 8 bytes without a token")
    }

    // With a token, the ENTRY command is 10 bytes (8 baseline + 2 token bytes).
    @Test func withToken_entryAppendsTwoBytes() async throws {
        let (device, transport) = try await connectedDevice()
        let token = try MWEventDataToken(length: 4, sourceOffset: 2, destOffset: 3)

        let injector = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            // Real firmware: plain notification (0x02), not read response (0x82).
            await transport.inject(notification: Data([0x0A, 0x02, 0x00]), to: MWUUIDs.notify)
        }
        defer { injector.cancel() }
        _ = try await device.createEvent(
            source: .buttonChanged(),
            action: try MWEventAction(command: MWLED.Play()),
            dataToken: token
        )

        let cmds = await transport.writtenCommands
        let entry = cmds.first { $0.count >= 2 && $0[0] == 0x0A && $0[1] == 0x02 }
        #expect(entry != nil)
        #expect(entry?.count == 10, "ENTRY must be 10 bytes with a token appended")
        // Verify the appended token bytes:
        //   length=4, sourceOffset=2 → 0x01 | 0x08 | 0x20 = 0x29
        //   destOffset=3
        #expect(entry?[8] == 0x29)
        #expect(entry?[9] == 0x03)
    }

    // CMD_PARAMETERS is still sent exactly as before — the token lives on ENTRY only.
    @Test func withToken_cmdParametersUnchanged() async throws {
        let (device, transport) = try await connectedDevice()
        let token = try MWEventDataToken(length: 1)

        let injector = Task {
            try? await Task.sleep(nanoseconds: 5_000_000)
            // Real firmware: plain notification (0x02), not read response (0x82).
            await transport.inject(notification: Data([0x0A, 0x02, 0x00]), to: MWUUIDs.notify)
        }
        defer { injector.cancel() }
        _ = try await device.createEvent(
            source: .buttonChanged(),
            action: try MWEventAction(command: MWLED.Play()),
            dataToken: token
        )

        let cmds = await transport.writtenCommands
        // MWLED.Play() commandData = [0x02, 0x01, 0x01] → action.params = [0x01]
        let params = cmds.first { $0.count >= 3 && $0[0] == 0x0A && $0[1] == 0x03 }
        #expect(params == Data([0x0A, 0x03, 0x01]))
    }
}
