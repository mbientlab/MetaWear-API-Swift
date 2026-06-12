import Foundation

// MARK: - MWEvent

/// A handle to an on-device event binding created via `MetaWearDevice.createEvent(...)`.
///
/// Events bind a source signal to a destination command that executes automatically
/// on the MetaWear — no BLE connection required once set up.
///
/// Typical flow:
/// ```swift
/// // Flash green LED every time timer 0 fires
/// let timer = try await device.createTimer(periodMs: 1000)
/// let event = try await device.createEvent(
///     source: .timerFired(timer),
///     action: MWEventAction(command: MWLED.Play())
/// )
/// try await device.startTimer(timer)
///
/// // Later, tear down:
/// try await device.removeEvent(event)
/// try await device.removeTimer(timer)
/// ```
public struct MWEvent: Sendable {
    /// Board-assigned ID used for removal.
    public let id: UInt8
}

// MARK: - MWEventSource

/// Describes the signal that triggers an event.
public struct MWEventSource: Sendable {
    public let module: MWModule
    /// Raw register byte (not OR'd with the read bit).
    public let register: UInt8
    /// Signal instance ID. Use `0xFF` to match any instance.
    public let dataID: UInt8

    public init(module: MWModule, register: UInt8, dataID: UInt8 = 0xFF) {
        self.module   = module
        self.register = register
        self.dataID   = dataID
    }
}

// MARK: - Source-module register opcodes referenced by event constructors
//
// Each event source identifies "module + register" of the signal that fires
// the event. The opcodes below name those signal registers so the convenience
// constructors don't read like a string of magic numbers.

private enum SourceRegister {
    /// TIMER module — TIMER_NOTIFY: fires once per timer tick. Register 0x06.
    static let timerNotify: UInt8       = 0x06
    /// SWITCH module — SWITCH_STATE: fires on every button state change. Register 0x01.
    static let switchState: UInt8       = 0x01
    /// GPIO module — PIN_CHANGE_NOTIFY: fires on pin-change interrupt. Register 0x0A.
    static let gpioPinChange: UInt8     = 0x0A
    /// SETTINGS module — DISCONNECT_EVENT: fires when the host drops connection. Register 0x0A.
    static let settingsDisconnect: UInt8 = 0x0A
}

// MARK: - Convenience source constructors

public extension MWEventSource {
    /// Fires each time the given timer ticks (`[0x0C, 0x06, timer_id]`).
    static func timerFired(_ timer: MWTimer) -> MWEventSource {
        MWEventSource(module: .timer, register: SourceRegister.timerNotify, dataID: timer.id)
    }

    /// Fires on every button state change (`[0x01, 0x01, ...]`).
    static func buttonChanged() -> MWEventSource {
        MWEventSource(module: .switch_, register: SourceRegister.switchState, dataID: 0xFF)
    }

    /// Fires on a GPIO pin-change notification for the given pin.
    static func gpioChanged(pin: UInt8) -> MWEventSource {
        MWEventSource(module: .gpio, register: SourceRegister.gpioPinChange, dataID: pin)
    }

    /// Fires when the board is disconnected by the host (`[0x11, 0x0A, ...]`).
    /// Bind this to a command to have the board run that command on disconnect
    /// — e.g. stop advertising, save state. Requires settings revision ≥ 2.
    static func disconnected() -> MWEventSource {
        MWEventSource(module: .settings, register: SourceRegister.settingsDisconnect, dataID: 0xFF)
    }
}

// MARK: - MWEventDataToken

/// Optional "data token" that slices bytes from the source signal's payload
/// into the destination command's parameter block at event-fire time.
///
/// Without a token, the destination command runs with its parameters exactly as
/// built (straight passthrough — the source signal's payload is ignored). With
/// a token, the firmware copies `length` bytes starting at `sourceOffset` of
/// the source signal into the destination params starting at `destOffset`,
/// overwriting whatever static bytes occupied that region.
///
/// Wire format (2 bytes appended to the ENTRY command):
/// ```
/// byte 0: 0x01 | (length << 1) | (sourceOffset << 4)
/// byte 1: destOffset
/// ```
/// Bit 0 is the "token present" marker. `length` occupies bits 1–3 (max 7);
/// `sourceOffset` occupies bits 4–7 (max 15).
public struct MWEventDataToken: Sendable, Equatable {
    /// Bytes of source data to copy into the destination command. Valid: 1…7.
    public let length: UInt8
    /// Byte offset into the source signal's payload. Valid: 0…15.
    public let sourceOffset: UInt8
    /// Byte offset into the destination command's params where the slice is written.
    public let destOffset: UInt8

    public init(length: UInt8, sourceOffset: UInt8 = 0, destOffset: UInt8 = 0) {
        precondition((1...7).contains(length),  "length must fit in 3 bits (1...7)")
        precondition(sourceOffset <= 15,        "sourceOffset must fit in 4 bits (0...15)")
        self.length       = length
        self.sourceOffset = sourceOffset
        self.destOffset   = destOffset
    }

    /// The 2-byte on-wire encoding appended to the ENTRY command.
    public var encodedBytes: [UInt8] {
        [
            0x01 | (length << 1) | (sourceOffset << 4),
            destOffset
        ]
    }
}

// MARK: - MWEventAction

/// Describes the command that executes when the source fires.
public struct MWEventAction: Sendable {
    public let module: MWModule
    /// Raw register byte (destination command register).
    public let register: UInt8
    /// Parameter bytes that follow module+register in the BLE command.
    public let params: Data

    public init(module: MWModule, register: UInt8, params: Data = Data()) {
        self.module   = module
        self.register = register
        self.params   = params
    }

    /// Build an action from any `MWCommand`.
    /// Splits `commandData` into (module, register, params).
    public init(command: any MWCommand) {
        let data   = command.commandData
        module     = MWModule(rawValue: data[0]) ?? .debug
        register   = data[1]
        params     = data.count > 2 ? data.advanced(by: 2) : Data()
    }
}

// MARK: - MetaWearDevice event API

public extension MetaWearDevice {

    // MARK: Create

    /// Bind a source signal to a destination command on the device.
    ///
    /// The board responds with an assigned event ID after receiving the ENTRY
    /// command. If the action has parameters, they are written immediately after
    /// in a CMD_PARAMETERS packet.
    ///
    /// Pass a `dataToken` to slice bytes from the source signal's payload into
    /// the destination command's parameters at fire time (e.g. routing a
    /// processor output value into part of a BLE advertising payload). Without
    /// a token, the destination command's `params` are sent as-is on every fire
    /// — straight passthrough.
    ///
    /// - Parameters:
    ///   - source: The signal whose notification triggers the action.
    ///   - action: The command to execute when the source fires.
    ///   - dataToken: Optional source→destination byte slicing instructions.
    /// - Returns: An `MWEvent` handle that can be used to remove the binding.
    func createEvent(
        source: MWEventSource,
        action: MWEventAction,
        dataToken: MWEventDataToken? = nil
    ) async throws -> MWEvent {
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
        let entryCmd = Data(entryBytes)

        // Board responds with [0x0A, 0x02, event_id] after processing ENTRY.
        // The reply is a plain notification (high bit clear), NOT a read
        // response — same shape as logger subscribe / processor add.
        // `sendRead` would await on the read-response form (0x82) and time out.
        let response = try await sendAndAwaitNotification(
            command: entryCmd, awaitModule: .event, awaitRegister: 0x02
        )
        guard response.count >= 3 else {
            throw MWError.operationFailed("Event create response too short: \(response.count) bytes")
        }
        let eventID = response[2]

        // Send parameters if the action command has a payload
        if !action.params.isEmpty {
            try await writeRaw(Data([MWModule.event.rawValue, 0x03] + action.params))
        }

        return MWEvent(id: eventID)
    }

    // MARK: Remove

    /// Remove a specific event binding by its board-assigned ID.
    func removeEvent(_ event: MWEvent) async throws {
        try await writeRaw(Data([MWModule.event.rawValue, 0x04, event.id]))
    }

    /// Remove all event bindings from the board.
    func removeAllEvents() async throws {
        try await writeRaw(Data([MWModule.event.rawValue, 0x05]))
    }
}
