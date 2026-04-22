@preconcurrency import CoreBluetooth
import Foundation

// MARK: - Device state

public enum DeviceState: Equatable, Sendable {
    case disconnected
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
    public let identifier: UUID

    /// Called when BLE drops unexpectedly (not via `disconnect()`).
    /// Use this to update your UI and optionally call `reconnect()`.
    public var onUnexpectedDisconnect: (@Sendable (Error) -> Void)?

    // MARK: - Private

    private let transport: any BLETransport
    private let proto: MWProtocolLayer

    /// Modules that are currently streaming. Used to detect sensor fusion conflicts.
    private var activeStreamModules: Set<MWModule> = []

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
        try await transport.connect(to: identifier)
        await proto.start()
        hookDisconnectCallback()
        try await initialize()
        state = .idle
        mwLog("[Device] connect: ready")
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
        activeStreamModules.removeAll()
        mwLog("[Device] disconnect: done")
    }

    // MARK: - Streaming

    /// Stream a sensor signal continuously.
    ///
    /// Usage:
    /// ```swift
    /// let stream = try await device.stream(MWAccelerometerBMI160(odr: .hz100, range: .g2))
    /// for try await sample in stream {
    ///     print(sample.time, sample.value.x, sample.value.y, sample.value.z)
    /// }
    /// ```
    public func stream<S: MWStreamable>(
        _ sensor: S,
        usePacked: Bool = true
    ) async throws -> AsyncThrowingStream<Timestamped<S.Sample>, Error> {
        mwLog("[Device] stream: \(sensor.module) packed=\(usePacked)")
        switch state {
        case .idle, .streaming: break
        default: throw MWError.invalidState("Device must be idle or streaming to add a sensor")
        }
        try checkSensorConflict(adding: sensor.module)

        state = .streaming
        activeStreamModules.insert(sensor.module)

        // Choose packed register if available and requested
        let register: UInt8
        if usePacked, let packed = sensor.packedDataRegister {
            register = packed
        } else {
            register = sensor.dataRegister
        }

        // C++ equivalent:
        //   mbl_mw_acc_write_acceleration_config  → configureCommands
        //   mbl_mw_datasignal_subscribe           → [module, register, 0x01]
        //   mbl_mw_acc_enable_acceleration_sampling → enableCommand
        //   mbl_mw_acc_start                      → startCommand
        for cmd in sensor.configureCommands where !cmd.isEmpty { try await proto.write(cmd) }
        try await proto.write(MWPacket.command(sensor.module, register, [0x01]))
        if !sensor.enableCommand.isEmpty { try await proto.write(sensor.enableCommand) }
        if !sensor.startCommand.isEmpty  { try await proto.write(sensor.startCommand) }

        let rawStream = await proto.subscribe(to: sensor.module, register: register)
        let isPacked = usePacked && sensor.packedDataRegister != nil

        return AsyncThrowingStream { continuation in
            Task {
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
        }
    }

    public func stopStreaming<S: MWStreamable>(_ sensor: S) async throws {
        mwLog("[Device] stopStreaming: \(sensor.module)")
        guard case .streaming = state else { return }

        // C++ equivalent:
        //   mbl_mw_acc_stop                        → stopCommand
        //   mbl_mw_acc_disable_acceleration_sampling → disableCommand
        //   mbl_mw_datasignal_unsubscribe           → [module, register, 0x00]
        if !sensor.stopCommand.isEmpty    { try await proto.write(sensor.stopCommand) }
        if !sensor.disableCommand.isEmpty { try await proto.write(sensor.disableCommand) }
        try await proto.write(MWPacket.command(sensor.module, sensor.dataRegister, [0x00]))
        if let packed = sensor.packedDataRegister {
            try await proto.write(MWPacket.command(sensor.module, packed, [0x00]))
        }
        await proto.unsubscribe(from: sensor.module, register: sensor.dataRegister)
        if let packed = sensor.packedDataRegister {
            await proto.unsubscribe(from: sensor.module, register: packed)
        }
        activeStreamModules.remove(sensor.module)
        state = activeStreamModules.isEmpty ? .idle : .streaming
    }

    // MARK: - Logging

    public func startLogging<L: MWLoggable>(_ loggable: L) async throws {
        mwLog("[Device] startLogging: \(loggable.module)")
        guard case .idle = state else {
            throw MWError.invalidState("Device must be idle to log")
        }
        state = .logging

        // Configure sensor hardware
        for cmd in loggable.configureCommands { try await proto.write(cmd) }

        // Subscribe each data chunk to the logger and collect the assigned IDs.
        // Command: [0x0B, 0x02, module, register, 0xFF, (offset<<5 | length-1)]
        // Response: [0x0B, 0x82, logger_id]
        var chunks: [(id: UInt8, byteCount: Int)] = []
        for chunk in loggable.logDataChunks {
            let packedByte: UInt8 = (chunk.offset << 5) | (chunk.length &- 1)
            let cmd = Data([MWModule.logging.rawValue, 0x02,
                            loggable.module.rawValue, loggable.dataRegister,
                            0xFF, packedByte])
            let response = try await proto.writeAndRead(command: cmd, awaitModule: .logging, awaitRegister: 0x02)
            guard response.count >= 3 else {
                throw MWError.operationFailed("Logger subscription returned short response")
            }
            chunks.append((id: response[2], byteCount: Int(chunk.length)))
        }
        loggerRegistry[loggable.loggerKey] = chunks

        // Enable sensor output and start hardware
        try await proto.write(loggable.enableCommand)
        try await proto.write(loggable.startCommand)

        // Enable circular buffer and start logging
        try await proto.write(MWPacket.command(.logging, 0x0B, [0x01]))  // circular buffer on
        try await proto.write(MWPacket.command(.logging, 0x01, [0x01]))  // enable logging
    }

    public func stopLogging<L: MWLoggable>(_ loggable: L) async throws {
        mwLog("[Device] stopLogging: \(loggable.module)")
        guard case .logging = state else { return }
        try await proto.write(MWPacket.command(.logging, 0x01, [0x00]))  // stop logging
        try await proto.write(loggable.stopCommand)
        try await proto.write(loggable.disableCommand)
        state = .idle
    }

    /// Download raw log entries from the device.
    /// Returns a stream of progress snapshots, each containing all entries received so far.
    public func downloadLogs() async throws -> AsyncThrowingStream<Download<[RawLogEntry]>, Error> {
        mwLog("[Device] downloadLogs")
        guard case .idle = state else {
            throw MWError.invalidState("Device must be idle to download")
        }
        state = .downloading(progress: 0)

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

        // Readout: [0x0B, 0x06, n_entries(4 LE), n_notify(4 LE)]
        // n_notify = 0 means one progress update per page.
        let cmd = MWPacket.command(.logging, 0x06,
                                   MWPacketParser.le32(nEntries) + MWPacketParser.le32(0))
        try await proto.write(cmd)

        let (stream, continuation) = AsyncThrowingStream<Download<[RawLogEntry]>, Error>.makeStream()
        Task { [self] in
            await self.runDownload(
                rawStream: rawStream,
                progressStream: progressStream,
                pageStream: pageStream,
                continuation: continuation
            )
        }
        return stream
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

        Task {
            do {
                for try await progress in rawStream {
                    let decoded = try decodeEntries(progress.data, chunks: chunks, loggable: loggable)
                    cont.yield(Download(data: decoded, percentComplete: progress.percentComplete))
                }
                cont.finish()
            } catch {
                cont.finish(throwing: error)
            }
        }
        return typed
    }

    /// Clear all log entries from the device flash and remove all logger subscriptions.
    public func clearLog() async throws {
        guard case .idle = state else {
            throw MWError.invalidState("Device must be idle to clear the log")
        }
        try await proto.write(MWPacket.command(.logging, 0x09, [0xFF, 0xFF, 0xFF, 0xFF]))
        // Remove all loggers from the board
        try await proto.write(MWPacket.command(.logging, 0x0A, []))
        loggerRegistry.removeAll()
    }

    /// Flush the active logging page to flash so in-flight samples become readable.
    ///
    /// Only valid on MMS boards — firmware ignores this command on MMRL, so the
    /// Swift side no-ops when the logging module revision is below 3
    /// (`MMS_REVISION` in the C++ SDK). Safe to call on any device.
    ///
    /// Typical use: call immediately after `stopLogging(_:)` and before
    /// `downloadLogs()` to ensure the final page of samples isn't stranded in
    /// RAM.
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

    /// Query the board for all currently active logger subscriptions.
    /// Returns one entry per chunk (logger ID) in the order the board assigned them.
    /// Useful for rebuilding `loggerRegistry` after an app restart.
    public func queryActiveLoggers() async throws -> [ActiveLogger] {
        var result: [ActiveLogger] = []
        for id: UInt8 in 0..<32 {
            do {
                // READ request for TRIGGER register: [0x0B, 0x82, logger_id]
                let cmd = Data([MWModule.logging.rawValue, 0x82, id])
                let response = try await proto.writeAndRead(command: cmd, awaitModule: .logging, awaitRegister: 0x02)
                // Response: [0x0B, 0x82, logger_id, module_id, register_id, channel, packed_byte]
                guard response.count >= 7 else { break }
                let loggerID = response[2]
                guard loggerID != 0xFF else { break }
                guard let module = MWModule(rawValue: response[3]) else { continue }
                let reg      = response[4]
                let channel  = response[5]
                let packed   = response[6]
                // Low 5 bits = offset, high 3 bits = length-1.
                let offset   = packed & 0x1F
                let length   = ((packed >> 5) & 0x7) + 1
                result.append(ActiveLogger(loggerID: loggerID, module: module,
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
    /// Response layout (mirrors the logging ADD echo):
    /// `[0x09, 0x82, id_echo, parent_module, parent_register, parent_proc_id_or_0xFF, packed, proc_type, config...]`
    public func queryActiveProcessors() async throws -> [ActiveProcessor] {
        var result: [ActiveProcessor] = []
        for id: UInt8 in 0..<32 {
            do {
                let cmd = Data([MWModule.dataProcessor.rawValue, 0x82, id])
                let response = try await proto.writeAndRead(
                    command: cmd, awaitModule: .dataProcessor, awaitRegister: 0x02
                )
                // Need at least: header(3) + parent_mod + parent_reg + parent_proc_id + packed + proc_type
                guard response.count >= 8 else { break }
                let idEcho = response[2]
                guard idEcho != 0xFF else { break }
                guard let parentMod = MWModule(rawValue: response[3]) else { continue }
                let parentReg = response[4]
                let parentProcID = response[5]
                let packed = response[6]
                let offset = packed & 0x1F
                let length = (packed >> 5) + 1
                let procType = response[7]
                let configBytes: [UInt8] = response.count > 8
                    ? Array(response[response.index(response.startIndex, offsetBy: 8)...])
                    : []
                result.append(ActiveProcessor(
                    processorID: idEcho,
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
        if modules[.accelerometer]?.isPresent == true {
            do {
                let resp = try await proto.writeAndRead(
                    command: Data([MWModule.accelerometer.rawValue, 0x83]),
                    awaitModule: .accelerometer,
                    awaitRegister: 0x03
                )
                if resp.count >= 4 {
                    scales.accel = Self.accelScaleFromRangeByte(resp[3])
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

    /// Map the BMI160 accelerometer range byte (0x03, 0x05, 0x08, 0x0C) or the
    /// BMI270 range byte (0x00..0x03) to LSB/g.
    private static func accelScaleFromRangeByte(_ b: UInt8) -> Float {
        switch b {
        case 0x03, 0x00: return 16384  // ±2g
        case 0x05, 0x01: return 8192   // ±4g
        case 0x08, 0x02: return 4096   // ±8g
        case 0x0C, 0x03: return 2048   // ±16g
        default:         return 16384
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
    public func recoverLoggers<L: MWLoggable>(for loggable: L) async throws {
        let active = try await queryActiveLoggers()
        let matched = active
            .filter { $0.module == loggable.module && $0.register == loggable.dataRegister }
            .sorted { $0.loggerID < $1.loggerID }
        guard !matched.isEmpty else {
            throw MWError.operationFailed(
                "No active logger found for '\(loggable.loggerKey)' on \(loggable.module)/\(loggable.dataRegister)"
            )
        }
        let chunks: [(id: UInt8, byteCount: Int)] = zip(matched, loggable.logDataChunks).map {
            (id: $0.loggerID, byteCount: Int($1.length))
        }
        loggerRegistry[loggable.loggerKey] = chunks
    }

    private func runDownload(
        rawStream: AsyncThrowingStream<Data, Error>,
        progressStream: AsyncThrowingStream<Data, Error>,
        pageStream: AsyncThrowingStream<Data, Error>,
        continuation: AsyncThrowingStream<Download<[RawLogEntry]>, Error>.Continuation
    ) async {
        let accumulator = LogEntryAccumulator()

        // Drain raw-entry notifications in the background
        let entryTask = Task {
            for try await packet in rawStream {
                for entry in (try? RawLogEntry.parseAll(from: packet)) ?? [] {
                    await accumulator.append(entry)
                }
            }
        }

        // Confirm each page-completed notification so the board sends the next page
        let pageTask = Task { [weak self] in
            guard let self else { return }
            for try await _ in pageStream {
                try? await self.proto.write(MWPacket.command(.logging, 0x0E, []))
            }
        }

        do {
            for try await packet in progressStream {
                guard packet.count >= 10 else { continue }
                let remaining = MWPacketParser.parseUInt32LE(packet, offset: 2)
                let total     = MWPacketParser.parseUInt32LE(packet, offset: 6)
                let percent   = total > 0 ? Double(total - remaining) / Double(total) : 1.0
                let snapshot  = await accumulator.all()
                continuation.yield(Download(data: snapshot, percentComplete: percent))
                if remaining == 0 {
                    entryTask.cancel()
                    pageTask.cancel()
                    state = .idle
                    continuation.finish()
                    return
                }
            }
        } catch {
            entryTask.cancel()
            pageTask.cancel()
            state = .idle
            continuation.finish(throwing: error)
        }
    }

    // MARK: - Log reassembly

    private func decodeEntries<L: MWLoggable>(
        _ entries: [RawLogEntry],
        chunks: [(id: UInt8, byteCount: Int)],
        loggable: L
    ) throws -> [MWLoggedSample<L.Sample>] {
        let byKey = Dictionary(grouping: entries) { LogEntryKey(resetUID: $0.resetUID, tick: $0.tick) }
        let ref = logReferenceDate

        var result: [MWLoggedSample<L.Sample>] = []
        for (key, group) in byKey {
            let byID: [UInt8: RawLogEntry] = Dictionary(
                group.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var assembled = Data()
            var complete = true
            for chunk in chunks {
                guard let entry = byID[chunk.id] else { complete = false; break }
                var raw = entry.rawData.littleEndian
                let bytes = withUnsafeBytes(of: &raw) { Data($0.prefix(chunk.byteCount)) }
                assembled.append(bytes)
            }
            guard complete else { continue }
            let sample = try loggable.parseLogSample(from: assembled)
            let msElapsed = Double(key.tick) * MWPacketParser.msPerTick
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

    private func hookDisconnectCallback() {
        let device = self
        Task {
            await device.proto.setDisconnectHandler { error in
                Task {
                    await device.handleUnexpectedDisconnect(error: error)
                }
            }
        }
    }

    private func handleUnexpectedDisconnect(error: Error) {
        mwLog("[Device] unexpectedDisconnect: \(error.localizedDescription)")
        state = .disconnected
        activeStreamModules.removeAll()
        logReferenceDate = nil
        // loggerRegistry is intentionally preserved — the device may still have
        // active loggers. After reconnect the caller can download without re-starting.
        terminateAllProcessorStreams(with: error)
        onUnexpectedDisconnect?(error)
    }

    // MARK: - Sensor conflict detection

    /// Throws if the module being added would conflict with currently active streams.
    /// Rule: sensor fusion and individual IMU sensors (accel/gyro/mag) are mutually exclusive.
    private func checkSensorConflict(adding module: MWModule) throws {
        if activeStreamModules.contains(module) {
            throw MWError.invalidState("\(module) is already streaming")
        }
        let imuModules: Set<MWModule> = [.accelerometer, .gyro, .magnetometer]
        let addingFusion = module == .sensorFusion
        let addingIMU    = imuModules.contains(module)

        if addingFusion && !activeStreamModules.isDisjoint(with: imuModules) {
            let active = activeStreamModules.intersection(imuModules).map { "\($0)" }.joined(separator: ", ")
            throw MWError.invalidState(
                "Cannot start sensor fusion while \(active) is already streaming"
            )
        }
        if addingIMU && activeStreamModules.contains(.sensorFusion) {
            throw MWError.invalidState(
                "Cannot stream \(module) while sensor fusion is active"
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
        // Entry layout: 1 byte id/resetUID + 3 byte tick + 4 byte data = 8 bytes
        let headerLen = 2   // [module, register]
        let entryLen  = 8
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

// MARK: - Log entry grouping key

private struct LogEntryKey: Hashable {
    let resetUID: UInt8
    let tick: UInt32
}

