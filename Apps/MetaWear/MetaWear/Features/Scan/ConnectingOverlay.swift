import SwiftUI

/// Modal-style scrim shown while a MetaWear is mid-handshake. Blocks taps on
/// whatever is behind it (scan list, detail pane) so the user can't try to
/// start a second connection or fire actions against a device that isn't
/// ready yet.
struct ConnectingOverlay: View {
    let deviceName: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                VStack(spacing: 2) {
                    Text("Connecting")
                        .font(.headline)
                    Text(deviceName ?? "MetaWear")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .background(.regularMaterial, in: .rect(cornerRadius: 18))
        }
        // The Color scrim at the back of the ZStack already absorbs taps,
        // so nothing behind the overlay receives them.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connecting to \(deviceName ?? "MetaWear")")
    }
}
