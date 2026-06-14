import Foundation
import Observation
import SwiftData
import MetaWear
import MetaWearPersistence

@Observable
@MainActor
final class DownloadViewModel {
    enum Phase {
        case idle
        /// `progress` is `0.0...1.0` from the firmware's progress register;
        /// `downloaded` and `total` are raw entry counts read from
        /// `LOG_LENGTH` at the start of the readout, so we can render
        /// "123 / 456 entries (27%)" without waiting for the first
        /// firmware progress notification to arrive.
        case downloading(progress: Double, downloaded: Int, total: Int)
        case ready(snapshots: [MWSessionSnapshot], warning: String?)
        case failed(message: String)
    }

    private let device: MetaWearDevice
    private let store: MWPersistenceStore
    private let containers: AppContainers

    var phase: Phase = .idle
    var lastError: AppError?

    init(device: MetaWearDevice, store: MWPersistenceStore, containers: AppContainers) {
        self.device = device
        self.store = store
        self.containers = containers
    }

    /// Drain every active logger on the board with a SINGLE raw `downloadLogs()`
    /// call, then dispatch the resulting entries to each `LogSessionRecord` for
    /// per-loggable decoding + persistence.
    ///
    /// The previous implementation called `device.downloadLogs(_:)` per
    /// loggable, but each call re-reads the board's `LOG_LENGTH` register and
    /// re-issues the `READOUT` command — which on the MetaWear's circular log
    /// drains entries exactly once. So the *second* loggable's readout always
    /// saw `LOG_LENGTH == 0` and came back empty, which is why users saw only
    /// one sensor's data after logging two.
    func downloadAll(records: [LogSessionRecord]) async {
        guard !records.isEmpty else {
            phase = .ready(snapshots: [], warning: nil)
            return
        }
        phase = .downloading(progress: 0, downloaded: 0, total: 0)

        let modules = await device.modules
        let chip = MWSensorFusionChip(accImpl: modules[.accelerometer]?.implementation ?? 1) ?? .bmi160
        guard let info = await device.deviceInfo else {
            phase = .failed(message: "Device info unavailable")
            return
        }

        // 1. Recover the logger registry for every record so the per-record
        //    `decodeEntries` calls below can find their chunks. Safe to call
        //    in-session (just refreshes) and required across app restarts.
        //    Enumerate the board's logger slots ONCE and share the result —
        //    every enumeration ends with one timed-out probe, so per-record
        //    enumeration multiplied that stall by the number of sensors.
        let activeLoggers: [ActiveLogger]
        do {
            activeLoggers = try await device.queryActiveLoggers()
        } catch {
            phase = .failed(message: error.localizedDescription)
            lastError = AppError(error: error)
            return
        }
        for record in records {
            await recoverLoggers(for: record, chip: chip, active: activeLoggers)
        }

        // 2. ONE raw download. Entries from every logger come through this
        //    stream together; per-record dispatch happens after.
        let allEntries: [RawLogEntry]
        do {
            allEntries = try await drainRawDownload()
        } catch {
            phase = .failed(message: error.localizedDescription)
            lastError = AppError(error: error)
            return
        }

        // 3. Decode + save per record.
        var snapshots: [MWSessionSnapshot] = []
        var keptBoardData = false
        for record in records {
            do {
                if let snap = try await decodeAndSave(
                    record: record,
                    chip: chip,
                    info: info,
                    entries: allEntries
                ) {
                    snapshots.append(snap)
                    record.status = .downloaded
                } else {
                    record.status = .stopped
                    keptBoardData = true
                }
            } catch {
                record.status = .stopped
                keptBoardData = true
                lastError = AppError(error: error)
            }
        }

        try? containers.local.mainContext.save()
        if keptBoardData {
            phase = .ready(
                snapshots: snapshots,
                warning: "Some log data could not be decoded. Board data was kept so you can retry Download or clear it from Settings."
            )
            return
        }

        // 4. Drop the on-flash entries + on-board logger triggers we just
        //    drained. The readout in step 2 streamed the data over BLE
        //    but didn't actually free anything on the board — `stopLogging`
        //    only stops the sampling sensor, not the logger subscriptions.
        //    Without this, the next `startLogging` would throw "already
        //    being logged" (the registry still has these keys) and the
        //    board's 8 logger slots stay occupied.
        do {
            try await device.clearLog()
            phase = .ready(snapshots: snapshots, warning: nil)
        } catch {
            lastError = AppError(error: error)
            phase = .ready(
                snapshots: snapshots,
                warning: "Downloaded data was saved, but the board logs could not be cleared. Retry clearing from Settings before starting another logging session."
            )
        }
    }

    /// Drain `device.downloadLogs()` into a single accumulated entries array,
    /// updating `phase` with the percentage as the download progresses.
    private func drainRawDownload() async throws -> [RawLogEntry] {
        let stream = try await device.downloadLogs()
        var all: [RawLogEntry] = []
        for try await chunk in stream {
            phase = .downloading(
                progress: chunk.percentComplete,
                downloaded: Int(chunk.entriesDownloaded ?? 0),
                total: Int(chunk.totalEntries ?? 0)
            )
            all = chunk.data
        }
        return all
    }

    /// Run `device.recoverLoggers(for:)` for whichever flavour of loggable
    /// (`MWLoggable` or `MWPolledLogger`) corresponds to the record. Silently
    /// ignores errors — they'll resurface meaningfully when `decodeAndSave`
    /// can't find the chunks in the registry.
    private func recoverLoggers(for record: LogSessionRecord, chip: MWSensorFusionChip,
                                active: [ActiveLogger]) async {
        guard let selection = LogSessionViewModel.decode(record.configJSON, kind: record.sensorKind) else { return }
        switch selection.id {
        case .temperature:
            let polled = MWPolledLogger(
                readable: MWThermometer(channel: UInt8(selection.channel ?? 0)),
                periodMs: LogSessionViewModel.periodMs(forHz: selection.hz)
            )
            try? await device.recoverLoggers(for: polled, using: active)
        case .humidity:
            let polled = MWPolledLogger(
                readable: MWHumidity(),
                periodMs: LogSessionViewModel.periodMs(forHz: selection.hz)
            )
            try? await device.recoverLoggers(for: polled, using: active)
        default:
            if let loggable = LogSessionViewModel.makeLoggable(for: selection, chip: chip) {
                try? await device.recoverLoggers(for: loggable, using: active)
            }
        }
    }

    private func decodeAndSave(
        record: LogSessionRecord,
        chip: MWSensorFusionChip,
        info: MWDeviceInformation,
        entries: [RawLogEntry]
    ) async throws -> MWSessionSnapshot? {
        guard let selection = LogSessionViewModel.decode(record.configJSON, kind: record.sensorKind) else {
            return nil
        }
        let label = selection.label

        switch selection.id {
        case .accelerometer:
            let rangeG = Float(selection.range ?? 2)
            let impl: UInt8 = chip == .bmi270 ? 4 : 1
            switch MWAccelerometer.make(impl: impl, odrHz: selection.hz, rangeG: rangeG) {
            case .bmi160(let s)?: return try await decodeAndPersist(s, info: info, label: label, entries: entries)
            case .bmi270(let s)?: return try await decodeAndPersist(s, info: info, label: label, entries: entries)
            case nil:             return nil
            }

        case .gyroscope:
            let rangeDPS = Float(selection.range ?? 2000)
            let impl: UInt8 = chip == .bmi270 ? 1 : 0
            switch MWGyroscope.make(impl: impl, odrHz: selection.hz, rangeDPS: rangeDPS) {
            case .bmi160(let s)?: return try await decodeAndPersist(s, info: info, label: label, entries: entries)
            case .bmi270(let s)?: return try await decodeAndPersist(s, info: info, label: label, entries: entries)
            case nil:             return nil
            }

        case .magnetometer:
            let odr = MWMagnetometer.ODR.allCases.min {
                abs($0.hz - selection.hz) < abs($1.hz - selection.hz)
            } ?? .hz10
            return try await decodeAndPersist(MWMagnetometer(xyReps: 9, zReps: 15, odr: odr),
                                              info: info, label: label, entries: entries)

        case .sensorFusion(let out):
            switch out {
            case .quaternion:
                return try await decodeAndPersist(MWSensorFusionQuaternion(chip: chip),
                                                  info: info, label: label, entries: entries)
            case .eulerAngles:
                return try await decodeAndPersist(MWSensorFusionEuler(chip: chip),
                                                  info: info, label: label, entries: entries)
            case .gravity:
                return try await decodeAndPersist(MWSensorFusionGravity(chip: chip),
                                                  info: info, label: label, entries: entries)
            case .linearAcceleration:
                return try await decodeAndPersist(MWSensorFusionLinearAcceleration(chip: chip),
                                                  info: info, label: label, entries: entries)
            case .correctedAcceleration:
                return try await decodeAndPersist(MWSensorFusionCorrectedAcc(chip: chip),
                                                  info: info, label: label, entries: entries)
            case .correctedAngularVelocity:
                return try await decodeAndPersist(MWSensorFusionCorrectedGyro(chip: chip),
                                                  info: info, label: label, entries: entries)
            case .correctedMagneticField:
                return try await decodeAndPersist(MWSensorFusionCorrectedMag(chip: chip),
                                                  info: info, label: label, entries: entries)
            }

        case .barometer:
            return try await decodeAndPersist(MWBarometer(), info: info, label: label, entries: entries)

        case .ambientLight:
            return try await decodeAndPersistAmbientLight(info: info, label: label, entries: entries)

        case .temperature:
            let polled = MWPolledLogger(
                readable: MWThermometer(channel: UInt8(selection.channel ?? 0)),
                periodMs: LogSessionViewModel.periodMs(forHz: selection.hz)
            )
            return try await decodeAndPersistPolled(polled, info: info, label: label, entries: entries)

        case .humidity:
            let polled = MWPolledLogger(
                readable: MWHumidity(),
                periodMs: LogSessionViewModel.periodMs(forHz: selection.hz)
            )
            return try await decodeAndPersistPolled(polled, info: info, label: label, entries: entries)
        }
    }

    private func decodeAndPersist<L: MWLoggable>(
        _ loggable: L,
        info: MWDeviceInformation,
        label: String,
        entries: [RawLogEntry]
    ) async throws -> MWSessionSnapshot? where L.Sample: MWPersistable {
        let samples = try await device.decodeEntries(entries, for: loggable)
        guard !samples.isEmpty else { return nil }
        return try await store.saveSession(
            deviceID: device.identifier,
            deviceInfo: info,
            sensorKind: L.Sample.persistenceKind,
            samples: samples,
            label: label
        )
    }

    /// Polled-logger variant: same shape as `decodeAndPersist` but uses the
    /// `MWPolledLogger` decode overload.
    private func decodeAndPersistPolled<R: MWPolledLoggable>(
        _ logger: MWPolledLogger<R>,
        info: MWDeviceInformation,
        label: String,
        entries: [RawLogEntry]
    ) async throws -> MWSessionSnapshot? where R.Sample: MWPersistable {
        let samples = try await device.decodeEntries(entries, for: logger)
        guard !samples.isEmpty else { return nil }
        return try await store.saveSession(
            deviceID: device.identifier,
            deviceInfo: info,
            sensorKind: R.Sample.persistenceKind,
            samples: samples,
            label: label
        )
    }

    /// Ambient light's raw `Sample = UInt32` (milli-lux) isn't `MWPersistable`,
    /// so we decode then convert to `Float` (lux) before saving — same
    /// rationale as the live-stream archive path.
    private func decodeAndPersistAmbientLight(
        info: MWDeviceInformation,
        label: String,
        entries: [RawLogEntry]
    ) async throws -> MWSessionSnapshot? {
        let raw = try await device.decodeEntries(entries, for: MWAmbientLight())
        guard !raw.isEmpty else { return nil }
        let asFloat = raw.map {
            MWLoggedSample(date: $0.date, tickMs: $0.tickMs, value: Float($0.value) / 1000)
        }
        return try await store.saveSession(
            deviceID: device.identifier,
            deviceInfo: info,
            sensorKind: Float.persistenceKind,
            samples: asFloat,
            label: label
        )
    }
}
