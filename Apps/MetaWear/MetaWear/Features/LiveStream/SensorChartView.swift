import SwiftUI
import Charts

struct SensorChartView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    let title: String
    let systemImage: String
    let samples: [AnyChartSample]
    let latest: AnyChartSample?
    let effectiveHz: Double
    let axisStyle: SensorAxisStyle

    private var channelCount: Int { axisStyle.channels.count }
    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 6 : 8) {
            header
            SensorReadoutChips(channels: axisStyle.channels, latest: latest, unit: axisStyle.unit)
            chart
                // Extra breathing room between the live x/y/z readout and the
                // top of the graph, beyond the VStack's uniform spacing.
                .padding(.top, isCompact ? 6 : 8)
        }
        .glassCard(padding: isCompact ? 10 : 16)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Label(title, systemImage: systemImage)
                .font(isCompact ? .subheadline.weight(.semibold) : .headline)
            Spacer()
            if effectiveHz > 0 {
                Text("\(effectiveHz, format: hzFormat) Hz")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Effective sample rate \(effectiveHz, format: hzFormat) hertz")
            }
        }
    }

    /// Format the Hz readout: one decimal so 12.4 vs 12.5 is distinguishable
    /// at low rates, but the trailing `.0` stays off integer rates.
    private var hzFormat: FloatingPointFormatStyle<Double> {
        .number.precision(.fractionLength(0...1))
    }

    @ViewBuilder
    private var chart: some View {
        if samples.isEmpty {
            placeholder
        } else {
            chartView
        }
    }

    /// Shown until the first sample lands. The configure → enable → start
    /// handshake takes a noticeable fraction of a second on some sensors
    /// (notably ambient light, which needs its first integration cycle),
    /// during which the chart card would otherwise look frozen.
    private var placeholder: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Waiting for first sample…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .containerRelativeFrame(.vertical, alignment: .center) { length, _ in
            max(160, length * (isCompact ? 0.34 : 0.28))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for first sample")
    }

    private var chartView: some View {
        Chart(samples) { sample in
            if channelCount > 0 {
                LineMark(x: .value("t", sample.time), y: .value(axisStyle.channels[0].id, Double(sample.f0)))
                    .foregroundStyle(by: .value("axis", axisStyle.channels[0].id))
            }
            if channelCount > 1 {
                LineMark(x: .value("t", sample.time), y: .value(axisStyle.channels[1].id, Double(sample.f1)))
                    .foregroundStyle(by: .value("axis", axisStyle.channels[1].id))
            }
            if channelCount > 2 {
                LineMark(x: .value("t", sample.time), y: .value(axisStyle.channels[2].id, Double(sample.f2)))
                    .foregroundStyle(by: .value("axis", axisStyle.channels[2].id))
            }
            if channelCount > 3 {
                LineMark(x: .value("t", sample.time), y: .value(axisStyle.channels[3].id, Double(sample.f3)))
                    .foregroundStyle(by: .value("axis", axisStyle.channels[3].id))
            }
        }
        .chartForegroundStyleScale(axisStyle.styleScale)
        .chartLegend(.hidden)
        .chartYScale(domain: axisStyle.yRange ?? autoYRange)
        .chartYAxisLabel(axisStyle.unit, position: .leading)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.minute().second())
                    .font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(v, format: yAxisFormat)
                            .font(.caption2)
                    }
                }
            }
        }
        .animation(nil, value: samples.last?.id)
        .containerRelativeFrame(.vertical, alignment: .center) { length, _ in
            // Sized so that two cards fit comfortably above the keyboard / safe
            // area on a typical iPhone, and three on iPad. Floor stops the
            // chart from collapsing when the container is tiny (e.g. Slide
            // Over).
            max(160, length * (isCompact ? 0.34 : 0.28))
        }
    }

    /// Auto-range fallback for sensors with no fixed bound. Pads ±10% around
    /// the observed min/max so the trace doesn't kiss the chart edges. Falls
    /// back to a small symmetric range when no samples have arrived yet.
    private var autoYRange: ClosedRange<Double> {
        guard !samples.isEmpty else { return -1...1 }
        var lo = Double.infinity
        var hi = -Double.infinity
        for s in samples {
            for ch in 0..<channelCount {
                let v = Double(channelValue(s, channel: ch))
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }
        guard lo.isFinite, hi.isFinite else { return -1...1 }
        if lo == hi { return (lo - 1)...(hi + 1) }
        let pad = (hi - lo) * 0.1
        return (lo - pad)...(hi + pad)
    }

    private func channelValue(_ s: AnyChartSample, channel: Int) -> Float {
        switch channel {
        case 0: return s.f0
        case 1: return s.f1
        case 2: return s.f2
        case 3: return s.f3
        default: return 0
        }
    }

    /// Y-axis tick formatter. Picks precision from the unit: integer units
    /// (Pa, lx, dps, °) get no fraction, finer units (g, ratio) get one.
    private var yAxisFormat: FloatingPointFormatStyle<Double> {
        switch axisStyle.unit {
        case "g", "ratio", "°C", "%", "µT": return .number.precision(.fractionLength(1))
        default:                            return .number.precision(.fractionLength(0))
        }
    }
}
