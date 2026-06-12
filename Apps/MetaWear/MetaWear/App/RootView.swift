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
        .modifier(ErrorAndOrphanAlerts(appStore: appStore))
        .onChange(of: appStore.activeDeviceID) { _, newID in
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
                // closure from `presenting:`) and passes it through to
                // the AppStore method. SwiftUI fires the `isPresented`
                // setter on tap, which nils `orphanLogState` *before*
                // the Task here runs — without the capture the methods
                // would see a nil state and silently no-op.
                //
                // Declaration order = top-to-bottom in the alert;
                // Download leads because it's the non-destructive
                // recovery path.
                Button("Download") {
                    Task { await appStore.downloadOrphanLog(state) }
                }
                Button("Keep", role: .cancel) { appStore.dismissOrphanLog() }
                Button("Discard", role: .destructive) {
                    Task { await appStore.discardOrphanLog(state) }
                }
            } message: { state in
                Text("This device has \(state.entryCount) log entries from a previous session. Download them (parsed via the anonymous-logger flow), keep them on the board, or discard?")
            }
            // Result-of-orphan-download alert — only shown for the two
            // terminal phases. Tapping OK resets the phase back to .idle.
            .alert(
                orphanResultTitle,
                isPresented: Binding(
                    get: { appStore.orphanDownloadPhase.isTerminal },
                    set: { if !$0 { appStore.clearOrphanDownloadPhase() } }
                )
            ) {
                Button("OK", role: .cancel) { appStore.clearOrphanDownloadPhase() }
            } message: {
                Text(orphanResultMessage)
            }
    }

    private var orphanResultTitle: String {
        switch appStore.orphanDownloadPhase {
        case .completed: return "Download complete"
        case .failed:    return "Download failed"
        default:         return ""
        }
    }

    private var orphanResultMessage: String {
        switch appStore.orphanDownloadPhase {
        case .completed(let savedCount):
            if savedCount == 0 {
                return "No decodable signals were recovered. The board's log buffer has been cleared."
            }
            return "Saved \(savedCount) session\(savedCount == 1 ? "" : "s") under \"Unknown · …\". Open Session History to view or export them."
        case .failed(let message):
            return message
        default:
            return ""
        }
    }
}

enum DeviceFeaturePane: Hashable {
    case sensorConfig
    case liveStream([SensorSelection])
    case logSession
    case download
    case sessionHistory
    case controls
    case deviceInfo
    case settings

    @ViewBuilder
    func destination() -> some View {
        switch self {
        case .sensorConfig:           SensorConfigView()
        case .liveStream(let sels):   LiveStreamView(selections: sels)
        case .logSession:             LogSessionView()
        case .download:               DownloadView()
        case .sessionHistory:         SessionHistoryView()
        case .controls:               ControlsView()
        case .deviceInfo:             DeviceInfoView()
        case .settings:               DeviceSettingsView()
        }
    }
}
