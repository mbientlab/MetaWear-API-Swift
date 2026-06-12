import SwiftUI

struct GlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: Double = 0

    var body: some View {
        Rectangle()
            .fill(meshGradient)
            .overlay {
                if !reduceMotion {
                    LinearGradient(
                        colors: [.clear, Palette.accent.opacity(0.18), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .rotationEffect(.degrees(phase))
                    .blendMode(.plusLighter)
                    .opacity(0.4)
                    .animation(.linear(duration: 12).repeatForever(autoreverses: false), value: phase)
                }
            }
            .task {
                guard !reduceMotion else { return }
                phase = 360
            }
            .ignoresSafeArea()
    }

    private var meshGradient: MeshGradient {
        let colors: [Color] = colorScheme == .dark
            ? [.black, Palette.accent.opacity(0.45), .black,
               Palette.info.opacity(0.30), Palette.accent.opacity(0.20), .black,
               .black, Palette.accent.opacity(0.30), .black]
            : [.white, Palette.accent.opacity(0.25), .white,
               Palette.info.opacity(0.20), Palette.accent.opacity(0.15), .white,
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
