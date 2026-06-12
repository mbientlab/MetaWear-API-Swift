import SwiftUI
import MetaWear

struct NearbyDeviceRow: View {
    let device: MetaWearDevice
    let name: String
    let rssi: Int?
    let isConnecting: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(Palette.info)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.isEmpty ? "MetaWear" : name)
                        .font(.body.weight(.medium))
                    Text(device.identifier.uuidString.prefix(8))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                DeviceStatusBadge(status: isConnecting ? .connecting : .available(rssi: rssi))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
