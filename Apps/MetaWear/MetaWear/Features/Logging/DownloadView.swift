import SwiftUI
import MetaWear
import MetaWearPersistence

struct DownloadView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewModel: DownloadViewModel?
    /// Built once the download reaches `.ready` so the rows that show the
    /// finished snapshots can also offer a ShareLink without a second tap
    /// or a follow-up sheet.
    @State private var exportItems: [UUID: URL] = [:]

    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        ScrollView {
            VStack(spacing: isCompact ? 8 : 12) {
                if let viewModel {
                    switch viewModel.phase {
                    case .idle:
                        ContentUnavailableView("No download yet", systemImage: "arrow.down.circle")
                    case .downloading(let progress, let downloaded, let total):
                        progressView(progress: progress, downloaded: downloaded, total: total)
                    case .ready(let snapshots):
                        readyView(snapshots: snapshots)
                    case .failed(let message):
                        ContentUnavailableView("Download failed",
                                               systemImage: "exclamationmark.triangle",
                                               description: Text(message))
                            .foregroundStyle(Palette.danger)
                    }
                } else {
                    ProgressView()
                }
            }
            .padding(.horizontal, isCompact ? 8 : 16)
            .padding(.vertical, isCompact ? 8 : 16)
        }
        .navigationTitle("Download")
        .task {
            guard let device = appStore.activeDevice else { return }
            if viewModel == nil {
                viewModel = DownloadViewModel(
                    device: device,
                    store: appStore.persistence,
                    containers: appStore.containers
                )
            }
            let records = appStore.pendingLogSessions.filter { $0.deviceID == device.identifier }
            await viewModel?.downloadAll(records: records)
            // Sessions are now `.downloaded` — drop them from the global
            // pending list so the StatePill (and remembered-device row
            // "logging waiting" indicator) disappear.
            appStore.refreshPendingLogSessions()
            // Build the CSV temp files up front so each row in the ready
            // view can hand a ShareLink a finished URL — avoids a second
            // tap on an Export CSV button to materialise them.
            if case .ready(let snapshots) = viewModel?.phase {
                await prepareExports(snapshots: snapshots)
            }
        }
    }

    @ViewBuilder
    private func progressView(progress: Double, downloaded: Int, total: Int) -> some View {
        GlassEffectContainer {
            VStack(spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Palette.accent)
                        .symbolEffect(.pulse, options: .repeating)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloading")
                            .font(.headline)
                        Text(countLabel(downloaded: downloaded, total: total))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Palette.accent)
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.metric.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .glassCard()
        }
    }

    /// "123 / 456 entries" once `total` is known; "starting…" until the
    /// SDK's initial yield arrives so the user isn't staring at "0 / 0".
    private func countLabel(downloaded: Int, total: Int) -> String {
        guard total > 0 else { return "Reading log length…" }
        return "\(downloaded) / \(total) entries"
    }

    @ViewBuilder
    private func readyView(snapshots: [MWSessionSnapshot]) -> some View {
        VStack(spacing: isCompact ? 8 : 12) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(Palette.success)
                Text("Download complete")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 4)

            // One glass card per session, matching the per-channel chart
            // card layout in LiveStreamView.
            GlassEffectContainer {
                ForEach(snapshots, id: \.id) { snap in
                    SessionDownloadCard(snapshot: snap, csvURL: exportItems[snap.id])
                }
            }
        }
    }

    private func prepareExports(snapshots: [MWSessionSnapshot]) async {
        var built: [UUID: URL] = [:]
        for snapshot in snapshots {
            if let url = try? await CSVExporter.exportToTempFile(
                store: appStore.persistence,
                snapshot: snapshot
            ) {
                built[snapshot.id] = url
            }
        }
        exportItems = built
    }
}

/// One downloaded-session card — mirrors the icon + title chrome of the
/// `SensorChartView` used in Live Stream so the two screens share a
/// consistent visual language. Includes an inline ShareLink once the CSV
/// temp file has been written; shows a small spinner until then.
private struct SessionDownloadCard: View {
    let snapshot: MWSessionSnapshot
    let csvURL: URL?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: sensorIcon)
                .font(.title2)
                .foregroundStyle(Palette.accent)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.label ?? snapshot.sensorKind.capitalized)
                    .font(.body.weight(.medium))
                Text("\(snapshot.sampleCount) samples · \(snapshot.startDate, format: .dateTime.hour().minute().second())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if let csvURL {
                ShareLink(item: csvURL) {
                    Label("Share CSV", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                        .font(.title3)
                }
                .buttonStyle(.glass)
                .accessibilityLabel("Share CSV for \(snapshot.label ?? snapshot.sensorKind)")
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(12)
        .glassCard()
    }

    /// Pick the SF Symbol that the Live Stream chart cards use for the
    /// matching sensor — keeps the icon vocabulary identical across the
    /// two screens. Falls back to a generic record-circle for snapshots
    /// whose label can't be mapped (older records, edge cases).
    private var sensorIcon: String {
        guard let head = snapshot.label?.components(separatedBy: " · ").first else {
            return "record.circle"
        }
        switch head {
        case "Accelerometer": return "move.3d"
        case "Gyroscope":     return "gyroscope"
        case "Magnetometer":  return "location.north.circle"
        case "Barometer":     return "barometer"
        case "Temperature":   return "thermometer.medium"
        case "Humidity":      return "humidity"
        case "Ambient Light": return "sun.max"
        case "Fusion":        return "cube.transparent"
        default:              return "record.circle"
        }
    }
}
