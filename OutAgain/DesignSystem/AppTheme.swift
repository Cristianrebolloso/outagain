import SwiftUI

enum AppTheme {
    static let ink = Color(hex: "#050506")
    static let charcoal = Color(hex: "#121114")
    static let smoke = Color(hex: "#1D191A")
    static let amber = Color(hex: "#D98B3D")
    static let warmGold = Color(hex: "#F5C77B")
    static let activeGreen = Color(hex: "#63D15D")
    static let rose = Color(hex: "#8F4E4F")
    static let line = Color.white.opacity(0.08)
    static let softText = Color.white.opacity(0.72)

    static let backgroundGradient = LinearGradient(
        colors: [
            Color(hex: "#030304"),
            Color(hex: "#110C0D"),
            Color(hex: "#1C1210")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct AmbientBackground: View {
    var body: some View {
        ZStack {
            AppTheme.backgroundGradient
            Circle()
                .fill(AppTheme.amber.opacity(0.17))
                .frame(width: 320, height: 320)
                .blur(radius: 100)
                .offset(x: 120, y: -240)
            Circle()
                .fill(AppTheme.rose.opacity(0.12))
                .frame(width: 260, height: 260)
                .blur(radius: 120)
                .offset(x: -140, y: 240)
            Rectangle()
                .fill(.black.opacity(0.18))
        }
        .ignoresSafeArea()
    }
}

struct NightPanel<Content: View>: View {
    let cornerRadius: CGFloat
    let padding: CGFloat
    let tint: Color
    let interactive: Bool
    @ViewBuilder var content: Content

    init(
        cornerRadius: CGFloat = 28,
        padding: CGFloat = 18,
        tint: Color = AppTheme.amber.opacity(0.24),
        interactive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.padding = padding
        self.tint = tint
        self.interactive = interactive
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(AppTheme.line, lineWidth: 1)
            )
            .glassEffect(.regular.tint(tint).interactive(interactive), in: .rect(cornerRadius: cornerRadius))
    }
}

struct SectionEyebrow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(AppTheme.warmGold.opacity(0.86))
                .tracking(1.8)
            Text(detail)
                .font(.system(size: 28, weight: .bold, design: .serif))
                .foregroundStyle(.white)
        }
    }
}

struct GlassPill: View {
    let title: String
    var icon: String? = nil
    var isActive = true

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
            }
            Text(title)
        }
        .font(.system(.caption, design: .rounded, weight: .semibold))
        .foregroundStyle(isActive ? .white : AppTheme.softText)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.white.opacity(isActive ? 0.08 : 0.04), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
        .glassEffect(.regular.tint(AppTheme.amber.opacity(isActive ? 0.18 : 0.08)), in: .capsule)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)

        let red = Double((value >> 16) & 0xFF) / 255
        let green = Double((value >> 8) & 0xFF) / 255
        let blue = Double(value & 0xFF) / 255

        self.init(red: red, green: green, blue: blue)
    }
}
