import SwiftUI

enum DeviceConnectionStatus: Equatable {
    case connected
    case connecting
    case available(rssi: Int?)
    case offline
}

struct DeviceStatusBadge: View {
    let status: DeviceConnectionStatus

    var body: some View {
        switch status {
        case .connected:
            label("Connected", systemImage: "circle.fill", tint: Palette.success)
        case .connecting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text("Connecting…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.warning)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Palette.warning.opacity(0.15)))
            .accessibilityElement(children: .combine)
        case .available(let rssi):
            HStack(spacing: 6) {
                RSSIBars(dBm: rssi)
                if let rssi {
                    Text("\(rssi) dBm")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Palette.info)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(Palette.info.opacity(0.12)))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(rssi.map { "Available, signal \($0) dBm" } ?? "Available")
        case .offline:
            label("Offline", systemImage: "circle", tint: Palette.neutral)
                .accessibilityLabel("Offline")
        }
    }

    private func label(_ text: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.caption2)
                .foregroundStyle(tint)
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.15)))
        .accessibilityElement(children: .combine)
    }
}
