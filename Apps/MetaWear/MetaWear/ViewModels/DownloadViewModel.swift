import Foundation
import Observation
import SwiftData
import MetaWear
import MetaWearPersistence

/// Coordinates download and persistence for stopped on-device logging sessions.
///
/// Drains the board once into raw entries, decodes those entries per pending
/// `LogSessionRecord`, saves typed snapshots through `MWPersistenceStore`, and
/// updates download progress for the UI.
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

    /// Download a FOREIGN session — one started on another phone / install /
    /// app — via the anonymous-logger SDK path. Same screen, same `Phase`
    /// progress UI as `downloadAll`, but the signals are reconstructed from
    /// the board's own logger metadata (`createAnonymousDataSignals`) since
    /// no local `LogSessionRecord` describes them. Each recovered signal is
    /// persisted as its own session labelled "Unknown · <identifier>", and
    /// the board is wiped once everything decodable is saved.
    func downloadForeign(_ state: OrphanLogState) async {
        // A stale navigation entry (pushed for board A, resolved after board
        // B connected) must never drain — and wipe — the wrong board. The
        // deleted AppStore engine had this guard; keep the invariant here,
        // at the point that owns both the device and the state.
        guard device.identifier == state.deviceID else {
            phase = .failed(message: "This session belongs to a different board. Reconnect to it and retry the download.")
            return
        }
        // Seed `total` from the entry count read at detection time so the
        // user sees "0 / N entries" immediately instead of "Reading log
        // length…" while the (multi-second) signal reconstruction runs.
        phase = .downloading(progress: 0, downloaded: 0, total: Int(state.entryCount))
        do {
            // If the foreign session is still recording, stop the sampling
            // first so the readout doesn't race concurrent writes. Entries
            // and logger metadata stay intact; no-op when already stopped.
            try await device.stopOnBoardLogging()
            let signals = try await device.createAnonymousDataSignals()
            guard !signals.isEmpty else {
                // The board reported `LOG_LENGTH > 0` but no recoverable
                // logger metadata — typically a corrupt slot or a logger
                // type we don't decode yet. Clear so we don't keep
                // re-alerting on every reconnect.
                try await device.clearLog()
                phase = .ready(
                    snapshots: [],
                    warning: "No recoverable sensor data was found on the board; its log was cleared."
                )
                return
            }

            let entries = try await drainRawDownload()
            guard let info = await device.deviceInfo else {
                throw MWError.invalidState("Device info unavailable")
            }

            var snapshots: [MWSessionSnapshot] = []
            for signal in signals {
                let samples = try await device.decodeEntries(entries, for: signal)
                if let snap = try await save(anonymousSignal: signal, samples: samples, info: info) {
                    snapshots.append(snap)
                }
            }

            // Never wipe the board when it reported entries but nothing was
            // persisted. The classic cause is an earlier interrupted readout:
            // the readout pointer is consumed even by a partial drain, so a
            // retry reads LOG_LENGTH == 0, decodes nothing — and an
            // unconditional clearLog here would erase the very session this
            // flow exists to recover. Mirror `downloadAll`'s keep-board-data
            // behaviour; the user can retry or Discard from the Logging screen.
            if snapshots.isEmpty && state.entryCount > 0 {
                phase = .failed(message: "No sensor data could be recovered in this download. The board's log was kept — retry the download, or discard it from the Logging screen.")
                return
            }

            try await device.clearLog()
            phase = .ready(
                snapshots: snapshots,
                warning: snapshots.isEmpty
                    ? "The session ended before any entries reached the board's flash memory."
                    : nil
            )
        } catch {
            phase = .failed(message: error.localizedDescription)
            lastError = AppError(error: error)
        }
    }

    /// Drain `device.downloadLogs()` into a single accumulated entries array,
    /// updating `phase` with the percentage as the download progresses.
    private func drainRawDownload() async throws -> [RawLogEntry] {
        let stream = try await device.downloadLogs()
        var all: [RawLogEntry] = []
        var sawCompletion = false
        for try await chunk in stream {
            phase = .downloading(
                progress: chunk.percentComplete,
                downloaded: Int(chunk.entriesDownloaded ?? 0),
                total: Int(chunk.totalEntries ?? 0)
            )
            all = chunk.data
            if chunk.percentComplete >= 1.0 { sawCompletion = true }
        }
        // `AsyncThrowingStream.next()` returns nil (NOT an error) when the
        // task is cancelled — e.g. the user navigates back mid-download and
        // SwiftUI cancels the `.task`. Without this check a partial drain
        // reads as complete, gets decoded/saved, and the follow-up
        // `clearLog()` wipes the entries that never made it over the air.
        // A drain that already saw the firmware's 100% notification is
        // complete data, though — the readout pointer is spent either way,
        // so throwing it out on a late cancellation would lose a finished
        // download for nothing.
        if !sawCompletion { try Task.checkCancellation() }
        return all
    }

    /// Persist one anonymous signal's samples as a session, returning the
    /// saved snapshot (nil when nothing decodable was in the entries — no
    /// harm, no foul). Dispatches on the first sample's case to pick the
    /// matching `MWPersistable` type. Fuser signals (two outputs per entry)
    /// only persist the first output for now; rare enough that we can
    /// revisit if a user actually exercises it.
    /// Human label for a recovered anonymous signal, in the SAME vocabulary
    /// as the standard logging labels ("Accelerometer · …", "Fusion ·
    /// Quaternion · …"). This matters beyond cosmetics: `CSVExporter.
    /// streamingTag(forLabel:)` derives the export filename's sensor tag
    /// from the label's leading display name — the old "Unknown ·
    /// acceleration" label fell through to the generic persistence-kind
    /// tag, so an accelerometer CSV said nothing about the accelerometer.
    static func label(forAnonymousIdentifier identifier: String) -> String {
        let root = identifier.split(separator: ":").first.map(String.init) ?? identifier
        let base = root.split(separator: "[").first.map(String.init) ?? root
        let head: String
        switch base {
        case "acceleration":               head = "Accelerometer"
        case "angular-velocity":           head = "Gyroscope"
        case "magnetic-field":             head = "Magnetometer"
        case "temperature":                head = "Temperature"
        case "quaternion":                 head = "Fusion · Quaternion"
        case "euler-angles":               head = "Fusion · Euler Angles"
        case "gravity":                    head = "Fusion · Gravity"
        case "linear-acceleration":        head = "Fusion · Linear Acceleration"
        case "corrected-acceleration":     head = "Fusion · Corrected Acceleration"
        case "corrected-angular-velocity": head = "Fusion · Corrected Angular Velocity"
        case "corrected-magnetic-field":   head = "Fusion · Corrected Magnetic Field"
        default:                           return "Unknown · \(identifier)"
        }
        // A processor chain ("acceleration:rms?id=0:…") is real information
        // about what the board was computing — keep it visible. Plain
        // signals just get the provenance marker.
        return identifier.contains(":")
            ? "\(head) · \(identifier)"
            : "\(head) · Recovered"
    }

    private func save(
        anonymousSignal signal: MWAnonymousSignal,
        samples: [MWLoggedSample<[MWAnonymousSignal.Output]>],
        info: MWDeviceInformation
    ) async throws -> MWSessionSnapshot? {
        let label = Self.label(forAnonymousIdentifier: signal.identifier)
        guard let firstOutput = samples.first?.value.first else { return nil }

        switch firstOutput {
        case .cartesian:
            let mapped: [MWLoggedSample<CartesianFloat>] = samples.compactMap {
                guard case .cartesian(let v) = $0.value.first else { return nil }
                return MWLoggedSample(date: $0.date, tickMs: $0.tickMs, value: v)
            }
            guard !mapped.isEmpty else { return nil }
            return try await store.saveSession(
                deviceID: device.identifier, deviceInfo: info,
                sensorKind: CartesianFloat.persistenceKind,
                samples: mapped, label: label)

        case .scalar:
            let mapped: [MWLoggedSample<Float>] = samples.compactMap {
                guard case .scalar(let v) = $0.value.first else { return nil }
                return MWLoggedSample(date: $0.date, tickMs: $0.tickMs, value: v)
            }
            guard !mapped.isEmpty else { return nil }
            return try await store.saveSession(
                deviceID: device.identifier, deviceInfo: info,
                sensorKind: Float.persistenceKind,
                samples: mapped, label: label)

        case .quaternion:
            let mapped: [MWLoggedSample<Quaternion>] = samples.compactMap {
                guard case .quaternion(let v) = $0.value.first else { return nil }
                return MWLoggedSample(date: $0.date, tickMs: $0.tickMs, value: v)
            }
            guard !mapped.isEmpty else { return nil }
            return try await store.saveSession(
                deviceID: device.identifier, deviceInfo: info,
                sensorKind: Quaternion.persistenceKind,
                samples: mapped, label: label)

        case .euler:
            let mapped: [MWLoggedSample<EulerAngles>] = samples.compactMap {
                guard case .euler(let v) = $0.value.first else { return nil }
                return MWLoggedSample(date: $0.date, tickMs: $0.tickMs, value: v)
            }
            guard !mapped.isEmpty else { return nil }
            return try await store.saveSession(
                deviceID: device.identifier, deviceInfo: info,
                sensorKind: EulerAngles.persistenceKind,
                samples: mapped, label: label)

        case .correctedCartesian:
            let mapped: [MWLoggedSample<CorrectedCartesianFloat>] = samples.compactMap {
                guard case .correctedCartesian(let v) = $0.value.first else { return nil }
                return MWLoggedSample(date: $0.date, tickMs: $0.tickMs, value: v)
            }
            guard !mapped.isEmpty else { return nil }
            return try await store.saveSession(
                deviceID: device.identifier, deviceInfo: info,
                sensorKind: CorrectedCartesianFloat.persistenceKind,
                samples: mapped, label: label)
        }
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
