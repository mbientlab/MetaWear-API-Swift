import SwiftUI
import MetaWear

/// MetaBase-style group logging: pick several boards, pick ONE shared
/// sensor config, start them all logging with a single tap — then come
/// back any time (logging is connectionless) and stop-and-download the
/// whole fleet. Orchestration lives in `AppStore.groupCapture`, which
/// walks the boards sequentially; this view only selects members and
/// renders per-board progress.
struct GroupLoggingView: View {
    @Environment(AppStore.self) private var appStore
    @State private var scanVM: ScannerViewModel?
    @State private var selectedIDs: Set<UUID> = []
    @State private var selections: [SensorSelection] = [
        SensorSelection(id: .accelerometer, hz: SensorKey.accelerometer.defaultHz, range: 2)
    ]
    @State private var showStopConfirm = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            Form {
                let coordinator = appStore.groupCapture
                let active = activeGroupRecords

                // Hide "Last Run" when it would only duplicate the
                // active-group section (a fully successful start pass:
                // every board it lists is already shown, recording, under
                // "Logging In Progress").
                let lastRunIsRedundant = !coordinator.isBusy
                    && !active.isEmpty
                    && coordinator.boards.allSatisfy { $0.phase == .logging }
                if (coordinator.isBusy || !coordinator.boards.isEmpty) && !lastRunIsRedundant {
                    progressSection(coordinator: coordinator)
                }

                if !active.isEmpty {
                    activeGroupSection(records: active)
                } else if !coordinator.isBusy {
                    boardPickerSection(now: timeline.date)
                    SensorPickerSection(
                        selections: $selections,
                        availableModules: Set(MWModule.allCases),
                        availableTempChannels: [],
                        supportedKinds: Self.groupLoggableKinds,
                        isLocked: false
                    )
                    startSection(now: timeline.date)
                }
            }
        }
        .navigationTitle("Group Logging")
        .task {
            if scanVM == nil { scanVM = ScannerViewModel(scanner: appStore.scanner) }
            scanVM?.startScan()
            appStore.refreshPendingLogSessions()
        }
        // Centered alert, not a confirmation dialog — dialogs anchor as
        // popovers in regular width and "pop up anywhere on the page"
        // (owner feedback); the app's convention is centered alerts for
        // every confirm.
        .alert(
            "Stop logging on all boards and download their data?",
            isPresented: $showStopConfirm
        ) {
            Button("Stop & Download All") {
                let members = activeGroupMembers
                Task { await appStore.groupCapture.stopAndDownloadAll(members: members) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each board is collected in turn. Boards that are out of range are skipped — their data stays on the board for later.")
        }
    }

    // MARK: - Sections

    /// Per-board walk progress for the pass that is running (or just ran).
    @ViewBuilder
    private func progressSection(coordinator: GroupCaptureCoordinator) -> some View {
        Section {
            ForEach(coordinator.boards) { board in
                HStack(spacing: 12) {
                    phaseIcon(board.phase)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(board.name)
                            .font(.body.weight(.medium))
                        Text(phaseText(board.phase))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if case .downloading = board.phase,
                       let download = coordinator.activeDownload,
                       case .downloading(let progress, _, _) = download.phase {
                        Text(progress, format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // A failed download keeps the board's data — offer the retry
            // right where the failure is shown. Rebuilds members from the
            // failed rows (device handles resolve demo-fleet-first).
            let failed = coordinator.boards.filter {
                if case .failed = $0.phase { return true }
                return false
            }
            // The whole point of collecting: the saved sessions. Surface
            // the way to them right where the results are shown — the
            // files live in Session History (per-board sections, CSV
            // share from each session).
            let savedAny = coordinator.boards.contains {
                if case .saved = $0.phase { return true }
                if case .savedWithIssues = $0.phase { return true }
                return false
            }
            if !coordinator.isBusy, savedAny {
                NavigationLink(value: DeviceFeaturePane.sessionHistory) {
                    Label("View Saved Sessions", systemImage: "clock.arrow.circlepath")
                }
            }
            if !coordinator.isBusy, coordinator.lastPass == .collect, !failed.isEmpty {
                Button {
                    let members = failed.map {
                        GroupCaptureCoordinator.Member(
                            device: resolveDevice(for: $0.id),
                            name: $0.name
                        )
                    }
                    Task { await appStore.groupCapture.stopAndDownloadAll(members: members) }
                } label: {
                    Label("Retry Failed Download\(failed.count == 1 ? "" : "s")",
                          systemImage: "arrow.clockwise")
                }
            }
        } header: {
            Text(coordinator.isBusy ? "Working…" : "Last Run")
        } footer: {
            if !coordinator.isBusy {
                Text("Skipped boards keep their data — collect them here later, or connect to one directly and use its Logging screen.")
            }
        }
    }

    /// The fleet is recording — show who, since when, and the collect button.
    @ViewBuilder
    private func activeGroupSection(records: [LogSessionRecord]) -> some View {
        let anyRunning = records.contains { $0.status == .running }
        return Section {
            ForEach(groupedByBoard(records), id: \.0) { deviceID, boardRecords in
                let isRunning = boardRecords.contains { $0.status == .running }
                HStack {
                    Image(systemName: isRunning ? "record.circle.fill" : "pause.circle.fill")
                        .foregroundStyle(isRunning ? Palette.danger : Palette.warning)
                        .symbolEffect(.pulse, options: .repeating, isActive: isRunning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(displayName(for: deviceID))
                            .font(.body.weight(.medium))
                        Text(isRunning
                             ? "\(boardRecords.count) sensor\(boardRecords.count == 1 ? "" : "s") · since \(boardRecords.map(\.startDate).min() ?? .now, format: .dateTime.hour().minute())"
                             : "Stopped — awaiting download")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Button {
                showStopConfirm = true
            } label: {
                Label(anyRunning ? "Stop & Download All" : "Download All",
                      systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(appStore.groupCapture.isBusy)
        } header: {
            Text(anyRunning ? "Logging In Progress" : "Ready To Collect")
        } footer: {
            Text("The boards record on their own — you can close the app or leave. Come back here to collect everything at once.")
        }
    }

    @ViewBuilder
    private func boardPickerSection(now: Date) -> some View {
        Section {
            let candidates = candidates(now: now)
            if candidates.isEmpty {
                Text("No boards available — bring them in range, or remember them by connecting once.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(candidates, id: \.device.identifier) { candidate in
                    Button {
                        toggle(candidate.device.identifier)
                    } label: {
                        HStack {
                            Image(systemName: selectedIDs.contains(candidate.device.identifier)
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(candidate.device.identifier)
                                                 ? Palette.accent : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.name)
                                    .foregroundStyle(.primary)
                                Text(candidate.detail)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if appStore.hasPendingLog(forPeripheral: candidate.device.identifier) {
                                    Text("Has a session waiting — download it first")
                                        .font(.caption)
                                        .foregroundStyle(Palette.warning)
                                }
                                let isOffAir = DemoMode.name(for: candidate.device.identifier) == nil
                                    && !DeviceFreshness.isFresh(
                                        lastSeen: appStore.scanner.advertisementLastSeen[candidate.device.identifier],
                                        now: now
                                    )
                                if isOffAir {
                                    Text("Not seen nearby — starting may wait up to 15 s")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if let rssi = candidate.rssi {
                                RSSIPill(dBm: rssi)
                            }
                        }
                        // Row taps must span the whole cell, not just the
                        // rendered text (same trap as the activity tiles).
                        .contentShape(.rect)
                    }
                    // Plain style, or the Form button tints the label and
                    // the name renders brand-orange: hierarchical .primary
                    // resolves against the button's tint, not label black.
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Text("Boards")
        } footer: {
            Text("Every selected board records the same sensors. Boards are set up one at a time and keep logging on their own — no connection needed while they record.")
        }
    }

    /// Members, footer count, and enablement all derive from ONE live
    /// computation — a board that went off-air after being checked must
    /// not be silently dropped while the footer still counts it.
    private func startSection(now: Date) -> some View {
        let members = selectedMembers(now: now)
        return Section {
            Button {
                Task {
                    await appStore.groupCapture.startAll(members: members, selections: selections)
                }
            } label: {
                Label("Start Logging All", systemImage: "record.circle.fill")
                    .font(.body.weight(.semibold))
            }
            .disabled(members.isEmpty || selections.isEmpty || appStore.groupCapture.isBusy)
        } footer: {
            Text(members.isEmpty
                 ? "Select at least one board above."
                 : "\(members.count) board\(members.count == 1 ? "" : "s") will start logging.")
        }
    }

    // MARK: - Candidates & members

    private struct Candidate {
        let device: MetaWearDevice
        let name: String
        /// Live signal when the board is on air; nil for off-air and demo.
        let rssi: Int?
        /// The distinguishing identity line: MAC when known (remembered
        /// record or MAC-broadcast advertisement), else the iOS peripheral
        /// identifier — a screen full of boards named "MetaWear" is
        /// unpickable without one or the other.
        let detail: String
    }

    /// Boards eligible for a group: remembered boards (connectable by known
    /// identifier even when off-air), freshly advertising nearby boards,
    /// and the demo fleet. Deduped by peripheral UUID.
    private func candidates(now: Date) -> [Candidate] {
        var seen = Set<UUID>()
        var result: [Candidate] = []

        for remembered in appStore.rememberedDevices {
            let localID = appStore.localPeripheralUUID(for: remembered)
            guard seen.insert(localID).inserted else { continue }
            let device = appStore.scanner.device(forKnownIdentifier: localID)
            let isFresh = DeviceFreshness.isFresh(
                lastSeen: appStore.scanner.advertisementLastSeen[localID], now: now
            )
            result.append(Candidate(
                device: device,
                name: remembered.name ?? "MetaWear",
                // The scanner's RSSI map freezes when a board goes off air —
                // only surface it while the advertisement is fresh.
                rssi: isFresh ? appStore.scanner.advertisementRSSI[localID] : nil,
                detail: remembered.macAddress
                    ?? appStore.scanner.advertisedMACs[localID]
                    ?? localID.uuidString
            ))
        }
        for device in scanVM?.devices ?? [] {
            guard DeviceFreshness.isFresh(
                lastSeen: appStore.scanner.advertisementLastSeen[device.identifier], now: now
            ) else { continue }
            guard seen.insert(device.identifier).inserted else { continue }
            let name = scanVM?.advertisedName(for: device.identifier) ?? "MetaWear"
            result.append(Candidate(
                device: device,
                name: name,
                rssi: appStore.scanner.advertisementRSSI[device.identifier],
                detail: appStore.scanner.advertisedMACs[device.identifier]
                    ?? device.identifier.uuidString
            ))
        }
        if DemoMode.isEnabled {
            for demo in appStore.demoDevices {
                guard seen.insert(demo.identifier).inserted else { continue }
                result.append(Candidate(
                    device: demo,
                    name: DemoMode.name(for: demo.identifier) ?? DemoMode.deviceName,
                    rssi: nil,
                    detail: DemoMode.macAddress(for: demo.identifier) ?? demo.identifier.uuidString
                ))
            }
        }
        return result
    }

    private func selectedMembers(now: Date) -> [GroupCaptureCoordinator.Member] {
        candidates(now: now)
            .filter { selectedIDs.contains($0.device.identifier) }
            .map { GroupCaptureCoordinator.Member(device: $0.device, name: $0.name) }
    }

    // MARK: - Active group

    /// Pending group-tagged records — the durable "a fleet is recording"
    /// signal. Survives app restarts (they're SwiftData rows), so this
    /// screen recovers the fleet even after a force-quit.
    private var activeGroupRecords: [LogSessionRecord] {
        appStore.pendingLogSessions.filter { $0.groupID != nil }
    }

    /// Members for the collect pass, resolved from the active records —
    /// names come from live sources (remembered/advertised/demo) since
    /// pending records don't carry one.
    private var activeGroupMembers: [GroupCaptureCoordinator.Member] {
        groupedByBoard(activeGroupRecords).map { deviceID, _ in
            GroupCaptureCoordinator.Member(
                device: resolveDevice(for: deviceID),
                name: displayName(for: deviceID)
            )
        }
    }

    /// Demo boards live ONLY in `AppStore.demoDevices` — the scanner knows
    /// nothing about them, and `device(forKnownIdentifier:)` would mint a
    /// CoreBluetooth-backed twin that can never connect in the simulator.
    /// Route demo IDs to the fleet first, everything else to the scanner.
    private func resolveDevice(for deviceID: UUID) -> MetaWearDevice {
        if let demo = appStore.demoDevices.first(where: { $0.identifier == deviceID }) {
            return demo
        }
        return appStore.scanner.device(forKnownIdentifier: deviceID)
    }

    private func groupedByBoard(_ records: [LogSessionRecord]) -> [(UUID, [LogSessionRecord])] {
        Dictionary(grouping: records, by: \.deviceID)
            .sorted { ($0.value.first?.startDate ?? .distantPast) < ($1.value.first?.startDate ?? .distantPast) }
            .map { ($0.key, $0.value) }
    }

    private func displayName(for deviceID: UUID) -> String {
        if let demoName = DemoMode.name(for: deviceID) { return demoName }
        if let advertised = appStore.scanner.advertisedNames[deviceID], !advertised.isEmpty {
            return advertised
        }
        if let remembered = appStore.rememberedDevices.first(where: {
            $0.peripheralUUID == deviceID || appStore.localPeripheralUUID(for: $0) == deviceID
        })?.name, !remembered.isEmpty {
            return remembered
        }
        return "MetaWear"
    }

    private func toggle(_ id: UUID) {
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    // MARK: - Phase rendering

    @ViewBuilder
    private func phaseIcon(_ phase: GroupCaptureCoordinator.BoardPhase) -> some View {
        switch phase {
        case .pending:
            Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .connecting, .starting, .verifying, .stopping, .downloading:
            ProgressView().controlSize(.small)
        case .logging:
            Image(systemName: "record.circle.fill").foregroundStyle(Palette.danger)
        case .saved:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
        case .savedWithIssues:
            Image(systemName: "checkmark.circle.trianglebadge.exclamationmark")
                .foregroundStyle(Palette.warning)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(Palette.warning)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.danger)
        }
    }

    private func phaseText(_ phase: GroupCaptureCoordinator.BoardPhase) -> String {
        switch phase {
        case .pending:              return "Waiting…"
        case .connecting:           return "Connecting…"
        case .starting:             return "Starting loggers…"
        case .verifying:            return "Confirming data is recording… (up to a minute after a clear)"
        case .logging:              return "Logging"
        case .stopping:             return "Stopping…"
        case .downloading:          return "Downloading…"
        case .saved(let count):     return "Saved \(count) session\(count == 1 ? "" : "s")"
        case .savedWithIssues(let count, let warning):
            return "Saved \(count) session\(count == 1 ? "" : "s") · \(warning)"
        case .skipped(let reason):  return reason
        case .failed(let message):  return message
        }
    }

    /// Group logging offers the natively-loggable sensor families. Polled
    /// sensors (temperature / humidity) are excluded for now: their
    /// board-side timer handles would need per-board bookkeeping in the
    /// group flow, and the headline use case is IMU fleets.
    private static let groupLoggableKinds: Set<SensorKey.Kind> = {
        var kinds = Set(SensorKey.Kind.allCases)
        kinds.remove(.temperature)
        kinds.remove(.humidity)
        return kinds
    }()
}
