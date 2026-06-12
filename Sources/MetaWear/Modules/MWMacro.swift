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

// MARK: - MWMacroRecorder

/// A scratch pad that collects raw wire packets while a `recordMacro(...)` closure runs.
///
/// The closure-based `recordMacro` overload hands the user one of these and
/// then plays the collected packets back into a macro recording session
/// (BEGIN → ADD_COMMAND…  → END). This is how a macro can embed actions that
/// would otherwise round-trip to the board for an ID — the recorder captures
/// the *bytes* you'd send, and lets the firmware assign IDs at replay time.
///
/// This is the only ergonomic way to nest `createEvent(...)` (or any other
/// multi-write action that returns a board-assigned handle) inside a macro:
/// the embedded event/timer/processor is created fresh every time the macro
/// runs, so a `MWEvent.id` cannot be known at recording time.
///
/// ```swift
/// let macro = try await device.recordMacro(executeOnBoot: true) { recorder in
///     await recorder.send(MWLED.SetPattern(color: .green, .flash))
///     await recorder.createEvent(
///         source: .buttonChanged(),
///         action: MWEventAction(command: MWLED.Play())
///     )
/// }
/// ```
///
/// On every reboot the firmware replays the macro, which:
///   1. Re-applies the green-flash pattern, and
///   2. Re-creates the button → LED Play binding.
///
/// The recorder is an `actor` so the closure can safely interleave it with
/// other async work; calls are serialised in declaration order.
public actor MWMacroRecorder {

    /// Captured wire packets, in the order they were recorded.
    /// `internal` so the embedding device extension can drain them after the
    /// closure returns; outside callers don't need to see the buffer.
    internal var packets: [Data] = []

    /// Constructed only by `MetaWearDevice.recordMacro(executeOnBoot:_:)`.
    internal init() {}

    // MARK: - Single command

    /// Record a single command into the macro.
    ///
    /// The command's `commandData` bytes are buffered verbatim and replayed
    /// during the macro recording session via `ADD_COMMAND` (split into
    /// `ADD_PARTIAL` + `ADD_COMMAND` automatically for >13-byte payloads).
    public func send(_ command: any MWCommand) {
        packets.append(command.commandData)
    }

    /// Record a multi-write command sequence (e.g. an Enable/Disable pair for
    /// a BMI270 feature, or a long `SetScanResponse` that splits across
    /// registers). Each underlying packet is appended in order.
    public func send(_ sequence: any MWCommandSequence) {
        for cmd in sequence.commands {
            packets.append(cmd)
        }
    }

    /// Record raw wire bytes. Escape hatch for callers that need to embed a
    /// command for which there is no `MWCommand` type yet (e.g. an opcode the
    /// SDK doesn't model). The bytes go through the same ADD_COMMAND /
    /// ADD_PARTIAL split logic as `send(_:)`.
    public func sendRaw(_ data: Data) {
        packets.append(data)
    }

    // MARK: - Embedded createEvent

    /// Record an event-creation inside the macro.
    ///
    /// Mirrors the wire shape of `MetaWearDevice.createEvent(...)` but writes
    /// the bytes into the macro buffer instead of sending them live. When the
    /// macro replays (manually via `executeMacro` or automatically on boot),
    /// the firmware processes the embedded ENTRY exactly as if the host had
    /// just sent it — assigning a fresh event ID and wiring the source signal
    /// to the destination action.
    ///
    /// Because the event ID is only assigned at replay time, this method
    /// returns `Void` — there's no handle to remove an embedded event
    /// individually. Use `device.removeAllEvents()` to tear down the bindings
    /// after they've been created (or just `eraseAllMacros()` so they don't
    /// re-create on next boot).
    ///
    /// - Parameters:
    ///   - source: The signal whose notification triggers the action.
    ///   - action: The command to execute when the source fires.
    ///   - dataToken: Optional source→destination byte slicing instructions.
    public func createEvent(
        source: MWEventSource,
        action: MWEventAction,
        dataToken: MWEventDataToken? = nil
    ) {
        // ENTRY: [0x0A, 0x02, src_module, src_register, src_dataID,
        //                      dst_module, dst_register, param_length,
        //                      (optional 2-byte data token)]
        var entryBytes: [UInt8] = [
            MWModule.event.rawValue, 0x02,
            source.module.rawValue, source.register, source.dataID,
            action.module.rawValue, action.register, UInt8(action.params.count)
        ]
        if let dataToken {
            entryBytes.append(contentsOf: dataToken.encodedBytes)
        }
        packets.append(Data(entryBytes))

        // CMD_PARAMETERS — only emitted if the action has a payload.
        if !action.params.isEmpty {
            packets.append(Data([MWModule.event.rawValue, 0x03] + action.params))
        }
    }
}

// MARK: - MetaWearDevice macro API

public extension MetaWearDevice {

    // MARK: Record (closure form)

    /// Record a macro by composing actions inside a closure.
    ///
    /// The closure receives a `MWMacroRecorder` whose `send(_:)` and
    /// `createEvent(...)` calls are buffered as raw wire packets, then played
    /// back into a macro recording session once the closure returns. This is
    /// the only way to embed multi-write actions (notably `createEvent`) into
    /// a macro — the array-form `recordMacro(executeOnBoot:commands:)` overload
    /// only takes single-command `MWCommand` values and can't represent an
    /// ENTRY + CMD_PARAMETERS pair.
    ///
    /// ```swift
    /// // Bind button → LED green flash, persisted across reboots
    /// let macro = try await device.recordMacro(executeOnBoot: true) { recorder in
    ///     await recorder.send(MWLED.SetPattern(color: .green, .flash))
    ///     await recorder.createEvent(
    ///         source: .buttonChanged(),
    ///         action: MWEventAction(command: MWLED.Play())
    ///     )
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - executeOnBoot: Whether the macro runs automatically on every power-on.
    ///   - body: Composes the macro by calling methods on the recorder.
    /// - Returns: An `MWMacro` handle for later `executeMacro(_:)` calls.
    func recordMacro(
        executeOnBoot: Bool = false,
        _ body: @Sendable (MWMacroRecorder) async throws -> Void
    ) async throws -> MWMacro {
        let recorder = MWMacroRecorder()
        try await body(recorder)
        let packets = await recorder.packets
        return try await commitMacro(executeOnBoot: executeOnBoot, packets: packets)
    }

    // MARK: Record (array form)

    /// Record a sequence of commands as a macro on the device.
    ///
    /// Each command is stored in flash. If `executeOnBoot` is `true`, the macro
    /// runs automatically every time the board powers on; otherwise it only runs
    /// when explicitly triggered with `executeMacro(_:)`.
    ///
    /// Commands longer than 13 bytes are split into an ADD_PARTIAL + ADD_COMMAND pair
    /// per the MetaWear protocol spec.
    ///
    /// For macros that need to embed a `createEvent(...)` (or any other
    /// multi-write action), use the closure-based overload instead:
    /// `recordMacro(executeOnBoot:_:)`.
    ///
    /// - Parameters:
    ///   - executeOnBoot: Whether to run on every power-on.
    ///   - commands: The commands to record, in order.
    /// - Returns: An `MWMacro` handle for later execution or identification.
    func recordMacro(
        executeOnBoot: Bool = false,
        commands: [any MWCommand]
    ) async throws -> MWMacro {
        let packets = commands.map { $0.commandData }
        return try await commitMacro(executeOnBoot: executeOnBoot, packets: packets)
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

    /// Shared BEGIN → ADD_COMMAND… → END implementation. Used by both the
    /// array-form and closure-form `recordMacro` overloads.
    private func commitMacro(executeOnBoot: Bool, packets: [Data]) async throws -> MWMacro {
        // BEGIN: [0x0F, 0x02, exec_on_boot] — responds with [0x0F, 0x02, macro_id]
        // as a plain notification (NOT [0x0F, 0x82, macro_id] / read response).
        // Same pattern as logger subscribe / processor add / event create /
        // timer create — every "create resource on register 0x02" reply lands
        // without the read bit, so we await on `notifyWaiters`. `sendRead`
        // would await on read responses and time out here.
        let beginCmd = Data([MWModule.macro.rawValue, 0x02, executeOnBoot ? 0x01 : 0x00])
        let response = try await sendAndAwaitNotification(
            command: beginCmd,
            awaitModule: .macro,
            awaitRegister: 0x02
        )
        guard response.count >= 3 else {
            throw MWError.operationFailed("Macro begin response too short: \(response.count) bytes")
        }
        let macroID = response[2]

        // ADD commands
        for packet in packets {
            try await addMacroCommand(packet)
        }

        // END: [0x0F, 0x04]
        try await writeMacroRaw(Data([MWModule.macro.rawValue, 0x04]))

        return MWMacro(id: macroID)
    }

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
