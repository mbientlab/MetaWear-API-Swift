import SwiftUI
import Charts
import MetaWear
import MetaWearPersistence

struct SessionDetailView: View {
    let snapshot: MWSessionSnapshot
    @Environment(AppStore.self) private var appStore
    @State private var preview: [AnyChartSample] = []
    /// Full-resolution samples + board-tick timeline for the 3D replay.
    /// Only populated for quaternion sessions with enough samples to scrub.
    @State private var replaySamples: [AnyChartSample] = []
    @State private var replayTimeline: ReplayTimeline?
    @State private var lastError: AppError?
    @State private var exportResult: ExportResult?

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statsCard
                if let replayTimeline, !replaySamples.isEmpty {
                    SessionReplayView(samples: replaySamples, timeline: replayTimeline)
                }
                if !preview.isEmpty {
                    SensorChartView(
                        title: snapshot.label ?? snapshot.sensorKind.capitalized,
                        systemImage: "chart.line.uptrend.xyaxis",
                        samples: preview,
                        latest: preview.last,
                        effectiveHz: 0,
                        axisStyle: .forSession(
                            sensorKind: snapshot.sensorKind,
                            label: snapshot.label,
                            channelCount: Int(preview.first?.channelCount ?? 1)
                        )
                    )
                }
                Button("Export CSV", systemImage: "square.and.arrow.up") {
                    Task { await prepareExport() }
                }
                .buttonStyle(.glassProminent)
            }
            .padding()
        }
        .navigationTitle(snapshot.label ?? snapshot.sensorKind.capitalized)
        .task {
            await loadPreview()
        }
        .sheet(item: $exportResult) { result in
            ExportSheet(items: result.items)
        }
        .alert(item: $lastError) { err in
            Alert(title: Text("Session failed"),
                  message: Text(err.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(snapshot.sampleCount, format: .number) samples", systemImage: "number")
            Label("\(snapshot.startDate, format: .dateTime.hour().minute().second()) – \(snapshot.endDate, format: .dateTime.hour().minute().second())", systemImage: "clock")
            Label(snapshot.deviceModel, systemImage: "sensor.tag.radiowaves.forward")
            Label(snapshot.deviceFirmware, systemImage: "wrench.and.screwdriver")
        }
        .font(.subheadline)
        .glassCard()
    }

    private func loadPreview() async {
        do {
            switch snapshot.sensorKind {
            case CartesianFloat.persistenceKind:
                let samples = try await appStore.persistence.fetchSamples(sessionID: snapshot.id, as: CartesianFloat.self)
                preview = samples.suffix(600).map(AnyChartSample.from)
            case Quaternion.persistenceKind:
                let samples = try await appStore.persistence.fetchSamples(sessionID: snapshot.id, as: Quaternion.self)
                preview = samples.suffix(600).map(AnyChartSample.from)
                if samples.count >= 2 {
                    replaySamples = samples.map(AnyChartSample.from)
                    replayTimeline = ReplayTimeline(ticksMs: samples.map(\.tickMs))
                }
            case EulerAngles.persistenceKind:
                let samples = try await appStore.persistence.fetchSamples(sessionID: snapshot.id, as: EulerAngles.self)
                preview = samples.suffix(600).map(AnyChartSample.from)
            case CorrectedCartesianFloat.persistenceKind:
                let samples = try await appStore.persistence.fetchSamples(sessionID: snapshot.id, as: CorrectedCartesianFloat.self)
                preview = samples.suffix(600).map(AnyChartSample.from)
            case Float.persistenceKind:
                let samples = try await appStore.persistence.fetchSamples(sessionID: snapshot.id, as: Float.self)
                preview = samples.suffix(600).map(AnyChartSample.from)
            case Bool.persistenceKind:
                let samples = try await appStore.persistence.fetchSamples(sessionID: snapshot.id, as: Bool.self)
                preview = samples.suffix(600).map(AnyChartSample.from)
            default:
                preview = []
            }
        } catch {
            lastError = AppError(error: error)
        }
    }

    private func prepareExport() async {
        do {
            let url = try await CSVExporter.exportToTempFile(store: appStore.persistence, snapshot: snapshot)
            exportResult = ExportResult(items: [ExportSheetItem(url: url, subtitle: "\(snapshot.sampleCount) samples")])
        } catch {
            lastError = AppError(error: error)
        }
    }
}
