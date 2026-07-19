import SwiftUI

/// Decorative background for the connection screen: the original app's
/// solid #FE9500 field, broken up with static white line-art so it doesn't
/// read as a wall of orange — the brand "m" as an oversized watermark (the
/// old landing screen led with a big white "m") and a set of concentric
/// scan ripples rising from the bottom corner, a nod to what this screen
/// does all day. No motion by owner request.
struct BrandScanBackground: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Palette.accent

                // Scan ripples centred just off the bottom-leading corner,
                // sweeping up behind the watermark.
                ForEach(1..<6) { ring in
                    Circle()
                        .stroke(.white.opacity(0.12), lineWidth: 1.5)
                        .frame(width: CGFloat(ring) * w * 0.45,
                               height: CGFloat(ring) * w * 0.45)
                        .position(x: 0, y: h)
                }

                // Oversized "m" peeking up from the bottom-trailing edge —
                // the device lists live in the top half, so the mark fills
                // the quiet space the way the old app's device pods did.
                Text("m")
                    .font(.system(size: w * 0.95, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.14))
                    .position(x: w * 0.74, y: h * 0.92)
            }
        }
        .ignoresSafeArea()
    }
}
