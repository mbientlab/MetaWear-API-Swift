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

/// Record a macro, injecting the board's ID-assignment response.
private func recordMacro(
    on device: MetaWearDevice,
    transport: MockBLETransport,
    executeOnBoot: Bool = false,
    commands: [any MWCommand],
    boardMacroID: UInt8 = 0
) async throws -> MWMacro {
    let injector = Task {
        try? await Task.sleep(nanoseconds: 5_000_000)
        // Response to BEGIN: [0x0F, 0x02, macro_id] — plain notification
        // (high bit clear), NOT a read response. Mirror real firmware so the
        // SDK's notify-side awaiter resumes correctly.
        await transport.inject(notification: Data([0x0F, 0x02, boardMacroID]), to: MWUUIDs.notify)
    }
    defer { injector.cancel() }
    return try await device.recordMacro(executeOnBoot: executeOnBoot, commands: commands)
}

// MARK: - recordMacro command format

@Suite("MetaWearDevice — recordMacro Commands")
struct MacroRecordTests {

    @Test func recordMacro_sendsBeginCommand_manualOnly() async throws {
        let (device, transport) = try await connectedDevice()
        _ = try await recordMacro(on: device, transport: transport,
                                  executeOnBoot: false, commands: [], boardMacroID: 0)

        let cmds = await transport.writtenCommands
        let begin = cmds.first { $0.count == 3 && $0[0] == 0x0F && $0[1] == 0x02 }
        #expect(begin != nil, "recordMacro must send [0x0F, 0x02, ...]")
        #expect(begin![2] == 0x00, "exec_on_boot should be 0x00 for manual-only")
    }

    @Test func recordMacro_sendsBeginCommand_executeOnBoot() async throws {
        let (device, transport) = try await connectedDevice()
        _ = try await recordMacro(on: device, transport: transport,
                                  executeOnBoot: true, commands: [], boardMacroID: 1)

        let cmds = await transport.writtenCommands
        let begin = cmds.first { $0.count == 3 && $0[0] == 0x0F && $0[1] == 0x02 }
        #expect(begin != nil)
        #expect(begin![2] == 0x01, "exec_on_boot should be 0x01")
    }

    @Test func recordMacro_sendsEndCommand() async throws {
        let (device, transport) = try await connectedDevice()
        _ = try await recordMacro(on: device, transport: transport,
                                  executeOnBoot: false, commands: [], boardMacroID: 0)

        let cmds = await transport.writtenCommands
        #expect(cmds.contains(Data([0x0F, 0x04])), "recordMacro must send END [0x0F, 0x04]")
    }

    @Test func recordMacro_returnsAssignedID() async throws {
        let (device, transport) = try await connectedDevice()
        let macro = try await recordMacro(on: device, transport: transport,
                                          commands: [], boardMacroID: 7)
        #expect(macro.id == 7)
    }

    @Test func recordMacro_shortCommand_sendsAddCommand() async throws {
        let (device, transport) = try await connectedDevice()
        _ = try await recordMacro(
            on: device, transport: transport,
            commands: [MWLED.Play()],
            boardMacroID: 0
        )

        let cmds = await transport.writtenCommands
        // ADD_COMMAND: [0x0F, 0x03, dst_mod, dst_reg, ...]
        // MWLED.Play() → commandData = [0x02, 0x01, 0x01]
        let addCmd = cmds.first { $0.count >= 3 && $0[0] == 0x0F && $0[1] == 0x03 }
        #expect(addCmd != nil, "Short command must use ADD_COMMAND [0x0F, 0x03, ...]")
        #expect(addCmd![2] == 0x02, "LED module")
        #expect(addCmd![3] == 0x01, "LED PLAY register")
    }

    @Test func recordMacro_multipleCommands_sendsAll() async throws {
        let (device, transport) = try await connectedDevice()
        _ = try await recordMacro(
            on: device, transport: transport,
            commands: [MWLED.Play(), MWLED.Stop(clearPattern: false)],
            boardMacroID: 0
        )

        let cmds = await transport.writtenCommands
        let addCmds = cmds.filter { $0.count >= 3 && $0[0] == 0x0F && $0[1] == 0x03 }
        #expect(addCmds.count == 2, "Two commands → two ADD_COMMAND packets")
    }

    @Test func recordMacro_longCommand_sendsAddPartialThenAddCommand() async throws {
        let (device, transport) = try await connectedDevice()

        // MWLED.SetPattern produces 15 bytes of commandData (> 13 byte threshold)
        let pattern = MWLEDPattern(
            highIntensity: 31, lowIntensity: 0,
            riseTime: 100, highTime: 200,
            fallTime: 100, pulseDuration: 800,
            delay: 0, repeatCount: 0xFF
        )
        let setPattern = MWLED.SetPattern(color: .green, pattern: pattern)
        #expect(setPattern.commandData.count > 13, "SetPattern must be > 13 bytes for this test")

        _ = try await recordMacro(
            on: device, transport: transport,
            commands: [setPattern],
            boardMacroID: 0
        )

        let cmds = await transport.writtenCommands
        let partial = cmds.first { $0.count == 4 && $0[0] == 0x0F && $0[1] == 0x09 }
        #expect(partial != nil, "Long command must send ADD_PARTIAL [0x0F, 0x09, byte0, byte1]")
        let addCmd = cmds.first { $0.count > 4 && $0[0] == 0x0F && $0[1] == 0x03 }
        #expect(addCmd != nil, "Long command must also send ADD_COMMAND [0x0F, 0x03, ...]")
    }

    @Test func recordMacro_longCommand_partialContainsFirstTwoBytes() async throws {
        let (device, transport) = try await connectedDevice()

        let pattern = MWLEDPattern(
            highIntensity: 31, lowIntensity: 0,
            riseTime: 100, highTime: 200,
            fallTime: 100, pulseDuration: 800,
            delay: 0, repeatCount: 0xFF
        )
        let setPattern = MWLED.SetPattern(color: .green, pattern: pattern)
        let originalData = setPattern.commandData

        _ = try await recordMacro(
            on: device, transport: transport,
            commands: [setPattern],
            boardMacroID: 0
        )

        let cmds = await transport.writtenCommands
        let partial = cmds.first { $0.count == 4 && $0[0] == 0x0F && $0[1] == 0x09 }!
        #expect(partial[2] == originalData[0], "ADD_PARTIAL byte0 must match command byte0")
        #expect(partial[3] == originalData[1], "ADD_PARTIAL byte1 must match command byte1")
    }
}

// MARK: - executeMacro / eraseAllMacros

@Suite("MetaWearDevice — executeMacro / eraseAllMacros")
struct MacroControlTests {

    @Test func executeMacro_correctCommand() async throws {
        let (device, transport) = try await connectedDevice()
        let macro = MWMacro(id: 3)
        try await device.executeMacro(macro)

        let cmds = await transport.writtenCommands
        #expect(cmds.contains(Data([0x0F, 0x05, 0x03])),
                "executeMacro must send [0x0F, 0x05, macro_id]")
    }

    @Test func eraseAllMacros_correctCommand() async throws {
        let (device, transport) = try await connectedDevice()
        try await device.eraseAllMacros()

        let cmds = await transport.writtenCommands
        #expect(cmds.contains(Data([0x0F, 0x08])),
                "eraseAllMacros must send [0x0F, 0x08]")
    }
}

// MARK: - Integration

@Suite("MWMacro — Integration")
struct MacroIntegrationTests {

    @Test func bootMacro_fullSequence() async throws {
        let (device, transport) = try await connectedDevice()

        let macro = try await recordMacro(
            on: device, transport: transport,
            executeOnBoot: true,
            commands: [MWLED.Play(), MWLED.Stop(clearPattern: false)],
            boardMacroID: 2
        )

        #expect(macro.id == 2)

        let cmds = await transport.writtenCommands
        // BEGIN with exec_on_boot=1
        let begin = cmds.first { $0.count == 3 && $0[0] == 0x0F && $0[1] == 0x02 }!
        #expect(begin[2] == 0x01)
        // Two ADD_COMMAND packets
        let addCmds = cmds.filter { $0.count >= 3 && $0[0] == 0x0F && $0[1] == 0x03 }
        #expect(addCmds.count == 2)
        // END
        #expect(cmds.contains(Data([0x0F, 0x04])))
    }
}
