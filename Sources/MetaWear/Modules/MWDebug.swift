import Foundation

// MARK: - Debug commands

/// Commands for the MetaWear debug module (0xFE).
/// These control board lifecycle: reset, DFU bootloader, and clean disconnect.
public enum MWDebug {

    /// Soft-reset the board. The BLE connection will drop; reconnect after ~1 second.
    public struct Reset: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.debug, 0x01, []) }
    }

    /// Jump to DFU (Device Firmware Update) bootloader mode.
    /// The board will appear as a Nordic DFU target over BLE.
    public struct JumpToBootloader: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.debug, 0x02, []) }
    }

    /// Cleanly disconnect from the board (board-initiated disconnect).
    /// Prefer this over dropping BLE from the host side so the board cleans up state.
    public struct Disconnect: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.debug, 0x06, []) }
    }

    /// Reset after garbage collection completes.
    /// Used after macro / event recording to apply changes.
    public struct ResetAfterGC: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.debug, 0x05, []) }
    }

    /// Enable low-power (sleep) mode.
    public struct EnablePowerSave: MWCommand, Sendable {
        public init() {}
        public var commandData: Data { MWPacket.command(.debug, 0x07, []) }
    }

    // MARK: - Stack overflow assertion (firmware rev ≥ 2)
    //
    // Register 0x09 in C++ `debug.cpp` (`DebugRegister::STACK_OVERFLOW`).
    // C++ `mbl_mw_debug_set_stack_overflow_assertion` coerces any non-zero
    // enable value to exactly 1 before sending.

    /// Enable or disable stack-overflow assertion monitoring.
    ///
    /// Emits `[0xFE, 0x09, enable]` where `enable` is 0 or 1. Python reference
    /// vectors (from `test_debug.py::test_stack_overflow`):
    /// ```
    /// enable=false → [0xFE, 0x09, 0x00]
    /// enable=true  → [0xFE, 0x09, 0x01]
    /// ```
    public struct SetStackOverflowAssertion: MWCommand, Sendable {
        public let enable: Bool
        public init(_ enable: Bool) { self.enable = enable }
        public var commandData: Data {
            MWPacket.command(.debug, 0x09, [enable ? 1 : 0])
        }
    }

    /// Decoded response of `mbl_mw_debug_read_stack_overflow_state`.
    ///
    /// Matches C++ `OverflowState` struct — 1-byte enable flag followed by a
    /// little-endian `UInt16` length counter (bytes used on the stack high-water mark).
    public struct OverflowState: Sendable, Equatable {
        /// Stack high-water mark, in bytes.
        public let length: UInt16
        /// Whether the stack-overflow assertion was armed at read time.
        public let assertEnabled: Bool

        public init(length: UInt16, assertEnabled: Bool) {
            self.length = length
            self.assertEnabled = assertEnabled
        }
    }

    /// One-shot read of the stack-overflow monitoring state.
    ///
    /// Emits `[0xFE, 0x89]` (register 0x09 with the read bit). Response shape
    /// per C++ `overflow_status_received`:
    ///   `[0xFE, 0x89, assert_en, length_lo, length_hi]`.
    public struct ReadStackOverflowState: MWReadable {
        public typealias Sample = OverflowState

        public init() {}

        public let module: MWModule = .debug
        public let dataRegister: UInt8 = 0x09
        public let packedDataRegister: UInt8? = nil

        public var readCommand: Data { MWPacket.read(.debug, 0x09) }

        public func parseSample(from packet: Data) throws -> OverflowState {
            try MWPacketParser.parseOverflowState(packet)
        }
    }

    // MARK: - Schedule queue usage (firmware rev ≥ 2)
    //
    // Register 0x0A in C++ `debug.cpp` (`DebugRegister::SCHEDULE_QUEUE`).
    // Response is a raw byte-array telemetry snapshot; the C++ side routes it
    // through `DataInterpreter::BYTE_ARRAY` — no structured decoding.

    /// One-shot read of the scheduler queue usage (debug/telemetry).
    ///
    /// Emits `[0xFE, 0x8A]`. Response payload is returned as `[UInt8]` with the
    /// module/register header stripped. Python reference vector (13 payload bytes):
    /// ```
    /// [0x03, 0x02, 0x01, 0x00, 0x10, 0x01, 0x01, 0x00, 0x00, 0x00, 0x1B, 0x00, 0x1E]
    /// ```
    public struct ReadScheduleQueueUsage: MWReadable {
        public typealias Sample = [UInt8]

        public init() {}

        public let module: MWModule = .debug
        public let dataRegister: UInt8 = 0x0A
        public let packedDataRegister: UInt8? = nil

        public var readCommand: Data { MWPacket.read(.debug, 0x0A) }

        public func parseSample(from packet: Data) throws -> [UInt8] {
            try MWPacketParser.parseScheduleQueueUsage(packet)
        }
    }

    // MARK: - Spoof button event
    //
    // Register 0x03 in C++ `debug.cpp` (`DebugRegister::NOTIFICATION_SPOOF`).
    // C++ `mbl_mw_debug_spoof_button_event(value)` emits a hard-coded
    // notification-spoof payload pointing at the switch module:
    //   [0xFE, 0x03, 0x01, 0x01, 0x00, value]
    //               └──┬──┘  └─┬─┘  └──┬──┘
    //             switch mod, reg 1, data_id 0
    //
    // i.e. "pretend the switch module (0x01) sent a register-1 notification
    // with state byte `value`" — useful for driving event/macro pipelines on
    // the host without physically pressing the button.

    /// Spoof a mechanical-button (switch module, reg 0x01) notification with
    /// the given state byte. Firmware reacts as if the push-button fired.
    ///
    /// Python reference vector (`test_debug.py::test_switch_spoof`, value=0x07):
    /// `[0xFE, 0x03, 0x01, 0x01, 0x00, 0x07]`.
    public struct SpoofButtonEvent: MWCommand, Sendable {
        public let value: UInt8
        public init(_ value: UInt8) { self.value = value }
        public var commandData: Data {
            MWPacket.command(.debug, 0x03, [0x01, 0x01, 0x00, value])
        }
    }
}
