import SwiftUI
import SwiftData
import MetaWearPersistence

struct SessionHistoryView: View {
    @Environment(AppStore.self) private var appStore
    @State private var snapshots: [MWSessionSnapshot] = []
    @State private var loadError: AppError?

    var body: some View {
        // Sessions grouped by the board that captured them — with several
        // boards logging, a flat list can't attribute rows.
        List {
            ForEach(SessionHistoryGrouping.sections(from: snapshots, macBySerial: macBySerial)) { section in
                Section(section.title) {
                    ForEach(section.sessions, id: \.id) { snap in
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
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                Task { await delete(snap) }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Session History")
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
        .alert(item: $loadError) { err in
            Alert(title: Text("Session History"),
                  message: Text(err.message),
                  dismissButton: .default(Text("OK")))
        }
    }

    /// Serial → MAC translation from the remembered-device records (which
    /// sync both fields). The MAC is the board's identity everywhere else
    /// in the app, so section titles prefer it over the DIS serial.
    private var macBySerial: [String: String] {
        Dictionary(
            appStore.rememberedDevices.compactMap { device in
                guard let serial = device.serialNumber, let mac = device.macAddress else {
                    return nil
                }
                return (serial, mac)
            },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private func reload() async {
        do {
            snapshots = try await appStore.persistence.fetchAllSessions()
        } catch {
            loadError = AppError(error: error)
        }
    }

    /// Standard swipe-to-delete: remove optimistically for instant UI,
    /// then delete from the store (samples cascade). On failure the reload
    /// resurrects the row and the alert explains — the row must never
    /// vanish while the data survives.
    private func delete(_ snapshot: MWSessionSnapshot) async {
        snapshots.removeAll { $0.id == snapshot.id }
        do {
            try await appStore.persistence.deleteSession(id: snapshot.id)
        } catch {
            loadError = AppError(error: error)
            await reload()
        }
    }
}

// MARK: - Grouping

/// Pure grouping logic for the history list, unit-tested. Sections are
/// keyed by board IDENTITY — the DIS serial, stamped on every record old
/// and new — never by display name: stock boards all advertise "MetaWear",
/// so a name key would merge distinct un-renamed boards, and legacy
/// records (nil `deviceName`) would split away from a board's new ones.
/// The stamped name is TITLE text only, disambiguated with the serial when
/// several boards share it.
enum SessionHistoryGrouping {

    struct BoardSection: Identifiable {
        /// The grouping key — DIS serial, or the deviceID string when a
        /// record predates serial stamping. Stable across renames.
        let id: String
        let title: String
        let sessions: [MWSessionSnapshot]
    }

    /// - Parameter macBySerial: serial → MAC translation; when a board's
    ///   MAC is known, titles show it instead of the DIS serial ("MetaWear
    ///   · CD:2E:…" beats "MetaWear · 0648AF" — the MAC is the identity
    ///   users see everywhere else). Grouping still KEYS on the serial:
    ///   it's stamped on every record, MAC knowledge is not.
    static func sections(from snapshots: [MWSessionSnapshot],
                         macBySerial: [String: String] = [:]) -> [BoardSection] {
        let grouped = Dictionary(grouping: snapshots) { snap in
            snap.deviceSerial.isEmpty ? snap.deviceID.uuidString : snap.deviceSerial
        }
        // Names claimed by more than one board need serial disambiguation
        // in their titles or the sections become indistinguishable.
        let claimedNames = grouped.values.compactMap { sessions in
            sessions.compactMap(\.deviceName).first { !$0.isEmpty }
        }
        let sharedNames = Set(
            Dictionary(grouping: claimedNames, by: { $0 })
                .filter { $0.value.count > 1 }
                .keys
        )
        return grouped
            .sorted { lhs, rhs in
                (lhs.value.first?.startDate ?? .distantPast)
                    > (rhs.value.first?.startDate ?? .distantPast)
            }
            .map { key, sessions in
                let serial = sessions.first?.deviceSerial ?? ""
                let displayID = macBySerial[serial] ?? serial
                // Sessions arrive newest-first from the store, so `first`
                // is the most recently stamped name — a rename wins.
                guard let name = sessions.compactMap(\.deviceName).first(where: { !$0.isEmpty }) else {
                    return BoardSection(
                        id: key,
                        title: displayID.isEmpty ? "Unknown board" : displayID,
                        sessions: sessions
                    )
                }
                let title = sharedNames.contains(name) && !displayID.isEmpty
                    ? "\(name) · \(displayID)"
                    : name
                return BoardSection(id: key, title: title, sessions: sessions)
            }
    }
}
