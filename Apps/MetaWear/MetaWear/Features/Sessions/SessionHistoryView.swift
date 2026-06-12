import SwiftUI
import SwiftData
import MetaWearPersistence

struct SessionHistoryView: View {
    @Environment(AppStore.self) private var appStore
    @State private var snapshots: [MWSessionSnapshot] = []
    @State private var loadError: AppError?

    var body: some View {
        List(snapshots, id: \.id) { snap in
            NavigationLink(value: snap) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(snap.label ?? snap.sensorKind.capitalized)
                        .font(.body.weight(.medium))
                    Text(snap.startDate, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(snap.sampleCount, format: .number) samples")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Session History")
        .navigationDestination(for: MWSessionSnapshot.self) { SessionDetailView(snapshot: $0) }
        .overlay {
            if snapshots.isEmpty {
                ContentUnavailableView("No sessions yet", systemImage: "clock", description: Text("Downloaded log sessions will appear here."))
            }
        }
        .task {
            await reload()
        }
        .refreshable {
            await reload()
        }
    }

    private func reload() async {
        do {
            snapshots = try await appStore.persistence.fetchAllSessions()
        } catch {
            loadError = AppError(error: error)
        }
    }
}
