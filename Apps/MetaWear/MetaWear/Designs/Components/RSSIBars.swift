import SwiftUI

struct RSSIBars: View {
    let dBm: Int?

    private var bars: Int {
        guard let dBm else { return 0 }
        return switch dBm {
        case ..<(-90): 1
        case -90 ..< -75: 2
        case -75 ..< -60: 3
        default: 4
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { index in
                Capsule()
                    .fill(index < bars ? Palette.accent : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 6 + CGFloat(index) * 3)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(dBm.map { "Signal strength \($0) decibels milliwatts" } ?? "Signal unknown")
    }
}
