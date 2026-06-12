import SwiftUI

struct RememberedDeviceRow: View {
    let remembered: RememberedDevice
    let isPinned: Bool
    let hasPendingLog: Bool
    let status: DeviceConnectionStatus
    let onTap: () -> Void
    let onForget: () -> Void

    private var isOffline: Bool { status == .offline }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .font(.title3)
                    .foregroundStyle(Palette.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(remembered.name.isEmpty ? "MetaWear" : remembered.name)
                            .font(.body.weight(.medium))
                        if hasPendingLog {
                            // Red, not amber: this means the board is
                            // actively recording — same visual semantic
                            // as the StatePill's "Logging" red, so the
                            // user sees one consistent colour for "this
                            // device is currently logging".
                            Label("Logging session waiting", systemImage: "record.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(Palette.danger)
                                .accessibilityLabel("Logging session waiting")
                        }
                    }
                    if let mac = remembered.macAddress {
                        Text(mac)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                DeviceStatusBadge(status: status)
            }
            .contentShape(.rect)
            .opacity(isOffline ? 0.65 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Forget Device", systemImage: "trash", role: .destructive, action: onForget)
        }
    }
}
