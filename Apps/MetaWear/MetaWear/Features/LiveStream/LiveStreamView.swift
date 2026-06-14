import SwiftUI
import MetaWear

struct LiveStreamView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let selections: [SensorSelection]
    @State private var viewModel: StreamSessionViewModel?
    /// Drives the export sheet via `.sheet(item:)` so the presented content
    /// is bound to the result that was just produced — avoids the stale-state
    /// timing where `.sheet(isPresented:)` captures an old `exportItems`.
    @State private var exportResult: ExportResult?
    @State private var exportError: AppError?
    @State private var isExporting = false

    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        ScrollView {
            VStack(spacing: isCompact ? 8 : 12) {
                if let viewModel, let startedAt = viewModel.startedAt {
                    SessionStatsBar(startedAt: startedAt, totalSamples: viewModel.totalSamples)
                }
                GlassEffectContainer {
                    if let viewModel {
                        ForEach(viewModel.channels) { channel in
                            if case .sensorFusion(.quaternion) = channel.id {
                                QuaternionRealityView(latest: channel.latest)
                            }
                            SensorChartView(
                                title: chartTitle(for: channel.id),
                                systemImage: chartIcon(for: channel.id),
                                samples: channel.displayBuffer,
                                latest: channel.latest,
                                effectiveHz: channel.effectiveHz,
                                axisStyle: channel.selection.axisStyle
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, isCompact ? 8 : 16)
            .padding(.vertical, isCompact ? 8 : 16)
        }
        .navigationTitle("Live Stream")
        .toolbar {
            if let viewModel {
                ToolbarItem(placement: .topBarTrailing) {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Export", systemImage: "square.and.arrow.up") {
                            exportBuffer()
                        }
                        .buttonStyle(.glass)
                        .disabled(viewModel.channels.allSatisfy { $0.ring.elements.isEmpty })
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(
                        viewModel.isPaused ? "Resume" : "Pause",
                        systemImage: viewModel.isPaused ? "play.fill" : "pause.fill"
                    ) {
                        viewModel.togglePause()
                    }
                    .buttonStyle(.glass)
                    .disabled(viewModel.isTogglingPause || !viewModel.isStreaming)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) {
                        Task { await viewModel.stop() }
                    }
                    .buttonStyle(.glass)
                    .tint(Palette.danger)
                    .disabled(!viewModel.isStreaming)
                }
            }
        }
        .sheet(item: $exportResult) { result in
            ExportSheet(items: result.items)
        }
        .alert(item: Binding(
            get: { viewModel?.lastError },
            set: { viewModel?.lastError = $0 }
        )) { err in
            Alert(title: Text("Live stream failed"),
                  message: Text(err.message),
                  dismissButton: .default(Text("OK")))
        }
        .alert(item: $exportError) { err in
            Alert(title: Text("Export failed"),
                  message: Text(err.message),
                  dismissButton: .default(Text("OK")))
        }
        .task {
            guard let device = appStore.activeDevice else { return }
            if viewModel == nil {
                let vm = StreamSessionViewModel(device: device, persistence: appStore.persistence)
                viewModel = vm
                await vm.start(selections)
            }
        }
        .onDisappear {
            // Archive the buffered samples to Session History before tearing
            // the BLE streams down. Order matters: stop() clears `selections`
            // and ring buffers persist on Channel, but archiving while we
            // still have channels alive keeps the logic simple.
            Task { [viewModel] in
                await viewModel?.archiveToHistory()
                await viewModel?.stop()
            }
        }
    }

    private func chartTitle(for key: SensorKey) -> String {
        SensorSelection(id: key, hz: 0).displayName
    }

    private func chartIcon(for key: SensorKey) -> String {
        SensorSelection(id: key, hz: 0).systemImage
    }

    private func exportBuffer() {
        guard let viewModel else { return }
        let deviceName = appStore.scanner.advertisedNames[appStore.activeDeviceID ?? UUID()] ?? "MetaWear"
        // Snapshot the rings on the main actor (Channels are @MainActor),
        // then write the CSVs off the main thread so the UI stays responsive
        // even if there are many channels or large buffers.
        let snapshots = viewModel.channels.map { channel in
            LiveBufferCSVExporter.ChannelSnapshot(
                key: channel.id,
                displayName: channel.selection.displayName,
                channelLabels: channel.id.axisStyle.channels.map(\.id),
                samples: channel.ring.elements
            )
        }
        isExporting = true
        Task {
            do {
                let items = try await LiveBufferCSVExporter.writeAsync(snapshots: snapshots, deviceName: deviceName)
                isExporting = false
                exportResult = ExportResult(items: items)
            } catch {
                isExporting = false
                exportError = AppError(error: error)
            }
        }
    }
}
