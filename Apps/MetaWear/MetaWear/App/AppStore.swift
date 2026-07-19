import Foundation
import Observation
import SwiftData
import MetaWear
import MetaWearPersistence
import os

/// Main app coordinator shared by the SwiftUI scene.
///
/// Owns long-lived services (`MetaWearScanner`, SwiftData containers, and the
/// persistence actor), tracks the active device, and handles cross-feature
/// flows that do not belong to a single screen: remembered devices, orphan log
/// recovery, connect/disconnect, and unexpected-disconnect handling.
@Observable
@MainActor
final class AppStore {

    /// Cross-feature diagnostics (filter Console on "MetaWearSync").
    static let log = Logger(
        subsystem: "com.mbientlab.MetaWear",
        category: "MetaWearSync"
    )

    let scanner: MetaWearScanner
    let containers: AppContainers
    let persistence: MWPersistenceStore

    var activeDeviceID: UUID?
    var activeDevice: MetaWearDevice?
    var connectionState: DeviceState = .disconnected
    var lastError: AppError?

    /// Live RSSI of the active connection, polled every 3 s. `nil` when
    /// disconnected or before the first read completes. Boards stop
    /// advertising once connected, so `scanner.advertisementRSSI` freezes —
    /// this poll is the only live signal source for a connected board.
    private(set) var connectedRSSI: Int?
    @ObservationIgnored private var rssiPollTask: Task<Void, Never>?

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
        loadLocalPeripheralMap()
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
            startRSSIPolling(for: device)
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
        stopRSSIPolling()
        connectionState = .disconnected
        activeDevice = nil
        activeDeviceID = nil
        connectingDeviceID = nil
        lastError = AppError(error: error)
    }

    func disconnect() async {
        guard let device = activeDevice else { return }
        stopRSSIPolling()
        try? await device.disconnect()
        connectionState = .disconnected
        activeDevice = nil
        activeDeviceID = nil
    }

    // MARK: - Connected-RSSI polling

    private func startRSSIPolling(for device: MetaWearDevice) {
        stopRSSIPolling()
        rssiPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.activeDeviceID == device.identifier else { return }
                // Best-effort: a failed read (mid-teardown, DFU handoff)
                // just leaves the last value; the poller is cancelled by
                // every disconnect path.
                if let rssi = try? await device.readRSSI(), !Task.isCancelled {
                    self.connectedRSSI = rssi
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopRSSIPolling() {
        rssiPollTask?.cancel()
        rssiPollTask = nil
        connectedRSSI = nil
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
        var records = (try? context.fetch(descriptor)) ?? []
        // CloudKit forbids unique constraints and its sync-state resets
        // ("Change Token Expired" recoveries) can re-import server rows next
        // to their local twins, so duplicates are a fact of life — sweep them
        // on every refresh. The keeper choice is deterministic so every host
        // deletes the SAME losers and the fold converges instead of hosts
        // fighting over which twin survives.
        let deduped = Self.dedupeRememberedDevices(records, in: context)
        if deduped.count != records.count {
            Self.log.info("Folded \(records.count - deduped.count) duplicate remembered-device rows")
            try? context.save()
            records = deduped
        }
        rememberedDevices = records
    }

    /// Fold records describing the same physical board — same MAC address,
    /// or same peripheral UUID (possible after a CloudKit sync-state reset
    /// resurrects a row) — into one deterministic keeper, merging fields the
    /// keeper lacks and deleting the rest.
    ///
    /// Keeper rule: newest `lastConnected`, tie-broken by MAC presence and
    /// then peripheral UUID string — all values that sync identically to
    /// every host, so all hosts converge on the same keeper.
    static func dedupeRememberedDevices(
        _ records: [RememberedDevice],
        in context: ModelContext
    ) -> [RememberedDevice] {
        func identity(_ record: RememberedDevice) -> String {
            record.macAddress ?? "uuid:\(record.peripheralUUID.uuidString)"
        }
        func precedence(_ record: RememberedDevice) -> (Date, Int, String) {
            (record.lastConnected, record.macAddress == nil ? 0 : 1,
             record.peripheralUUID.uuidString)
        }

        var keepers: [String: RememberedDevice] = [:]
        var order: [String] = []
        for record in records {
            let key = identity(record)
            guard let existing = keepers[key] else {
                keepers[key] = record
                order.append(key)
                continue
            }
            let (keeper, loser) = precedence(record) > precedence(existing)
                ? (record, existing) : (existing, record)
            // Merge anything the keeper is missing before dropping the twin.
            keeper.macAddress = keeper.macAddress ?? loser.macAddress
            keeper.serialNumber = keeper.serialNumber ?? loser.serialNumber
            keeper.firmwareRevision = keeper.firmwareRevision ?? loser.firmwareRevision
            keeper.modelNumber = keeper.modelNumber ?? loser.modelNumber
            keepers[key] = keeper
            context.delete(loser)
        }
        // Second pass: a MAC-less row whose peripheralUUID matches a
        // MAC-bearing keeper is the same board pre-backfill — fold it too.
        var byUUID: [UUID: String] = [:]
        for key in order {
            guard let record = keepers[key] else { continue }
            if let existingKey = byUUID[record.peripheralUUID],
               let existing = keepers[existingKey] {
                let (keeper, loser) = precedence(record) > precedence(existing)
                    ? (record, existing) : (existing, record)
                keeper.macAddress = keeper.macAddress ?? loser.macAddress
                keeper.serialNumber = keeper.serialNumber ?? loser.serialNumber
                keeper.firmwareRevision = keeper.firmwareRevision ?? loser.firmwareRevision
                keeper.modelNumber = keeper.modelNumber ?? loser.modelNumber
                keepers[existingKey] = keeper
                keepers[key] = nil
                context.delete(loser)
            } else {
                byUUID[record.peripheralUUID] = key
            }
        }
        return order.compactMap { keepers[$0] }
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
        // The MAC address is the only identity that survives across the
        // user's Apple devices: CoreBluetooth peripheral UUIDs are generated
        // per host, so a record synced from the iPhone can't be matched to
        // an on-air peripheral on the Mac by UUID alone.
        let mac = try? await device.read(MWSettings.ReadMacAddress()).value
        if let mac {
            recordLocalPeripheral(mac: mac, uuid: id)
            // While connected anyway, teach the board to broadcast its MAC so
            // the user's OTHER devices recognize it on air (one-time, gated).
            await configureMACAdvertisementIfNeeded(device, id: id, mac: mac)
        }

        let context = containers.cloud.mainContext
        let existing = Self.reconcileRememberedDevice(
            in: context, peripheralUUID: id, macAddress: mac
        )
        if let existing {
            existing.lastConnected = .now
            existing.name = scanner.advertisedNames[id] ?? existing.name
            existing.serialNumber = info?.serialNumber ?? existing.serialNumber
            existing.firmwareRevision = info?.firmwareRevision ?? existing.firmwareRevision
            existing.modelNumber = info?.modelNumber ?? existing.modelNumber
            if let mac { existing.macAddress = mac }
        } else {
            let record = RememberedDevice(
                peripheralUUID: id,
                name: scanner.advertisedNames[id] ?? "MetaWear",
                macAddress: mac,
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

    /// Find the synced row for a board identified by this host's peripheral
    /// UUID and (when readable) its MAC address, folding duplicates.
    ///
    /// MAC match wins: it's the same physical board even when it was
    /// remembered by another host under that host's peripheral UUID. If a
    /// UUID-keyed row ALSO exists and is a different object (the board was
    /// remembered here before MAC backfill existed), it's a duplicate of the
    /// same hardware — fold it by deleting the UUID row and keeping the MAC
    /// row, which other hosts may already reference.
    static func reconcileRememberedDevice(
        in context: ModelContext,
        peripheralUUID: UUID,
        macAddress: String?
    ) -> RememberedDevice? {
        let uuidDescriptor = FetchDescriptor<RememberedDevice>(
            predicate: #Predicate { $0.peripheralUUID == peripheralUUID }
        )
        let byUUID = (try? context.fetch(uuidDescriptor))?.first
        guard macAddress != nil else { return byUUID }
        // Compare optional-to-optional: SwiftData's #Predicate fatalErrors at
        // fetch time when an optional stored property is compared against a
        // non-optional value (the implicit promotion isn't translatable).
        let mac: String? = macAddress
        let macDescriptor = FetchDescriptor<RememberedDevice>(
            predicate: #Predicate { $0.macAddress == mac }
        )
        guard let byMAC = (try? context.fetch(macDescriptor))?.first else {
            return byUUID
        }
        if let byUUID, byUUID !== byMAC {
            context.delete(byUUID)
        }
        return byMAC
    }

    // MARK: - Host-local peripheral resolution

    /// Host-local map from board MAC address to THIS host's CoreBluetooth
    /// peripheral UUID, built as boards are connected here. Lives in
    /// UserDefaults precisely because it must never sync: peripheral UUIDs
    /// are meaningless on any other host.
    private static let localPeripheralsKey = "MWLocalPeripheralUUIDByMAC"

    private(set) var localPeripheralUUIDByMAC: [String: UUID] = [:]

    func loadLocalPeripheralMap() {
        let raw = UserDefaults.standard.dictionary(forKey: Self.localPeripheralsKey) as? [String: String] ?? [:]
        localPeripheralUUIDByMAC = raw.compactMapValues(UUID.init(uuidString:))
        macAdvertisementConfigured = Set(
            UserDefaults.standard.stringArray(forKey: Self.configuredMACAdKey) ?? []
        )
    }

    private func recordLocalPeripheral(mac: String, uuid: UUID) {
        guard localPeripheralUUIDByMAC[mac] != uuid else { return }
        localPeripheralUUIDByMAC[mac] = uuid
        UserDefaults.standard.set(
            localPeripheralUUIDByMAC.mapValues(\.uuidString),
            forKey: Self.localPeripheralsKey
        )
    }

    /// Resolve which peripheral UUID represents a remembered board on THIS
    /// host, in order of confidence:
    ///   1. The host-local mapping by MAC (built when the board was connected
    ///      here before).
    ///   2. A live advertisement broadcasting the record's MAC — boards the
    ///      app has touched anywhere are configured to self-identify on air
    ///      (`enableMACAdvertisement`), so a record synced from another host
    ///      matches its nearby twin without ever connecting here.
    ///   3. The record's own UUID (correct on the host that remembered it).
    func localPeripheralUUID(for remembered: RememberedDevice) -> UUID {
        guard let mac = remembered.macAddress else { return remembered.peripheralUUID }
        if let local = localPeripheralUUIDByMAC[mac] {
            return local
        }
        if let onAir = scanner.advertisedMACs.first(where: { $0.value == mac })?.key {
            return onAir
        }
        return remembered.peripheralUUID
    }

    // MARK: - Board MAC self-identification

    /// Host-local set of board MACs this host has already configured to
    /// broadcast their MAC (an on-boot macro uses a finite flash slot, so
    /// configuration must not repeat on every connect).
    private static let configuredMACAdKey = "MWMACAdvertisementConfigured"

    private(set) var macAdvertisementConfigured: Set<String> = []

    private func markMACAdvertisementConfigured(_ mac: String) {
        guard macAdvertisementConfigured.insert(mac).inserted else { return }
        UserDefaults.standard.set(
            Array(macAdvertisementConfigured),
            forKey: Self.configuredMACAdKey
        )
    }

    /// One-time board configuration: make it broadcast its MAC so every
    /// other Apple device recognizes it during scanning (peripheral UUIDs
    /// are host-specific; the advertised MAC is the shared identity).
    /// Failures are logged and ignored — the connect-time mapping still
    /// covers this host, and the next connect retries.
    private func configureMACAdvertisementIfNeeded(
        _ device: MetaWearDevice, id: UUID, mac: String
    ) async {
        guard Self.shouldConfigureMACAdvertisement(
            observedMAC: scanner.advertisedMACs[id],
            lastAdvertisementSeen: scanner.advertisementLastSeen[id],
            alreadyConfigured: macAdvertisementConfigured.contains(mac),
            now: .now
        ) else { return }
        do {
            try await device.enableMACAdvertisement(
                advertisedName: scanner.advertisedNames[id] ?? "MetaWear"
            )
            markMACAdvertisementConfigured(mac)
            Self.log.info("Configured MAC advertisement for \(mac, privacy: .public)")
        } catch {
            Self.log.error("MAC advertisement configuration failed for \(mac, privacy: .public): \(error, privacy: .public)")
        }
    }

    /// Pure decision gate for the one-time configuration, unit-tested.
    ///
    /// Configure only when this host RECENTLY observed the board advertising
    /// WITHOUT a MAC (a fresh advertisement proves the current scan-response
    /// content) and hasn't already configured it. If no advertisement was
    /// observed — e.g. a direct reconnect to a known identifier without a
    /// scan — we can't judge the board's current state, so do nothing rather
    /// than risk stacking duplicate on-boot macros.
    static func shouldConfigureMACAdvertisement(
        observedMAC: String?,
        lastAdvertisementSeen: Date?,
        alreadyConfigured: Bool,
        now: Date
    ) -> Bool {
        guard observedMAC == nil, !alreadyConfigured,
              let seen = lastAdvertisementSeen,
              now.timeIntervalSince(seen) < 15 * 60 else { return false }
        return true
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
