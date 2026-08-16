import SwiftUI
import MetaWear
import CoreBluetooth

struct ScanView: View {
    @Environment(AppStore.self) private var appStore
    @Binding var selectedDeviceID: UUID?
    /// Asks the parent split view to focus the detail column. Called on every
    /// successful tap, including re-taps of the already-active device — in
    /// that case `AppStore.connect` early-returns, so without this signal the
    /// detail column never re-appears in compact width.
    let showDetail: () -> Void
    @State private var viewModel: ScannerViewModel?

    /// Which MetaBoot device (if any) the user has tapped, driving the
    /// firmware-update sheet. `.sheet(item:)` presents/dismisses as this
    /// becomes non-nil / nil.
    @State private var metaBootUpdateTarget: MetaBootAdvertisement?

    private var pinnedID: UUID? {
        appStore.rememberedDevices.first?.peripheralUUID
    }

    var body: some View {
        // Staleness must become visible even when NOTHING changes: a board
        // that powers off or connects elsewhere stops advertising, and silence
        // triggers no observation updates — without a clock, its last-seen
        // state (row present, RSSI frozen) would linger indefinitely. The
        // 1 s timeline re-evaluates freshness so silent boards drop out.
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            content(now: timeline.date)
        }
        .navigationTitle(viewModel?.isMetaBootMode == true ? "MetaBoot" : "MetaWear")
        // Brand the scan column the way the original app did: a flat,
        // full-bleed brand orange (the old connect screen was solid #FE9500
        // with white chrome — no gradient, no motion). Hide the List's
        // opaque background so the orange shows through; the rows keep
        // their own glass material for contrast. (The RootView-level
        // background sits behind the split view, but the sidebar column
        // composites its own background above it, so it must be applied
        // here too.)
        .scrollContentBackground(.hidden)
        .background {
            BrandScanBackground()
        }
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
            // MetaBoot mode toggle. Sits next to the Scan/Stop button so
            // "toggle MetaBoot scanning on/off just like regular scanning"
            // maps to the exact same toolbar affordance. Wrench icon is
            // consistent with the row treatment (this is a rescue flow),
            // and swaps to `checkmark.circle.fill` when active so the
            // ON state is legible at a glance.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel?.toggleMetaBootMode()
                } label: {
                    Label(
                        viewModel?.isMetaBootMode == true ? "Exit MetaBoot" : "MetaBoot",
                        systemImage: viewModel?.isMetaBootMode == true
                            ? "checkmark.circle.fill"
                            : "wrench.and.screwdriver"
                    )
                }
                .tint(viewModel?.isMetaBootMode == true ? Palette.warning : nil)
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Group logging — log on several boards at once, MetaBase
                // style. Badged red while a fleet is recording so the way
                // back to Stop & Download stays discoverable. VALUE-based
                // push, deliberately: a screen presented via an
                // isPresented destination can't resolve value links tapped
                // inside it (the path doesn't contain the screen), which
                // silently broke "View Saved Sessions" on the group page.
                NavigationLink(value: DeviceFeaturePane.groupLogging) {
                    Label("Group Logging", systemImage: "square.stack.3d.down.right")
                }
                .tint(hasActiveGroup ? Palette.danger : nil)
            }
        }
        .task {
            if viewModel == nil {
                viewModel = ScannerViewModel(scanner: appStore.scanner)
            }
            viewModel?.startScan()
        }
        .onDisappear { viewModel?.stopScan() }
        .sheet(item: $metaBootUpdateTarget, onDismiss: {
            // Rebuild the bootloader list from a fresh scan. A successfully
            // flashed board has rebooted into application mode, but its
            // stale MetaBoot entry would otherwise linger — same UUID, still
            // advertising, so the freshness window never culls it.
            viewModel?.refreshMetaBootScan()
        }) { advertisement in
            MetaBootUpdateView(advertisement: advertisement)
        }
    }

    /// Section header in white — the original app set all its chrome in
    /// white on the solid orange, and the default gray reads muddy on it.
    private func brandHeader(_ title: String) -> some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if viewModel?.isMetaBootMode == true {
            metaBootContent()
        } else {
            normalContent(now: now)
        }
    }

    // MARK: - MetaBoot-mode list
    //
    // Mode-switch semantics: when the toggle is on, the whole scan list
    // becomes the bootloader-mode list. Remembered / Nearby / Demo don't
    // appear (they'd be empty and misleading) — leaving only the bootloader
    // devices makes it visually obvious the app is in a different mode.
    private func metaBootContent() -> some View {
        List {
            Section(header: brandHeader("Bootloader Mode")) {
                Text("Boards currently in Nordic DFU / MetaBoot mode. Tap to flash the latest firmware.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                let devices = viewModel?.metaBootDevices ?? []
                if appStore.scanner.isBluetoothUnavailable {
                    Label {
                        Text(bluetoothUnavailableMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(Palette.warning)
                    }
                } else if devices.isEmpty {
                    Text(viewModel?.isScanning == true
                         ? "Scanning for bootloader-mode boards…"
                         : "Tap Scan to look for boards in bootloader mode.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(devices) { advertisement in
                        MetaBootDeviceRow(
                            advertisement: advertisement,
                            onTap: { metaBootUpdateTarget = advertisement }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Normal list

    private func normalContent(now: Date) -> some View {
        List {
            Section(header: brandHeader("Remembered")) {
                if appStore.rememberedDevices.isEmpty {
                    Text("No remembered devices yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    // Keyed by SwiftData identity, not peripheralUUID: CloudKit
                    // sync resets can transiently duplicate rows (same UUID),
                    // and duplicate ForEach IDs are undefined behavior. The
                    // dedupe sweep in refreshRememberedDevices folds them, but
                    // rendering must stay safe in the window before it runs.
                    ForEach(appStore.rememberedDevices, id: \.persistentModelID) { device in
                        // Resolve to THIS host's peripheral UUID (by MAC) so a
                        // record synced from another Apple device still gets
                        // live status/pending-log info once the board has been
                        // connected here.
                        let localID = appStore.localPeripheralUUID(for: device)
                        RememberedDeviceRow(
                            remembered: device,
                            isPinned: device.peripheralUUID == pinnedID,
                            hasPendingLog: appStore.hasPendingLog(forPeripheral: localID),
                            status: status(for: localID, now: now),
                            onTap: { Task { await connect(to: device) } },
                            onForget: { appStore.forget(device) }
                        )
                    }
                }
            }

            Section(header: brandHeader("Nearby")) {
                // A discovered peripheral is "nearby" only if it's actually
                // ON AIR — an advertisement within the freshness window; the
                // scanner's discovery cache is append-only, so without this a
                // powered-off or connected-elsewhere board would keep showing
                // as connectable with a frozen RSSI — and no remembered record
                // claims it, either directly by UUID or through the host-local
                // MAC mapping (a board remembered on another Apple device,
                // already connected once here).
                let nearby = (viewModel?.devices ?? []).filter { d in
                    DeviceFreshness.isFresh(
                        lastSeen: appStore.scanner.advertisementLastSeen[d.identifier],
                        now: now
                    )
                    && !appStore.rememberedDevices.contains {
                        $0.peripheralUUID == d.identifier
                            || appStore.localPeripheralUUID(for: $0) == d.identifier
                    }
                }
                if appStore.scanner.isBluetoothUnavailable {
                    // Without this, Bluetooth-off shows an eternal "Scanning…".
                    Label {
                        Text(bluetoothUnavailableMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(Palette.warning)
                    }
                } else if nearby.isEmpty {
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

            if DemoMode.isEnabled {
                Section(header: brandHeader("Demo")) {
                    // The whole simulated fleet — several boards so
                    // multi-board flows are exercisable without hardware.
                    ForEach(appStore.demoDevices, id: \.identifier) { demo in
                        Button {
                            Task { await connect(to: demo) }
                        } label: {
                            HStack {
                                Label {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(DemoMode.name(for: demo.identifier) ?? DemoMode.deviceName)
                                            .foregroundStyle(.primary)
                                        Text("Synthetic sensors — no hardware needed")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: "sparkles")
                                        .foregroundStyle(Palette.accent)
                                }
                                Spacer()
                                if appStore.connectingDeviceID == demo.identifier {
                                    ProgressView()
                                }
                            }
                        }
                        .accessibilityHint("Connects to a simulated MetaWear with synthetic sensor data")
                    }
                }
            }

            Section {
                NavigationLink(value: DeviceFeaturePane.sessionHistory) {
                    Label("Session History", systemImage: "clock.arrow.circlepath")
                }
            }
        }
    }

    /// True while any pending session carries a group tag — a fleet is
    /// recording (or awaiting collection).
    private var hasActiveGroup: Bool {
        appStore.pendingLogSessions.contains { $0.groupID != nil }
    }

    private func status(for uuid: UUID, now: Date) -> DeviceConnectionStatus {
        if appStore.activeDeviceID == uuid,
           appStore.connectionState != .disconnected,
           appStore.connectingDeviceID != uuid {
            return .connected(rssi: appStore.connectedRSSI)
        }
        if appStore.connectingDeviceID == uuid {
            return .connecting
        }
        if DeviceFreshness.isFresh(
            lastSeen: appStore.scanner.advertisementLastSeen[uuid], now: now
        ) {
            return .available(rssi: appStore.scanner.advertisementRSSI[uuid])
        }
        return .offline
    }

    private func connect(to remembered: RememberedDevice) async {
        // Resolve through the host-local MAC mapping: a record created on
        // another Apple device carries that host's peripheral UUID, which
        // CoreBluetooth here can't connect to.
        let localID = appStore.localPeripheralUUID(for: remembered)
        let device = appStore.scanner.device(forKnownIdentifier: localID)
        await appStore.connect(to: device)
        selectedDeviceID = device.identifier
        showDetail()
    }

    private func connect(to device: MetaWearDevice) async {
        await appStore.connect(to: device)
        selectedDeviceID = device.identifier
        showDetail()
    }

    /// One actionable sentence per unavailability cause.
    private var bluetoothUnavailableMessage: String {
        switch appStore.scanner.bluetoothState {
        case .unauthorized:
            return "Bluetooth access is denied — allow it for MetaWear in Settings."
        case .unsupported:
            return "Bluetooth isn't available on this device."
        default:
            return "Bluetooth is turned off — turn it on in Settings or Control Center to scan."
        }
    }
}
