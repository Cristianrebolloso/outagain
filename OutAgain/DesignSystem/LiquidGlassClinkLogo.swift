import SwiftUI

/// The original asymmetric clink mark, rendered from the live backdrop.
/// Keeping the cups as paths lets Liquid Glass refract the user's theme.
struct LiquidGlassClinkLogo: View {
    var body: some View {
        Color.clear
            .glassEffect(.clear, in: ClinkLogoShape())
            .aspectRatio(660.0 / 520.0, contentMode: .fit)
            .accessibilityLabel("Out Again")
            .accessibilityAddTraits(.isImage)
            .allowsHitTesting(false)
    }
}

private struct ClinkLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        // Taller cup: soft, slightly irregular sides and a slanted rim.
        path.move(to: CGPoint(x: 42, y: 0))
        path.addCurve(to: CGPoint(x: 322, y: 49),
                      control1: CGPoint(x: 107, y: 1), control2: CGPoint(x: 253, y: 25))
        path.addCurve(to: CGPoint(x: 344, y: 89),
                      control1: CGPoint(x: 343, y: 57), control2: CGPoint(x: 350, y: 69))
        path.addLine(to: CGPoint(x: 235, y: 482))
        path.addCurve(to: CGPoint(x: 201, y: 509),
                      control1: CGPoint(x: 229, y: 501), control2: CGPoint(x: 220, y: 509))
        path.addCurve(to: CGPoint(x: 31, y: 483),
                      control1: CGPoint(x: 157, y: 509), control2: CGPoint(x: 62, y: 496))
        path.addCurve(to: CGPoint(x: 0, y: 443),
                      control1: CGPoint(x: 10, y: 474), control2: CGPoint(x: 0, y: 461))
        path.addLine(to: CGPoint(x: 10, y: 29))
        path.addCurve(to: CGPoint(x: 42, y: 0),
                      control1: CGPoint(x: 10, y: 11), control2: CGPoint(x: 19, y: 0))
        path.closeSubpath()

        // Counter-wound openings stay genuinely empty, including in the glass effect.
        path.move(to: CGPoint(x: 43, y: 28))
        path.addCurve(to: CGPoint(x: 170, y: 100),
                      control1: CGPoint(x: 65, y: 51), control2: CGPoint(x: 101, y: 80))
        path.addCurve(to: CGPoint(x: 296, y: 114),
                      control1: CGPoint(x: 210, y: 112), control2: CGPoint(x: 277, y: 129))
        path.addCurve(to: CGPoint(x: 316, y: 78),
                      control1: CGPoint(x: 305, y: 105), control2: CGPoint(x: 310, y: 91))
        path.addCurve(to: CGPoint(x: 43, y: 28),
                      control1: CGPoint(x: 242, y: 53), control2: CGPoint(x: 100, y: 29))
        path.closeSubpath()

        // Shorter, broader cup, with its own contour rather than a mirrored copy.
        path.move(to: CGPoint(x: 350, y: 137))
        path.addCurve(to: CGPoint(x: 631, y: 88),
                      control1: CGPoint(x: 424, y: 113), control2: CGPoint(x: 559, y: 91))
        path.addCurve(to: CGPoint(x: 659, y: 113),
                      control1: CGPoint(x: 649, y: 87), control2: CGPoint(x: 658, y: 95))
        path.addLine(to: CGPoint(x: 659, y: 434))
        path.addCurve(to: CGPoint(x: 631, y: 477),
                      control1: CGPoint(x: 659, y: 455), control2: CGPoint(x: 648, y: 468))
        path.addCurve(to: CGPoint(x: 438, y: 517),
                      control1: CGPoint(x: 582, y: 499), control2: CGPoint(x: 494, y: 515))
        path.addCurve(to: CGPoint(x: 398, y: 490),
                      control1: CGPoint(x: 417, y: 518), control2: CGPoint(x: 405, y: 510))
        path.addLine(to: CGPoint(x: 330, y: 180))
        path.addCurve(to: CGPoint(x: 350, y: 137),
                      control1: CGPoint(x: 324, y: 160), control2: CGPoint(x: 331, y: 145))
        path.closeSubpath()

        path.move(to: CGPoint(x: 365, y: 163))
        path.addCurve(to: CGPoint(x: 393, y: 201),
                      control1: CGPoint(x: 371, y: 183), control2: CGPoint(x: 378, y: 199))
        path.addCurve(to: CGPoint(x: 526, y: 176),
                      control1: CGPoint(x: 421, y: 205), control2: CGPoint(x: 464, y: 198))
        path.addCurve(to: CGPoint(x: 631, y: 114),
                      control1: CGPoint(x: 581, y: 157), control2: CGPoint(x: 620, y: 134))
        path.addCurve(to: CGPoint(x: 365, y: 163),
                      control1: CGPoint(x: 561, y: 118), control2: CGPoint(x: 421, y: 144))
        path.closeSubpath()

        return path.applying(CGAffineTransform(a: rect.width / 660, b: 0,
                                             c: 0, d: rect.height / 520,
                                             tx: rect.minX, ty: rect.minY))
    }
}
