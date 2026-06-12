import SwiftUI
import MetaWear

struct DeviceDetailView: View {
    @Environment(AppStore.self) private var appStore
    @Binding var path: NavigationPath
    @State private var viewModel: DeviceViewModel?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let viewModel {
                    headerCard(viewModel)
                    activityGrid
                } else {
                    ProgressView()
                }
            }
            .padding()
        }
        .navigationTitle(appStore.scanner.advertisedNames[appStore.activeDeviceID ?? UUID()] ?? "Device")
        .toolbar {
            if let viewModel {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Identify", systemImage: "lightbulb") {
                        Task { await viewModel.identify() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Disconnect", systemImage: "xmark.circle", role: .destructive) {
                        Task { await viewModel.disconnect() }
                    }
                }
            }
        }
        // Key the task to the active device ID so it re-runs on every
        // connect cycle. Without this, SwiftUI may keep the previous
        // `@State viewModel` alive across a disconnect → reconnect (since
        // the parent `if appStore.activeDevice != nil { DeviceDetailView }`
        // can be re-identified rather than torn down), and we'd never
        // re-read the MAC, battery, or device info on the second connect.
        .task(id: appStore.activeDeviceID) {
            guard let device = appStore.activeDevice else {
                viewModel = nil
                return
            }
            let vm = DeviceViewModel(device: device, appStore: appStore)
            viewModel = vm
            await vm.refreshAfterConnect()
        }
    }

    /// True when any pending log session for the active device is
    /// `.running`. Drives the StatePill into its red "Logging" state so
    /// the user can see at a glance that the board is recording — without
    /// stacking a second status pill above the navigation bar.
    private var isDeviceLogging: Bool {
        guard let id = appStore.activeDeviceID else { return false }
        return appStore.pendingLogSessions.contains {
            $0.deviceID == id && $0.status == .running
        }
    }

    @ViewBuilder
    private func headerCard(_ vm: DeviceViewModel) -> some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(vm.macAddress ?? "—")
                        .font(.title3.weight(.semibold).monospaced())
                    Spacer()
                    StatePill(state: appStore.connectionState,
                              isLogging: isDeviceLogging)
                }
                HStack(spacing: 8) {
                    BatteryPill(battery: vm.battery)
                    if let info = vm.deviceInfo {
                        Text(info.model.name)
                            .font(.metricCaption)
                            .foregroundStyle(Palette.accent)
                            .glassPill()
                        Text("fw \(info.firmwareRevision)")
                            .font(.metricCaption.monospaced())
                            .foregroundStyle(.secondary)
                            .glassPill()
                    }
                }
            }
            .glassCard()
        }
    }

    private var activityGrid: some View {
        LazyVGrid(columns: [.init(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            activityTile("Live Stream", systemImage: "chart.line.uptrend.xyaxis", tint: Palette.info, pane: .sensorConfig)
            activityTile("Logging", systemImage: "record.circle", tint: Palette.accent, pane: .logSession)
            activityTile("Controls", systemImage: "slider.horizontal.3", tint: Palette.success, pane: .controls)
            activityTile("Device Info", systemImage: "info.circle", tint: Palette.info, pane: .deviceInfo)
            activityTile("Settings", systemImage: "gearshape", tint: Palette.warning, pane: .settings)
            activityTile("Session History", systemImage: "clock.arrow.circlepath", tint: Palette.accent, pane: .sessionHistory)
        }
    }

    private func activityTile(_ title: String, systemImage: String, tint: Color, pane: DeviceFeaturePane) -> some View {
        Button {
            path.append(pane)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title)
                    .foregroundStyle(tint)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.headline)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .glassCard()
            // Without this, `.buttonStyle(.plain)` only registers taps on the
            // rendered icon + text. The trailing Spacer and the glass card's
            // padding are layout-only, so half the visible tile is dead.
            .contentShape(.rect(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
