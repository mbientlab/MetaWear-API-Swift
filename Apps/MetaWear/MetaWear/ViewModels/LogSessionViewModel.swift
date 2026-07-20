import Foundation
import Observation
import SwiftData
import MetaWear

/// Per-module hardware implementations, read from module discovery. Each
/// sensor variant MUST be selected by its own module's implementation byte
/// (mirroring the C++ SDK's `module_info.at(MODULE).implementation`) —
/// deriving the gyro from the ACCEL chip armed the wrong gyro data
/// register on mixed-generation boards, so its loggers never fired.
/// Field evidence: an MMS + MMRL group logged accel fine on both, gyro on
/// neither-or-one depending on which board the guess happened to match.
struct SensorImplementations {
    let accel: UInt8
    let gyro: UInt8
    let fusionChip: MWSensorFusionChip

    init(modules: [MWModule: MWModuleInfo]) {
        accel = modules[.accelerometer]?.implementation ?? 1
        gyro = modules[.gyro]?.implementation ?? 0
        fusionChip = MWSensorFusionChip(accImpl: accel) ?? .bmi160
    }
}

/// Drives on-device logging setup and teardown.
///
/// Converts selected UI sensors into SDK loggers, persists pending
/// `LogSessionRecord` rows so interrupted sessions can be recovered, and
/// keeps elapsed-time state for the logging UI while the board records to
/// flash independently of the app.
@Observable
@MainActor
final class LogSessionViewModel {
    enum Phase: Equatable {
        case idle
        case running(startedAt: Date)
        case stopped
    }

    private let device: MetaWearDevice
    private let containers: AppContainers

    var phase: Phase = .idle
    var elapsedSeconds: Int = 0
    var lastError: AppError?
    var activeRecords: [LogSessionRecord] = []

    private var elapsedTask: Task<Void, Never>?

    init(device: MetaWearDevice, containers: AppContainers) {
        self.device = device
        self.containers = containers
    }

    /// - Parameter groupID: stamped onto every created record when this
    ///   start is part of a group capture (several boards logging together)
    ///   so the downloaded sessions can be batched back together.
    func start(_ selections: [SensorSelection], groupID: UUID? = nil) async {
        guard case .idle = phase else {
            return
        }
        let context = containers.local.mainContext
        let modules = await device.modules
        let impls = SensorImplementations(modules: modules)
        var records: [LogSessionRecord] = []
        do {
            for selection in selections {
                if let record = try await startOne(selection: selection, impls: impls, context: context, groupID: groupID) {
                    records.append(record)
                }
            }
            try context.save()
            activeRecords = records
            phase = .running(startedAt: .now)
            startElapsedTimer()
        } catch {
            let stillRunning = await rollbackStartedRecords(records, impls: impls, context: context)
            if stillRunning.isEmpty {
                activeRecords = []
                phase = .idle
                lastError = AppError(error: error)
            } else {
                activeRecords = stillRunning
                let earliestStart = stillRunning.map(\.startDate).min() ?? .now
                phase = .running(startedAt: earliestStart)
                startElapsedTimer()
                lastError = AppError(error: PartialStartRollbackError(
                    startError: error,
                    remainingCount: stillRunning.count
                ))
            }
        }
    }

    /// Dispatch one selection to either the natively-loggable path or the
    /// polled path (temp / humidity), persist a `LogSessionRecord` either
    /// way. Returns nil if the sensor can't be logged on this board.
    private func startOne(
        selection: SensorSelection,
        impls: SensorImplementations,
        context: ModelContext,
        groupID: UUID? = nil
    ) async throws -> LogSessionRecord? {
        switch selection.id {
        case .temperature:
            let channelIdx = UInt8(selection.channel ?? 0)
            let polled = MWPolledLogger(
                readable: MWThermometer(channel: channelIdx),
                periodMs: Self.periodMs(forHz: selection.hz)
            )
            let handles = try await device.startLogging(polled)
            let record = LogSessionRecord(
                deviceID: device.identifier,
                sensorKind: selection.id.persistenceKey,
                configJSON: Self.encode(selection),
                loggerKey: polled.loggerKey,
                status: .running,
                polledHandlesJSON: Self.encodeHandles(handles),
                groupID: groupID
            )
            context.insert(record)
            return record

        case .humidity:
            let polled = MWPolledLogger(
                readable: MWHumidity(),
                periodMs: Self.periodMs(forHz: selection.hz)
            )
            let handles = try await device.startLogging(polled)
            let record = LogSessionRecord(
                deviceID: device.identifier,
                sensorKind: selection.id.persistenceKey,
                configJSON: Self.encode(selection),
                loggerKey: polled.loggerKey,
                status: .running,
                polledHandlesJSON: Self.encodeHandles(handles),
                groupID: groupID
            )
            context.insert(record)
            return record

        default:
            guard let loggable = Self.makeLoggable(for: selection, impls: impls) else { return nil }
            try await device.startLogging(loggable)
            let record = LogSessionRecord(
                deviceID: device.identifier,
                sensorKind: selection.id.persistenceKey,
                configJSON: Self.encode(selection),
                loggerKey: loggable.loggerKey,
                status: .running,
                groupID: groupID
            )
            context.insert(record)
            return record
        }
    }

    func stop() async {
        elapsedTask?.cancel()
        elapsedTask = nil

        let modules = await device.modules
        let impls = SensorImplementations(modules: modules)
        // Per-record try/catch — a single failed `stopOne` (BLE hiccup,
        // unexpected board state) used to abort the loop, leaving the
        // remaining records' `status` stuck at `.running` and the global
        // `LoggingPill` ticking forever. We always flip the status to
        // `.stopped` even when the BLE command threw, because:
        //   - the user explicitly asked the session to stop, and
        //   - the captured data is still on the board for download.
        // If the board kept sampling, the next `cleanUpOrphanResources`
        // on connect will sweep any leftover state.
        // `where` guard: a group collect pass can stop + download + clear
        // this board while a solo Logging screen still holds these records
        // in its view model (iPad split view). Re-stopping a `.downloaded`
        // record would fire stop commands at logger slots clearLog already
        // freed AND resurrect the record as pending everywhere.
        for record in activeRecords where record.status != .downloaded {
            do {
                try await stopOne(record: record, impls: impls)
            } catch {
                lastError = AppError(error: error)
            }
            record.status = .stopped
        }
        try? containers.local.mainContext.save()
        phase = .stopped
    }

    private func stopOne(record: LogSessionRecord, impls: SensorImplementations) async throws {
        guard let selection = Self.decode(record.configJSON, kind: record.sensorKind) else { return }
        switch selection.id {
        case .temperature:
            guard let handles = record.polledHandlesJSON.flatMap(Self.decodeHandles) else { return }
            let polled = MWPolledLogger(
                readable: MWThermometer(channel: UInt8(selection.channel ?? 0)),
                periodMs: Self.periodMs(forHz: selection.hz)
            )
            try await device.stopLogging(polled, handles: handles)
        case .humidity:
            guard let handles = record.polledHandlesJSON.flatMap(Self.decodeHandles) else { return }
            let polled = MWPolledLogger(
                readable: MWHumidity(),
                periodMs: Self.periodMs(forHz: selection.hz)
            )
            try await device.stopLogging(polled, handles: handles)
        default:
            if let loggable = Self.makeLoggable(for: selection, impls: impls) {
                try await device.stopLogging(loggable)
            }
        }
    }

    private func rollbackStartedRecords(
        _ records: [LogSessionRecord],
        impls: SensorImplementations,
        context: ModelContext
    ) async -> [LogSessionRecord] {
        var stillRunning: [LogSessionRecord] = []
        for record in records {
            do {
                try await stopOne(record: record, impls: impls)
                context.delete(record)
            } catch {
                record.status = .running
                stillRunning.append(record)
            }
        }
        try? context.save()
        return stillRunning
    }

    /// Translate a user-facing Hz selection (one of 0.5, 1, 2, 5) into the
    /// board's timer period in ms. Clamps to ≥ 200 ms so a stray 0 from
    /// the picker can't generate a 0-period timer (which the firmware
    /// rejects).
    static func periodMs(forHz hz: Double) -> UInt32 {
        let clamped = max(0.5, hz)
        return UInt32(max(200, Int(1000 / clamped)))
    }

    /// Rehydrate this view model from any `.running` `LogSessionRecord`s that
    /// already exist for the connected device — needed when the user
    /// navigated away from the Logging screen without tapping Stop. The
    /// board kept logging (and the SDK's `loggerRegistry` still has its
    /// entries), so when the screen is re-entered we want to surface the
    /// real state (running + elapsed) instead of looking idle and offering
    /// a Start button that would just throw "already being logged".
    func restoreFromPending(records: [LogSessionRecord]) {
        guard !records.isEmpty else { return }
        guard case .idle = phase else { return }
        activeRecords = records
        let earliestStart = records.map(\.startDate).min() ?? .now
        phase = .running(startedAt: earliestStart)
        startElapsedTimer()
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if case .running(let start) = self.phase {
                    self.elapsedSeconds = Int(Date.now.timeIntervalSince(start))
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private struct PartialStartRollbackError: LocalizedError {
        let startError: Error
        let remainingCount: Int

        var errorDescription: String? {
            let noun = remainingCount == 1 ? "logger is" : "loggers are"
            return "Logging did not start cleanly: \(startError.localizedDescription). \(remainingCount) \(noun) still running on the board; stop or download before starting another session."
        }
    }

    // MARK: - Loggable factory

    /// Build a `MWLoggable` for the given selection, honouring the chosen
    /// rate, range, and detected chip. Returns nil for sensors that aren't
    /// natively loggable on the board (baro / temp / humidity / ambient
    /// light) — `SensorPickerSection` should already keep those out of the
    /// logging Add menu, but the nil branch is the safety net.
    static func makeLoggable(for selection: SensorSelection, impls: SensorImplementations) -> (any MWLoggable)? {
        switch selection.id {
        case .accelerometer:
            let rangeG = Float(selection.range ?? 2)
            switch MWAccelerometer.make(impl: impls.accel, odrHz: selection.hz, rangeG: rangeG) {
            case .bmi160(let s)?: return s
            case .bmi270(let s)?: return s
            case nil:             return nil
            }

        case .gyroscope:
            let rangeDPS = Float(selection.range ?? 2000)
            switch MWGyroscope.make(impl: impls.gyro, odrHz: selection.hz, rangeDPS: rangeDPS) {
            case .bmi160(let s)?: return s
            case .bmi270(let s)?: return s
            case nil:             return nil
            }

        case .magnetometer:
            // Bypass the locked-rate "regular" preset and pick the closest
            // BMM150 ODR. xy=9 / z=15 matches the regular preset's noise
            // trade-off and fits within the 30 Hz conversion budget.
            let odr = MWMagnetometer.ODR.allCases.min {
                abs($0.hz - selection.hz) < abs($1.hz - selection.hz)
            } ?? .hz10
            return MWMagnetometer(xyReps: 9, zReps: 15, odr: odr)

        case .sensorFusion(let out):
            switch out {
            case .quaternion:                return MWSensorFusionQuaternion(chip: impls.fusionChip)
            case .eulerAngles:               return MWSensorFusionEuler(chip: impls.fusionChip)
            case .gravity:                   return MWSensorFusionGravity(chip: impls.fusionChip)
            case .linearAcceleration:        return MWSensorFusionLinearAcceleration(chip: impls.fusionChip)
            case .correctedAcceleration:     return MWSensorFusionCorrectedAcc(chip: impls.fusionChip)
            case .correctedAngularVelocity:  return MWSensorFusionCorrectedGyro(chip: impls.fusionChip)
            case .correctedMagneticField:    return MWSensorFusionCorrectedMag(chip: impls.fusionChip)
            }

        case .barometer:
            return MWBarometer()

        case .ambientLight:
            return MWAmbientLight()

        case .temperature, .humidity:
            // Polled-via-timer logging — handled by `startOne` /
            // `DownloadViewModel.downloadAndSave` outside this factory.
            return nil
        }
    }

    static func encodeHandles(_ handles: MWPolledLoggerHandles) -> String {
        (try? String(data: JSONEncoder().encode(handles), encoding: .utf8)) ?? "{}"
    }

    static func decodeHandles(_ json: String) -> MWPolledLoggerHandles? {
        try? JSONDecoder().decode(MWPolledLoggerHandles.self, from: Data(json.utf8))
    }

    // MARK: - Selection persistence (JSON in LogSessionRecord.configJSON)

    private struct ConfigEnvelope: Codable {
        let hz: Double
        let range: Int?
        let channel: Int?
    }

    static func encode(_ selection: SensorSelection) -> String {
        let env = ConfigEnvelope(hz: selection.hz, range: selection.range, channel: selection.channel)
        return (try? String(data: JSONEncoder().encode(env), encoding: .utf8)) ?? "{}"
    }

    static func decode(_ configJSON: String, kind: String) -> SensorSelection? {
        guard let key = SensorKey(persistenceKey: kind) else { return nil }
        let data = Data(configJSON.utf8)
        let env = (try? JSONDecoder().decode(ConfigEnvelope.self, from: data)) ?? ConfigEnvelope(hz: key.defaultHz, range: nil, channel: nil)
        return SensorSelection(id: key, hz: env.hz, range: env.range, channel: env.channel)
    }
}
