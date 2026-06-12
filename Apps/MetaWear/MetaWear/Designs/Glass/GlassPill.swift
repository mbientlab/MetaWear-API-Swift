import SwiftUI

struct GlassPillModifier: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .font(.callout.weight(.medium))
            .glassEffect(
                tint.map { .regular.tint($0) } ?? .regular,
                in: .capsule
            )
    }
}

extension View {
    func glassPill(tint: Color? = nil) -> some View {
        modifier(GlassPillModifier(tint: tint))
    }
}
