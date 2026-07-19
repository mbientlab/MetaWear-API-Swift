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

    /// Boards holding foreign log data, keyed by peripheral UUID. Unlike
    /// the one-shot connect alert (`orphanLogState`), this SURVIVES the
    /// alert's dismissal so the Log Session screen can offer Stop &
    /// Download at any time — "Keep" is no longer a dead end. Cleared by
    /// download/discard, or when a local record claims the board.
    private(set) var foreignLogs: [UUID: OrphanLogState] = [:]

    init(containers: AppContainers) {
        self.containers = containers
        self.scanner = MetaWearScanner()
        self.persistence = MWPersistenceStore(modelContainer: containers.local)
        loadLocalPeripheralMap()
        refreshRememberedDevices()
        refreshPendingLogSessions()
    }

    // MARK: - Demo device

    /// The fully simulated MetaWear fleet (see `DemoBLETransport.Identity`).
    /// Created on first access so non-demo sessions never pay for it; each
    /// board is a stable instance reused across connect/disconnect cycles
    /// like a real discovered device.
    private var _demoDevices: [MetaWearDevice]?
    var demoDevices: [MetaWearDevice] {
        if let devices = _demoDevices { return devices }
        let devices = DemoMode.identities.map {
            MetaWearDevice(identifier: $0.identifier, transport: DemoBLETransport(identity: $0))
        }
        _demoDevices = devices
        return devices
    }

    /// The primary demo board — kept for call sites that predate the fleet.
    var demoDevice: MetaWearDevice { demoDevices[0] }

    /// Display name for the active device: advertised name when we have
    /// one, the demo label for a simulated device, then the REMEMBERED
    /// name. The remembered fallback matters beyond cosmetics: a direct
    /// reconnect to a known identifier (retrievePeripherals path) observes
    /// zero advertisements, and this name gets STAMPED onto persisted
    /// sessions — without it, a renamed board's sessions would be
    /// attributed to the generic literal forever.
    var activeDeviceName: String {
        guard let id = activeDeviceID else { return "Device" }
        if let demoName = DemoMode.name(for: id) { return demoName }
        if let advertised = scanner.advertisedNames[id], !advertised.isEmpty {
            return advertised
        }
        if let remembered = rememberedDevices.first(where: { $0.peripheralUUID == id })?.name,
           !remembered.isEmpty {
            return remembered
        }
        return "MetaWear"
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
        if let state = await evaluateForeignLog(on: device, surfaceAlert: true) {
            orphanLogState = state
        }
    }

    /// Re-evaluate a board's foreign-log status on demand — the Log
    /// Session screen calls this on appear so the download path stays
    /// discoverable after the connect-time alert was dismissed (or when
    /// logging started elsewhere AFTER this phone connected).
    func refreshForeignLogState(for device: MetaWearDevice) async {
        _ = await evaluateForeignLog(on: device, surfaceAlert: false)
    }

    /// Shared detection: reads the board's logging state, applies the pure
    /// decision table, updates `foreignLogs`, and performs the silent
    /// cleanup of provably-garbage entries. Returns a state when the
    /// caller should raise the connect-time alert.
    private func evaluateForeignLog(
        on device: MetaWearDevice, surfaceAlert: Bool
    ) async -> OrphanLogState? {
        let id = device.identifier
        let hasLocalPending = pendingLogSessions.contains { $0.deviceID == id }

        let entryCount: UInt32
        do {
            entryCount = try await device.read(MWLogLength()).value
        } catch {
            // A cancelled refresh (the Logging screen's `.task` dies when
            // the user navigates away — e.g. straight into the download)
            // is routine, not an error worth a global alert. Cancellation
            // can surface as CancellationError OR as a read timeout, so
            // check the task flag too.
            if !(error is CancellationError), !Task.isCancelled {
                lastError = AppError(error: error)
            }
            return nil
        }
        // The enabled read catches a session in progress even when the
        // entry count is 0 (MMS buffers the first flash page in RAM).
        let loggingEnabled = (try? await device.read(MWLoggingEnabled()).value) ?? false
        let activeLoggers = try? await device.queryActiveLoggers()

        // Never ACT on a cancelled evaluation: a logger enumeration cut
        // short by cancellation reads as "no loggers", which the decision
        // table below would treat as clearable garbage — and clearLog here
        // could run concurrently with the very download the user just
        // navigated to, wiping the board mid-drain.
        guard !Task.isCancelled else { return nil }

        let decision = Self.foreignLogDecision(
            entryCount: entryCount,
            hasActiveLoggers: activeLoggers.map { !$0.isEmpty },
            isLoggingEnabled: loggingEnabled,
            hasLocalPendingRecord: hasLocalPending
        )
        switch decision {
        case .surface(let isActive):
            let state = OrphanLogState(
                entryCount: entryCount, deviceID: id, isActivelyLogging: isActive
            )
            foreignLogs[id] = state
            return surfaceAlert ? state : nil
        case .silentClear:
            // Entries with no logger subscriptions are guaranteed garbage —
            // no decoder anywhere could turn them into samples. Drop them so
            // we don't re-alert on every reconnect.
            do {
                try await device.clearLog()
            } catch {
                lastError = AppError(error: error)
            }
            foreignLogs[id] = nil
            return nil
        case .leaveAlone:
            foreignLogs[id] = nil
            return nil
        }
    }

    enum ForeignLogDecision: Equatable {
        /// Recoverable foreign data (or a session in progress) — show it.
        case surface(isActivelyLogging: Bool)
        /// Entries with no loggers: undecodable garbage, clear silently.
        case silentClear
        /// Nothing foreign here (or it's this phone's own session).
        case leaveAlone
    }

    /// Pure decision table for foreign-log detection, unit-tested.
    ///
    /// - Parameters:
    ///   - hasActiveLoggers: `nil` when enumeration failed — we then can't
    ///     prove entries are garbage, so anything suggesting data surfaces.
    static func foreignLogDecision(
        entryCount: UInt32,
        hasActiveLoggers: Bool?,
        isLoggingEnabled: Bool,
        hasLocalPendingRecord: Bool
    ) -> ForeignLogDecision {
        // A local record means the board's state is ours; the app's own
        // Download/Stop UI handles teardown.
        if hasLocalPendingRecord { return .leaveAlone }
        switch hasActiveLoggers {
        case .some(true):
            if entryCount > 0 || isLoggingEnabled {
                return .surface(isActivelyLogging: isLoggingEnabled)
            }
            // Armed loggers, no entries, not sampling: configured but never
            // started. Nothing recoverable; leave the wiring alone.
            return .leaveAlone
        case .some(false):
            return entryCount > 0 ? .silentClear : .leaveAlone
        case .none:
            return (entryCount > 0 || isLoggingEnabled)
                ? .surface(isActivelyLogging: isLoggingEnabled)
                : .leaveAlone
        }
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
            foreignLogs[state.deviceID] = nil
        } catch {
            orphanLogState = state
            lastError = AppError(error: error)
        }
    }

    /// Dismiss the orphan-log ALERT without touching the board. Not a dead
    /// end: the persistent `foreignLogs` entry keeps the Stop & Download
    /// path available on the Log Session screen.
    func dismissOrphanLog() {
        orphanLogState = nil
    }

    /// Drop the persistent foreign-log entry for a board once its data has
    /// been downloaded (the Download screen calls this on success — the
    /// download itself runs in `DownloadViewModel.downloadForeign`, same
    /// screen and progress UI as a normal download).
    func clearForeignLog(for deviceID: UUID) {
        foreignLogs[deviceID] = nil
        if orphanLogState?.deviceID == deviceID {
            orphanLogState = nil
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
        // Drop the connect-time foreign-log alert with the link — its
        // Download/Discard actions target a board we can no longer reach.
        // The persistent `foreignLogs` entry survives, so the path stays
        // discoverable from the Logging screen after a reconnect.
        if orphanLogState?.deviceID == deviceID {
            orphanLogState = nil
        }
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

    /// Rename the synced record for a board immediately. Without this,
    /// the record's name only refreshes on a future reconnect after fresh
    /// advertisements — the rename would look like it did nothing, and the
    /// user's other devices wouldn't see the new name until then either.
    func renameRememberedDevice(peripheralUUID: UUID, mac: String?, to name: String) {
        let record = rememberedDevices.first {
            ($0.macAddress != nil && $0.macAddress == mac)
                || $0.peripheralUUID == peripheralUUID
        }
        guard let record, record.name != name else { return }
        record.name = name
        try? containers.cloud.mainContext.save()
        refreshRememberedDevices()
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
        // Simulated devices never persist into Remembered — they would show
        // up as stale phantom rows in non-demo sessions. Set membership, not
        // board-0 equality: the whole demo fleet is excluded.
        guard !DemoMode.isDemoID(device.identifier) else { return }
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

/// Reported when a connected board holds (or is actively recording) log
/// data that no local record claims — a session started on another phone,
/// a previous install, or a third-party app.
struct OrphanLogState: Identifiable, Hashable, Sendable {
    let id = UUID()
    let entryCount: UInt32
    let deviceID: UUID
    /// True when the board's logging is currently ENABLED — a session in
    /// progress, not just leftover data. Drives the user-facing copy and
    /// catches the MMS case where `LOG_LENGTH` reads 0 because the first
    /// flash page is still buffering in RAM.
    let isActivelyLogging: Bool
}
