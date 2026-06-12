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
/// let stream = try await device.startStream(MWSwitch())
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

    // The switch's "subscribe" and "enable" are the same write
    // (`[0x01, 0x01, 0x01]`) — `mbl_mw_datasignal_subscribe` is the only
    // command the C++/Combine SDKs ever send for this module. The actor's
    // generic `startStream` already issues `[module, dataRegister, 0x01]`
    // before walking the enable/start commands, and `stopStreaming` issues
    // the matching `[module, dataRegister, 0x00]` on the way out, so all
    // four module-level hooks below are deliberate no-ops. Re-issuing the
    // same write would have been at best redundant and at worst toggled
    // notifications back off on certain firmwares — which presented as a
    // silent stream during hardware testing.
    public var enableCommand: Data  { Data() }
    public var startCommand: Data   { Data() }
    public var disableCommand: Data { Data() }
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
