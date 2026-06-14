import SwiftUI

/// Top-of-screen pill that surfaces an active logging session on the connected
/// device. Only shown while a session is *actually recording* (`status == .running`);
/// `.stopped` sessions (data captured, awaiting download) show up as the
/// remembered-device row badge instead, so the pill doesn't keep ticking after
/// the user has stopped the session.
struct LoggingPill: View {
    @Environment(AppStore.self) private var appStore
    @State private var now: Date = .now

    private var runningSessions: [LogSessionRecord] {
        appStore.pendingLogSessions.filter {
            $0.deviceID == appStore.activeDeviceID && $0.status == .running
        }
    }

    private var earliestStart: Date? {
        runningSessions.map(\.startDate).min()
    }

    var body: some View {
        if let start = earliestStart {
            HStack(spacing: 8) {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(Palette.danger)
                    .symbolEffect(.pulse, options: .repeating)
                    .accessibilityHidden(true)
                Text("Logging · \(elapsed(from: start))")
                    .font(.subheadline.weight(.medium))
                    .monospacedDigit()
            }
            .glassPill(tint: Palette.danger.opacity(0.25))
            .task {
                while !Task.isCancelled {
                    now = .now
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .accessibilityLabel("Logging in progress, \(elapsed(from: start)) elapsed")
        }
    }

    private func elapsed(from start: Date) -> String {
        let elapsed = Int(now.timeIntervalSince(start))
        let m = elapsed / 60, s = elapsed % 60
        return "\(twoDigits(m)):\(twoDigits(s))"
    }

    private func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
