import Foundation
import Observation
import SwiftData
import MetaWear
import MetaWearPersistence

/// Orchestrates MetaBase-style group logging: start logging on several
/// boards with one shared config, then stop-and-download them all later.
///
/// Logging is connectionless — boards record to their own flash with no
/// phone anywhere near them — so the coordinator never holds N live links.
/// It walks the fleet SEQUENTIALLY (one board at a time; the radio is
/// shared and one-at-a-time is the reliable shape): connect → act →
/// disconnect, then the next board. Boards are driven through the SDK
/// (`device.connect()`) directly, NOT `AppStore.connect(to:)` — the
/// AppStore path is entangled with navigation, the active-device slot, and
/// the connect-time orphan alert, none of which should fire N times during
/// a group pass.
///
/// Owned by `AppStore` (not a view) so an in-flight pass survives
/// navigation — the lesson of the foreign-download saga: never let a
/// destructive BLE operation ride a view's `.task` lifetime.
@Observable
@MainActor
final class GroupCaptureCoordinator {

    // MARK: - Per-board progress

    enum BoardPhase: Equatable {
        case pending
        case connecting
        case starting
        /// Loggers armed; waiting for proof that entries are landing.
        case verifying
        /// Start pass succeeded — the board is recording on its own.
        case logging
        case stopping
        case downloading
        /// Collect pass succeeded; the payload is the saved session count.
        case saved(Int)
        /// The drain succeeded and SOME sessions saved, but not all records
        /// decoded. No Retry is offered: the readout already consumed the
        /// board's entries, so a re-download cannot recover the rest.
        case savedWithIssues(Int, String)
        /// The board was left untouched, with the reason (out of range,
        /// nothing to download, …). Not an error: absent boards can be
        /// collected individually later via the normal per-board flow.
        case skipped(String)
        case failed(String)

        var isTerminal: Bool {
            switch self {
            case .logging, .saved, .savedWithIssues, .skipped, .failed: return true
            default: return false
            }
        }
    }

    struct BoardProgress: Identifiable, Equatable {
        let id: UUID
        let name: String
        var phase: BoardPhase = .pending
    }

    /// One board the caller wants in the group: a resolved device handle
    /// plus the display name to stamp onto its sessions.
    struct Member {
        let device: MetaWearDevice
        let name: String
    }

    // MARK: - Observable state

    enum PassKind { case start, collect }

    private(set) var boards: [BoardProgress] = []
    /// Which pass produced `boards` — drives the post-pass affordances
    /// (a failed COLLECT offers Retry; a failed start does not, since the
    /// user can simply select those boards and start again).
    private(set) var lastPass: PassKind?
    /// True while a start or collect pass is walking the fleet.
    private(set) var isBusy = false
    /// The download engine for whichever board is currently draining —
    /// exposed so the UI can render its live progress bar. Nil between
    /// boards and outside collect passes.
    private(set) var activeDownload: DownloadViewModel?

    private let containers: AppContainers
    private let persistence: MWPersistenceStore
    private unowned let appStore: AppStore

    /// The on-board "recording" heartbeat: a short red pulse every 5 s,
    /// played while a group session logs. LED playback runs on the board
    /// itself, so the heartbeat survives the disconnect — a glance at the
    /// fleet shows which pucks are recording. Slow + dim-duty on purpose:
    /// the LED must not meaningfully dent a multi-hour logging battery.
    static let recordingHeartbeat = MWLEDPattern(
        highIntensity: 31, lowIntensity: 0,
        riseTime: 0, highTime: 100, fallTime: 0,
        pulseDuration: 5000, repeatCount: .max
    )

    /// How long a sequential pass waits for one board's connect before
    /// declaring it absent and moving on. CoreBluetooth itself never times
    /// out a connect — without this cap one missing board wedges the whole
    /// fleet walk forever.
    static let connectTimeout: Duration = .seconds(15)

    init(containers: AppContainers, persistence: MWPersistenceStore, appStore: AppStore) {
        self.containers = containers
        self.persistence = persistence
        self.appStore = appStore
    }

    // MARK: - Start pass

    /// Sequentially start logging `selections` (one shared config) on every
    /// member. Each board: connect → start loggers → stamp group-tagged
    /// `LogSessionRecord`s → disconnect. Boards that already carry a
    /// pending session are skipped — starting over it would fight the
    /// existing session for logger slots.
    func startAll(members: [Member], selections: [SensorSelection]) async {
        guard !isBusy, !members.isEmpty, !selections.isEmpty else { return }
        isBusy = true
        lastPass = .start
        defer { isBusy = false }

        let groupID = UUID()
        boards = members.map { BoardProgress(id: $0.device.identifier, name: $0.name) }

        for member in members {
            let id = member.device.identifier
            if appStore.hasPendingLog(forPeripheral: id) {
                setPhase(id, .skipped("Already has a session — download it first"))
                continue
            }
            do {
                setPhase(id, .connecting)
                let ownsConnection = try await connectIfNeeded(member.device)
                setPhase(id, .starting)
                // Boards reaching here have no local claim on their flash
                // (pending boards were skipped above). Field evidence: MMS
                // boards carrying stale trigger slots from abandoned
                // sessions read LOG_LENGTH 0 FOREVER after logging (flush
                // and all) — the same boards download fine after a clear.
                // Start every group session on a clean slate. This also
                // wipes unclaimed foreign data by design: the user just
                // chose to record fresh on this board.
                try? await member.device.clearLog()
                let vm = LogSessionViewModel(device: member.device, containers: containers)
                await vm.start(selections, groupID: groupID)
                if case .running = vm.phase {
                    // Don't take the firmware's word for it — verify that
                    // entries are actually landing before leaving the
                    // board. NAND garbage collection (kicked off by any
                    // drop, including our clear moments ago) silently
                    // swallows samples while it grinds, and SEVEN field
                    // sessions proved no proxy detects its end: LOG_LENGTH
                    // reads 0 on an empty-but-dirty log, and the 0x0D
                    // drop notification may never arrive. The entry count
                    // rising is the only trustworthy signal — while
                    // logging is enabled it includes the RAM page, so a
                    // healthy board confirms within seconds.
                    setPhase(id, .verifying)
                    if await confirmEntriesLanding(on: member.device) {
                        // Best-effort: the heartbeat is a courtesy
                        // indicator — an LED hiccup must not fail a
                        // successfully started board. The immediate play
                        // covers the connected window; the firmware stops
                        // LED playback the moment the link drops, so the
                        // BOARD re-arms it via disconnect events. Their
                        // ids are stamped onto the records so the collect
                        // pass can tear them down even after an app
                        // restart — an un-removed pair would relight the
                        // LED on every future disconnect, forever.
                        try? await member.device.setLED(red: Self.recordingHeartbeat)
                        let eventIDs = await armDisconnectHeartbeat(on: member.device)
                        if !eventIDs.isEmpty,
                           let json = Self.encodeEventIDs(eventIDs) {
                            vm.activeRecords.forEach { $0.ledEventIDsJSON = json }
                            try? containers.local.mainContext.save()
                        }
                        setPhase(id, .logging)
                    } else {
                        // The session is doomed — the sensors run but the
                        // flash swallows everything. Tear it down so no
                        // zombie records linger.
                        await vm.stop()
                        let context = containers.local.mainContext
                        vm.activeRecords.forEach { context.delete($0) }
                        try? context.save()
                        setPhase(id, .failed("The board's flash is still busy (housekeeping after a clear). Wait a minute and start again."))
                    }
                } else {
                    setPhase(id, .failed(vm.lastError?.message ?? "Logging did not start"))
                }
                if ownsConnection { try? await member.device.disconnect() }
            } catch {
                setPhase(id, .failed(Self.friendlyConnectError(error)))
            }
        }
        appStore.refreshPendingLogSessions()
    }

    // MARK: - Collect pass

    /// Sequentially stop and download every member — the catch-all pass:
    ///   • our own running records → stop, download, save (group-tagged)
    ///   • stopped-but-not-downloaded records → download, save
    ///   • no local records but data/logging on the board (started on
    ///     another phone, reinstall) → anonymous foreign download
    ///   • board out of range → skipped; its data stays on flash and the
    ///     normal per-board flow can collect it any time later
    func stopAndDownloadAll(members: [Member]) async {
        guard !isBusy, !members.isEmpty else { return }
        isBusy = true
        lastPass = .collect
        defer {
            isBusy = false
            activeDownload = nil
        }

        boards = members.map { BoardProgress(id: $0.device.identifier, name: $0.name) }

        for member in members {
            let id = member.device.identifier
            do {
                setPhase(id, .connecting)
                let ownsConnection = try await connectIfNeeded(member.device)
                await collectOne(member: member)
                if ownsConnection { try? await member.device.disconnect() }
            } catch {
                setPhase(id, .skipped(Self.friendlyConnectError(error)))
            }
            appStore.refreshPendingLogSessions()
        }
    }

    /// Stop + drain one connected board. Never throws: every outcome lands
    /// in the board's phase so one board's failure can't abort the walk.
    private func collectOne(member: Member) async {
        let id = member.device.identifier
        // Recording is over the moment collection begins — clear the
        // heartbeat first so the LED state can't outlive the session even
        // if the download below fails. Best-effort, like the set.
        try? await member.device.stopLED()
        let pending = appStore.pendingLogSessions.filter { $0.deviceID == id }
        // Tear down the disconnect-event heartbeat armed at start —
        // without this the board relights its LED on EVERY disconnect.
        if let json = pending.compactMap(\.ledEventIDsJSON).first,
           let eventIDs = Self.decodeEventIDs(json) {
            for eventID in eventIDs {
                try? await member.device.removeEvent(MWEvent(id: eventID))
            }
        }
        let running = pending.filter { $0.status == .running }

        if !running.isEmpty {
            setPhase(id, .stopping)
            let vm = LogSessionViewModel(device: member.device, containers: containers)
            vm.restoreFromPending(records: running)
            await vm.stop()
        }

        setPhase(id, .downloading)
        let download = DownloadViewModel(
            device: member.device,
            store: persistence,
            containers: containers,
            deviceName: member.name
        )
        activeDownload = download

        if !pending.isEmpty {
            await download.downloadAll(records: pending)
        } else {
            // Catch-all: nothing local claims this board. If its flash
            // holds entries (or it is actively logging), recover via the
            // anonymous-logger path — same engine as the Logging screen's
            // foreign-session card.
            let entryCount = (try? await member.device.read(MWLogLength()).value) ?? 0
            let loggingEnabled = (try? await member.device.read(MWLoggingEnabled()).value) ?? false
            guard entryCount > 0 || loggingEnabled else {
                activeDownload = nil
                setPhase(id, .skipped("Nothing to download"))
                return
            }
            let state = OrphanLogState(
                entryCount: entryCount, deviceID: id, isActivelyLogging: loggingEnabled
            )
            await download.downloadForeign(state)
            if case .ready = download.phase {
                appStore.clearForeignLog(for: id)
            }
        }

        switch download.phase {
        case .ready(let snapshots, let warning):
            if let warning {
                // Partial success must not render an unqualified green
                // check — but when sessions DID save, it isn't a failure
                // either, and a Retry can't help (the drain consumed the
                // board's entries).
                setPhase(id, snapshots.isEmpty
                    ? .failed(warning)
                    : .savedWithIssues(snapshots.count, warning))
            } else {
                setPhase(id, .saved(snapshots.count))
            }
        case .failed(let message):
            setPhase(id, .failed(message))
        default:
            setPhase(id, .failed("Download did not complete"))
        }
        activeDownload = nil
    }

    // MARK: - Helpers

    /// Connect unless the board is already usable. Policy by state:
    ///   • `.idle` — the app already holds the link (it's the active
    ///     device, parked): BORROW it; the caller must not disconnect.
    ///   • `.disconnected` — open our own connection (caller owns it).
    ///   • anything else (`.connecting`/`.streaming`/`.logging`/
    ///     `.downloading`) — some other flow is actively driving this
    ///     board (Live Stream, a solo download, a user-initiated
    ///     connect); barging in would corrupt its state machine. Skip.
    /// Bounded by `connectTimeout`: an absent board must cost one
    /// timeout, not wedge the fleet walk.
    /// - Returns: true when this call opened the connection (caller owns it).
    private func connectIfNeeded(_ device: MetaWearDevice) async throws -> Bool {
        switch await device.state {
        case .idle:
            return false
        case .disconnected:
            break
        default:
            throw BoardBusyError()
        }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await device.connect()
            }
            group.addTask {
                try await Task.sleep(for: Self.connectTimeout)
                throw ConnectTimeoutError()
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                // Cancel the pending CoreBluetooth connect so the board
                // doesn't attach mid-walk to a slot nobody owns anymore.
                // ONLY when a connect is actually pending: after an
                // outright failure ("Peripheral not found") the device is
                // already back at .disconnected, the central never
                // registered the peripheral, and a transport disconnect
                // would park a continuation nothing will ever resume —
                // wedging the walk with isBusy stuck true.
                if await device.state != .disconnected {
                    try? await device.disconnect()
                }
                throw error
            }
        }
        return true
    }

    /// Record the LED heartbeat into the board's DISCONNECT EVENT so the
    /// blinking survives the link drop: two events fire on disconnect —
    /// re-set the red pattern, then play. Requires Settings revision ≥ 2
    /// (the disconnect signal's floor); best-effort like every LED touch.
    /// - Returns: the board-assigned event ids (for collect-time removal),
    ///   empty when arming was skipped or failed.
    private func armDisconnectHeartbeat(on device: MetaWearDevice) async -> [UInt8] {
        guard (await device.modules[.settings]?.revision ?? 0) >= 2 else { return [] }
        do {
            let pattern = try await device.createEvent(
                source: .disconnected(),
                action: try MWEventAction(
                    command: MWLED.SetPattern(color: .red, pattern: Self.recordingHeartbeat)
                )
            )
            let play = try await device.createEvent(
                source: .disconnected(),
                action: try MWEventAction(command: MWLED.Play())
            )
            return [pattern.id, play.id]
        } catch {
            return []
        }
    }

    private static func encodeEventIDs(_ ids: [UInt8]) -> String? {
        (try? JSONEncoder().encode(ids)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decodeEventIDs(_ json: String) -> [UInt8]? {
        try? JSONDecoder().decode([UInt8].self, from: Data(json.utf8))
    }

    /// Poll the live entry count until it rises — proof the board is
    /// genuinely recording. 90 s bound covers the longest post-clear GC
    /// observed in the field; healthy boards confirm on the first poll.
    private func confirmEntriesLanding(on device: MetaWearDevice) async -> Bool {
        for _ in 0..<45 {
            try? await Task.sleep(for: .seconds(2))
            if let count = try? await device.read(MWLogLength()).value, count > 0 {
                return true
            }
        }
        return false
    }

    private struct ConnectTimeoutError: Error {}
    private struct BoardBusyError: Error {}

    private static func friendlyConnectError(_ error: Error) -> String {
        if error is ConnectTimeoutError {
            return "Not found nearby — bring the board closer and retry, or download from it individually later"
        }
        if error is BoardBusyError {
            return "In use elsewhere in the app — leave its screen and retry"
        }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func setPhase(_ id: UUID, _ phase: BoardPhase) {
        guard let index = boards.firstIndex(where: { $0.id == id }) else { return }
        boards[index].phase = phase
    }
}
