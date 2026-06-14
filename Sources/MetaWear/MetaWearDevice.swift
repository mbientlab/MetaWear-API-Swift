@preconcurrency import CoreBluetooth
import Foundation

// MARK: - Device state

public enum DeviceState: Equatable, Sendable {
    case disconnected
    case connecting
    case idle
    case streaming
    case logging
    case downloading(progress: Double)
}

// MARK: - MetaWearDevice

/// The main entry point for communicating with a single MetaWear sensor.
/// All operations are actor-isolated — thread-safe by default.
public actor MetaWearDevice {

    // MARK: - Public state

    public private(set) var state: DeviceState = .disconnected
    public private(set) var deviceInfo: MWDeviceInformation?
    public private(set) var modules: [MWModule: MWModuleInfo] = [:]
    public nonisolated let identifier: UUID

    /// Called when BLE drops unexpectedly (not via `disconnect()`).
    /// Use this to update your UI and optionally call `reconnect()`.
    public var onUnexpectedDisconnect: (@Sendable (Error) -> Void)?

    // MARK: - Private

    private let transport: any BLETransport
    private let proto: MWProtocolLayer

    private struct ActiveStreamKey: Hashable, Sendable {
        let module: MWModule
        let dataRegister: UInt8
    }

    /// Signals that are currently streaming. Used to detect duplicates and
    /// sensor fusion / raw IMU conflicts.
    private var activeStreamKeys: Set<ActiveStreamKey> = []

    /// Fusion config command (`[0x19, 0x02, mode, range]`) of the currently
    /// running sensor-fusion engine, or `nil` when no fusion output is active.
    /// All simultaneous fusion outputs share one engine, so they must share this
    /// mode/range; a second output requesting a different one is rejected.
    private var activeFusionConfig: Data?

    /// Maps loggerKey → ordered list of (loggerID, byteCount) for each data chunk.
    /// Populated during startLogging; survives disconnects so download still works after reconnect.
    /// Only cleared by clearLog().
    private var loggerRegistry: [String: [(id: UInt8, byteCount: Int)]] = [:]

    /// The wall-clock date corresponding to device tick=0.
    /// Computed during connect from the board's time signal; used to convert ticks → Dates.
    private var logReferenceDate: Date?

    // MARK: - Data processor demux

    /// Single background task that fans out (0x09, 0x03) notifications by processor ID.
    var processorDemuxTask: Task<Void, Never>?
    /// Per-processor-ID continuations registered by `streamProcessor(_:)`.
    var processorContinuations: [UInt8: AsyncThrowingStream<Data, Error>.Continuation] = [:]

    // MARK: - Init

    public init(identifier: UUID, transport: any BLETransport) {
        self.identifier = identifier
        self.transport = transport
        self.proto = MWProtocolLayer(transport: transport)
    }

    // MARK: - Connection

    public func connect() async throws {
        mwLog("[Device] connect: \(identifier)")
        guard case .disconnected = state else {
            mwLog("[Device] connect: already connected or connecting")
            throw MWError.invalidState("Already connected or connecting")
        }
        state = .connecting
        do {
            try await transport.connect(to: identifier)
            await proto.start()
            await hookDisconnectCallback()
            try await initialize()
            state = .idle
            mwLog("[Device] connect: ready")
        } catch {
            state = .disconnected
            throw error
        }
    }

    /// Reconnect after an unexpected BLE drop.
    /// The device must be in `.disconnected` state (set automatically on unexpected drops).
    public func reconnect() async throws {
        try await connect()
    }

    public func disconnect() async throws {
        mwLog("[Device] disconnect: \(identifier)")
        // Unhook the callback first so the disconnect we're about to trigger
        // doesn't call onUnexpectedDisconnect.
        await proto.clearDisconnectHandler()
        await proto.stop()
        try await transport.disconnect()
        state = .disconnected
        activeStreamKeys.removeAll()
        activeFusionConfig = nil
        mwLog("[Device] disconnect: done")
    }

    // MARK: - Factory reset

    /// Scrub all on-device runtime state and reboot the board.
    ///
    /// Equivalent to the C-API call sequence:
    /// ```
    /// mbl_mw_logging_stop(board);
    /// mbl_mw_logging_clear_entries(board);
    /// mbl_mw_event_remove_all(board);
    /// mbl_mw_dataprocessor_remove_all(board);
    /// mbl_mw_macro_erase_all(board);
    /// mbl_mw_debug_reset_after_gc(board);
    /// ```
    ///
    /// The wire sequence (write-without-response, in order) is:
    /// 1. `[0x0B, 0x01, 0x00]` — stop logging
    /// 2. `[0x0B, 0x09, 0xFF, 0xFF, 0xFF, 0xFF]` — drop all log entries
    /// 3. `[0x0B, 0x0A]` — remove all logger triggers
    /// 4. `[0x0A, 0x05]` — remove all event bindings
    /// 5. `[0x09, 0x08]` — remove all data processors
    /// 6. `[0x0F, 0x08]` — erase all macros
    /// 7. `[0xFE, 0x05]` — reset after garbage collection (preferred reboot trigger)
    /// 8. `[0xFE, 0x01]` — immediate reset (fallback: some firmware revisions —
    ///    notably MMS fw 1.5.0 — silently ignore `[0xFE, 0x05]` if the board
    ///    has nothing pending in flash GC, leaving the resetUID unincremented
    ///    and the boot counter unchanged. Step 8 forces the reboot. If step 7
    ///    already triggered a reset, the BLE link is gone and step 8 is
    ///    dropped, which is exactly what we want.)
    ///
    /// After steps 7–8 the BLE link drops and the actor transitions to `.disconnected`.
    /// The `onUnexpectedDisconnect` callback is suppressed because this disconnect
    /// is intentional. Call `connect()` (or `reconnect()`) again after a short
    /// delay (~1s) to bring the device back up.
    ///
    /// - Note: Active timers and currently-streaming sensor outputs aren't stopped
    ///   explicitly — the reboot in step 7 clears all volatile state, including
    ///   sensor output enables and timer handles, so they're swept up automatically.
    ///
    /// - Throws: `MWError.invalidState` if the device is already `.disconnected`,
    ///   or any underlying transport error if a write fails before the reset
    ///   command lands. Once a write fails the sequence aborts — partial resets
    ///   are possible but rare in practice (each step is a single write).
    public func factoryReset() async throws {
        mwLog("[Device] factoryReset: \(identifier)")
        guard state != .disconnected else {
            throw MWError.invalidState("Cannot factory-reset a disconnected device")
        }

        // Suppress the unexpected-disconnect callback: the reset we're about to
        // trigger will drop BLE, but it's intentional, not an unexpected drop.
        await proto.clearDisconnectHandler()

        // 1. Stop active logging. Use a raw write rather than `stopLogging(_:)`
        //    because that overload requires a specific MWLoggable handle, and we
        //    don't (and shouldn't) need to know which sensors are running.
        try await proto.write(MWPacket.command(.logging, 0x01, 0x00))

        // 2. Drop all log entries from flash. Mirrors `mbl_mw_logging_clear_entries`.
        try await proto.write(MWPacket.command(.logging, 0x09, 0xFF, 0xFF, 0xFF, 0xFF))

        // 3. Remove all logger triggers (subscriptions assigned via [0x0B, 0x02, ...]).
        try await proto.write(MWPacket.command(.logging, 0x0A))

        // 4. Remove all event bindings. Mirrors `mbl_mw_event_remove_all`.
        try await removeAllEvents()

        // 5. Remove all data processors. Mirrors `mbl_mw_dataprocessor_remove_all`.
        //    Also tears down the processor demux task and finishes any open
        //    processor streams on the Swift side.
        try await removeAllProcessors()

        // 6. Erase all macros. Mirrors `mbl_mw_macro_erase_all`.
        try await eraseAllMacros()

        // 7. Reset after GC — the firmware finishes garbage collection of the
        //    flash regions we just freed, then reboots. BLE drops momentarily.
        try await send(MWDebug.ResetAfterGC())

        // 8. Immediate reset fallback — see the doc comment above. On MMS
        //    firmware revisions where step 7 is a no-op, this guarantees the
        //    reboot. We swallow any error here because the link may already
        //    be gone (which is what success looks like).
        try? await send(MWDebug.Reset())

        // Local cleanup. The wire side is done; the link will drop on the
        // next BLE event. Tear down the protocol layer and zero out the in-
        // memory caches that won't survive the reboot.
        await proto.stop()
        state = .disconnected
        activeStreamKeys.removeAll()
        activeFusionConfig = nil
        loggerRegistry.removeAll()
        logReferenceDate = nil
        // deviceInfo and `modules` describe immutable hardware — preserved so
        // the caller can decide whether to reuse them after `reconnect()`.
        mwLog("[Device] factoryReset: done")
    }

    // MARK: - Streaming

    /// Stream a sensor signal continuously.
    ///
    /// Usage:
    /// ```swift
    /// let stream = try await device.startStream(MWAccelerometerBMI160(odr: .hz100, range: .g2))
    /// for try await sample in stream {
    ///     print(sample.time, sample.value.x, sample.value.y, sample.value.z)
    /// }
    /// ```
    public func startStream<S: MWStreamable>(
        _ sensor: S,
        usePacked: Bool = true
    ) async throws -> AsyncThrowingStream<Timestamped<S.Sample>, Error> {
        mwLog("[Device] startStream: \(sensor.module.name) packed=\(usePacked)")
        switch state {
        case .idle, .streaming: break
        default: throw MWError.invalidState("Device must be idle or streaming to add a sensor")
        }
        let streamKey = ActiveStreamKey(module: sensor.module, dataRegister: sensor.dataRegister)
        try checkSensorConflict(adding: streamKey)
        let moduleWasAlreadyStreaming = activeStreamKeys.contains { $0.module == sensor.module }

        // Sensor fusion runs a single shared engine; a second output (e.g. euler
        // alongside quaternion) only flips an extra bit in the output-enable
        // mask — it does not reconfigure the engine. All outputs therefore share
        // one mode/range. Adding a second output with a different mode would be
        // silently ignored by the board (the first config wins), so reject it
        // with a clear error rather than returning a stream that never matches
        // the requested mode.
        if sensor.module == .sensorFusion {
            let newConfig = sensor.configureCommands.first {
                $0.count >= 2 && $0[0] == MWModule.sensorFusion.rawValue && $0[1] == 0x02
            }
            if moduleWasAlreadyStreaming {
                if let active = activeFusionConfig, let newConfig, active != newConfig {
                    throw MWError.invalidState(
                        "Cannot add a sensor-fusion output with a different mode/range than the running fusion engine"
                    )
                }
            } else {
                activeFusionConfig = newConfig
            }
        }

        state = .streaming
        activeStreamKeys.insert(streamKey)

        // Choose packed register if available and requested
        let register: UInt8
        if usePacked, let packed = sensor.packedDataRegister {
            register = packed
        } else {
            register = sensor.dataRegister
        }

        // C++ equivalent:
        //   (optional warmup)                     → warmupCommands + delay
        //   mbl_mw_acc_write_acceleration_config  → configureCommands
        //   mbl_mw_datasignal_subscribe           → [module, register, 0x01]
        //   mbl_mw_acc_enable_acceleration_sampling → enableCommand
        //   mbl_mw_acc_start                      → startCommand
        do {
            for cmd in sensor.warmupCommands where !cmd.isEmpty { try await proto.write(cmd) }
            if sensor.warmupDelayNanos > 0 {
                try await Task.sleep(for: .nanoseconds(sensor.warmupDelayNanos))
            }
            if sensor.module == .sensorFusion, moduleWasAlreadyStreaming {
                try await proto.write(MWPacket.command(sensor.module, register, [0x01]))
                if !sensor.enableCommand.isEmpty {
                    try await proto.write(sensor.enableCommand)
                }
            } else {
                for cmd in sensor.configureCommands where !cmd.isEmpty { try await proto.write(cmd) }
                try await proto.write(MWPacket.command(sensor.module, register, [0x01]))
                for cmd in sensor.enableCommands where !cmd.isEmpty { try await proto.write(cmd) }
                for cmd in sensor.startCommands  where !cmd.isEmpty { try await proto.write(cmd) }
            }
        } catch {
            // Roll back — the sensor never started. Leaving it marked active
            // would block any retry with "already streaming".
            activeStreamKeys.remove(streamKey)
            if !activeStreamKeys.contains(where: { $0.module == .sensorFusion }) {
                activeFusionConfig = nil
            }
            state = activeStreamKeys.isEmpty ? .idle : .streaming
            throw error
        }

        let rawStream = await proto.subscribe(to: sensor.module, register: register)
        let isPacked = usePacked && sensor.packedDataRegister != nil

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await packet in rawStream {
                        let now = Date()
                        if isPacked {
                            let samples = try sensor.parsePackedSamples(from: packet)
                            for sample in samples {
                                continuation.yield(Timestamped(time: now, value: sample))
                            }
                        } else {
                            let sample = try sensor.parseSample(from: packet)
                            continuation.yield(Timestamped(time: now, value: sample))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Run a streamable signal's configure → enable → start commands without
    /// subscribing to its BLE notifications.
    ///
    /// Use when something on-board — typically a data processor created via
    /// `createProcessor(_:source:)` — consumes the signal directly. The host
    /// only needs the sensor's data path running; the processor pulls samples
    /// off the bus without any host involvement.
    ///
    /// Unlike `startStream(_:)`, this does not engage BLE notifications and
    /// does not move the device into `.streaming`. The device stays `.idle`,
    /// so a subsequent `startLogging(_:key:)` can succeed against a processor
    /// fed by the prepared source.
    ///
    /// Pair with `teardownSignalSource(_:)` to stop the sensor when done.
    public func prepareSignalSource<S: MWStreamable>(_ sensor: S) async throws {
        mwLog("[Device] prepareSignalSource: \(sensor.module.name)")
        try checkSensorConflict(adding: ActiveStreamKey(module: sensor.module, dataRegister: sensor.dataRegister))
        for cmd in sensor.warmupCommands where !cmd.isEmpty { try await proto.write(cmd) }
        if sensor.warmupDelayNanos > 0 {
            try await Task.sleep(for: .nanoseconds(sensor.warmupDelayNanos))
        }
        for cmd in sensor.configureCommands where !cmd.isEmpty { try await proto.write(cmd) }
        for cmd in sensor.enableCommands    where !cmd.isEmpty { try await proto.write(cmd) }
        for cmd in sensor.startCommands     where !cmd.isEmpty { try await proto.write(cmd) }
    }

    /// Run a streamable signal's stop → disable commands. Undoes the effect of
    /// `prepareSignalSource(_:)` without touching subscription state (since
    /// `prepareSignalSource` never subscribed in the first place).
    public func teardownSignalSource<S: MWStreamable>(_ sensor: S) async throws {
        mwLog("[Device] teardownSignalSource: \(sensor.module.name)")
        for cmd in sensor.stopCommands    where !cmd.isEmpty { try await proto.write(cmd) }
        for cmd in sensor.disableCommands where !cmd.isEmpty { try await proto.write(cmd) }
    }

    public func stopStreaming<S: MWStreamable>(_ sensor: S) async throws {
        mwLog("[Device] stopStreaming: \(sensor.module.name)")
        guard case .streaming = state else { return }
        let streamKey = ActiveStreamKey(module: sensor.module, dataRegister: sensor.dataRegister)
        let remainingKeys = activeStreamKeys.subtracting([streamKey])
        let hasOtherFusionStreams = sensor.module == .sensorFusion
            && remainingKeys.contains { $0.module == .sensorFusion }

        // C++ equivalent:
        //   mbl_mw_acc_stop                        → stopCommand
        //   mbl_mw_acc_disable_acceleration_sampling → disableCommand
        //   mbl_mw_datasignal_unsubscribe           → [module, register, 0x00]
        if hasOtherFusionStreams {
            if !sensor.disableCommand.isEmpty {
                try await proto.write(sensor.disableCommand)
            }
        } else {
            for cmd in sensor.stopCommands    where !cmd.isEmpty { try await proto.write(cmd) }
            for cmd in sensor.disableCommands where !cmd.isEmpty { try await proto.write(cmd) }
        }
        try await proto.write(MWPacket.command(sensor.module, sensor.dataRegister, [0x00]))
        if let packed = sensor.packedDataRegister {
            try await proto.write(MWPacket.command(sensor.module, packed, [0x00]))
        }
        await proto.unsubscribe(from: sensor.module, register: sensor.dataRegister)
        if let packed = sensor.packedDataRegister {
            await proto.unsubscribe(from: sensor.module, register: packed)
        }
        activeStreamKeys.remove(streamKey)
        if !activeStreamKeys.contains(where: { $0.module == .sensorFusion }) {
            activeFusionConfig = nil
        }
        state = activeStreamKeys.isEmpty ? .idle : .streaming
    }

    // MARK: - Logging

    public func startLogging<L: MWLoggable>(_ loggable: L) async throws {
        mwLog("[Device] startLogging: \(loggable.module.name)")
        // Allow stacking — multiple distinct sensors can be added to one
        // logging session by calling this once per sensor while the device is
        // already in `.logging`. But the same signal cannot be subscribed
        // twice: doing so would allocate a duplicate logger-ID on flash, leak
        // the first subscription's chunk entries, and silently overwrite
        // `loggerRegistry[loggerKey]`. Mirrors the conflict check in
        // `checkSensorConflict` for the streaming path, and the duplicate-key
        // guard in the processor-handle `startLogging(_:key:)` overload.
        switch state {
        case .idle, .logging: break
        default:
            throw MWError.invalidState("Device must be idle or already logging")
        }
        if loggerRegistry[loggable.loggerKey] != nil {
            throw MWError.invalidState("\(loggable.loggerKey) is already being logged")
        }
        let priorState = state
        state = .logging
        do {

        // Cold-boot warmup (e.g. BMM150 SLEEP-then-settle). Must precede
        // configureCommands — without this the magnetometer silently produces
        // zero samples on a freshly-powered MetaMotion (matches the streaming
        // path in `prepareSignalSource`). See `MWStreamable.warmupCommands`.
        for cmd in loggable.warmupCommands where !cmd.isEmpty { try await proto.write(cmd) }
        if loggable.warmupDelayNanos > 0 {
            try await Task.sleep(for: .nanoseconds(loggable.warmupDelayNanos))
        }

        // Configure sensor hardware
        for cmd in loggable.configureCommands { try await proto.write(cmd) }

        // Subscribe each data chunk to the logger and collect the assigned IDs.
        // Command:  [0x0B, 0x02, module, register, 0xFF, ((length-1)<<5 | offset)]
        // Response: [0x0B, 0x02, logger_id]   ← plain notification, NOT a read
        //                                       response (high bit stays clear)
        //
        // Must use `writeAndAwaitNotification` here, not `writeAndRead` — the
        // proto layer's read waiters only fire on responses with bit-7 set on
        // the register byte, but the firmware's TRIGGER_DATA_PROC reply comes
        // back as a plain notification.
        //
        // Encoding matches MetaWear-SDK-Cpp datasignal.cpp `get_data_ubyte()`
        // (`((length() - 1) << 5) | offset`) and logging.cpp:868
        // (`((entry_size - 1) << 5) | entry_offset`). The packed byte is decoded
        // back the same way in `queryActiveLoggers()` below.
        var chunks: [(id: UInt8, byteCount: Int)] = []
        for chunk in loggable.logDataChunks {
            let packedByte: UInt8 = ((chunk.length &- 1) << 5) | chunk.offset
            let cmd = Data([MWModule.logging.rawValue, 0x02,
                            loggable.module.rawValue, loggable.dataRegister,
                            0xFF, packedByte])
            let response = try await proto.writeAndAwaitNotification(
                command: cmd, awaitModule: .logging, awaitRegister: 0x02
            )
            guard response.count >= 3 else {
                throw MWError.operationFailed("Logger subscription returned short response")
            }
            chunks.append((id: response[2], byteCount: Int(chunk.length)))
        }
        loggerRegistry[loggable.loggerKey] = chunks

        // Enable sensor output and start hardware
        for cmd in loggable.enableCommands where !cmd.isEmpty { try await proto.write(cmd) }
        for cmd in loggable.startCommands  where !cmd.isEmpty { try await proto.write(cmd) }

        // Enable circular buffer and start logging
        try await proto.write(MWPacket.command(.logging, 0x0B, [0x01]))  // circular buffer on
        try await proto.write(MWPacket.command(.logging, 0x01, [0x01]))  // enable logging

        } catch {
            // Roll back — the logging session never started. Loggers already
            // subscribed on the board are orphaned (cleared by `clearLog()` /
            // `factoryReset()`), but the Swift-side state must not claim an
            // active session, or every retry fails with "already being logged".
            loggerRegistry.removeValue(forKey: loggable.loggerKey)
            state = priorState
            throw error
        }
    }

    public func stopLogging<L: MWLoggable>(_ loggable: L) async throws {
        mwLog("[Device] stopLogging: \(loggable.module.name)")
        // No guard on `state == .logging`: the first call in a multi-sensor
        // stop sequence drops state to `.idle`, but each subsequent sensor
        // still needs its own stop + disable writes — otherwise the board
        // keeps sampling that sensor (and `downloadLogs` returns no entries
        // because the logger never sees a fresh session marker).
        try await proto.write(MWPacket.command(.logging, 0x01, [0x00]))  // stop logging
        for cmd in loggable.stopCommands    where !cmd.isEmpty { try await proto.write(cmd) }
        for cmd in loggable.disableCommands where !cmd.isEmpty { try await proto.write(cmd) }
        state = .idle
    }

    // MARK: - Polled-readable logging

    /// Start logging a read-only (`MWReadable`) sensor by pairing an on-board
    /// timer with an event that triggers the read, then subscribing a logger
    /// to the read response. The board fires reads at `logger.periodMs`
    /// intervals and writes each result to flash without host involvement —
    /// keeps working across disconnects, app close, etc.
    ///
    /// - Returns: The board-allocated `timerID`, `eventID`, and logger IDs.
    ///   Persist these so a later `stopLogging(_:handles:)` can dismantle
    ///   the chain and `recoverLoggers(for:)` can rebuild the registry
    ///   after a fresh app launch.
    public func startLogging<R: MWPolledLoggable>(
        _ logger: MWPolledLogger<R>
    ) async throws -> MWPolledLoggerHandles {
        mwLog("[Device] startLogging polled: \(logger.readable.module.name) period=\(logger.periodMs)ms")
        switch state {
        case .idle, .logging: break
        default:
            throw MWError.invalidState("Device must be idle or already logging")
        }
        // Same rationale as the `MWLoggable` overload: a duplicate subscription
        // would orphan the first logger ID on flash and clobber the registry
        // entry, making download incomplete. The check is before `state = .logging`
        // so a rejected duplicate leaves the device in its prior state intact.
        if loggerRegistry[logger.loggerKey] != nil {
            throw MWError.invalidState("\(logger.loggerKey) is already being logged")
        }
        let priorState = state
        state = .logging
        do {

        // 1. Create the on-board timer that drives the reads.
        let timer = try await createTimer(periodMs: logger.periodMs)

        // 2. Record an event: when the timer fires, execute the readable's
        //    readCommand. The board issues the read internally; the response
        //    flows back out through the readable's data register as a normal
        //    notification, where the logger picks it up below.
        let readData = logger.readable.readCommand
        let action: MWEventAction = {
            let module = MWModule(rawValue: readData[0]) ?? .debug
            // Force the SILENT bit (0x40) onto the read register: silent
            // responses route to the board's internal data path — which is
            // what the logger taps. A loud read (0x80 only) goes out over
            // BLE to the host and the logger captures nothing (verified on
            // MMS firmware 1.7.2).
            let register = (readData.count > 1 ? readData[1] : 0) | 0x40
            let params = readData.count > 2 ? readData.advanced(by: 2) : Data()
            return MWEventAction(module: module, register: register, params: params)
        }()
        let event = try await createEvent(
            source: .timerFired(timer),
            action: action
        )

        // 3. Subscribe a logger per chunk on the readable's data register.
        //    Identical wire pattern to MWLoggable subscription (see the
        //    `startLogging<L: MWLoggable>` overload above for the protocol
        //    detail). Logger ID is returned in the reply notification.
        var chunks: [(id: UInt8, byteCount: Int)] = []
        for chunk in logger.readable.logDataChunks {
            let packedByte: UInt8 = ((chunk.length &- 1) << 5) | chunk.offset
            // Trigger names the readable's FULL register byte (read + silent
            // bits, e.g. temperature = 0xC1) and its channel index — matching
            // how the C++ SDK builds logger triggers from the signal header.
            // A bare register byte (0x01) with index 0xFF never matches the
            // silent read responses and the log stays empty.
            let cmd = Data([MWModule.logging.rawValue, 0x02,
                            logger.readable.module.rawValue,
                            logger.readable.loggerTriggerRegister,
                            logger.readable.loggerTriggerIndex, packedByte])
            let response = try await proto.writeAndAwaitNotification(
                command: cmd, awaitModule: .logging, awaitRegister: 0x02
            )
            guard response.count >= 3 else {
                throw MWError.operationFailed("Polled logger subscription returned short response")
            }
            chunks.append((id: response[2], byteCount: Int(chunk.length)))
        }
        loggerRegistry[logger.loggerKey] = chunks

        // 4. Enable the logging module + circular buffer, then kick off the
        //    timer. Order matters — start the timer last so the first read
        //    fires into a ready logger.
        try await proto.write(MWPacket.command(.logging, 0x0B, [0x01]))
        try await proto.write(MWPacket.command(.logging, 0x01, [0x01]))
        try await startTimer(timer)

        return MWPolledLoggerHandles(
            timerID: timer.id,
            eventID: event.id,
            loggerIDs: chunks.map(\.id)
        )

        } catch {
            // Roll back — the polled session never started. Board-side
            // resources allocated before the failure (timer, event, loggers)
            // are orphaned; `clearLog()`/`factoryReset()` reclaims them.
            loggerRegistry.removeValue(forKey: logger.loggerKey)
            state = priorState
            throw error
        }
    }

    /// Tear down a polled logger: stop and remove the timer, remove the
    /// event binding, stop the logging module. Logger registrations stay
    /// in the registry so a subsequent `downloadLogs(_:)` can drain the
    /// flash entries before they're cleared.
    public func stopLogging<R: MWPolledLoggable>(
        _ logger: MWPolledLogger<R>,
        handles: MWPolledLoggerHandles
    ) async throws {
        mwLog("[Device] stopLogging polled: \(logger.readable.module.name)")
        // Same reasoning as the MWLoggable overload: don't gate on
        // `state == .logging` because the first sensor stopped in a
        // multi-sensor session has already moved state to .idle.
        let timer = MWTimer(
            id: handles.timerID,
            periodMs: logger.periodMs,
            repetitions: MWTimer.infinite,
            immediate: false
        )
        // Best-effort teardown — if a single sub-step fails we still want to
        // try the others rather than leaving half a chain on the board.
        try? await stopTimer(timer)
        try? await removeTimer(timer)
        try? await removeEvent(MWEvent(id: handles.eventID))
        try await proto.write(MWPacket.command(.logging, 0x01, [0x00]))
        state = .idle
    }

    /// Drain the typed log stream for a polled logger. Reuses the existing
    /// closure-based `downloadLogs<S>(key:decode:)` so all the chunk-
    /// reassembly logic stays in one place.
    public func downloadLogs<R: MWPolledLoggable>(
        _ logger: MWPolledLogger<R>
    ) async throws -> AsyncThrowingStream<Download<[MWLoggedSample<R.Sample>]>, Error> {
        let readable = logger.readable
        return try await downloadLogs(key: logger.loggerKey) { data in
            try readable.parseLogSample(from: data)
        }
    }

    /// Refresh `loggerRegistry` for a polled logger by matching the
    /// board's active loggers against the readable's module + data
    /// register. Used after app restart when the registry was lost but
    /// the board's timer + event + logger are still running.
    public func recoverLoggers<R: MWPolledLoggable>(
        for logger: MWPolledLogger<R>
    ) async throws {
        try recoverLoggers(for: logger, using: try await queryActiveLoggers())
    }

    /// Variant of the polled-logger `recoverLoggers(for:)` that matches against
    /// a pre-fetched enumeration — see the `MWLoggable` overload for rationale.
    public func recoverLoggers<R: MWPolledLoggable>(
        for logger: MWPolledLogger<R>,
        using active: [ActiveLogger]
    ) throws {
        // The board echoes the trigger's FULL register byte (read + silent
        // bits) — normalize both sides so 0xC1 matches dataRegister 0x01.
        let matched = active
            .filter {
                $0.module == logger.readable.module
                    && ($0.register & 0x3F) == (logger.readable.dataRegister & 0x3F)
                    && $0.channel == logger.readable.loggerTriggerIndex
            }
            .sorted { $0.loggerID < $1.loggerID }
        guard !matched.isEmpty else {
            throw MWError.operationFailed(
                "No active polled logger found for '\(logger.loggerKey)' on \(logger.readable.module.name)/\(logger.readable.dataRegister)"
            )
        }
        let chunks: [(id: UInt8, byteCount: Int)] = zip(matched, logger.readable.logDataChunks).map {
            (id: $0.loggerID, byteCount: Int($1.length))
        }
        loggerRegistry[logger.loggerKey] = chunks
    }

    /// Download raw log entries from the device.
    /// Returns a stream of progress snapshots, each containing all entries received so far.
    ///
    /// On MMS boards (logging revision ≥ 3) the firmware buffers the active log
    /// page in RAM and only commits to flash when the page fills, so a short
    /// session (a few seconds at low ODR — small enough that the page never
    /// completes before stop) leaves its samples stranded. `LOG_LENGTH` then
    /// reads 0 and the download finishes empty even though the sensor produced
    /// data. We force-flush the active page here so that workflow shape always
    /// works without the caller having to remember `flushLogPage()`. The flush
    /// is a no-op on MMRL (logging revision < 3).
    public func downloadLogs() async throws -> AsyncThrowingStream<Download<[RawLogEntry]>, Error> {
        mwLog("[Device] downloadLogs")
        guard case .idle = state else {
            throw MWError.invalidState("Device must be idle to download")
        }
        state = .downloading(progress: 0)

        do {
            // Force-flush any partial page sitting in RAM so the LOG_LENGTH read
            // below reflects every captured sample. Idempotent — safe to call even
            // if the user already invoked `flushLogPage()` explicitly. No-op on
            // pre-MMS firmware (revision < 3).
            _ = try await flushLogPage()

            // Enable readout-notify and progress channels, then read the entry count.
            try await proto.write(MWPacket.command(.logging, 0x07, [0x01]))  // enable readout notify
            try await proto.write(MWPacket.command(.logging, 0x0D, [0x01]))  // enable page-completed
            try await proto.write(MWPacket.command(.logging, 0x08, [0x01]))  // enable progress

            let rawStream      = await proto.subscribe(to: .logging, register: 0x07)
            let progressStream = await proto.subscribe(to: .logging, register: 0x08)
            let pageStream     = await proto.subscribe(to: .logging, register: 0x0D)

            // Read entry count, then start the download
            let lengthResponse = try await proto.read(.logging, 0x05)
            guard lengthResponse.count >= 6 else {
                throw MWError.operationFailed("Log length response too short")
            }
            let nEntries = MWPacketParser.parseUInt32LE(lengthResponse, offset: 2)

            // Empty log buffer: short-circuit. Issuing the readout with count=0
            // produces no `0x07` raw entries, no `0x0D` page-completed notice, and
            // no `0x08` progress update — `runDownload` would block on
            // `progressStream` forever. Yield a single 100% snapshot with no data
            // and finish.
            if nEntries == 0 {
                await cleanupLogDownloadSetup()
                state = .idle
                let (stream, continuation) = AsyncThrowingStream<Download<[RawLogEntry]>, Error>.makeStream()
                continuation.yield(Download(data: [], percentComplete: 1.0,
                                            totalEntries: 0, entriesDownloaded: 0))
                continuation.finish()
                return stream
            }

            // Readout: [0x0B, 0x06, n_entries(4 LE), n_notify(4 LE)]
            // n_notify = 0 means one progress update per page.
            let cmd = MWPacket.command(.logging, 0x06,
                                       MWPacketParser.le32(nEntries) + MWPacketParser.le32(0))
            try await proto.write(cmd)

            let (stream, continuation) = AsyncThrowingStream<Download<[RawLogEntry]>, Error>.makeStream()
            let downloadTask = Task { [self] in
                await self.runDownload(
                    rawStream: rawStream,
                    progressStream: progressStream,
                    pageStream: pageStream,
                    totalEntries: nEntries,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in downloadTask.cancel() }
            return stream
        } catch {
            await cleanupLogDownloadSetup()
            state = .idle
            throw error
        }
    }

    private func cleanupLogDownloadSetup() async {
        try? await proto.write(MWPacket.command(.logging, 0x07, [0x00]))
        try? await proto.write(MWPacket.command(.logging, 0x0D, [0x00]))
        try? await proto.write(MWPacket.command(.logging, 0x08, [0x00]))
        await proto.unsubscribe(from: .logging, register: 0x07)
        await proto.unsubscribe(from: .logging, register: 0x08)
        await proto.unsubscribe(from: .logging, register: 0x0D)
    }

    /// Download and decode log entries for a specific loggable sensor.
    /// Requires that `startLogging(_:)` was called for this sensor in the same session
    /// so that logger IDs are known.
    public func downloadLogs<L: MWLoggable>(
        _ loggable: L
    ) async throws -> AsyncThrowingStream<Download<[MWLoggedSample<L.Sample>]>, Error> {
        guard let chunks = loggerRegistry[loggable.loggerKey] else {
            throw MWError.invalidState("No logger registered for \(loggable.loggerKey). Call startLogging first.")
        }

        let rawStream = try await downloadLogs()
        let (typed, cont) = AsyncThrowingStream<Download<[MWLoggedSample<L.Sample>]>, Error>.makeStream()

        let decodingTask = Task {
            do {
                for try await progress in rawStream {
                    let decoded = try decodeEntries(progress.data, chunks: chunks, loggable: loggable)
                    cont.yield(Download(data: decoded, percentComplete: progress.percentComplete, totalEntries: progress.totalEntries, entriesDownloaded: progress.entriesDownloaded))
                }
                cont.finish()
            } catch {
                cont.finish(throwing: error)
            }
        }
        cont.onTermination = { _ in decodingTask.cancel() }
        return typed
    }

    // MARK: - Logging — processor handle
    //
    // Logging the *output* of a data processor (rather than a raw sensor) is a
    // common pattern: throttle a 100 Hz fusion stream down to 1 Hz before
    // committing it to flash, accumulate axis magnitudes, gate on a comparator,
    // etc. The wire shape is the same as sensor logging — `[0x0B, 0x02, src_mod,
    // src_reg, src_id, packed]` — except the source triple is the processor's
    // NOTIFY register: `(0x09, 0x03, processorID)`.
    //
    // The caller passes a string `key` to identify the logger registration so
    // it can be matched up with a `downloadLogs` call later. Sensor lifecycle
    // (configure / enable / start / stop the source signal feeding the
    // processor chain) is the caller's responsibility — `startLogging(handle:)`
    // only wires the processor output to flash.

    /// Start logging the output of a data processor.
    ///
    /// The handle's full output (per `nChannels × channelSize`) is split into
    /// chunks of up to 4 bytes — the firmware's per-entry byte limit — and one
    /// logger ID is allocated per chunk. IDs are stored under `key` so a later
    /// `downloadLogs(key:decode:)` call can reassemble the chunks back into
    /// full samples.
    ///
    /// The caller must already have started the source sensor(s) feeding the
    /// processor chain. This method does not touch any sensor lifecycle — it
    /// only enables the logging module and circular buffer.
    ///
    /// Typical flow:
    /// ```swift
    /// // Configure + start the source sensor that feeds the processor chain.
    /// let euler = MWSensorFusionEuler(mode: .ndof, chip: .bmi160)
    /// for cmd in euler.configureCommands { try await device.send(MWPacket.raw(cmd)) }
    /// for cmd in euler.enableCommands    { try await device.send(MWPacket.raw(cmd)) }
    /// for cmd in euler.startCommands     { try await device.send(MWPacket.raw(cmd)) }
    ///
    /// // Throttle euler to 1 Hz, log the throttled output.
    /// let throttle = try await device.createProcessor(
    ///     MWDataProcessor.Time(periodMs: 1000, mode: .absolute),
    ///     source: MWSensorFusionEulerSignal()
    /// )
    /// try await device.startLogging(throttle, key: "euler-1hz")
    ///
    /// // ...later...
    /// try await device.stopLogging(key: "euler-1hz")
    /// for cmd in euler.stopCommands    { try await device.send(MWPacket.raw(cmd)) }
    /// for cmd in euler.disableCommands { try await device.send(MWPacket.raw(cmd)) }
    /// try await device.flushLogPage()
    ///
    /// let download = try await device.downloadLogs(key: "euler-1hz") { data in
    ///     try MWPacketParser.parseEulerAngles(Data([0x19, 0x08]) + data)
    /// }
    /// for try await progress in download { /* ... */ }
    /// ```
    ///
    /// - Parameters:
    ///   - handle: A processor handle returned from `createProcessor(_:source:)`.
    ///   - key:    A unique string under which to register the logger IDs.
    ///             Use the same `key` later in `downloadLogs(key:decode:)`.
    public func startLogging(_ handle: MWProcessorHandle, key: String) async throws {
        mwLog("[Device] startLogging(processor): id=\(handle.id) key=\(key)")
        guard case .idle = state else {
            throw MWError.invalidState("Device must be idle to log")
        }
        guard loggerRegistry[key] == nil else {
            throw MWError.invalidState("Logger key '\(key)' already registered")
        }
        state = .logging
        do {

        // Slice the processor's output into <=4-byte chunks. The firmware's
        // per-flash-entry limit is 4 bytes (LOG_ENTRY_DATA_SIZE). Sample size is
        // nChannels × channelSize — e.g. 16 bytes for euler/quat (4 × float32),
        // 12 bytes for gravity/linear-acc (3 × float32).
        let totalLen = Int(handle.dataLength)
        var chunkOffsets: [(offset: UInt8, length: UInt8)] = []
        var pos = 0
        while pos < totalLen {
            let len = min(4, totalLen - pos)
            chunkOffsets.append((offset: UInt8(pos), length: UInt8(len)))
            pos += len
        }

        // Subscribe each chunk and collect the assigned logger IDs.
        // Wire:     [0x0B, 0x02, 0x09, 0x03, proc_id, packed]
        // Response: [0x0B, 0x02, logger_id]  ← plain notification (not a read
        //                                      response — high bit stays clear)
        // packed = ((length-1) << 5) | offset (matches C++ datasignal.cpp:162)
        // Use `writeAndAwaitNotification` (not `writeAndRead`): the firmware's
        // TRIGGER_DATA_PROC reply doesn't set bit-7 on the register byte.
        var chunks: [(id: UInt8, byteCount: Int)] = []
        for chunk in chunkOffsets {
            let packed: UInt8 = ((chunk.length &- 1) << 5) | chunk.offset
            let cmd = Data([
                MWModule.logging.rawValue, 0x02,
                MWModule.dataProcessor.rawValue, 0x03, handle.id,
                packed
            ])
            let response = try await proto.writeAndAwaitNotification(
                command: cmd, awaitModule: .logging, awaitRegister: 0x02
            )
            guard response.count >= 3 else {
                throw MWError.operationFailed("Logger subscription returned short response")
            }
            chunks.append((id: response[2], byteCount: Int(chunk.length)))
        }
        loggerRegistry[key] = chunks

        // Enable circular buffer and start logging.
        try await proto.write(MWPacket.command(.logging, 0x0B, [0x01]))
        try await proto.write(MWPacket.command(.logging, 0x01, [0x01]))

        } catch {
            // Roll back — the session never started (guard above ensures the
            // prior state was `.idle`). Board-side loggers subscribed before
            // the failure are orphaned; `clearLog()` reclaims them.
            loggerRegistry.removeValue(forKey: key)
            state = .idle
            throw error
        }
    }

    /// Stop logging for a processor-handle registration.
    ///
    /// Disables the global logging module (mirrors `stopLogging<L>(_:)`) but
    /// does not touch any source-sensor lifecycle — the caller is responsible
    /// for stopping the source sensors that feed the processor chain.
    ///
    /// The logger registration under `key` is left in `loggerRegistry` so that
    /// `downloadLogs(key:decode:)` can still find the chunk IDs. Use
    /// `clearLog()` (which wipes the registry) once the download is complete.
    public func stopLogging(key: String) async throws {
        mwLog("[Device] stopLogging(processor): key=\(key)")
        guard case .logging = state else { return }
        guard loggerRegistry[key] != nil else {
            throw MWError.invalidState("No logger registered for key '\(key)'")
        }
        try await proto.write(MWPacket.command(.logging, 0x01, [0x00]))
        state = .idle
    }

    /// Download and decode log entries for a processor-handle registration.
    ///
    /// Requires that `startLogging(_:key:)` was called with the same `key`
    /// (in this session, or in a previous one if the registry was rebuilt via
    /// `recoverLoggers`). The user-supplied `decode` closure runs on the
    /// reassembled chunk bytes — i.e. for a 16-byte euler signal the closure
    /// receives all 16 bytes in chunk order.
    ///
    /// - Parameters:
    ///   - key:    The same string passed to `startLogging(_:key:)`.
    ///   - decode: A pure decoder run against the reassembled per-sample bytes.
    ///             For built-in fusion signals, prepend a fake [module, register]
    ///             header and call the matching `MWPacketParser` method (see
    ///             `MWLoggable`'s default `parseLogSample`).
    public func downloadLogs<S: Sendable>(
        key: String,
        decode: @Sendable @escaping (Data) throws -> S
    ) async throws -> AsyncThrowingStream<Download<[MWLoggedSample<S>]>, Error> {
        guard let chunks = loggerRegistry[key] else {
            throw MWError.invalidState("No logger registered for '\(key)'. Call startLogging(_:key:) first.")
        }

        let rawStream = try await downloadLogs()
        let (typed, cont) = AsyncThrowingStream<Download<[MWLoggedSample<S>]>, Error>.makeStream()

        let decodingTask = Task {
            do {
                for try await progress in rawStream {
                    let decoded = try decodeEntries(progress.data, chunks: chunks, decode: decode)
                    cont.yield(Download(data: decoded, percentComplete: progress.percentComplete, totalEntries: progress.totalEntries, entriesDownloaded: progress.entriesDownloaded))
                }
                cont.finish()
            } catch {
                cont.finish(throwing: error)
            }
        }
        cont.onTermination = { _ in decodingTask.cancel() }
        return typed
    }

    /// Clear all log entries from the device flash and remove all logger subscriptions.
    ///
    /// Stops logging first (`[0x0B, 0x01, 0x00]`) because the firmware
    /// ignores `CLEAR_ENTRIES` (`[0x0B, 0x09, …]`) and `REMOVE_ALL_LOGGERS`
    /// (`[0x0B, 0x0A]`) while sampling is enabled — silently, without an
    /// error. This matters for the orphan-log discard flow where the
    /// board can still be actively logging at the moment we call this.
    /// Mirrors steps 1–3 of `factoryReset()`.
    public func clearLog() async throws {
        guard case .idle = state else {
            throw MWError.invalidState("Device must be idle to clear the log")
        }
        try await proto.write(MWPacket.command(.logging, 0x01, [0x00]))           // stop logging
        try await proto.write(MWPacket.command(.logging, 0x09, [0xFF, 0xFF, 0xFF, 0xFF]))
        try await proto.write(MWPacket.command(.logging, 0x0A, []))               // remove all loggers
        loggerRegistry.removeAll()
    }

    /// Flush the active logging page to flash so in-flight samples become readable.
    ///
    /// Only valid on MMS boards — firmware ignores this command on MMRL, so the
    /// Swift side no-ops when the logging module revision is below 3
    /// (`MMS_REVISION` in the C++ SDK). Safe to call on any device.
    ///
    /// **You almost never need to call this directly.** `downloadLogs()` (and
    /// every overload built on it) auto-flushes before reading `LOG_LENGTH`, so
    /// the standard `startLogging → stop → download` flow works without it.
    /// The remaining use case is a non-download read of `MWLogLength()` mid-
    /// session where you want the count to include the in-RAM partial page.
    ///
    /// Wire format: `[0x0B, 0x10, 0x01]`.
    ///
    /// - Returns: `true` if the command was sent, `false` if the board is not MMS.
    @discardableResult
    public func flushLogPage() async throws -> Bool {
        guard let info = modules[.logging], info.revision >= 3 else {
            return false
        }
        try await proto.write(MWPacket.command(.logging, 0x10, [0x01]))
        return true
    }

    // MARK: - Logger recovery

    /// Timeout for slot-enumeration probes (`queryActiveLoggers` /
    /// `queryActiveProcessors`). The firmware does not respond at all for an
    /// empty slot, so every enumeration *ends* with one timed-out probe —
    /// at the default 5 s read timeout that put a 5-second stall in every
    /// connect/recovery flow. 1 s is still ~20× a typical connection
    /// interval, so a populated slot's response can't realistically miss it.
    static let probeTimeout: Duration = .seconds(1)

    /// Query the board for all currently active logger subscriptions.
    /// Returns one entry per chunk (logger ID) in the order the board assigned them.
    /// Useful for rebuilding `loggerRegistry` after an app restart.
    public func queryActiveLoggers() async throws -> [ActiveLogger] {
        var result: [ActiveLogger] = []
        for id: UInt8 in 0..<32 {
            do {
                // READ request for TRIGGER register: [0x0B, 0x82, logger_id]
                let cmd = Data([MWModule.logging.rawValue, 0x82, id])
                let response = try await proto.writeAndRead(command: cmd, awaitModule: .logging, awaitRegister: 0x02,
                                                            timeout: Self.probeTimeout)
                // Response: [0x0B, 0x82, source_module, source_register, source_data_id, packed_byte]
                // The firmware does NOT echo the logger_id back — the queried `id`
                // IS the logger ID. An empty slot is signalled by a short response
                // or a sentinel 0xFF in the source-module byte.
                guard response.count >= 6 else { break }
                let sourceModuleByte = response[2]
                guard sourceModuleByte != 0xFF else { break }
                guard let module = MWModule(rawValue: sourceModuleByte) else { continue }
                let reg      = response[3]
                let channel  = response[4]
                let packed   = response[5]
                // Low 5 bits = offset, high 3 bits = length-1.
                let offset   = packed & 0x1F
                let length   = ((packed >> 5) & 0x7) + 1
                result.append(ActiveLogger(loggerID: id, module: module,
                                           register: reg, channel: channel,
                                           chunkOffset: offset, chunkLength: length))
            } catch MWError.timeout {
                break  // No more loggers at this ID
            }
        }
        return result
    }

    // MARK: - Data processor recovery

    /// Query the board for all currently-installed data processors.
    /// Returns one entry per processor ID in the order the board reports them.
    /// Used to reconstruct the processor graph behind an anonymous (replayed) signal.
    ///
    /// Response layout (firmware does NOT echo the processor_id):
    /// `[0x09, 0x82, parent_module, parent_register, parent_proc_id_or_0xFF, packed, proc_type, config...]`
    /// The queried `id` IS the processor ID.
    public func queryActiveProcessors() async throws -> [ActiveProcessor] {
        var result: [ActiveProcessor] = []
        for id: UInt8 in 0..<32 {
            do {
                let cmd = Data([MWModule.dataProcessor.rawValue, 0x82, id])
                let response = try await proto.writeAndRead(
                    command: cmd, awaitModule: .dataProcessor, awaitRegister: 0x02,
                    timeout: Self.probeTimeout
                )
                // Need at least: header(2) + parent_mod + parent_reg + parent_proc_id + packed + proc_type
                guard response.count >= 7 else { break }
                let parentModByte = response[2]
                guard parentModByte != 0xFF else { break }
                guard let parentMod = MWModule(rawValue: parentModByte) else { continue }
                let parentReg = response[3]
                let parentProcID = response[4]
                let packed = response[5]
                let offset = packed & 0x1F
                let length = (packed >> 5) + 1
                let procType = response[6]
                let configBytes: [UInt8] = response.count > 7
                    ? Array(response[response.index(response.startIndex, offsetBy: 7)...])
                    : []
                result.append(ActiveProcessor(
                    processorID: id,
                    parentModule: parentMod,
                    parentRegister: parentReg,
                    parentProcessorID: parentProcID,
                    chunkOffset: offset,
                    chunkLength: length,
                    processorType: procType,
                    configBytes: configBytes
                ))
            } catch MWError.timeout {
                break
            }
        }
        return result
    }

    // MARK: - Anonymous signal reconstruction

    /// Reconstruct the full list of logger-backed signals from on-device state.
    ///
    /// Used when the Swift process has restarted (or never configured the loggers
    /// itself) but the board still holds logger + data-processor metadata and
    /// pending flash entries. Walks `queryActiveLoggers()` and
    /// `queryActiveProcessors()`, follows any processor chain back to its root
    /// sensor, and produces `[MWAnonymousSignal]` with canonical identifiers and
    /// typed decode closures.
    ///
    /// Sensor scale factors are resolved at call time from the live board
    /// (`[0x03, 0x83]` for accel, `[0x13, 0x83]` for gyro). Changing the range
    /// on the board afterward invalidates the returned signals — call again to refresh.
    ///
    /// - Throws: `MWError.timeout` if logger or processor enumeration can't be completed.
    public func createAnonymousDataSignals() async throws -> [MWAnonymousSignal] {
        let loggers    = try await queryActiveLoggers()
        let processors = try await queryActiveProcessors()
        let scales     = try await readSensorScales()
        return MWAnonymousSignalBuilder.build(
            loggers: loggers, processors: processors, scales: scales
        )
    }

    /// Internal: read live sensor range bytes and convert to LSB/unit scales.
    /// Any individual read failure is treated as "sensor not present" → nil scale.
    private func readSensorScales() async throws -> MWAnonymousSignalBuilder.Scales {
        var scales = MWAnonymousSignalBuilder.Scales(accel: nil, gyro: nil, mag: 16.0)

        // Accelerometer range — query 0x83 on accel module. Response: [0x03, 0x83, odr, range_byte].
        // The range byte encoding differs between BMI160 and BMI270 (and the
        // 0x03 value collides — ±2g on BMI160 vs ±16g on BMI270), so pass the
        // implementation byte through so the scale lookup can pick the right table.
        if let accInfo = modules[.accelerometer], accInfo.isPresent {
            do {
                let resp = try await proto.writeAndRead(
                    command: Data([MWModule.accelerometer.rawValue, 0x83]),
                    awaitModule: .accelerometer,
                    awaitRegister: 0x03
                )
                if resp.count >= 4 {
                    scales.accel = Self.accelScaleFromRangeByte(resp[3], implementation: accInfo.implementation)
                }
            } catch MWError.timeout {
                // Leave as nil
            }
        }

        // Gyro range — query 0x83 on gyro module. Response: [0x13, 0x83, odr, range_byte].
        if modules[.gyro]?.isPresent == true {
            do {
                let resp = try await proto.writeAndRead(
                    command: Data([MWModule.gyro.rawValue, 0x83]),
                    awaitModule: .gyro,
                    awaitRegister: 0x03
                )
                if resp.count >= 4 {
                    scales.gyro = Self.gyroScaleFromRangeByte(resp[3])
                }
            } catch MWError.timeout {
                // Leave as nil
            }
        }

        return scales
    }

    /// Map the live accelerometer range byte to LSB/g.
    ///
    /// BMI160 and BMI270 encode the range byte differently and both encodings
    /// share the value `0x03` (±2g on BMI160, ±16g on BMI270). The chip is
    /// identified by `implementation`, drawn from the accelerometer module's
    /// discovery info — `1` = BMI160, `4` = BMI270.
    private static func accelScaleFromRangeByte(_ b: UInt8, implementation: UInt8) -> Float {
        switch implementation {
        case 4:  // BMI270 — range byte is 0-based: 0x00=±2g, 0x01=±4g, 0x02=±8g, 0x03=±16g
            switch b {
            case 0x00: return 16384  // ±2g
            case 0x01: return 8192   // ±4g
            case 0x02: return 4096   // ±8g
            case 0x03: return 2048   // ±16g
            default:   return 16384
            }
        default: // BMI160 (impl 1) and anything unknown — fall through to BMI160 table
            switch b {
            case 0x03: return 16384  // ±2g
            case 0x05: return 8192   // ±4g
            case 0x08: return 4096   // ±8g
            case 0x0C: return 2048   // ±16g
            default:   return 16384
            }
        }
    }

    /// Map the BMI160/BMI270 gyroscope range byte (0..4) to LSB/dps.
    private static func gyroScaleFromRangeByte(_ b: UInt8) -> Float {
        switch b {
        case 0x00: return 16.4    // ±2000 dps
        case 0x01: return 32.8    // ±1000 dps
        case 0x02: return 65.6    // ±500 dps
        case 0x03: return 131.2   // ±250 dps
        case 0x04: return 262.4   // ±125 dps
        default:   return 16.4
        }
    }

    /// Rebuild `loggerRegistry` for a sensor after reconnect (e.g. after app restart).
    /// Queries the board for active loggers and matches them by module + register.
    /// Safe to call even if the registry already has an entry — it will be refreshed.
    ///
    /// Recovering several sensors? Enumerate once and use the `using:` overload —
    /// each call of this convenience re-runs the slot enumeration (which always
    /// ends with one timed-out probe).
    public func recoverLoggers<L: MWLoggable>(for loggable: L) async throws {
        try recoverLoggers(for: loggable, using: try await queryActiveLoggers())
    }

    /// Variant of `recoverLoggers(for:)` that matches against a pre-fetched
    /// enumeration from `queryActiveLoggers()`, so callers recovering multiple
    /// sensors pay for the slot scan once.
    public func recoverLoggers<L: MWLoggable>(for loggable: L, using active: [ActiveLogger]) throws {
        // Normalized register comparison (& 0x3F) so triggers created with
        // read/silent bits still match the loggable's bare data register.
        let matched = active
            .filter { $0.module == loggable.module && ($0.register & 0x3F) == (loggable.dataRegister & 0x3F) }
            .sorted { $0.loggerID < $1.loggerID }
        guard !matched.isEmpty else {
            throw MWError.operationFailed(
                "No active logger found for '\(loggable.loggerKey)' on \(loggable.module.name)/\(loggable.dataRegister)"
            )
        }
        let chunks: [(id: UInt8, byteCount: Int)] = zip(matched, loggable.logDataChunks).map {
            (id: $0.loggerID, byteCount: Int($1.length))
        }
        loggerRegistry[loggable.loggerKey] = chunks
    }

    /// How long a download may go without any BLE activity (raw entries,
    /// page-completed notices, or progress updates) before it is aborted
    /// with `MWError.timeout`. Without this, a firmware that stops sending
    /// progress (drained battery, radio glitch) leaves `downloadLogs()`
    /// suspended forever.
    static let downloadInactivityTimeout: Duration = .seconds(60)

    private func runDownload(
        rawStream: AsyncThrowingStream<Data, Error>,
        progressStream: AsyncThrowingStream<Data, Error>,
        pageStream: AsyncThrowingStream<Data, Error>,
        totalEntries: UInt32,
        continuation: AsyncThrowingStream<Download<[RawLogEntry]>, Error>.Continuation
    ) async {
        let accumulator = LogEntryAccumulator()
        let activity = DownloadActivityMonitor()

        // Yield an initial 0% snapshot so callers see the total entry
        // count immediately — useful for UIs that want to render
        // "0 of N entries" before the first firmware progress notification
        // arrives. (Long downloads can wait several seconds for that
        // first page-complete notice, which would otherwise leave the
        // progress bar at 0% with no context.)
        continuation.yield(Download(data: [], percentComplete: 0.0,
                                    totalEntries: totalEntries,
                                    entriesDownloaded: 0))

        // Drain raw-entry notifications in the background
        let entryTask = Task {
            for try await packet in rawStream {
                await activity.bump()
                for entry in (try? RawLogEntry.parseAll(from: packet)) ?? [] {
                    await accumulator.append(entry)
                }
            }
        }

        // Confirm each page-completed notification so the board sends the next page
        let pageTask = Task { [weak self] in
            guard let self else { return }
            for try await _ in pageStream {
                await activity.bump()
                try? await self.proto.write(MWPacket.command(.logging, 0x0E, []))
            }
        }

        // Inactivity watchdog. When the board goes silent on all three
        // channels for `downloadInactivityTimeout`, unsubscribe the logging
        // registers — that finishes the streams cleanly, the progress loop
        // below falls through, and the fall-through path surfaces
        // `MWError.timeout` to the consumer.
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try await Task.sleep(for: .seconds(5))
                if await activity.idleDuration() > Self.downloadInactivityTimeout {
                    mwLog("[Device] download watchdog: no activity for \(Self.downloadInactivityTimeout) — aborting")
                    guard let self else { return }
                    await self.proto.unsubscribe(from: .logging, register: 0x07)
                    await self.proto.unsubscribe(from: .logging, register: 0x08)
                    await self.proto.unsubscribe(from: .logging, register: 0x0D)
                    return
                }
            }
        }
        defer { watchdog.cancel() }

        do {
            for try await packet in progressStream {
                await activity.bump()
                // Firmware sends only [0x0B, 0x08, remaining(LE32)] — 6 bytes total.
                // Older drafts of the SDK assumed an 8-byte payload that included
                // `total`, but the C++ SDK actually caches `total` from the
                // earlier read of register 0x05 (see `logging_response_readout_progress`
                // in metawear/core/cpp/logging.cpp — `memcpy(&entries_left, response + 2,
                // min(len - 2, 4))`). We pass `totalEntries` in via the call site for
                // the same reason.
                guard packet.count >= 6 else { continue }
                let remaining = MWPacketParser.parseUInt32LE(packet, offset: 2)
                let downloaded = totalEntries - min(remaining, totalEntries)
                let percent: Double = totalEntries > 0
                    ? Double(downloaded) / Double(totalEntries)
                    : 1.0
                let snapshot  = await accumulator.all()
                continuation.yield(Download(data: snapshot, percentComplete: percent,
                                            totalEntries: totalEntries,
                                            entriesDownloaded: downloaded))
                if remaining == 0 {
                    // The firmware can deliver the trailing `0x07` raw-entry
                    // packets in the same radio window as the final `0x08`
                    // progress notice. The `entryTask` runs concurrently
                    // (unstructured `Task { ... }` on the global executor)
                    // and may not have drained its buffered packets by the
                    // time we observe `remaining == 0` here. Poll the
                    // accumulator until it reaches the entry count we
                    // cached from the earlier read of register 0x05, or
                    // until progress has been stable for a short window
                    // (in case the firmware sent fewer entries than the
                    // cached total — better an incomplete download than a
                    // 2-second tail on every successful run).
                    let hardDeadline = ContinuousClock.now + .seconds(2)
                    let target       = Int(totalEntries)
                    var lastCount    = snapshot.count
                    var stableSince  = ContinuousClock.now
                    while await accumulator.all().count < target,
                          ContinuousClock.now < hardDeadline {
                        try? await Task.sleep(for: .milliseconds(20))
                        let now = await accumulator.all().count
                        if now != lastCount {
                            lastCount   = now
                            stableSince = ContinuousClock.now
                        } else if ContinuousClock.now - stableSince > .milliseconds(300) {
                            break
                        }
                    }
                    let finalSnapshot = await accumulator.all()
                    if finalSnapshot.count > snapshot.count {
                        continuation.yield(Download(data: finalSnapshot, percentComplete: 1.0,
                                                    totalEntries: totalEntries,
                                                    entriesDownloaded: totalEntries))
                    }
                    entryTask.cancel()
                    pageTask.cancel()
                    await cleanupLogDownloadSetup()
                    state = .idle
                    continuation.finish()
                    return
                }
            }
            // The progress stream finished without `remaining == 0` — the
            // inactivity watchdog unsubscribed the logging channels (or
            // something else tore the subscription down). Either way the
            // readout never completed; surface a timeout.
            entryTask.cancel()
            pageTask.cancel()
            await cleanupLogDownloadSetup()
            state = .idle
            continuation.finish(throwing: MWError.timeout)
        } catch {
            entryTask.cancel()
            pageTask.cancel()
            await cleanupLogDownloadSetup()
            state = .idle
            continuation.finish(throwing: error)
        }
    }

    // MARK: - Log reassembly

    /// Decode an already-downloaded set of raw log entries into typed samples
    /// for one loggable, using the chunk layout registered for it.
    ///
    /// Use this when you have *multiple* active loggers and want to download
    /// them all in one pass: call `downloadLogs()` (no args) once to drain
    /// the board's circular log, accumulate the raw entries, then call this
    /// once per loggable to extract its samples. Calling `downloadLogs(_:)`
    /// per loggable instead would re-trigger the readout each time and the
    /// second call would see `LOG_LENGTH == 0` (the first readout drained
    /// the log).
    ///
    /// - Throws: `MWError.invalidState` if no logger is registered for
    ///   `loggable.loggerKey` — call `startLogging(_:)` (live in the same
    ///   session) or `recoverLoggers(for:)` (across app restart) first.
    public func decodeEntries<L: MWLoggable>(
        _ entries: [RawLogEntry],
        for loggable: L
    ) throws -> [MWLoggedSample<L.Sample>] {
        guard let chunks = loggerRegistry[loggable.loggerKey] else {
            throw MWError.invalidState(
                "No logger registered for '\(loggable.loggerKey)'. Call startLogging(_:) or recoverLoggers(for:) first."
            )
        }
        return try decodeEntries(entries, chunks: chunks, loggable: loggable)
    }

    /// Decode an already-downloaded set of raw log entries into typed samples
    /// for one polled-readable logger. Same multi-logger rationale as the
    /// `MWLoggable` overload — issue a single raw `downloadLogs()` to drain
    /// the board, then call this per polled logger to extract its samples.
    public func decodeEntries<R: MWPolledLoggable>(
        _ entries: [RawLogEntry],
        for logger: MWPolledLogger<R>
    ) throws -> [MWLoggedSample<R.Sample>] {
        guard let chunks = loggerRegistry[logger.loggerKey] else {
            throw MWError.invalidState(
                "No logger registered for '\(logger.loggerKey)'. Call startLogging(_:) or recoverLoggers(for:) first."
            )
        }
        let readable = logger.readable
        return try decodeEntries(entries, chunks: chunks, decode: { data in
            try readable.parseLogSample(from: data)
        })
    }

    /// Decode an already-downloaded set of raw log entries against an
    /// `MWAnonymousSignal` reconstructed via `createAnonymousDataSignals()`.
    ///
    /// Used for the "another app / a previous install configured these
    /// loggers" workflow: the board's logger registry is intact but we
    /// don't have a matching `MWLoggable` on this side. The anonymous
    /// signal carries the logger IDs + per-chunk byte counts + a decode
    /// closure, so reassembly works without any `loggerRegistry` entry.
    public func decodeEntries(
        _ entries: [RawLogEntry],
        for signal: MWAnonymousSignal
    ) throws -> [MWLoggedSample<[MWAnonymousSignal.Output]>] {
        let chunks: [(id: UInt8, byteCount: Int)] = signal.chunks.map {
            (id: $0.id, byteCount: $0.byteCount)
        }
        return try decodeEntries(entries, chunks: chunks, decode: { data in
            try signal.decode(data)
        })
    }

    private func decodeEntries<L: MWLoggable>(
        _ entries: [RawLogEntry],
        chunks: [(id: UInt8, byteCount: Int)],
        loggable: L
    ) throws -> [MWLoggedSample<L.Sample>] {
        try decodeEntries(entries, chunks: chunks) { try loggable.parseLogSample(from: $0) }
    }

    /// Chunk-reassembly core shared by every `decodeEntries`/`downloadLogs` overload.
    ///
    /// Chunks are paired by **per-logger-ID arrival order**, mirroring the C++
    /// SDK (`process_log_data` queues entries per logger ID and pops one from
    /// each queue to form a sample). An earlier draft grouped entries by
    /// identical `(resetUID, tick)` instead — that breaks above ~683 Hz, where
    /// one tick (≈1.465 ms) spans more than one sample and distinct samples
    /// collapse into the same group and get dropped.
    ///
    /// The sample timestamp is taken from the first chunk's entry. A trailing
    /// sample whose later chunks were cut off by the end of the download is
    /// dropped, matching the old behaviour for incomplete groups.
    private func decodeEntries<S: Sendable>(
        _ entries: [RawLogEntry],
        chunks: [(id: UInt8, byteCount: Int)],
        decode: @Sendable (Data) throws -> S
    ) throws -> [MWLoggedSample<S>] {
        let chunkIDs = chunks.map(\.id)
        var queues: [UInt8: [RawLogEntry]] = [:]
        for entry in entries where chunkIDs.contains(entry.id) {
            queues[entry.id, default: []].append(entry)
        }
        let sampleCount = chunkIDs.map { queues[$0]?.count ?? 0 }.min() ?? 0
        guard sampleCount > 0, let firstQueue = queues[chunkIDs[0]] else { return [] }

        let ref = logReferenceDate
        var result: [MWLoggedSample<S>] = []
        result.reserveCapacity(sampleCount)
        for i in 0..<sampleCount {
            var assembled = Data()
            for chunk in chunks {
                let entry = queues[chunk.id]![i]
                var raw = entry.rawData.littleEndian
                let bytes = withUnsafeBytes(of: &raw) { Data($0.prefix(chunk.byteCount)) }
                assembled.append(bytes)
            }
            let sample = try decode(assembled)
            let msElapsed = Double(firstQueue[i].tick) * MWPacketParser.msPerTick
            let date: Date
            if let ref {
                date = Date(timeInterval: msElapsed / 1000.0, since: ref)
            } else {
                // No time reference — use ms-since-reset as a relative offset from epoch
                date = Date(timeIntervalSince1970: msElapsed / 1000.0)
            }
            result.append(MWLoggedSample(date: date, tickMs: msElapsed, value: sample))
        }
        return result.sorted { $0.tickMs < $1.tickMs }
    }

    // MARK: - One-shot reads

    public func readBattery() async throws -> BatteryState {
        let packet = try await proto.read(.settings, 0x0c)
        return try MWPacketParser.parseBatteryState(packet)
    }

    public func readTemperature(channel: UInt8 = 0) async throws -> Float {
        let packet = try await proto.read(.temperature, 0x01, channel)
        return try MWPacketParser.parseTemperature(packet)
    }

    /// Read the active connection's RSSI (in dBm) as observed by the central.
    /// Requires an established connection. Higher (less-negative) values mean
    /// a stronger received signal — e.g. raising the board's TX power via
    /// `MWSettings.SetTXPower(.plus4)` should produce a higher RSSI than
    /// `.zero` at the same distance.
    public func readRSSI() async throws -> Int {
        try await transport.readRSSI()
    }

    /// Read the current sensor fusion calibration state.
    /// Each axis value is 0 (uncalibrated) to 3 (fully calibrated).
    /// Only valid when sensor fusion is active.
    public func readFusionCalibration() async throws -> MWSensorFusionCalibration {
        guard modules[.sensorFusion]?.isPresent == true else {
            throw MWError.operationFailed("Sensor fusion module not present on this device")
        }
        let packet = try await proto.read(.sensorFusion, 0x0B)
        guard packet.count >= 5 else {
            throw MWError.operationFailed("Calibration response too short: \(packet.count) bytes")
        }
        return MWSensorFusionCalibration(
            accelerometer: packet[2],
            gyroscope:     packet[3],
            magnetometer:  packet[4]
        )
    }

    /// Auto-select the correct accelerometer type from module info.
    /// Returns `nil` if the accelerometer module is absent or the implementation is unrecognised.
    public func makeAccelerometer(odrHz: Double = 100, rangeG: Float = 2) -> MWAccelerometer? {
        guard let info = modules[.accelerometer], info.isPresent else { return nil }
        return MWAccelerometer.make(impl: info.implementation, odrHz: odrHz, rangeG: rangeG)
    }

    /// Auto-select the correct gyroscope type from module info.
    /// Returns `nil` if the gyroscope module is absent or the implementation is unrecognised.
    public func makeGyroscope(odrHz: Double = 100, rangeDPS: Float = 2000) -> MWGyroscope? {
        guard let info = modules[.gyro], info.isPresent else { return nil }
        return MWGyroscope.make(impl: info.implementation, odrHz: odrHz, rangeDPS: rangeDPS)
    }

    // MARK: - Commands

    public func send(_ command: any MWCommand) async throws {
        try await proto.write(command.commandData)
    }

    /// Issue a multi-write action (e.g. an Enable/Disable pair for a BMI270
    /// feature, or a long `SetScanResponse` that splits across two registers).
    /// Writes are sent in order — if any individual write throws, subsequent
    /// writes are skipped.
    public func send(_ sequence: any MWCommandSequence) async throws {
        for cmd in sequence.commands {
            try await proto.write(cmd)
        }
    }

    /// Internal: write `command` to the board and await a response notification
    /// on `(awaitModule, awaitRegister)`. Used by GPIO reads and other one-shot
    /// commands that have a different request vs response register.
    func sendRead(command: Data, awaitModule: MWModule, awaitRegister: UInt8) async throws -> Data {
        try await proto.writeAndRead(command: command, awaitModule: awaitModule, awaitRegister: awaitRegister)
    }

    /// Generic one-shot read for any `MWReadable`. Writes the readable's
    /// `readCommand`, awaits the response on `(module, dataRegister)`, parses
    /// the typed sample, and wraps it in a `Timestamped` with the wall-clock
    /// time the response arrived.
    ///
    /// ```swift
    /// let humidity = try await device.read(MWHumidity())   // Timestamped<Float>
    /// let mac      = try await device.read(MWSettings.ReadMacAddress())
    /// ```
    public func read<R: MWReadable>(_ readable: R) async throws -> Timestamped<R.Sample> {
        let packet = try await proto.writeAndRead(
            command: readable.readCommand,
            awaitModule: readable.module,
            awaitRegister: readable.dataRegister
        )
        let value = try readable.parseSample(from: packet)
        return Timestamped(time: Date(), value: value)
    }

    /// Poll an `MWPollable` on a repeating interval and deliver each reading
    /// through an `AsyncThrowingStream`. Cancellation (either from the
    /// consumer terminating iteration or by cancelling the enclosing Task)
    /// stops the polling loop; a thrown read error terminates the stream.
    ///
    /// ```swift
    /// for try await sample in await device.poll(MWSettings.ReadBatteryState(),
    ///                                           every: .seconds(30)) {
    ///     updateBatteryUI(sample.value)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - readable: Any `MWPollable` (i.e. an `MWReadable` marked for polling).
    ///   - interval: Time between successive reads. The first read fires
    ///     immediately; subsequent reads fire `interval` after the previous
    ///     response completes (not on a fixed wall-clock cadence), so a slow
    ///     board can't build up a backlog.
    nonisolated public func poll<P: MWPollable>(
        _ readable: P,
        every interval: Duration
    ) -> AsyncThrowingStream<Timestamped<P.Sample>, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    while !Task.isCancelled {
                        let sample = try await self.read(readable)
                        continuation.yield(sample)
                        try await Task.sleep(for: interval)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Internal: write `command` and await a plain (non-read-bit) notification
    /// on `(awaitModule, awaitRegister)`. Used for I2C/SPI reads where the board
    /// responds with an unsolicited data packet rather than a read-response packet.
    func sendAndAwaitNotification(command: Data, awaitModule: MWModule, awaitRegister: UInt8) async throws -> Data {
        try await proto.writeAndAwaitNotification(command: command, awaitModule: awaitModule, awaitRegister: awaitRegister)
    }

    /// Internal: write raw bytes (used by module extensions outside MetaWearDevice.swift).
    func writeRaw(_ data: Data) async throws {
        try await proto.write(data)
    }

    /// Internal: write raw bytes using write-with-response (macro commands).
    func writeMacroRaw(_ data: Data) async throws {
        try await proto.writeMacro(data)
    }

    /// Internal: subscribe to notifications from (module, register).
    func subscribeRaw(to module: MWModule, register: UInt8) async -> AsyncThrowingStream<Data, Error> {
        await proto.subscribe(to: module, register: register)
    }

    // MARK: - Module info convenience

    public func moduleInfo(for module: MWModule) -> MWModuleInfo? {
        modules[module]
    }

    public var hasGyroscope: Bool      { modules[.gyro]?.isPresent ?? false }
    public var hasMagnetometer: Bool   { modules[.magnetometer]?.isPresent ?? false }
    public var hasBarometer: Bool      { modules[.barometer]?.isPresent ?? false }
    public var hasSensorFusion: Bool   { modules[.sensorFusion]?.isPresent ?? false }

    // MARK: - Initialization

    private func initialize() async throws {
        deviceInfo = try await readDeviceInformation()
        modules    = try await proto.discoverModules()
        await readLogTimeReference()
    }

    // MARK: - Board state (serialize / deserialize)

    /// Capture the current board state for persistence. Call after `connect()` has
    /// completed at least once. Returns `nil` if initialization has not yet run.
    public func captureBoardState() -> MWBoardState? {
        guard let info = deviceInfo else { return nil }
        return MWBoardState(
            deviceInformation: info,
            modules: MWModule.allCases.compactMap { modules[$0] },
            logReferenceDate: logReferenceDate
        )
    }

    /// Restore a previously-captured state to skip module discovery on the next
    /// connect. Must be called while the device is `.disconnected`.
    ///
    /// The caller is responsible for verifying firmware/hardware compatibility via
    /// `MWBoardState.isCompatible(with:)` before calling — this method performs no
    /// validation of its own beyond state.
    public func restoreBoardState(_ state: MWBoardState) throws {
        guard case .disconnected = self.state else {
            throw MWError.operationFailed("restoreBoardState requires disconnected state")
        }
        self.deviceInfo       = state.deviceInformation
        self.modules          = state.modulesByOpcode
        self.logReferenceDate = state.logReferenceDate
    }

    private func readDeviceInformation() async throws -> MWDeviceInformation {
        async let manufacturer  = readDISString(MWUUIDs.manufacturerName)
        async let model         = readDISString(MWUUIDs.modelNumber)
        async let serial        = readDISString(MWUUIDs.serialNumber)
        async let firmware      = readDISString(MWUUIDs.firmwareRevision)
        async let hardware      = readDISString(MWUUIDs.hardwareRevision)
        return try await MWDeviceInformation(
            manufacturer: manufacturer,
            modelNumber:  model,
            serialNumber: serial,
            firmwareRevision: firmware,
            hardwareRevision: hardware
        )
    }

    private func readDISString(_ uuid: CBUUID) async throws -> String {
        let data = try await transport.read(from: uuid)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Read the board's current tick and compute the wall-clock date for tick=0.
    /// Non-fatal: if the logging module is absent or the read times out the reference stays nil.
    private func readLogTimeReference() async {
        guard let response = try? await proto.read(.logging, 0x04),
              response.count >= 6 else { return }
        let tick = MWPacketParser.parseUInt32LE(response, offset: 2)
        let msElapsed = Double(tick) * MWPacketParser.msPerTick
        logReferenceDate = Date(timeIntervalSinceNow: -(msElapsed / 1000.0))
    }

    // MARK: - Disconnect handling

    private func hookDisconnectCallback() async {
        await proto.setDisconnectHandler { [weak self] error in
            guard let self else { return }
            Task { await self.handleUnexpectedDisconnect(error: error) }
        }
    }

    private func handleUnexpectedDisconnect(error: Error) {
        mwLog("[Device] unexpectedDisconnect: \(error.localizedDescription)")
        state = .disconnected
        activeStreamKeys.removeAll()
        activeFusionConfig = nil
        logReferenceDate = nil
        // loggerRegistry is intentionally preserved — the device may still have
        // active loggers. After reconnect the caller can download without re-starting.
        terminateAllProcessorStreams(with: error)
        onUnexpectedDisconnect?(error)
    }

    // MARK: - Sensor conflict detection

    /// Throws if the signal being added would conflict with currently active streams.
    /// Rule: sensor fusion and individual IMU sensors (accel/gyro/mag) are mutually exclusive.
    private func checkSensorConflict(adding key: ActiveStreamKey) throws {
        if activeStreamKeys.contains(key) {
            throw MWError.invalidState("\(key.module.name) register 0x\(String(key.dataRegister, radix: 16)) is already streaming")
        }
        let imuModules: Set<MWModule> = [.accelerometer, .gyro, .magnetometer]
        let activeModules = Set(activeStreamKeys.map(\.module))
        let addingFusion = key.module == .sensorFusion
        let addingIMU    = imuModules.contains(key.module)

        if !addingFusion && activeModules.contains(key.module) {
            throw MWError.invalidState("\(key.module.name) is already streaming")
        }

        if addingFusion && !activeModules.isDisjoint(with: imuModules) {
            let active = activeModules.intersection(imuModules).map { "\($0)" }.joined(separator: ", ")
            throw MWError.invalidState(
                "Cannot start sensor fusion while \(active) is already streaming"
            )
        }
        if addingIMU && activeModules.contains(.sensorFusion) {
            throw MWError.invalidState(
                "Cannot stream \(key.module.name) while sensor fusion is active"
            )
        }
    }
}

// MARK: - Test hooks (internal)

extension MetaWearDevice {
    /// Exposes the log reference date for test assertions.
    func _logReferenceDate() -> Date? { logReferenceDate }
    /// Returns true if loggerRegistry contains an entry for the given key.
    func _loggerRegistryHasKey(_ key: String) -> Bool { loggerRegistry[key] != nil }
    /// Exposes the chunk-reassembly core for unit tests (no registry required).
    func _decodeEntries<S: Sendable>(
        _ entries: [RawLogEntry],
        chunks: [(id: UInt8, byteCount: Int)],
        decode: @Sendable (Data) throws -> S
    ) throws -> [MWLoggedSample<S>] {
        try decodeEntries(entries, chunks: chunks, decode: decode)
    }
}

// MARK: - Raw log entry

/// A single 8-byte on-device flash entry returned during log download.
public struct RawLogEntry: Sendable {
    public let id: UInt8
    public let resetUID: UInt8
    public let tick: UInt32
    public let rawData: UInt32
    /// Elapsed milliseconds since the MetaWear last reset (tick × ms/tick).
    public let epochMs: Double

    /// Parse one entry from raw entry bytes (without the 2-byte BLE notification header).
    init(entryBytes: Data) throws {
        (id, resetUID, tick, rawData) = try MWPacketParser.parseLogEntry(entryBytes)
        epochMs = Double(tick) * MWPacketParser.msPerTick
    }

    /// Parse all log entries from a single BLE notification packet (1 or 2 entries per packet).
    public static func parseAll(from notification: Data) throws -> [RawLogEntry] {
        // Entry layout: 1 byte id/resetUID + 4 byte tick (LE) + 4 byte data = 9 bytes
        // — see `MWPacketParser.parseLogEntry`. A paired BLE notification is
        // therefore 2 (header) + 9 + 9 = 20 bytes; a single-entry one is 11.
        let headerLen = 2   // [module, register]
        let entryLen  = 9
        var result: [RawLogEntry] = []
        if notification.count >= headerLen + entryLen {
            result.append(try RawLogEntry(entryBytes: notification.advanced(by: headerLen)))
        }
        if notification.count >= headerLen + entryLen + entryLen {
            result.append(try RawLogEntry(entryBytes: notification.advanced(by: headerLen + entryLen)))
        }
        return result
    }
}

// MARK: - Log entry accumulator

private actor LogEntryAccumulator {
    private var entries: [RawLogEntry] = []
    func append(_ entry: RawLogEntry) { entries.append(entry) }
    func all() -> [RawLogEntry] { entries }
}

// MARK: - Download activity monitor

/// Tracks the time of the most recent BLE activity during a log download so
/// the inactivity watchdog can distinguish "slow but alive" from "stalled".
private actor DownloadActivityMonitor {
    private var last = ContinuousClock.now
    func bump() { last = ContinuousClock.now }
    func idleDuration() -> Duration { ContinuousClock.now - last }
}
