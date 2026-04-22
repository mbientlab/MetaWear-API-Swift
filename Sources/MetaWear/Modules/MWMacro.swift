import Foundation

// MARK: - MWMacro

/// A handle to an on-device macro created via `MetaWearDevice.recordMacro(...)`.
///
/// Macros are sequences of commands stored in flash that execute atomically —
/// either manually triggered or automatically on every power-on.
///
/// Typical flow:
/// ```swift
/// let macro = try await device.recordMacro(executeOnBoot: true, commands: [
///     MWLED.SetPattern(color: .green, pattern: .init(highIntensity: 31, lowIntensity: 0,
///                                                    riseTime: 100, highTime: 200,
///                                                    fallTime: 100, period: 800,
///                                                    delay: 0, repeat: 0xFF)),
///     MWLED.Play()
/// ])
///
/// // Later, run manually:
/// try await device.executeMacro(macro)
///
/// // Remove all macros:
/// try await device.eraseAllMacros()
/// ```
public struct MWMacro: Sendable, Equatable {
    /// Board-assigned macro ID.
    public let id: UInt8
}

// MARK: - MetaWearDevice macro API

public extension MetaWearDevice {

    // MARK: Record

    /// Record a sequence of commands as a macro on the device.
    ///
    /// Each command is stored in flash. If `executeOnBoot` is `true`, the macro
    /// runs automatically every time the board powers on; otherwise it only runs
    /// when explicitly triggered with `executeMacro(_:)`.
    ///
    /// Commands longer than 13 bytes are split into an ADD_PARTIAL + ADD_COMMAND pair
    /// per the MetaWear protocol spec.
    ///
    /// - Parameters:
    ///   - executeOnBoot: Whether to run on every power-on.
    ///   - commands: The commands to record, in order.
    /// - Returns: An `MWMacro` handle for later execution or identification.
    func recordMacro(
        executeOnBoot: Bool = false,
        commands: [any MWCommand]
    ) async throws -> MWMacro {
        // BEGIN: [0x0F, 0x02, exec_on_boot] — responds with [0x0F, 0x82, macro_id]
        let beginCmd = Data([MWModule.macro.rawValue, 0x02, executeOnBoot ? 0x01 : 0x00])
        let response = try await sendRead(
            command: beginCmd,
            awaitModule: .macro,
            awaitRegister: 0x02
        )
        guard response.count >= 3 else {
            throw MWError.operationFailed("Macro begin response too short: \(response.count) bytes")
        }
        let macroID = response[2]

        // ADD commands
        for command in commands {
            try await addMacroCommand(command.commandData)
        }

        // END: [0x0F, 0x04]
        try await writeMacroRaw(Data([MWModule.macro.rawValue, 0x04]))

        return MWMacro(id: macroID)
    }

    // MARK: Execute

    /// Execute a previously recorded macro by its board-assigned ID.
    func executeMacro(_ macro: MWMacro) async throws {
        try await writeRaw(Data([MWModule.macro.rawValue, 0x05, macro.id]))
    }

    // MARK: Erase

    /// Erase all macros stored on the device.
    func eraseAllMacros() async throws {
        try await writeRaw(Data([MWModule.macro.rawValue, 0x08]))
    }

    // MARK: - Internal

    /// Add a single command to an in-progress macro recording.
    ///
    /// Per spec, commands > 13 bytes are split:
    /// - ADD_PARTIAL `[0x0F, 0x09, byte0, byte1]`
    /// - ADD_COMMAND `[0x0F, 0x03, byte2..byteN]`
    private func addMacroCommand(_ commandData: Data) async throws {
        let maxDirect = 13
        if commandData.count <= maxDirect {
            // ADD_COMMAND: [0x0F, 0x03, ...commandData...]
            try await writeMacroRaw(Data([MWModule.macro.rawValue, 0x03]) + commandData)
        } else {
            // ADD_PARTIAL: first 2 bytes
            let partial = Data([MWModule.macro.rawValue, 0x09, commandData[0], commandData[1]])
            try await writeMacroRaw(partial)
            // ADD_COMMAND: remaining bytes
            let rest = commandData.advanced(by: 2)
            try await writeMacroRaw(Data([MWModule.macro.rawValue, 0x03]) + rest)
        }
    }
}
