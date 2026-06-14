import Foundation
import Observation
import SwiftData
import MetaWear
import MetaWearPersistence

@Observable
@MainActor
final class AppStore {

    let scanner: MetaWearScanner
    let containers: AppContainers
    let persistence: MWPersistenceStore

    var activeDeviceID: UUID?
    var activeDevice: MetaWearDevice?
    var connectionState: DeviceState = .disconnected
    var lastError: AppError?

    var rememberedDevices: [RememberedDevice] = []
    var pendingLogSessions: [LogSessionRecord] = []

    /// Set when a freshly connected board reports `LOG_LENGTH > 0` but we
    /// have no local `LogSessionRecord` for it — i.e. the board kept logging
    /// across an app uninstall, phone swap, or any session we lost track of.
    /// Surfaced as an alert in `RootView` so the user can decide whether to
    /// discard the data; cleared by `dismissOrphanLog` or `discardOrphanLog`.
    var orphanLogState: OrphanLogState?

    /// Progress of an in-flight orphan-log download (triggered from the
    /// orphan-log alert's "Download" button). Anonymous-logger flow: the
    /// SDK reconstructs the signals from on-board metadata via
    /// `createAnonymousDataSignals()` and decodes the entries without ever
    /// having seen an `MWLoggable` for them.
    var orphanDownloadPhase: OrphanDownloadPhase = .idle

    init(containers: AppContainers) {
        self.containers = containers
        self.scanner = MetaWearScanner()
        self.persistence = MWPersistenceStore(modelContainer: containers.local)
        refreshRememberedDevices()
        refreshPendingLogSessions()
    }

    // MARK: - Demo device

    /// A fully simulated MetaWear (see `DemoBLETransport`). Created on first
    /// access so non-demo sessions never pay for it. Reused across
    /// connect/disconnect cycles like a real discovered device.
    private var _demoDevice: MetaWearDevice?
    var demoDevice: MetaWearDevice {
        if let device = _demoDevice { return device }
        let device = MetaWearDevice(
            identifier: DemoBLETransport.deviceIdentifier,
            transport: DemoBLETransport()
        )
        _demoDevice = device
        return device
    }

    /// Display name for the active device: advertised name when we have one,
    /// the demo label for the simulated device, generic fallback otherwise.
    var activeDeviceName: String {
        guard let id = activeDeviceID else { return "Device" }
        if id == DemoBLETransport.deviceIdentifier { return DemoMode.deviceName }
        return scanner.advertisedNames[id] ?? "MetaWear"
    }

    var connectingDeviceID: UUID?

    func connect(to device: MetaWearDevice) async {
        // No-op if we're already wired to this device (connected or mid-connect):
        // re-tapping just navigates to the existing session.
        if activeDeviceID == device.identifier, connectionState != .disconnected {
            return
        }
        if let current = activeDevice, current.identifier != device.identifier {
            try? await current.disconnect()
        }
        // Set active device IMMEDIATELY so navigation transitions on tap.
        activeDeviceID = device.identifier
        activeDevice = device
        connectingDeviceID = device.identifier
        connectionState = .connecting
        do {
            try await device.connect()
            // The user may have tapped a different device while this connect
            // was in flight — that flow already disconnected us and owns the
            // shared state now. Stand down without touching it.
            guard activeDeviceID == device.identifier else {
                try? await device.disconnect()
                return
            }
            await installUnexpectedDisconnectHandler(for: device)
            await cleanUpOrphanResources(on: device)
            // Re-check after the cleanup awaits (orphan inspection can take
            // seconds on boards with stale logger slots).
            guard activeDeviceID == device.identifier else {
                try? await device.disconnect()
                return
            }
            connectionState = await device.state
            connectingDeviceID = nil
            await rememberDevice(device)
        } catch {
            // Same staleness rule on the failure path: only reset shared
            // state if this device still owns it.
            guard activeDeviceID == device.identifier else { return }
            connectingDeviceID = nil
            connectionState = .disconnected
            activeDevice = nil
            activeDeviceID = nil
            lastError = AppError(error: error)
        }
    }

    /// Inspect the board's logging state after connect and take action
    /// only on provably-stale resources. Everything else — timers,
    /// events, processors, and loggers we don't recognise — is left
    /// alone, because it might belong to another app, another phone, or
    /// an in-flight session we haven't downloaded yet.
    ///
    /// The decision matrix:
    ///   • LOG_LENGTH > 0  +  active loggers  → orphan alert
    ///       (real entries, decodable via the anonymous-logger flow;
    ///        let the user choose Download / Keep / Discard)
    ///   • LOG_LENGTH > 0  +  zero loggers    → silent `clearLog()`
    ///       (entries with no decoder = phantom data, often the MMS
    ///        firmware sentinel `LOG_LENGTH == 1` that lingers for
    ///        ~60 s after a clear)
    ///   • LOG_LENGTH == 0                   → no-op
    ///       (nothing to clean up that we can prove is ours; trust the
    ///        board's state, including any loggers / timers / events
    ///        that belong to a session we don't know about)
    ///
    /// We don't pre-emptively `removeAllEvents` / `removeAllTimers` any
    /// more — that used to be a blanket clean-up after our own crashes,
    /// but it also wiped legitimate state belonging to other apps.
    private func cleanUpOrphanResources(on device: MetaWearDevice) async {
        let id = device.identifier
        let anyPendingForDevice = pendingLogSessions.contains { $0.deviceID == id }

        // If our local store knows about a session on this device, the
        // board's state is ours — leave it alone; Download/Stop in the
        // app's own UI handles teardown.
        if anyPendingForDevice { return }

        let entryCount: UInt32
        do {
            entryCount = try await device.read(MWLogLength()).value
        } catch {
            lastError = AppError(error: error)
            return
        }
        guard entryCount > 0 else { return }

        let activeLoggers: [ActiveLogger]
        do {
            activeLoggers = try await device.queryActiveLoggers()
        } catch {
            // Enumeration failed, so we cannot prove the entries are
            // undecodable garbage. Keep the on-board data and surface the
            // orphan flow instead of clearing recoverable logs.
            orphanLogState = OrphanLogState(entryCount: entryCount, deviceID: id)
            return
        }
        if activeLoggers.isEmpty {
            // Entries with no logger subscriptions are guaranteed
            // garbage — there's no decoder anywhere that could turn
            // them into samples. Drop them so we don't re-alert on
            // every reconnect.
            do {
                try await device.clearLog()
            } catch {
                lastError = AppError(error: error)
            }
            return
        }

        // Real entries + real loggers, but no matching local record →
        // the data belongs to someone else (different phone, previous
        // install, third-party app). Surface to the user.
        orphanLogState = OrphanLogState(entryCount: entryCount, deviceID: id)
    }

    /// Wipe the orphan log entries the user was just told about. Called
    /// from the `RootView` alert's Discard action.
    ///
    /// `state` is passed in by the caller (captured from the alert's
    /// `presenting:` closure) because SwiftUI fires the `isPresented`
    /// binding's setter — which nils `orphanLogState` — *before* the
    /// button's `Task` actually runs. If we read `self.orphanLogState`
    /// here it would always be nil and the work would silently no-op.
    func discardOrphanLog(_ state: OrphanLogState) async {
        guard let device = activeDevice, device.identifier == state.deviceID else {
            orphanLogState = nil
            return
        }
        do {
            try await device.clearLog()
            orphanLogState = nil
        } catch {
            orphanLogState = state
            lastError = AppError(error: error)
        }
    }

    /// Dismiss the orphan-log alert without touching the board. Subsequent
    /// `startLogging` will clear the stale loggers as part of its setup.
    func dismissOrphanLog() {
        orphanLogState = nil
    }

    /// Download the orphan log data via the anonymous-logger SDK path,
    /// persist each reconstructed signal as its own `MWSessionRecord` with
    /// an "Unknown · …" label, then wipe the board. Used when the user
    /// taps "Download" on the orphan-log alert — the loggers were set up
    /// by a different app / install / phone, so we don't have any
    /// `MWLoggable` for them, but the board still holds the wiring needed
    /// to decode the data.
    ///
    /// Same captured-state pattern as `discardOrphanLog(_:)`: SwiftUI nils
    /// `orphanLogState` synchronously on tap, so the alert's button
    /// closure passes in the state it captured from `presenting:`.
    func downloadOrphanLog(_ state: OrphanLogState) async {
        guard let device = activeDevice, device.identifier == state.deviceID else {
            orphanLogState = nil
            return
        }
        orphanLogState = nil
        orphanDownloadPhase = .downloading(progress: 0)

        do {
            let signals = try await device.createAnonymousDataSignals()
            guard !signals.isEmpty else {
                // The board reported `LOG_LENGTH > 0` but no recoverable
                // logger metadata — typically a corrupt slot or a logger
                // type we don't decode yet. Clear so we don't keep re-
                // alerting on every reconnect.
                try await device.clearLog()
                orphanDownloadPhase = .completed(savedCount: 0)
                return
            }

            // Single raw drain; we'll decode per signal afterwards. The
            // orphan flow only surfaces a 0…1 progress (no count UI yet),
            // so we forward `percentComplete` straight through.
            var allEntries: [RawLogEntry] = []
            let stream = try await device.downloadLogs()
            for try await chunk in stream {
                orphanDownloadPhase = .downloading(progress: chunk.percentComplete)
                allEntries = chunk.data
            }

            guard let info = await device.deviceInfo else {
                throw MWError.invalidState("Device info unavailable")
            }

            var savedCount = 0
            for signal in signals {
                let typedSamples = try await device.decodeEntries(allEntries, for: signal)
                if try await save(orphanSignal: signal, samples: typedSamples,
                                  device: device, info: info) {
                    savedCount += 1
                }
            }

            try await device.clearLog()
            orphanDownloadPhase = .completed(savedCount: savedCount)
        } catch {
            orphanDownloadPhase = .failed(message: error.localizedDescription)
            lastError = AppError(error: error)
        }
    }

    /// Dismiss the post-download completion banner.
    func clearOrphanDownloadPhase() {
        orphanDownloadPhase = .idle
    }

    /// Persist one anonymous signal's samples as a session. Returns true
    /// when at least one sample was actually saved (empty signals are a
    /// no-op — no harm, no foul). Dispatches on the first sample's case
    /// to pick the matching `MWPersistable` type. Fuser signals (two
    /// outputs per entry) only persist the first output for now; rare
    /// enough that we can revisit if a user actually exercises it.
    private func save(
        orphanSignal signal: MWAnonymousSignal,
        samples: [MWLoggedSample<[MWAnonymousSignal.Output]>],
        device: MetaWearDevice,
        info: MWDeviceInformation
    ) async throws -> Bool {
        let label = "Unknown · \(signal.identifier)"
        guard let firstOutput = samples.first?.value.first else { return false }

        switch firstOutput {
        case .cartesian:
            let mapped: [MWLoggedSample<CartesianFloat>] = samples.compactMap {
                guard case .cartesian(let v) = $0.value.first else { return nil }
                return MWLoggedSample(date: $0.date, tickMs: $0.tickMs, value: v)
            }
            guard !mapped.isEmpty else { return false }
            _ = try await persistence.saveSession(
                deviceID: device.identifier, deviceInfo: info,
                sensorKind: CartesianFloat.persistenceKind,
                samples: mapped, label: label)
            return true

        case .scalar:
            let mapped: [MWLoggedSample<Float>] = samples.compactMap {
                guard case .scalar(let v) = $0.value.first else { return nil }
                return MWLoggedSample(date: $0.date, tickMs: $0.tickMs, value: v)
            }
            guard !mapped.isEmpty else { return false }
            _ = try await persistence.saveSession(
                deviceID: device.identifier, deviceInfo: info,
                sensorKind: Float.persistenceKind,
                samples: mapped, label: label)
            return true

        case .quaternion:
            let mapped: [MWLoggedSample<Quaternion>] = samples.compactMap {
                guard case .quaternion(let v) = $0.value.first else { return nil }
                return MWLoggedSample(date: $0.date, tickMs: $0.tickMs, value: v)
            }
            guard !mapped.isEmpty else { return false }
            _ = try await persistence.saveSession(
                deviceID: device.identifier, deviceInfo: info,
                sensorKind: Quaternion.persistenceKind,
                samples: mapped, label: label)
            return true

        case .euler:
            let mapped: [MWLoggedSample<EulerAngles>] = samples.compactMap {
                guard case .euler(let v) = $0.value.first else { return nil }
                return MWLoggedSample(date: $0.date, tickMs: $0.tickMs, value: v)
            }
            guard !mapped.isEmpty else { return false }
            _ = try await persistence.saveSession(
                deviceID: device.identifier, deviceInfo: info,
                sensorKind: EulerAngles.persistenceKind,
                samples: mapped, label: label)
            return true

        case .correctedCartesian:
            let mapped: [MWLoggedSample<CorrectedCartesianFloat>] = samples.compactMap {
                guard case .correctedCartesian(let v) = $0.value.first else { return nil }
                return MWLoggedSample(date: $0.date, tickMs: $0.tickMs, value: v)
            }
            guard !mapped.isEmpty else { return false }
            _ = try await persistence.saveSession(
                deviceID: device.identifier, deviceInfo: info,
                sensorKind: CorrectedCartesianFloat.persistenceKind,
                samples: mapped, label: label)
            return true
        }
    }

    private func installUnexpectedDisconnectHandler(for device: MetaWearDevice) async {
        let id = device.identifier
        await device.setOnUnexpectedDisconnect { [weak self] error in
            Task { @MainActor in
                self?.handleUnexpectedDisconnect(deviceID: id, error: error)
            }
        }
    }

    private func handleUnexpectedDisconnect(deviceID: UUID, error: Error) {
        // Ignore stale callbacks from a device we've since moved away from.
        guard activeDeviceID == deviceID else { return }
        connectionState = .disconnected
        activeDevice = nil
        activeDeviceID = nil
        connectingDeviceID = nil
        lastError = AppError(error: error)
    }

    func disconnect() async {
        guard let device = activeDevice else { return }
        try? await device.disconnect()
        connectionState = .disconnected
        activeDevice = nil
        activeDeviceID = nil
    }

    func forget(_ remembered: RememberedDevice) {
        let context = containers.cloud.mainContext
        context.delete(remembered)
        try? context.save()
        refreshRememberedDevices()
    }

    func refreshRememberedDevices() {
        let context = containers.cloud.mainContext
        let descriptor = FetchDescriptor<RememberedDevice>(
            sortBy: [SortDescriptor(\.lastConnected, order: .reverse)]
        )
        rememberedDevices = (try? context.fetch(descriptor)) ?? []
    }

    func refreshPendingLogSessions() {
        let context = containers.local.mainContext
        // "Pending" = still has data on the board's flash that hasn't been
        // downloaded. That covers both `.running` (currently recording) and
        // `.stopped` (recording finished, awaiting Download). Filtering on
        // just `.running` made `DownloadView` see an empty list whenever the
        // user hit Stop and then tapped Download in the same session.
        let descriptor = FetchDescriptor<LogSessionRecord>(
            predicate: #Predicate { $0.statusRaw == "running" || $0.statusRaw == "stopped" },
            sortBy: [SortDescriptor(\.startDate, order: .reverse)]
        )
        pendingLogSessions = (try? context.fetch(descriptor)) ?? []
    }

    func hasPendingLog(forPeripheral uuid: UUID) -> Bool {
        pendingLogSessions.contains { $0.deviceID == uuid }
    }

    private func rememberDevice(_ device: MetaWearDevice) async {
        // The simulated device never persists into Remembered — it would show
        // up as a stale phantom row in non-demo sessions.
        guard device.identifier != DemoBLETransport.deviceIdentifier else { return }
        let info = await device.deviceInfo
        let id = device.identifier
        let context = containers.cloud.mainContext
        let descriptor = FetchDescriptor<RememberedDevice>(
            predicate: #Predicate { $0.peripheralUUID == id }
        )
        let existing = (try? context.fetch(descriptor))?.first
        if let existing {
            existing.lastConnected = .now
            existing.name = scanner.advertisedNames[id] ?? existing.name
            existing.serialNumber = info?.serialNumber ?? existing.serialNumber
            existing.firmwareRevision = info?.firmwareRevision ?? existing.firmwareRevision
            existing.modelNumber = info?.modelNumber ?? existing.modelNumber
        } else {
            let record = RememberedDevice(
                peripheralUUID: id,
                name: scanner.advertisedNames[id] ?? "MetaWear",
                lastConnected: .now,
                serialNumber: info?.serialNumber,
                firmwareRevision: info?.firmwareRevision,
                modelNumber: info?.modelNumber
            )
            context.insert(record)
        }
        try? context.save()
        refreshRememberedDevices()
    }
}

struct AppError: Identifiable, Sendable {
    let id = UUID()
    let message: String

    init(error: Error) {
        self.message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}

/// Reported when a freshly connected board has on-flash log entries that
/// no local record claims — the SDK reads `LOG_LENGTH` after connect, and
/// any non-zero count without a matching pending session lands here.
struct OrphanLogState: Identifiable, Sendable {
    let id = UUID()
    let entryCount: UInt32
    let deviceID: UUID
}

/// Lifecycle of an orphan-log download. Drives the modal overlay shown in
/// `RootView` while the anonymous-logger pipeline reconstructs + persists
/// foreign-session data.
enum OrphanDownloadPhase: Equatable, Sendable {
    case idle
    case downloading(progress: Double)
    case completed(savedCount: Int)
    case failed(message: String)

    /// True for the two terminal cases — drives the result alert binding.
    var isTerminal: Bool {
        switch self {
        case .completed, .failed: return true
        default:                  return false
        }
    }
}
