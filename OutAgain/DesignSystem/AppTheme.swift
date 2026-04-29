import SwiftUI

enum AppTheme {
    static let ink = Color(hex: "#050506")
    static let charcoal = Color(hex: "#121114")
    static let smoke = Color(hex: "#1D191A")
    static let amber = Color(hex: "#D98B3D")
    // Primary accent — electric violet, reads as nightlife/club
    static let warmGold = Color(hex: "#A855F7")
    static let activeGreen = Color(hex: "#63D15D")
    static let rose = Color(hex: "#8F4E4F")
    static let line = Color.white.opacity(0.08)
    static let softText = Color.white.opacity(0.72)

    // Pure black base — club/nightlife feel
    static let backgroundGradient = LinearGradient(
        colors: [
            Color(hex: "#000000"),
            Color(hex: "#050508"),
            Color(hex: "#000000")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct AmbientBackground: View {
    // Orb positions are defined as normalized (0–1) fractions of the
    // screen. AnimatedOrb resolves them to real points at render time
    // using GeometryReader, so orbs are guaranteed to stay on screen
    // regardless of device size.
    struct Orb {
        let color: Color
        let size: CGFloat
        let blur: CGFloat
        let opacity: Double
        // Start and end positions, both as unit fractions (0–1) of screen size.
        // The orb animates between fromX/Y and toX/Y, then autoreverses.
        let fromX: CGFloat  // 0 = left edge, 1 = right edge
        let fromY: CGFloat  // 0 = top edge,  1 = bottom edge
        let toX: CGFloat
        let toY: CGFloat
    }

    // Each orb owns a dedicated screen zone and its path stays within that
    // zone so no two orbs ever converge. The screen is divided into six
    // non-overlapping territories: TL, TR, ML, MR, BL, BR. Each orb
    // bounces within its territory only — the from/to coordinates are both
    // inside the same half of the screen so paths never cross through the
    // center simultaneously. Sizes are reduced and blur increased to soften
    // the halo, further reducing visible overlap at zone boundaries.
    private let orbs: [Orb] = [
        // Electric blue — top-left zone (stays in upper-left quarter)
        Orb(color: Color(hex: "#1A6EFF"), size: 280, blur: 120, opacity: 0.40,
            fromX: 0.05, fromY: 0.04, toX: 0.40, toY: 0.30),
        // Hot magenta — top-right zone (upper-right quarter)
        Orb(color: Color(hex: "#E8009A"), size: 260, blur: 115, opacity: 0.36,
            fromX: 0.62, fromY: 0.04, toX: 0.94, toY: 0.28),
        // Deep purple — mid-left zone (left strip, middle band)
        Orb(color: Color(hex: "#7B2FFF"), size: 240, blur: 125, opacity: 0.32,
            fromX: 0.02, fromY: 0.38, toX: 0.35, toY: 0.62),
        // Cyan — mid-right zone (right strip, middle band)
        Orb(color: Color(hex: "#00D4E8"), size: 220, blur: 118, opacity: 0.28,
            fromX: 0.64, fromY: 0.36, toX: 0.96, toY: 0.64),
        // Crimson red — bottom-left zone (lower-left quarter)
        Orb(color: Color(hex: "#FF2244"), size: 250, blur: 122, opacity: 0.30,
            fromX: 0.04, fromY: 0.68, toX: 0.40, toY: 0.94),
        // Neon green — bottom-right zone (lower-right quarter)
        Orb(color: Color(hex: "#39FF6A"), size: 220, blur: 118, opacity: 0.26,
            fromX: 0.60, fromY: 0.70, toX: 0.94, toY: 0.96),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                AppTheme.backgroundGradient

                ForEach(Array(orbs.enumerated()), id: \.offset) { index, orb in
                    AnimatedOrb(orb: orb, index: index, screenSize: geo.size)
                }

                // Light veil keeps black dominant — orbs glow, not paint.
                Rectangle()
                    .fill(.black.opacity(0.18))
            }
        }
        .ignoresSafeArea()
    }
}

/// Drives one orb between its fromX/Y and toX/Y positions (expressed as
/// unit fractions of the screen). Positions are clamped so the orb center
/// always stays within the screen bounds.
private struct AnimatedOrb: View {
    let orb: AmbientBackground.Orb
    let index: Int
    let screenSize: CGSize

    @State private var flip = false

    private var duration: Double {
        let base = 40.0
        let perOrb = 8.0
        return base + Double(index) * perOrb
    }

    // Resolve a unit-fraction position to a screen-space offset from center,
    // clamped so the orb edge never exits the screen.
    private func resolvedOffset(unitX: CGFloat, unitY: CGFloat) -> CGSize {
        let halfOrb = orb.size / 2
        let minX = halfOrb - screenSize.width / 2
        let maxX = screenSize.width / 2 - halfOrb
        let minY = halfOrb - screenSize.height / 2
        let maxY = screenSize.height / 2 - halfOrb

        let rawX = (unitX - 0.5) * screenSize.width
        let rawY = (unitY - 0.5) * screenSize.height

        return CGSize(
            width:  min(max(rawX, minX), maxX),
            height: min(max(rawY, minY), maxY)
        )
    }

    var body: some View {
        let from = resolvedOffset(unitX: orb.fromX, unitY: orb.fromY)
        let to   = resolvedOffset(unitX: orb.toX,   unitY: orb.toY)
        let offset = flip ? to : from

        Circle()
            .fill(orb.color.opacity(orb.opacity))
            .frame(width: orb.size, height: orb.size)
            .blur(radius: orb.blur)
            .offset(x: offset.width, y: offset.height)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 6.0) {
                    withAnimation(
                        .easeInOut(duration: duration)
                        .repeatForever(autoreverses: true)
                    ) {
                        flip = true
                    }
                }
            }
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
        // Default tint is now clear — plain liquid glass, no amber cast.
        // Pass an explicit tint only for cards that need a color accent
        // (e.g. contacts permission pitch with a warm-gold hint).
        tint: Color = .clear,
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
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            )
            .glassEffect(.regular.tint(tint).interactive(interactive), in: .rect(cornerRadius: cornerRadius))
    }
}

struct SectionEyebrow: View {
    @Environment(\.appAccent) private var accent
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(accent.opacity(0.86))
                .tracking(1.8)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
            }
        }
    }
}

struct GlassPill: View {
    @Environment(\.appAccent) private var accent
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
        .glassEffect(.regular.tint(accent.opacity(isActive ? 0.18 : 0.08)), in: .capsule)
    }
}

// MARK: - Accent Color Environment Key

/// A SwiftUI environment key that carries the current accent color down the
/// entire view tree. Injected once at the root (MainShellView) from
/// `store.accentColorChoice.color`, so every leaf view can read
/// `@Environment(\.appAccent)` without coupling to AppStore directly.
struct AppAccentKey: EnvironmentKey {
    static let defaultValue: Color = Color(hex: "#A855F7") // purple fallback for previews / loading
}

extension EnvironmentValues {
    var appAccent: Color {
        get { self[AppAccentKey.self] }
        set { self[AppAccentKey.self] = newValue }
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
