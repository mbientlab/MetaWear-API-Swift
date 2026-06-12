import SwiftUI
import MetaWear

struct StatePill: View {
    let state: DeviceState
    /// When true, render the pill as "Logging" in red regardless of the
    /// underlying SDK `state`. Needed because the board can be logging
    /// autonomously while the SDK actor sits in `.idle` (e.g. after a
    /// reconnect to a board that kept logging across an app crash). Driven
    /// from `pendingLogSessions` so the pill is the single source of truth
    /// for "this device is recording" instead of stacking a separate
    /// status pill at the top of the window.
    var isLogging: Bool = false

    var body: some View {
        Label {
            Text(label)
                .font(.metricCaption)
        } icon: {
            Image(systemName: icon)
        }
        .glassPill(tint: tint.opacity(0.18))
        .foregroundStyle(tint)
        .accessibilityLabel(label)
    }

    private var label: String {
        if isLogging { return "Logging" }
        switch state {
        case .disconnected: return "Disconnected"
        case .connecting:   return "Connecting…"
        case .idle:         return "Idle"
        case .streaming:    return "Streaming"
        case .logging:      return "Logging"
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        }
    }

    private var icon: String {
        if isLogging { return "record.circle.fill" }
        switch state {
        case .disconnected: return "wifi.slash"
        case .connecting:   return "wifi"
        case .idle:         return "checkmark.circle"
        case .streaming:    return "chart.line.uptrend.xyaxis"
        case .logging:      return "record.circle.fill"
        case .downloading:  return "arrow.down.circle"
        }
    }

    private var tint: Color {
        if isLogging { return Palette.danger }
        switch state {
        case .disconnected: return Palette.danger
        case .connecting:   return Palette.warning
        case .idle:         return Palette.warning
        case .streaming:    return Palette.info
        case .logging:      return Palette.danger
        case .downloading:  return Palette.accent
        }
    }
}
