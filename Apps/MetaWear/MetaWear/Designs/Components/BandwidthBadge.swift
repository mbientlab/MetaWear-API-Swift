import SwiftUI

struct BandwidthBadge: View {
    let aggregateHz: Double
    let onHalve: () -> Void

    private var isOverCeiling: Bool { aggregateHz > BandwidthAdvisor.bleSafeCeilingHz }

    var body: some View {
        if isOverCeiling {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Combined rate \(aggregateHz, format: .number.precision(.fractionLength(0))) Hz")
                        .font(.headline)
                    Text("Above BLE limit — samples may drop.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Halve all rates", action: onHalve)
                    .buttonStyle(.glassProminent)
                    .tint(Palette.warning)
            }
            .glassCard(cornerRadius: 18)
            .accessibilityElement(children: .combine)
        }
    }
}
