import SwiftUI
import MetaWear

/// Row for a MetaWear board observed advertising in bootloader (MetaBoot)
/// mode. Distinct visual language from `NearbyDeviceRow`:
///   • wrench icon (this is a rescue / recovery flow, not a normal connect);
///   • `Palette.warning` accent to signal the board is in a non-normal state;
///   • no RSSI badge — MetaBoot ads carry the same signal but the value is
///     rarely actionable during the seconds a user spends flashing.
///
/// Tap opens the firmware-update sheet from `ScanView`.
struct MetaBootDeviceRow: View {
    let advertisement: MetaBootAdvertisement
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.title3)
                    .foregroundStyle(Palette.warning)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(advertisement.name)
                        .font(.body.weight(.medium))
                    Text(advertisement.identifier.uuidString.prefix(8))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text("Bootloader")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.warning)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Palette.warning.opacity(0.15)))
                    .accessibilityLabel("In bootloader mode")
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
