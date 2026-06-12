import SwiftUI
import MetaWear

struct LogSessionView: View {
    @Environment(AppStore.self) private var appStore
    @State private var viewModel: LogSessionViewModel?
    @State private var selections: [SensorSelection] = [
        SensorSelection(id: .accelerometer, hz: SensorKey.accelerometer.defaultHz, range: 2)
    ]
    @State private var availableModules: Set<MWModule> = []
    @State private var availableTempChannels: [TempChannel] = []
    @State private var showDownload = false

    /// Logging supports every sensor family the SDK can drive. IMU sensors
    /// (accel/gyro/mag) and sensor fusion use the native `MWLoggable` path;
    /// barometer + ambient light log directly via their streamable signals;
    /// temperature + humidity are routed through `MWPolledLogger` (an
    /// on-board timer triggers reads which are then logged).
    private static let loggableKinds: Set<SensorKey.Kind> = Set(SensorKey.Kind.allCases)

    var body: some View {
        Form {
            SensorPickerSection(
                selections: $selections,
                availableModules: availableModules,
                availableTempChannels: availableTempChannels,
                supportedKinds: Self.loggableKinds,
                isLocked: isRunning
            )
            Section {
                HStack {
                    Image(systemName: phaseIcon)
                        .foregroundStyle(phaseColor)
                        .symbolEffect(.pulse, options: .repeating, isActive: isRunning)
                    Text(phaseStatusText)
                        .font(.body.monospacedDigit())
                }
                Text("The board keeps logging even if you close the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if isRunning, let records = viewModel?.activeRecords, !records.isEmpty {
                Section("Active Loggers") {
                    ForEach(records, id: \.id) { record in
                        ActiveLoggerRow(record: record)
                    }
                }
            }
        }
        .navigationTitle("Logging")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                phaseToolbarButton
            }
        }
        .task {
            guard let device = appStore.activeDevice else { return }
            if viewModel == nil {
                viewModel = LogSessionViewModel(device: device, containers: appStore.containers)
            }
            let mods = await device.modules
            availableModules = Set(mods.compactMap { $0.value.isPresent ? $0.key : nil })
            if let tempInfo = mods[.temperature], tempInfo.isPresent {
                availableTempChannels = tempInfo.extra.enumerated().compactMap {
                    TempChannel(index: $0.offset, rawSource: $0.element)
                }
            }
            // If the user navigated away mid-session — or the app was
            // killed entirely and they're reconnecting after the board
            // kept logging on its own — restore the view model from the
            // still-running records so the UI reflects reality (Stop
            // button + ticking elapsed time) instead of showing Start,
            // which would then fail with "already being logged" from
            // the SDK.
            let pending = appStore.pendingLogSessions.filter {
                $0.deviceID == device.identifier && $0.status == .running
            }
            // `restoreFromPending` is guarded against re-firing once
            // phase has moved to `.running`, so we use the phase as the
            // signal for "this is the first restore" — only then do we
            // overwrite `selections`. Subsequent navigations back to
            // this view leave the user's picker untouched.
            let isFirstRestore: Bool = if case .idle = viewModel?.phase ?? .idle { true } else { false }
            viewModel?.restoreFromPending(records: pending)
            if isFirstRestore, !pending.isEmpty {
                // Mirror the running loggers into the (greyed-out)
                // Sensors section so the user can see what's actually
                // being captured — without this, the picker shows the
                // pre-Start default, which is misleading after a
                // crash/disconnect reconnect.
                selections = pending.compactMap {
                    LogSessionViewModel.decode($0.configJSON, kind: $0.sensorKind)
                }
            }
        }
        .navigationDestination(isPresented: $showDownload) {
            DownloadView()
        }
        // Surface viewModel.lastError so a thrown `startLogging` is visible
        // instead of silently leaving the phase at `.idle` (which looks like
        // "the button did nothing").
        .alert(item: Binding(
            get: { viewModel?.lastError },
            set: { viewModel?.lastError = $0 }
        )) { err in
            Alert(title: Text("Logging failed"),
                  message: Text(err.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    private var isRunning: Bool {
        if case .running = viewModel?.phase ?? .idle { return true }
        return false
    }

    private var phaseIcon: String {
        switch viewModel?.phase ?? .idle {
        case .idle:     return "circle"
        case .running:  return "record.circle.fill"
        case .stopped:  return "checkmark.circle.fill"
        }
    }

    private var phaseColor: Color {
        switch viewModel?.phase ?? .idle {
        case .idle:     return .secondary
        case .running:  return Palette.danger
        case .stopped:  return Palette.success
        }
    }

    private var phaseStatusText: String {
        switch viewModel?.phase ?? .idle {
        case .idle:
            return "Idle · tap Start to begin"
        case .running:
            return "Logging · \(viewModel?.elapsedSeconds ?? 0)s"
        case .stopped:
            return "Stopped · \(viewModel?.elapsedSeconds ?? 0)s captured"
        }
    }

    /// Single phase-driven toolbar button — mirrors the Live Stream pattern
    /// of putting the primary action in the top-right corner. The button's
    /// label, symbol, role, and action all switch based on the current
    /// logging phase (idle → start, running → stop, stopped → download).
    @ViewBuilder
    private var phaseToolbarButton: some View {
        switch viewModel?.phase ?? .idle {
        case .idle:
            Button("Start", systemImage: "record.circle.fill") {
                print("[Log] Start tapped — viewModel=\(viewModel != nil) selections=\(selections.count)")
                Task {
                    await viewModel?.start(selections)
                    // Refresh the AppStore's pending-sessions cache so the
                    // global `LoggingPill` becomes visible immediately.
                    appStore.refreshPendingLogSessions()
                }
            }
            .disabled(selections.isEmpty)
            .buttonStyle(.glassProminent)
            .tint(Palette.danger)

        case .running:
            Button("Stop", systemImage: "stop.fill", role: .destructive) {
                Task {
                    await viewModel?.stop()
                    appStore.refreshPendingLogSessions()
                }
            }
            .buttonStyle(.glass)

        case .stopped:
            Button("Download", systemImage: "arrow.down.circle.fill") {
                showDownload = true
            }
            .buttonStyle(.glassProminent)
        }
    }
}

/// One row in the "Active Loggers" section. Decodes the record's
/// `configJSON` back into a `SensorSelection` so we can render the same
/// rich label that the Live Stream / Session History flows use — e.g.
/// "Gyroscope · ±2000 dps · 25 Hz".
private struct ActiveLoggerRow: View {
    let record: LogSessionRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selection?.systemImage ?? "record.circle")
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(selection?.label ?? record.sensorKind.capitalized)
                    .font(.body.weight(.medium))
                Text(record.startDate, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selection: SensorSelection? {
        LogSessionViewModel.decode(record.configJSON, kind: record.sensorKind)
    }
}
