import SwiftUI
import SwiftData
import MetaWear
import MetaWearFirmware

struct DeviceSettingsView: View {
    @Environment(AppStore.self) private var appStore
    @State private var viewModel: DeviceViewModel?
    @State private var firmware: FirmwareUpdateViewModel?
    @State private var draftName: String = ""
    @State private var showFactoryResetConfirm = false
    @State private var showClearLogsConfirm = false

    /// Latest on-board entry count + active logger count, refreshed on
    /// appear and after a Clear action so the user can see what's about
    /// to be wiped and confirm that the wipe took effect.
    @State private var logEntryCount: UInt32?
    @State private var activeLoggerCount: Int?
    @State private var isClearing = false
    @State private var clearLogError: AppError?

    var body: some View {
        Form {
            Section("Rename") {
                TextField("Device name", text: $draftName)
                    .textInputAutocapitalization(.never)
                Button("Save", systemImage: "checkmark") {
                    Task { await viewModel?.rename(to: draftName) }
                }
                .disabled(draftName.isEmpty)
            }

            if let firmware {
                FirmwareSection(viewModel: firmware)
            }

            Section {
                LabeledContent("Log Entries") {
                    Text(logEntryCount.map { "\($0)" } ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Active Loggers") {
                    Text(activeLoggerCount.map { "\($0)" } ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("Clear Logs & Loggers",
                       systemImage: "trash",
                       role: .destructive) {
                    showClearLogsConfirm = true
                }
                .disabled(isClearing)
            } header: {
                Text("Logging")
            } footer: {
                Text("Stops any active logging, drops every entry from flash, and removes all logger subscriptions. Local pending sessions for this device are also deleted (their backing data on the board is gone).")
            }

            Section {
                Button("Factory Reset", systemImage: "exclamationmark.triangle", role: .destructive) {
                    showFactoryResetConfirm = true
                }
            } footer: {
                Text("Erases all logs, processors, events, macros, and timers on the board, then reboots it.")
            }
        }
        .navigationTitle("Settings")
        .task {
            guard let device = appStore.activeDevice else { return }
            if viewModel == nil {
                viewModel = DeviceViewModel(device: device, appStore: appStore)
                await viewModel?.refreshAfterConnect()
            }
            // Firmware update is a real-hardware operation — it queries
            // MbientLab's catalog and flashes over DFU — so the section is
            // hidden for the simulated Demo Mode board: there's nothing to
            // flash, and the catalog lookup would just error on its synthetic
            // firmware revision.
            if firmware == nil, device.identifier != DemoBLETransport.deviceIdentifier {
                firmware = FirmwareUpdateViewModel(device: device, appStore: appStore)
                await firmware?.loadCurrentVersion()
            }
            await refreshLogStats()
        }
        .confirmationDialog("Factory reset this MetaWear?",
                            isPresented: $showFactoryResetConfirm,
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) {
                Task { await viewModel?.factoryReset() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will erase all on-device state. The board will reboot and disconnect.")
        }
        .confirmationDialog("Clear all log data and loggers?",
                            isPresented: $showClearLogsConfirm,
                            titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                Task { await clearLogs() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let n = logEntryCount, n > 0 {
                Text("\(n) log entries and \(activeLoggerCount ?? 0) logger subscriptions will be removed from the board. This cannot be undone.")
            } else {
                Text("Any logger subscriptions and pending entries will be removed from the board.")
            }
        }
        .alert(item: $clearLogError) { err in
            Alert(title: Text("Clear logs failed"),
                  message: Text(err.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    /// Read `LOG_LENGTH` and enumerate active loggers so the section
    /// reflects what's actually on the board right now. Silently no-ops
    /// if BLE is disconnected; the `—` placeholders stay visible.
    private func refreshLogStats() async {
        guard let device = appStore.activeDevice else { return }
        logEntryCount = try? await device.read(MWLogLength()).value
        activeLoggerCount = (try? await device.queryActiveLoggers())?.count
    }

    /// Wire the destructive Clear action: wipe on-board state via the
    /// SDK, then drop any local `LogSessionRecord` rows for this device
    /// since their backing flash data is now gone.
    private func clearLogs() async {
        guard let device = appStore.activeDevice else { return }
        isClearing = true
        defer { isClearing = false }
        do {
            try await device.clearLog()
            deleteLocalPendingRecords(for: device.identifier)
            appStore.refreshPendingLogSessions()
            await refreshLogStats()
        } catch {
            clearLogError = AppError(error: error)
        }
    }

    private func deleteLocalPendingRecords(for deviceID: UUID) {
        let context = appStore.containers.local.mainContext
        let descriptor = FetchDescriptor<LogSessionRecord>(
            predicate: #Predicate { $0.deviceID == deviceID }
        )
        if let records = try? context.fetch(descriptor) {
            for record in records { context.delete(record) }
            try? context.save()
        }
    }
}

// MARK: - Firmware

/// Settings section that surfaces the board's firmware version, checks
/// MbientLab's catalog for a newer build, and runs an over-the-air DFU update
/// with a live progress readout. All state lives in `FirmwareUpdateViewModel`;
/// this view just maps `phase` onto rows.
private struct FirmwareSection: View {
    let viewModel: FirmwareUpdateViewModel
    @State private var showUpdateConfirm = false

    var body: some View {
        Section {
            LabeledContent("Installed") {
                Text(viewModel.currentVersion ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            content
        } header: {
            Text("Firmware")
        } footer: {
            footer
        }
        .confirmationDialog("Update firmware?",
                            isPresented: $showUpdateConfirm,
                            titleVisibility: .visible) {
            Button("Update") {
                Task { await viewModel.startUpdate() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keep MetaWear open with the board nearby and powered until the update finishes. The board restarts automatically when it's done.")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .unknown:
            Button("Check for Updates", systemImage: "arrow.triangle.2.circlepath") {
                Task { await viewModel.checkForUpdate() }
            }

        case .checking:
            HStack {
                Text("Checking for updates…")
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView().controlSize(.small)
            }

        case .upToDate:
            LabeledContent("Status") {
                Label("Up to date", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            }
            Button("Check Again", systemImage: "arrow.triangle.2.circlepath") {
                Task { await viewModel.checkForUpdate() }
            }

        case .updateAvailable(let build):
            LabeledContent("Latest") {
                Text(build.firmwareRev)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("Update Firmware", systemImage: "square.and.arrow.down") {
                showUpdateConfirm = true
            }

        case .updating(let progress):
            FirmwareProgressView(progress: progress)

        case .completed:
            LabeledContent("Status") {
                Label("Updated", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
            }

        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Button("Try Again", systemImage: "arrow.triangle.2.circlepath") {
                Task { await viewModel.checkForUpdate() }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch viewModel.phase {
        case .updating:
            Text("Updating firmware. Keep the app open with the board nearby and powered — do not disconnect.")
        case .updateAvailable:
            Text("Downloads the latest firmware from MbientLab and installs it over Bluetooth. The board restarts when finished.")
        default:
            EmptyView()
        }
    }
}

/// One row showing the active DFU phase plus a determinate progress bar while
/// firmware bytes are actually transferring (`percentComplete` is only
/// meaningful during `.uploading`; every other phase shows a small spinner).
private struct FirmwareProgressView: View {
    let progress: DFUProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                Spacer()
                if progress.state == .uploading {
                    Text("\(Int(progress.percentComplete))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            if progress.state == .uploading {
                ProgressView(value: progress.percentComplete, total: 100)
            }
        }
        .padding(.vertical, 4)
    }

    private var label: String {
        switch progress.state {
        case .fetchingCatalog:     return "Checking catalog…"
        case .downloadingFirmware: return "Downloading firmware…"
        case .bootloaderHandoff:   return "Preparing device…"
        case .scanning:            return "Locating device…"
        case .connecting:          return "Connecting…"
        case .starting:            return "Starting transfer…"
        case .validating:          return "Validating…"
        case .uploading:           return "Installing…"
        case .disconnecting:       return "Finishing up…"
        case .completed:           return "Complete"
        case .aborted:             return "Aborted"
        }
    }
}
