import SwiftUI
import SwiftData
import MetaWear

struct DeviceSettingsView: View {
    @Environment(AppStore.self) private var appStore
    @State private var viewModel: DeviceViewModel?
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
