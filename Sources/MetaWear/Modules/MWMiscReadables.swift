import Foundation

// MARK: - Misc one-shot readables (parity with the old Combine SDK)
//
// Groups small logging/settings readables that don't warrant their own file.
// Each conforms to `MWReadable` so it composes with the generic
// `device.read(_:)` helper and the polling stream:
//
// ```swift
// let entries = try await device.read(MWLogLength())         // Timestamped<UInt32>
// let reset   = try await device.read(MWLastResetTime())     // Timestamped<Reading> — { epoch, resetUID }
// let mac     = try await device.read(MWMACAddress())        // Timestamped<String>
// ```

// MARK: - Logging ENTRIES_LEFT (0x0B / 0x05)
//
// Mirrors `mbl_mw_logging_get_length` in the C++ SDK. The firmware responds
// with the number of log entries currently stored on-device; each entry is
// 4 bytes of parent-signal payload. `downloadLogs()` already consumes this
// value internally, but exposing it as a `MWReadable` lets callers poll
// capacity ahead of a download.
//
// Request:  `[0x0B, 0x85]`        (register 0x05 | READ)
// Response: `[0x0B, 0x85, n0, n1, n2, n3]` — UInt32 LE entry count at offset 2.

/// One-shot read of the on-device log entry count.
public struct MWLogLength: MWReadable {
    public typealias Sample = UInt32

    public init() {}

    public let module: MWModule = .logging
    public let dataRegister: UInt8 = 0x05
    public let packedDataRegister: UInt8? = nil

    /// `[0x0B, 0x85]` — LOG_LENGTH with the read bit set.
    public var readCommand: Data { MWPacket.read(.logging, 0x05) }

    public func parseSample(from packet: Data) throws -> UInt32 {
        guard packet.count >= 6 else {
            throw MWError.operationFailed("Log length packet too short: \(packet.count) bytes")
        }
        return MWPacketParser.parseUInt32LE(packet, offset: 2)
    }
}

// MARK: - Logging TIME reference (0x0B / 0x04)
//
// Mirrors the firmware's LOGGING_TIME register. The board responds with its
// current tick counter plus a reset-UID byte; dividing the tick by the
// board's clock (≈ 1.4648 ms/tick) gives milliseconds since the device's
// last reset. Converting that to a wall-clock `Date` yields the moment the
// board was last powered on / reset, and the trailing `reset_uid` byte is
// the firmware's per-boot counter — it is the unambiguous "the board
// rebooted" signal (some firmware revisions pause / persist the tick
// counter across soft resets, but `reset_uid` always increments on a real
// boot, mod 8).
//
// Request:  `[0x0B, 0x84]`
// Response: `[0x0B, 0x84, t0, t1, t2, t3, reset_uid]` — UInt32 LE tick at
// offset 2. Parity with the Combine SDK's `MWLastResetTime`, which returns
// the reset moment as a `Date` paired with the reset UID.

/// One-shot read of the board's "last reset" wall-clock time.
///
/// `epoch` is computed as `now − (tick × msPerTick)`. Accuracy degrades with
/// BLE round-trip jitter, so treat the value as approximate (±50 ms typical).
/// `resetUID` is the firmware's 3-bit per-boot counter — *intended* to
/// increment on every reset, but in the field neither field is reliable on
/// its own:
///   • Some firmware revisions pause/persist the tick counter across
///     `[0xFE, 0x05]`, so `epoch` looks ~unchanged across a real reboot.
///   • Some other firmware revisions don't advance `resetUID` even after a
///     confirmed reboot.
/// The two quirks appear to be mutually exclusive — if you need a robust
/// "did the board reboot?" signal, require **either** `resetUID` to change
/// mod 8 **or** `epoch` to advance by more than ~1 s. See
/// `factoryReset_isObservableInLoggingTime` for the canonical assertion.
public struct MWLastResetTime: MWReadable {

    /// Parsed LOGGING_TIME response.
    public struct Reading: Sendable, Equatable {
        /// Approximate wall-clock moment the board last booted, derived from
        /// the firmware tick counter and the local clock.
        ///
        /// On firmware that resets the tick counter at boot, this jumps
        /// forward to ~now after a reboot. On firmware that pauses/persists
        /// the tick across `[0xFE, 0x05]`, it stays ~unchanged. Pair with
        /// `resetUID` to detect a reboot reliably across firmware variants.
        public let epoch: Date

        /// Firmware reset counter, masked to its valid 3-bit range (0…7).
        /// *Designed* to increment on every reset, but observed in the field
        /// to remain stuck on some firmware revisions even after a confirmed
        /// reboot. Don't rely on this signal alone — combine with `epoch`.
        public let resetUID: UInt8

        public init(epoch: Date, resetUID: UInt8) {
            self.epoch = epoch
            self.resetUID = resetUID & MWLastResetTime.resetUIDMask
        }
    }

    public typealias Sample = Reading

    /// Mask matching the C++ SDK's `RESET_UID_MASK` — the firmware encodes
    /// `reset_uid` in the low 3 bits of its byte.
    public static let resetUIDMask: UInt8 = 0x07

    public init() {}

    public let module: MWModule = .logging
    public let dataRegister: UInt8 = 0x04
    public let packedDataRegister: UInt8? = nil

    /// `[0x0B, 0x84]` — LOGGING_TIME with the read bit set.
    public var readCommand: Data { MWPacket.read(.logging, 0x04) }

    public func parseSample(from packet: Data) throws -> Reading {
        // Need [0x0B, 0x84, t0, t1, t2, t3, reset_uid] — exactly 7 bytes.
        // Older firmware was thought to omit the trailing byte, but every
        // build the SDK targets (1.5.0+) returns the full 7-byte payload.
        guard packet.count >= 7 else {
            throw MWError.operationFailed("Log time packet too short: \(packet.count) bytes")
        }
        let tick = MWPacketParser.parseUInt32LE(packet, offset: 2)
        let msElapsed = Double(tick) * MWPacketParser.msPerTick
        let epoch = Date(timeIntervalSinceNow: -(msElapsed / 1000.0))
        return Reading(epoch: epoch, resetUID: packet[6])
    }
}

// MARK: - MAC address (parity naming)
//
// The canonical implementation lives at `MWSettings.ReadMacAddress`. This
// typealias matches the Combine SDK's `MWMACAddress` name so callers can
// port code unchanged.

public typealias MWMACAddress = MWSettings.ReadMacAddress

// MARK: - MWPollable conformances
//
// Mark the readables whose values evolve over time (battery, power/charge
// state, environmental sensors, log capacity) as `MWPollable` so they work
// with `device.poll(_:every:)`. One-shot identity reads (MAC address) are
// also conformed since polling them is a harmless no-op way to verify the
// link is alive.

extension MWLogLength: MWPollable {}
extension MWLastResetTime: MWPollable {}

extension MWSettings.ReadBatteryState: MWPollable {}
extension MWSettings.ReadMacAddress:   MWPollable {}
extension MWSettings.ReadPowerStatus:  MWPollable {}
extension MWSettings.ReadChargeStatus: MWPollable {}

extension MWHumidity: MWPollable {}
extension MWBarometerPressureRead: MWPollable {}
extension MWThermometer: MWPollable {}
extension MWSensorFusionCalibrationState: MWPollable {}
