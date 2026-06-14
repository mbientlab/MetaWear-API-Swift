import SwiftUI

struct ExportSheetItem: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let subtitle: String
}

struct ExportResult: Identifiable, Sendable {
    let id = UUID()
    let items: [ExportSheetItem]
}

struct ExportSheet: View {
    let items: [ExportSheetItem]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        "Nothing to Export",
                        systemImage: "square.and.arrow.up",
                        description: Text("No samples are buffered yet. Stream for a few seconds before exporting.")
                    )
                } else {
                    List(items) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.url.lastPathComponent)
                                .font(.body.weight(.medium))
                            Text(item.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ShareLink(item: item.url) {
                                Label("Share CSV", systemImage: "square.and.arrow.up")
                            }
                            .buttonStyle(.glass)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle("Export")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: { dismiss() })
                }
            }
        }
    }
}
