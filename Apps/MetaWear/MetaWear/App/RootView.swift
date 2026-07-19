import SwiftUI
import MetaWear

struct RootView: View {
    @Environment(AppStore.self) private var appStore
    @State private var path = NavigationPath()
    @State private var sidebarPath = NavigationPath()
    @State private var selectedDeviceID: UUID?
    @State private var preferredColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredColumn) {
            // Sidebar gets its own NavigationStack so links inside ScanView
            // (e.g. Session History) can push within the sidebar column.
            // Without this, SwiftUI can't resolve `NavigationLink(value:)`
            // against the destination registered on the detail stack —
            // links search only the column they originate from.
            NavigationStack(path: $sidebarPath) {
                ScanView(selectedDeviceID: $selectedDeviceID) {
                    preferredColumn = .detail
                }
                .navigationDestination(for: DeviceFeaturePane.self) { pane in
                    pane.destination()
                }
            }
        } detail: {
            NavigationStack(path: $path) {
                Group {
                    if appStore.activeDevice != nil {
                        DeviceDetailView(path: $path)
                    } else {
                        // No active device: render a blank pane rather
                        // than a "No Device Connected" placeholder. In
                        // compact (iPhone) the `onChange` below has
                        // already moved focus back to the sidebar, so
                        // this is only briefly visible during the
                        // transition. In regular (iPad) the sidebar is
                        // already showing alongside, so the detail just
                        // sits empty rather than nagging the user.
                        Color.clear
                    }
                }
                .navigationDestination(for: DeviceFeaturePane.self) { pane in
                    pane.destination()
                }
            }
        }
        .background {
            GlassBackground()
                .ignoresSafeArea()
        }
        // The dedicated top "Logging" pill used to live here; we removed
        // it in favour of folding that signal into the StatePill in the
        // device header (which now switches to a red "Logging" label
        // whenever a session is `.running`). Single source of truth, less
        // chrome.
        .modifier(ErrorAndOrphanAlerts(
            appStore: appStore, detailPath: $path, preferredColumn: $preferredColumn
        ))
        .onChange(of: appStore.activeDeviceID) { _, newID in
            // Every pane on the detail stack is per-device — a stale entry
            // (e.g. a foreignDownload pushed for the previous board) must
            // not resolve against the next one.
            path = NavigationPath()
            preferredColumn = newID == nil ? .sidebar : .detail
        }
        .overlay {
            if isConnecting {
                ConnectingOverlay(deviceName: connectingDeviceName)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isConnecting)
    }

    /// True only during the BLE handshake — once the device reaches `.idle`
    /// the overlay drops. Driven off both the active state and the
    /// `connectingDeviceID` flag so a late-arriving `idle` state doesn't
    /// leave the scrim visible.
    private var isConnecting: Bool {
        appStore.connectingDeviceID != nil
            && appStore.connectionState == .connecting
    }

    private var connectingDeviceName: String? {
        guard let id = appStore.connectingDeviceID else { return nil }
        return appStore.scanner.advertisedNames[id]
            ?? appStore.rememberedDevices.first(where: { $0.peripheralUUID == id })?.name
    }
}

/// Both alerts the root view needs to present — extracted as a `ViewModifier`
/// so the main `body` stays inside the SwiftUI type-checker's complexity
/// budget (chaining the two `.alert` modifiers inline blew the timeout).
private struct ErrorAndOrphanAlerts: ViewModifier {
    let appStore: AppStore
    /// Detail-column navigation path — the orphan alert's Download button
    /// pushes the standard Download screen (which runs the foreign-session
    /// download with the usual progress + export UI) instead of kicking
    /// off an invisible background task.
    @Binding var detailPath: NavigationPath
    /// On compact width the push is invisible unless the detail column is
    /// frontmost — Download forces it forward before appending.
    @Binding var preferredColumn: NavigationSplitViewColumn

    func body(content: Content) -> some View {
        content
            .alert(item: Binding(
                get: { appStore.lastError },
                set: { appStore.lastError = $0 }
            )) { err in
                Alert(title: Text("Something went wrong"),
                      message: Text(err.message),
                      dismissButton: .default(Text("OK")))
            }
            // Surface any stale on-board log data discovered after connect
            // so the user can decide what to do with it. The alert only
            // fires when LOG_LENGTH > 0 *and* we have no matching local
            // pending session — the in-app logging flow has its own UI
            // for sessions it already knows about (LoggingPill,
            // DownloadView).
            .alert(
                "Logging in progress",
                isPresented: Binding(
                    get: { appStore.orphanLogState != nil },
                    set: { if !$0 { appStore.dismissOrphanLog() } }
                ),
                presenting: appStore.orphanLogState
            ) { state in
                // Each button captures `state` (which SwiftUI hands the
                // closure from `presenting:`) and passes it through.
                // SwiftUI fires the `isPresented` setter on tap, which
                // nils `orphanLogState` *before* the button body runs —
                // without the capture the actions would see a nil state
                // and silently no-op.
                //
                // Declaration order = top-to-bottom in the alert;
                // Download leads because it's the non-destructive
                // recovery path.
                Button("Download") {
                    preferredColumn = .detail
                    detailPath.append(DeviceFeaturePane.foreignDownload(state))
                }
                Button("Not Now", role: .cancel) { appStore.dismissOrphanLog() }
                Button("Discard", role: .destructive) {
                    Task { await appStore.discardOrphanLog(state) }
                }
            } message: { state in
                if state.isActivelyLogging {
                    Text("This board is logging a session started on another device\(state.entryCount > 0 ? " (\(state.entryCount) entries so far)" : ""). Download stops the logging and saves the data. You can also do this later from the Logging screen.")
                } else {
                    Text("This board holds \(state.entryCount) log entries from a session this phone doesn't know about. Download them, or handle it later from the Logging screen.")
                }
            }
    }
}

enum DeviceFeaturePane: Hashable {
    case sensorConfig
    case liveStream([SensorSelection])
    case logSession
    case download
    /// The Download screen in foreign-session mode: drains a board whose
    /// logging was started on another device via the anonymous-logger path.
    case foreignDownload(OrphanLogState)
    case sessionHistory
    case controls
    case deviceInfo
    case settings

    @ViewBuilder
    func destination() -> some View {
        switch self {
        case .sensorConfig:              SensorConfigView()
        case .liveStream(let sels):      LiveStreamView(selections: sels)
        case .logSession:                LogSessionView()
        case .download:                  DownloadView()
        case .foreignDownload(let s):    DownloadView(foreign: s)
        case .sessionHistory:            SessionHistoryView()
        case .controls:                  ControlsView()
        case .deviceInfo:                DeviceInfoView()
        case .settings:                  DeviceSettingsView()
        }
    }
}
