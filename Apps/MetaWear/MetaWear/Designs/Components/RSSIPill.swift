import SwiftUI

/// Live signal-strength pill: bars + dBm in the same blue capsule styling as
/// the scan screen's "available" badge, for showing a connected board's link
/// quality (fed by `AppStore.connectedRSSI` — boards stop advertising once
/// connected, so this value comes from the connection poll).
struct RSSIPill: View {
    let dBm: Int

    var body: some View {
        HStack(spacing: 6) {
            RSSIBars(dBm: dBm)
            Text("\(dBm) dBm")
                .font(.caption2.monospaced())
                .foregroundStyle(Palette.info)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Palette.info.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Signal \(dBm) dBm")
    }
}
