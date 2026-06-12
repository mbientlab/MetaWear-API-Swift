import SwiftUI

struct GlassControlModifier: ViewModifier {
    var cornerRadius: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
    }
}

extension View {
    func glassControl(cornerRadius: CGFloat = 16) -> some View {
        modifier(GlassControlModifier(cornerRadius: cornerRadius))
    }
}
