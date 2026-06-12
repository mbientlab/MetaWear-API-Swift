import SwiftUI
import MetaWear

struct ScanView: View {
    @Environment(AppStore.self) private var appStore
    @Binding var selectedDeviceID: UUID?
    /// Asks the parent split view to focus the detail column. Called on every
    /// successful tap, including re-taps of the already-active device — in
    /// that case `AppStore.connect` early-returns, so without this signal the
    /// detail column never re-appears in compact width.
    let showDetail: () -> Void
    @State private var viewModel: ScannerViewModel?

    private var pinnedID: UUID? {
        appStore.rememberedDevices.first?.peripheralUUID
    }

    var body: some View {
        List {
            Section("Remembered") {
                if appStore.rememberedDevices.isEmpty {
                    Text("No remembered devices yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appStore.rememberedDevices, id: \.peripheralUUID) { device in
                        RememberedDeviceRow(
                            remembered: device,
                            isPinned: device.peripheralUUID == pinnedID,
                            hasPendingLog: appStore.hasPendingLog(forPeripheral: device.peripheralUUID),
                            status: status(for: device.peripheralUUID),
                            onTap: { Task { await connect(to: device) } },
                            onForget: { appStore.forget(device) }
                        )
                    }
                }
            }

            Section("Nearby") {
                let nearby = (viewModel?.devices ?? []).filter { d in
                    !appStore.rememberedDevices.contains { $0.peripheralUUID == d.identifier }
                }
                if nearby.isEmpty {
                    Text(viewModel?.isScanning == true ? "Scanning…" : "Tap Scan to look for devices.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(nearby, id: \.identifier) { device in
                        NearbyDeviceRow(
                            device: device,
                            name: viewModel?.advertisedName(for: device.identifier) ?? "MetaWear",
                            rssi: appStore.scanner.advertisementRSSI[device.identifier],
                            isConnecting: appStore.connectingDeviceID == device.identifier,
                            onTap: { Task { await connect(to: device) } }
                        )
                    }
                }
            }

            Section {
                NavigationLink(value: DeviceFeaturePane.sessionHistory) {
                    Label("Session History", systemImage: "clock.arrow.circlepath")
                }
            }
        }
        .navigationTitle("MetaWear")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel?.toggleScan()
                } label: {
                    Label(
                        viewModel?.isScanning == true ? "Stop Scanning" : "Scan",
                        systemImage: viewModel?.isScanning == true ? "stop.circle" : "antenna.radiowaves.left.and.right"
                    )
                }
            }
        }
        .task {
            if viewModel == nil {
                viewModel = ScannerViewModel(scanner: appStore.scanner)
            }
            viewModel?.startScan()
        }
        .onDisappear { viewModel?.stopScan() }
    }

    /// Window after the last advertisement during which we still consider the
    /// device "available" on air. Advertisements normally arrive several times
    /// per second; 8 s tolerates one missed scan cycle without flicker.
    private static let availableFreshnessWindow: TimeInterval = 8

    private func status(for uuid: UUID) -> DeviceConnectionStatus {
        if appStore.activeDeviceID == uuid,
           appStore.connectionState != .disconnected,
           appStore.connectingDeviceID != uuid {
            return .connected
        }
        if appStore.connectingDeviceID == uuid {
            return .connecting
        }
        let lastSeen = appStore.scanner.advertisementLastSeen[uuid]
        let fresh = lastSeen.map { Date.now.timeIntervalSince($0) < Self.availableFreshnessWindow } ?? false
        if fresh {
            return .available(rssi: appStore.scanner.advertisementRSSI[uuid])
        }
        return .offline
    }

    private func connect(to remembered: RememberedDevice) async {
        let device = appStore.scanner.device(forKnownIdentifier: remembered.peripheralUUID)
        await appStore.connect(to: device)
        selectedDeviceID = device.identifier
        showDetail()
    }

    private func connect(to device: MetaWearDevice) async {
        await appStore.connect(to: device)
        selectedDeviceID = device.identifier
        showDetail()
    }
}
