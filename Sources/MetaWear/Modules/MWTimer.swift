import Foundation

// MARK: - MWTimer

/// A handle to an on-device timer created via `MetaWearDevice.createTimer(...)`.
///
/// Timers execute entirely on the MetaWear — no BLE connection required once started.
/// They fire `[0x0C, 0x06, timer_id]` notifications at the configured interval.
///
/// Typical flow:
/// ```swift
/// let timer = try await device.createTimer(periodMs: 1000, repetitions: .infinite)
/// try await device.startTimer(timer)
///
/// // Stream notifications while connected:
/// let ticks = await device.streamTimer(timer)
/// for try await _ in ticks { ... }
///
/// // Stop and clean up when done:
/// try await device.stopTimer(timer)
/// try await device.removeTimer(timer)
/// ```
public struct MWTimer: Sendable, Equatable {
    /// Board-assigned ID (0-based).
    public let id: UInt8
    /// Period in milliseconds.
    public let periodMs: UInt32
    /// How many times the timer fires before stopping. `0xFFFF` = infinite.
    public let repetitions: UInt16
    /// Whether the first fire happens immediately (`true`) or after one period.
    public let immediate: Bool
}

public extension MWTimer {
    /// A repetition count meaning "fire indefinitely".
    static let infinite: UInt16 = 0xFFFF
}

// MARK: - MetaWearDevice timer API

public extension MetaWearDevice {

    // MARK: Create

    /// Create an on-device timer and return a handle.
    ///
    /// - Parameters:
    ///   - periodMs:    How often the timer fires, in milliseconds.
    ///   - repetitions: Number of times to fire. Pass `MWTimer.infinite` (0xFFFF) for indefinite.
    ///   - immediate:   If `true`, the first fire happens at t=0; otherwise after one period.
    func createTimer(
        periodMs: UInt32,
        repetitions: UInt16 = MWTimer.infinite,
        immediate: Bool = false
    ) async throws -> MWTimer {
        // [0x0C, 0x02, period(4 LE), repetitions(2 LE), immediate]
        let cmd = Data([
            MWModule.timer.rawValue, 0x02,
            UInt8(periodMs & 0xFF), UInt8((periodMs >> 8) & 0xFF),
            UInt8((periodMs >> 16) & 0xFF), UInt8((periodMs >> 24) & 0xFF),
            UInt8(repetitions & 0xFF), UInt8(repetitions >> 8),
            immediate ? 0x01 : 0x00
        ])
        // Response: [0x0C, 0x82, timer_id]  (0x02 | read-bit 0x80)
        let response = try await sendRead(command: cmd, awaitModule: .timer, awaitRegister: 0x02)
        guard response.count >= 3 else {
            throw MWError.operationFailed("Timer create response too short: \(response.count) bytes")
        }
        return MWTimer(id: response[2], periodMs: periodMs,
                       repetitions: repetitions, immediate: immediate)
    }

    // MARK: Start / Stop / Remove

    /// Start a previously created timer.
    func startTimer(_ timer: MWTimer) async throws {
        try await send(MWTimerCommand.start(timer))
    }

    /// Stop a running timer (the timer_id remains valid; call `startTimer` to resume).
    func stopTimer(_ timer: MWTimer) async throws {
        try await send(MWTimerCommand.stop(timer))
    }

    /// Remove the timer from the board, freeing its ID. Cannot be restarted after this.
    func removeTimer(_ timer: MWTimer) async throws {
        try await send(MWTimerCommand.remove(timer))
    }

    // MARK: Notification stream

    /// Subscribe to tick notifications from a running timer.
    /// Each element in the stream is the timer ID that fired.
    /// The stream ends when the caller cancels it or the device disconnects.
    func streamTimer(_ timer: MWTimer) async -> AsyncThrowingStream<UInt8, Error> {
        let raw = await subscribeRaw(to: .timer, register: 0x06)
        return raw.compactMap { packet -> UInt8? in
            // [0x0C, 0x06, timer_id]
            guard packet.count >= 3 else { return nil }
            return packet[2] == timer.id ? packet[2] : nil
        }
    }

    // MARK: Enable notifications (needed for the board to send 0x06 packets)

    /// Enable / disable timer-fired notifications on the board.
    /// Call before streaming timer ticks.
    func setTimerNotify(_ timer: MWTimer, enabled: Bool) async throws {
        try await writeRaw(MWPacket.command(.timer, 0x07, [timer.id, enabled ? 0x01 : 0x00]))
    }
}

// MARK: - Timer commands (internal)

enum MWTimerCommand {
    static func start(_ t: MWTimer)  -> any MWCommand { TimerCmd(reg: 0x03, id: t.id) }
    static func stop(_ t: MWTimer)   -> any MWCommand { TimerCmd(reg: 0x04, id: t.id) }
    static func remove(_ t: MWTimer) -> any MWCommand { TimerCmd(reg: 0x05, id: t.id) }

    private struct TimerCmd: MWCommand, Sendable {
        let reg: UInt8
        let id:  UInt8
        var commandData: Data { MWPacket.command(.timer, reg, [id]) }
    }
}

// MARK: - AsyncThrowingStream compactMap helper

extension AsyncThrowingStream where Element == Data, Failure == Error {
    func compactMap<T: Sendable>(_ transform: @escaping @Sendable (Data) -> T?) -> AsyncThrowingStream<T, Error> {
        let (stream, continuation) = AsyncThrowingStream<T, Error>.makeStream()
        Task {
            do {
                for try await element in self {
                    if let mapped = transform(element) { continuation.yield(mapped) }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }
}
