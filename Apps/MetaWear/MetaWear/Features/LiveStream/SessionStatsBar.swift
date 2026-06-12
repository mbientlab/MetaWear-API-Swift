import SwiftUI

/// Compact header row above the chart cards showing elapsed session time and
/// the running total sample count across all channels. Uses `TimelineView`
/// to tick the duration once per second without forcing the rest of the
/// streaming UI to redraw at that cadence.
struct SessionStatsBar: View {
    let startedAt: Date
    let totalSamples: Int

    var body: some View {
        TimelineView(.periodic(from: startedAt, by: 1)) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        HStack(spacing: 12) {
            stat(systemImage: "clock", label: durationText(for: now))
            Divider()
                .frame(height: 14)
            stat(systemImage: "number", label: "\(totalSamples.formatted(.number)) samples")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func stat(systemImage: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text(label)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }

    /// Format "mm:ss" up to 59:59, "h:mm:ss" beyond. `Duration` formatting
    /// handles both cleanly.
    private func durationText(for now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(startedAt))
        let duration = Duration.seconds(Int(seconds))
        if seconds >= 3600 {
            return duration.formatted(.time(pattern: .hourMinuteSecond))
        }
        return duration.formatted(.time(pattern: .minuteSecond))
    }
}
