import Foundation

// MARK: - Switch (mechanical push button)
//
// Mirrors C++ `switch.{h,cpp}`. The switch module (0x01) exposes exactly one
// thing: a streaming signal for the board's physical push button. The firmware
// emits a 1-byte state (0 = released, 1 = pressed) on every transition.
//
// Registers:
//   STATE = 0x01   subscribe (payload 0x01) / unsubscribe (payload 0x00)
//                  state-change notifications arrive on the same register

/// Streams press / release events from the MetaWear's physical button.
///
/// Usage:
/// ```swift
/// let stream = try await device.stream(MWSwitch())
/// for try await event in stream {
///     print(event.value ? "pressed" : "released")
/// }
/// ```
///
/// The legacy Combine SDK called this `MWMechanicalButton`; the Swift 6 SDK
/// standardises on `MWSwitch` to match the C++ module name (`MBL_MW_MODULE_SWITCH`).
public struct MWSwitch: MWStreamable {
    public typealias Sample = Bool

    public init() {}

    // MARK: MWSensor

    public let module: MWModule = .switch_
    /// Register 0x01 (STATE) delivers state-change notifications: `[0x01, 0x01, state]`.
    public let dataRegister: UInt8 = 0x01
    // `packedDataRegister` defaults to `nil` via the MWStreamable protocol — the
    // switch has no packed-data variant.

    // MARK: MWStreamable

    /// No configuration needed — the switch fires on hardware events only.
    public var configureCommands: [Data] { [] }

    /// Subscribe to state-change notifications (the only command needed).
    /// Mirrors Python `test_mbl_mw_switch_subscribe` → `[0x01, 0x01, 0x01]`.
    public var enableCommand: Data  { MWPacket.command(.switch_, 0x01, [0x01]) }
    /// No-op: the switch module subscribes with a single command (enableCommand).
    public var startCommand: Data   { Data() }
    /// Unsubscribe from state-change notifications.
    /// Mirrors Python `test_mbl_mw_switch_unsubscribe` → `[0x01, 0x01, 0x00]`.
    public var disableCommand: Data { MWPacket.command(.switch_, 0x01, [0x00]) }
    /// No-op: the switch module unsubscribes with a single command (disableCommand).
    public var stopCommand: Data    { Data() }

    // MARK: Parsing

    /// Parse a switch-state packet `[0x01, 0x01, state]`.
    /// - Returns: `true` if the button is currently pressed, `false` on release.
    public func parseSample(from packet: Data) throws -> Bool {
        guard packet.count >= 3 else {
            throw MWError.operationFailed("Switch packet too short: \(packet.count) bytes")
        }
        return packet[2] == 0x01
    }

    // `parsePackedSamples` falls through to the MWStreamable default (returns
    // `[]`) — the switch has no packed-data register.
}
