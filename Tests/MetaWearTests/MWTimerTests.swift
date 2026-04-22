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
                let impl: UInt8 = [0x03, 0x0B, 0x0C, 0x13, 0x12, 0x15, 0x19].contains(cmd[0]) ? 0x01 : 0xFF
                await transport.inject(notification: Data([cmd[0], 0x80, impl, 0x00]), to: MWUUIDs.notify)
            }
        }
    }
    try await device.connect()
    discovery.cancel()
    return (device, transport)
}

/// Create a timer, injecting the board's ID-assignment response.
private func createTimer(
    on device: MetaWearDevice,
    transport: MockBLETransport,
    periodMs: UInt32 = 1000,
    repetitions: UInt16 = MWTimer.infinite,
    immediate: Bool = false,
    boardAssignedID: UInt8 = 0
) async throws -> MWTimer {
    let injector = Task {
        try? await Task.sleep(nanoseconds: 5_000_000)
        // Response: [0x0C, 0x82, timer_id]
        await transport.inject(
            notification: Data([0x0C, 0x82, boardAssignedID]),
            to: MWUUIDs.notify
        )
    }
    defer { injector.cancel() }
    return try await device.createTimer(periodMs: periodMs, repetitions: repetitions, immediate: immediate)
}

// MARK: - Timer creation

@Suite("MWTimer — Creation")
struct TimerCreationTests {

    @Test func createTimer_commandFormat() async throws {
        let (device, transport) = try await connectedDevice()
        _ = try await createTimer(on: device, transport: transport, periodMs: 500, repetitions: 10, immediate: true)

        let cmds = await transport.writtenCommands
        let createCmd = cmds.first { $0.count == 9 && $0[0] == 0x0C && $0[1] == 0x02 }
        #expect(createCmd != nil, "createTimer must send [0x0C, 0x02, ...]")

        // period=500ms LE: [0xF4, 0x01, 0x00, 0x00]
        #expect(createCmd![2] == 0xF4)
        #expect(createCmd![3] == 0x01)
        #expect(createCmd![4] == 0x00)
        #expect(createCmd![5] == 0x00)
        // repetitions=10 LE: [0x0A, 0x00]
        #expect(createCmd![6] == 0x0A)
        #expect(createCmd![7] == 0x00)
        // immediate=true: 0x01
        #expect(createCmd![8] == 0x01)
    }

    @Test func createTimer_infinite_repetitions() async throws {
        let (device, transport) = try await connectedDevice()
        _ = try await createTimer(on: device, transport: transport, repetitions: MWTimer.infinite)

        let cmds = await transport.writtenCommands
        let createCmd = cmds.first { $0.count == 9 && $0[0] == 0x0C && $0[1] == 0x02 }!
        // 0xFFFF LE: [0xFF, 0xFF]
        #expect(createCmd[6] == 0xFF && createCmd[7] == 0xFF)
    }

    @Test func createTimer_returnsAssignedID() async throws {
        let (device, transport) = try await connectedDevice()
        let timer = try await createTimer(on: device, transport: transport, boardAssignedID: 3)
        #expect(timer.id == 3)
    }

    @Test func createTimer_preservesPeriodAndRepetitions() async throws {
        let (device, transport) = try await connectedDevice()
        let timer = try await createTimer(on: device, transport: transport, periodMs: 2500, repetitions: 5)
        #expect(timer.periodMs == 2500)
        #expect(timer.repetitions == 5)
    }
}

// MARK: - Start / Stop / Remove

@Suite("MWTimer — Start Stop Remove")
struct TimerControlTests {

    @Test func startTimer_correctCommand() async throws {
        let (device, transport) = try await connectedDevice()
        let timer = try await createTimer(on: device, transport: transport, boardAssignedID: 1)
        try await device.startTimer(timer)

        let cmds = await transport.writtenCommands
        #expect(cmds.contains(Data([0x0C, 0x03, 0x01])), "startTimer must send [0x0C, 0x03, id]")
    }

    @Test func stopTimer_correctCommand() async throws {
        let (device, transport) = try await connectedDevice()
        let timer = try await createTimer(on: device, transport: transport, boardAssignedID: 2)
        try await device.stopTimer(timer)

        let cmds = await transport.writtenCommands
        #expect(cmds.contains(Data([0x0C, 0x04, 0x02])), "stopTimer must send [0x0C, 0x04, id]")
    }

    @Test func removeTimer_correctCommand() async throws {
        let (device, transport) = try await connectedDevice()
        let timer = try await createTimer(on: device, transport: transport, boardAssignedID: 0)
        try await device.removeTimer(timer)

        let cmds = await transport.writtenCommands
        #expect(cmds.contains(Data([0x0C, 0x05, 0x00])), "removeTimer must send [0x0C, 0x05, id]")
    }

    @Test func setTimerNotify_enable() async throws {
        let (device, transport) = try await connectedDevice()
        let timer = try await createTimer(on: device, transport: transport, boardAssignedID: 0)
        try await device.setTimerNotify(timer, enabled: true)

        let cmds = await transport.writtenCommands
        #expect(cmds.contains(Data([0x0C, 0x07, 0x00, 0x01])))
    }

    @Test func setTimerNotify_disable() async throws {
        let (device, transport) = try await connectedDevice()
        let timer = try await createTimer(on: device, transport: transport, boardAssignedID: 0)
        try await device.setTimerNotify(timer, enabled: false)

        let cmds = await transport.writtenCommands
        #expect(cmds.contains(Data([0x0C, 0x07, 0x00, 0x00])))
    }
}

// MARK: - Notification stream

@Suite("MWTimer — Notification Stream")
struct TimerStreamTests {

    @Test @MainActor func streamTimer_deliversTicks() async throws {
        let (device, transport) = try await connectedDevice()
        let timer = try await createTimer(on: device, transport: transport, boardAssignedID: 0)

        let stream = await device.streamTimer(timer)
        var received: [UInt8] = []

        let consumer = Task {
            for try await timerID in stream {
                received.append(timerID)
            }
        }
        defer { consumer.cancel() }

        try await Task.sleep(nanoseconds: 5_000_000)
        // Inject two tick notifications for our timer
        await transport.inject(notification: Data([0x0C, 0x06, 0x00]), to: MWUUIDs.notify)
        await transport.inject(notification: Data([0x0C, 0x06, 0x00]), to: MWUUIDs.notify)
        try await Task.sleep(nanoseconds: 5_000_000)

        #expect(received.count == 2)
        #expect(received.allSatisfy { $0 == 0 })
    }

    @Test @MainActor func streamTimer_filtersOtherTimerIDs() async throws {
        let (device, transport) = try await connectedDevice()
        let timer = try await createTimer(on: device, transport: transport, boardAssignedID: 1)

        let stream = await device.streamTimer(timer)
        var received: [UInt8] = []

        let consumer = Task {
            for try await timerID in stream { received.append(timerID) }
        }
        defer { consumer.cancel() }

        try await Task.sleep(nanoseconds: 5_000_000)
        // Inject notification for timer 0 (different ID — should be filtered)
        await transport.inject(notification: Data([0x0C, 0x06, 0x00]), to: MWUUIDs.notify)
        // Inject notification for our timer 1
        await transport.inject(notification: Data([0x0C, 0x06, 0x01]), to: MWUUIDs.notify)
        try await Task.sleep(nanoseconds: 5_000_000)

        #expect(received.count == 1, "Must filter ticks from other timer IDs")
        #expect(received[0] == 1)
    }
}

// MARK: - Period encoding

@Suite("MWTimer — Period Encoding")
struct TimerEncodingTests {

    @Test func period_1000ms_encodedCorrectly() async throws {
        let (device, transport) = try await connectedDevice()
        _ = try await createTimer(on: device, transport: transport, periodMs: 1000)

        let cmds = await transport.writtenCommands
        let cmd = cmds.first { $0.count == 9 && $0[0] == 0x0C && $0[1] == 0x02 }!
        // 1000 = 0x000003E8 LE: [0xE8, 0x03, 0x00, 0x00]
        #expect(cmd[2] == 0xE8 && cmd[3] == 0x03 && cmd[4] == 0x00 && cmd[5] == 0x00)
    }

    @Test func period_60000ms_encodedCorrectly() async throws {
        let (device, transport) = try await connectedDevice()
        _ = try await createTimer(on: device, transport: transport, periodMs: 60_000)

        let cmds = await transport.writtenCommands
        let cmd = cmds.first { $0.count == 9 && $0[0] == 0x0C && $0[1] == 0x02 }!
        // 60000 = 0x0000EA60 LE: [0x60, 0xEA, 0x00, 0x00]
        #expect(cmd[2] == 0x60 && cmd[3] == 0xEA && cmd[4] == 0x00 && cmd[5] == 0x00)
    }
}
