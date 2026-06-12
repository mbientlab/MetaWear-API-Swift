import SwiftUI

/// Row of small chips, one per channel, showing the latest value with the
/// same color used by the chart line. Lets the user read precise values
/// without eyeballing the trace.
struct SensorReadoutChips: View {
    let channels: [SensorAxisStyle.Channel]
    let latest: AnyChartSample?
    let unit: String

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(channels.enumerated()), id: \.element.id) { index, channel in
                chip(label: channel.id, color: channel.color, value: value(at: index))
            }
        }
    }

    private func chip(label: String, color: Color, value: Float?) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            if let value {
                Text("\(value, format: valueFormat)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.primary)
            } else {
                Text("—")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.12)))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(value.map { "\(label) \($0) \(unit)" } ?? "\(label) no value")
    }

    private func value(at index: Int) -> Float? {
        guard let latest else { return nil }
        switch index {
        case 0: return latest.f0
        case 1: return latest.f1
        case 2: return latest.f2
        case 3: return latest.f3
        default: return nil
        }
    }

    /// 2 fraction digits for fine-grained units (g, ratio), 1 for moderate
    /// (°C, %, µT, lx), 0 for coarse (Pa, dps, °).
    private var valueFormat: FloatingPointFormatStyle<Float> {
        switch unit {
        case "g", "ratio":     return .number.precision(.fractionLength(2))
        case "°C", "%", "µT", "lx": return .number.precision(.fractionLength(1))
        default:               return .number.precision(.fractionLength(0))
        }
    }
}
