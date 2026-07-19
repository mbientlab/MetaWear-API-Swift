import SwiftUI

/// Static orange wash behind every screen. Used to carry a rotating
/// shimmer sweep and a blue tint in the mesh; both were dropped by owner
/// request — the background is now a calm, motionless gradient in the
/// brand orange only, with white/black anchors so the Liquid Glass cards
/// keep their contrast in both color schemes.
struct GlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(meshGradient)
            .ignoresSafeArea()
    }

    private var meshGradient: MeshGradient {
        let colors: [Color] = colorScheme == .dark
            ? [.black, Palette.accent.opacity(0.45), .black,
               Palette.accent.opacity(0.30), Palette.accent.opacity(0.20), .black,
               .black, Palette.accent.opacity(0.30), .black]
            : [.white, Palette.accent.opacity(0.25), .white,
               Palette.accent.opacity(0.20), Palette.accent.opacity(0.15), .white,
               .white, Palette.accent.opacity(0.20), .white]
        return MeshGradient(
            width: 3,
            height: 3,
            points: [
                .init(0, 0), .init(0.5, 0), .init(1, 0),
                .init(0, 0.5), .init(0.5, 0.5), .init(1, 0.5),
                .init(0, 1), .init(0.5, 1), .init(1, 1)
            ],
            colors: colors
        )
    }
}
