import Foundation

// MARK: - MWPolledLoggable

/// A read-only sensor (`MWReadable`) whose responses can be captured to the
/// board's flash log by pairing a timer + event with a logger subscription.
///
/// Conforming types declare how their data payload (the bytes *after* the
/// two-byte BLE `[module, register]` header) should be split into 4-byte
/// flash entries — same shape as `MWLoggable`, but driven by an on-board
/// timer rather than the sensor streaming on its own.
public protocol MWPolledLoggable: MWReadable {
    /// How to split the readable's data payload into 4-byte flash entries.
    /// Each element is `(byteOffset, byteCount)` within the bytes after the
    /// 2-byte BLE header. One logger ID is allocated per chunk.
    var logDataChunks: [(offset: UInt8, length: UInt8)] { get }

    /// Source index byte for the logger trigger. Readables with a per-channel
    /// data id (e.g. the multichannel thermometer) return the channel here so
    /// the firmware matches the logger to that channel's responses; id-less
    /// readables use the default `0xFF`.
    var loggerTriggerIndex: UInt8 { get }

    /// Decode one complete sample from the bytes reassembled in chunk order.
    func parseLogSample(from data: Data) throws -> Sample
}

public extension MWPolledLoggable {
    var loggerTriggerIndex: UInt8 { 0xFF }

    /// Register byte used in the logger TRIGGER: the readable register with
    /// the read (0x80) and silent (0x40) bits set — matching the C++ SDK,
    /// which builds logger triggers from the readable signal's full header
    /// register (e.g. temperature = `0xC1`, not the bare `0x01`). The
    /// timer-driven event must issue the matching SILENT read.
    var loggerTriggerRegister: UInt8 { dataRegister | 0x80 | 0x40 }

    /// Default: prepend a synthetic `[module, register]` header so the
    /// existing `parseSample(from:)` (which expects a full BLE packet) works
    /// on the logger-side reassembled payload too.
    func parseLogSample(from data: Data) throws -> Sample {
        try parseSample(from: Data([module.rawValue, dataRegister]) + data)
    }
}

// MARK: - MWPolledLogger

/// Pairs an `MWPolledLoggable` readable with the on-board timer period at
/// which the firmware should drive the read. Pass to
/// `MetaWearDevice.startLogging(_:)` to set up the timer → event → logger
/// chain in one call.
public struct MWPolledLogger<R: MWPolledLoggable>: Sendable {
    public let readable: R
    public let periodMs: UInt32

    public init(readable: R, periodMs: UInt32) {
        self.readable = readable
        self.periodMs = periodMs
    }

    /// Synthetic key used to store this polled-logger's chunk registry on
    /// `MetaWearDevice`. Distinct from any same-module streamed logger so
    /// the two don't collide if both are active.
    public var loggerKey: String {
        "polled-\(String(format: "%02X", readable.module.rawValue))-\(String(format: "%02X", readable.dataRegister))"
    }
}

// MARK: - Handles returned by startLogging

/// On-board resource IDs allocated by `startLogging(polledLogger:)`. Callers
/// must persist these (or otherwise remember them) so the polled logger can
/// be stopped/recovered across app restarts — the host doesn't poll, the
/// board does, and timer + event survive disconnects.
public struct MWPolledLoggerHandles: Sendable, Codable, Equatable {
    public let timerID: UInt8
    public let eventID: UInt8
    public let loggerIDs: [UInt8]

    public init(timerID: UInt8, eventID: UInt8, loggerIDs: [UInt8]) {
        self.timerID = timerID
        self.eventID = eventID
        self.loggerIDs = loggerIDs
    }
}
