import SwiftUI
import UIKit

enum AppTheme {
    static let ink = Color(hex: "#050506")
    static let charcoal = Color(hex: "#121114")
    static let smoke = Color(hex: "#1D191A")
    static let amber = Color(hex: "#D98B3D")
    /// Flash-on bolt tint — matches gold-theme sparkle tones.
    static let lightningGold = Color(hex: "#F5C451")
    // Primary accent — electric violet, reads as nightlife/club
    static let warmGold = Color(hex: "#A855F7")
    static let activeGreen = Color(hex: "#63D15D")
    static let rose = Color(hex: "#8F4E4F")
    static let line = Color.white.opacity(0.08)
    static let softText = Color.white.opacity(0.72)
    static let barLightPurple = Color(hex: "#A855F7")
    static let barLightIndigo = Color(hex: "#7B6EF6")
    static let barLightBlue = Color(hex: "#32D7FF")
    static let barLightGreen = Color(hex: "#2EE6A6")
    static let barLightRed = Color(hex: "#FF3B6B")

    /// Foreground color for text/icons placed directly on an accent-filled
    /// surface. Most accents need white text; the white accent needs black.
    static func foregroundOnAccent(_ accent: Color) -> Color {
        accent == .white ? .black : .white
    }

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

/// App-wide typography tokens. See `DesignSystem/Typography.md` before adding
/// new text styles or using direct `.system(...)` fonts for user-facing text.
enum AppTypography {
    // Bundled original Fontshare faces; relative styles retain Dynamic Type.
    private static func display(_ size: CGFloat, relativeTo style: Font.TextStyle = .title2) -> Font {
        .custom("CabinetGrotesk-Bold", size: size, relativeTo: style)
    }

    private static func text(_ size: CGFloat, weight: String = "Regular", relativeTo style: Font.TextStyle = .body) -> Font {
        .custom("GeneralSans-\(weight)", size: size, relativeTo: style)
    }

    static let brandHero = Font.custom("CabinetGrotesk-Extrabold", size: 42, relativeTo: .largeTitle)
    static let brandTitle = display(34, relativeTo: .largeTitle)
    static let brandMoment = display(28, relativeTo: .title)

    static let pageTitle = display(30, relativeTo: .largeTitle)
    static let sheetTitle = display(24)
    static let sectionTitle = display(22)
    static let captureSectionTitle = display(26)
    static let fieldLabel = text(15, weight: "Medium", relativeTo: .subheadline)
    static let heroSubtitle = text(20, weight: "Medium", relativeTo: .title3)

    private static let feedAuthorSize: CGFloat = 26
    static let feedAuthor = display(feedAuthorSize, relativeTo: .title2)
    /// Native ad assets stay inside Google's UIKit view while sharing the
    /// same name styling and Dynamic Type scale as SwiftUI post headers.
    static var feedAuthorUIFont: UIFont {
        UIFontMetrics(forTextStyle: .title2).scaledFont(for:
            UIFont(name: "CabinetGrotesk-Bold", size: feedAuthorSize)
                ?? UIFont.preferredFont(forTextStyle: .title2))
    }
    static let profileName = feedAuthor
    static let profileNameLarge = display(36, relativeTo: .largeTitle)
    static let profileCountLarge = display(28, relativeTo: .title)
    static let feedCaptionAuthor = text(16, weight: "Semibold", relativeTo: .callout)
    static let username = text(15, weight: "Medium", relativeTo: .subheadline)
    static let usernameCompact = text(12, relativeTo: .caption)

    static let body = text(17)
    static let bodyMedium = text(17, weight: "Medium")
    static let callout = text(16, relativeTo: .callout)
    static let rowTitle = text(17, weight: "Semibold", relativeTo: .headline)
    static let rowSubtitle = text(15, relativeTo: .subheadline)
    static let rowSubtitleMedium = text(15, weight: "Medium", relativeTo: .subheadline)
    static let formInput = body
    static let searchInput = rowSubtitle
    static let toolbarAction = text(17, weight: "Semibold")
    static let footnote = text(13, relativeTo: .footnote)
    static let footnoteMedium = text(13, weight: "Medium", relativeTo: .footnote)
    static let caption = text(12, relativeTo: .caption)
    static let captionMedium = text(12, weight: "Medium", relativeTo: .caption)
    static let caption2Emphasis = text(11, weight: "Semibold", relativeTo: .caption2)

    static let metadata = captionMedium
    static let metadataEmphasis = text(12, weight: "Semibold", relativeTo: .caption)
    static let chip = metadata
    static let chipEmphasis = metadataEmphasis
    static let chipSmall = text(10, weight: "Semibold", relativeTo: .caption2)
    static let pill = text(14, weight: "Semibold", relativeTo: .subheadline)
    static let pillMedium = text(14, weight: "Medium", relativeTo: .subheadline)
    static let pillSmall = text(13, weight: "Semibold", relativeTo: .footnote)
    static let controlLabel = text(15, weight: "Semibold", relativeTo: .subheadline)
    static let actionLabel = text(17, weight: "Semibold")
    static let button = controlLabel
    static let buttonFootnote = pillSmall
    static let badge = caption2Emphasis
    static let badgeStrong = caption2Emphasis
    static let badgeNumber = metadataEmphasis
    static let timer = text(12, weight: "Medium", relativeTo: .caption).monospacedDigit()
    static let statNumber = display(22)
    static let statLabel = metadata

    // Display numerals and labels shared by Home, Activity and profile stats.
    static let statHero = display(70, relativeTo: .largeTitle)
    static let statFeature = display(46, relativeTo: .largeTitle)
    static let statTotal = display(44, relativeTo: .largeTitle)
    static let statSummary = display(40, relativeTo: .largeTitle)
    static let statCard = display(38, relativeTo: .largeTitle)
    static let statCompact = display(34, relativeTo: .largeTitle)
}

enum AppLayout {
    static let inlineCommentsMinimumWidth: CGFloat = 640
    static let feedMaximumWidth: CGFloat = 600
    static let phoneColumnMaximumWidth: CGFloat = 440

    static func photoGridColumnCount(width: CGFloat) -> Int {
        guard width >= 600 else { return width < 300 ? 2 : 3 }
        return min(6, max(4, Int(width / 150) / 2 * 2))
    }
    static let screenPadding: CGFloat = 20
    static let tabBarClearance: CGFloat = 24
    static let sheetContentPadding: CGFloat = 20
    static let secondaryPageTopPadding: CGFloat = 16
    static let secondaryPageBottomPadding: CGFloat = 60
    static let panelRadius: CGFloat = 24
    static let compactPanelRadius: CGFloat = 20
}

/// Main Duo panes reveal the single full-window background. Presented sheets keep
/// their own AmbientBackground and ordinary iPhone pages retain their surface.
struct MainPageSurface: ViewModifier {
    @Environment(AppStore.self) private var store

    @ViewBuilder
    func body(content: Content) -> some View {
        if store.isDuoDevice {
            content.containerBackground(.clear, for: .navigation)
        } else {
            content.background(AmbientBackground())
        }
    }
}

struct AmbientBackground: View {
    /// When set, renders this theme directly instead of reading from the environment.
    /// Used for standalone profile previews and other explicit theme surfaces.
    var overrideTheme: BackgroundTheme? = nil

    @Environment(\.appBackgroundTheme) private var environmentTheme
    @Environment(\.defaultBackgroundPhase) private var defaultPhase

    private var backgroundTheme: BackgroundTheme { overrideTheme ?? environmentTheme }

    struct OrbStyle {
        let color: Color
        let opacity: Double
    }

    // Orb positions are defined as normalized (0–1) fractions of the
    // screen. AnimatedOrb resolves them to real points at render time
    // using GeometryReader, so orbs are guaranteed to stay on screen
    // regardless of device size.
    struct Orb {
        let size: CGFloat
        let blur: CGFloat
        // Start and end positions, both as unit fractions (0–1) of screen size.
        // The orb animates between fromX/Y and toX/Y, then autoreverses.
        let fromX: CGFloat  // 0 = left edge, 1 = right edge
        let fromY: CGFloat  // 0 = top edge,  1 = bottom edge
        let toX: CGFloat
        let toY: CGFloat
    }

    // Legacy palette retained for the original and speakeasy themes —
    // deep blue, red, and green pools bleeding through near-black.
    private static let launchOrbStyles: [OrbStyle] = [
        OrbStyle(color: Color(hex: "#0033CC"), opacity: 0.70),  // deep stage blue
        OrbStyle(color: Color(hex: "#CC0A0A"), opacity: 0.58),  // red floor light
        OrbStyle(color: Color(hex: "#007A3D"), opacity: 0.55),  // green floor pool
        OrbStyle(color: Color(hex: "#1A00AA"), opacity: 0.52),  // indigo backwash
        OrbStyle(color: Color(hex: "#8B0000"), opacity: 0.44),  // dark crimson bleed
        OrbStyle(color: Color(hex: "#004D20"), opacity: 0.42),  // deep green shadow
    ]

    // Sunset theme orb styles — deep orange, rose, magenta, and violet
    private static let sunsetOrbStyles: [OrbStyle] = [
        OrbStyle(color: Color(hex: "#FF5E1A"), opacity: 0.50),  // burnt orange
        OrbStyle(color: Color(hex: "#C8184A"), opacity: 0.44),  // deep rose
        OrbStyle(color: Color(hex: "#FF8C42"), opacity: 0.40),  // warm amber-orange
        OrbStyle(color: Color(hex: "#8B1A6B"), opacity: 0.46),  // rich magenta-violet
        OrbStyle(color: Color(hex: "#E84060"), opacity: 0.38),  // coral pink
        OrbStyle(color: Color(hex: "#5C1060"), opacity: 0.42),  // deep purple
    ]

    private static let sunsetBaseGradient = LinearGradient(
        colors: [
            Color(hex: "#0D0408"),
            Color(hex: "#120408"),
            Color(hex: "#080308"),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Orange theme — warm neon nightlife: tangerine, peach, and rose-amber
    // against a near-black base. Orbs are deeply hazed — color bleeds in
    // atmospherically rather than sitting as visible blobs.
    private static let orangeOrbStyles: [OrbStyle] = [
        OrbStyle(color: Color(hex: "#FF6B35"), opacity: 0.36),  // hot tangerine
        OrbStyle(color: Color(hex: "#FF3D6B"), opacity: 0.26),  // rose-coral pop
        OrbStyle(color: Color(hex: "#FFAA50"), opacity: 0.30),  // warm amber glow
        OrbStyle(color: Color(hex: "#FF2D55"), opacity: 0.22),  // deep rose ember
        OrbStyle(color: Color(hex: "#FF8C42"), opacity: 0.32),  // citrus haze
        OrbStyle(color: Color(hex: "#C8382A"), opacity: 0.24),  // smoldering crimson
    ]

    private static let orangeSparkleStyles: [OrbStyle] = [
        OrbStyle(color: Color(hex: "#FFD4A8"), opacity: 0.44),  // warm champagne
        OrbStyle(color: Color(hex: "#FFAA70"), opacity: 0.38),  // peach glint
        OrbStyle(color: Color(hex: "#FFE8CC"), opacity: 0.48),  // pale candlelight
        OrbStyle(color: Color(hex: "#FF8C60"), opacity: 0.36),  // coral flash
        OrbStyle(color: Color(hex: "#FFD4A8"), opacity: 0.42),  // champagne repeat
        OrbStyle(color: Color(hex: "#FFE8CC"), opacity: 0.44),  // soft warm glint
        OrbStyle(color: Color(hex: "#FFAA70"), opacity: 0.36),  // peach shimmer
        OrbStyle(color: Color(hex: "#FF8C60"), opacity: 0.40),  // coral echo
    ]

    private static let orangeBaseGradient = LinearGradient(
        colors: [
            Color(hex: "#0A0402"),
            Color(hex: "#0D0503"),
            Color(hex: "#080300"),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Gold theme orb styles — warm gold, amber, and champagne tones
    private static let goldOrbStyles: [OrbStyle] = [
        OrbStyle(color: Color(hex: "#F5C451"), opacity: 0.52),  // bright gold
        OrbStyle(color: Color(hex: "#D4A017"), opacity: 0.44),  // deep gold
        OrbStyle(color: Color(hex: "#FFE08A"), opacity: 0.38),  // champagne
        OrbStyle(color: Color(hex: "#C8860A"), opacity: 0.40),  // amber
        OrbStyle(color: Color(hex: "#FFF0A0"), opacity: 0.30),  // pale glint
        OrbStyle(color: Color(hex: "#E8A020"), opacity: 0.46),  // warm amber
    ]

    // Each orb owns a dedicated screen zone and its path stays within that
    // zone so no two orbs ever converge. The screen is divided into six
    // non-overlapping territories: TL, TR, ML, MR, BL, BR. Each orb
    // bounces within its territory only — the from/to coordinates are both
    // inside the same half of the screen so paths never cross through the
    // center simultaneously. Sizes are reduced and blur increased to soften
    // the halo, further reducing visible overlap at zone boundaries.
    private let orbs: [Orb] = [
        Orb(size: 280, blur: 120, fromX: 0.05, fromY: 0.04, toX: 0.40, toY: 0.30),
        Orb(size: 260, blur: 115, fromX: 0.62, fromY: 0.04, toX: 0.94, toY: 0.28),
        Orb(size: 240, blur: 125, fromX: 0.02, fromY: 0.38, toX: 0.35, toY: 0.62),
        Orb(size: 220, blur: 118, fromX: 0.64, fromY: 0.36, toX: 0.96, toY: 0.64),
        Orb(size: 250, blur: 122, fromX: 0.04, fromY: 0.68, toX: 0.40, toY: 0.94),
        Orb(size: 220, blur: 118, fromX: 0.60, fromY: 0.70, toX: 0.94, toY: 0.96),
    ]

    // Gold sparkle positions — smaller, sharper, more numerous
    private let sparkles: [Orb] = [
        Orb(size: 80,  blur: 28, fromX: 0.15, fromY: 0.08, toX: 0.30, toY: 0.20),
        Orb(size: 60,  blur: 22, fromX: 0.70, fromY: 0.12, toX: 0.85, toY: 0.06),
        Orb(size: 70,  blur: 25, fromX: 0.45, fromY: 0.30, toX: 0.55, toY: 0.18),
        Orb(size: 50,  blur: 18, fromX: 0.10, fromY: 0.50, toX: 0.22, toY: 0.42),
        Orb(size: 90,  blur: 32, fromX: 0.78, fromY: 0.45, toX: 0.88, toY: 0.55),
        Orb(size: 65,  blur: 24, fromX: 0.35, fromY: 0.65, toX: 0.50, toY: 0.75),
        Orb(size: 55,  blur: 20, fromX: 0.60, fromY: 0.80, toX: 0.72, toY: 0.70),
        Orb(size: 75,  blur: 26, fromX: 0.20, fromY: 0.85, toX: 0.08, toY: 0.92),
    ]

    // Tiny point-flash positions — scattered across the whole screen.
    // These flash in and out independently, simulating glitter/diamond sparkle.
    // Stored as normalized (x, y) unit fractions, same convention as Orb.
    fileprivate let goldPointSparkles: [(x: CGFloat, y: CGFloat)] = [
        (0.12, 0.07), (0.78, 0.11), (0.35, 0.04), (0.55, 0.19),
        (0.88, 0.28), (0.08, 0.33), (0.48, 0.38), (0.22, 0.52),
        (0.68, 0.47), (0.91, 0.58), (0.30, 0.63), (0.15, 0.72),
        (0.60, 0.68), (0.82, 0.76), (0.40, 0.82), (0.72, 0.90),
        (0.05, 0.88), (0.50, 0.95), (0.25, 0.20), (0.65, 0.33),
    ]

    // Night theme — dense star field covering the full screen.
    // More stars than gold sparkles, spread edge-to-edge.
    fileprivate let nightStarPositions: [(x: CGFloat, y: CGFloat)] = [
        // Spread field — visible at top and between cards
        (0.05, 0.03), (0.20, 0.08), (0.42, 0.02), (0.63, 0.06), (0.80, 0.04), (0.94, 0.10),
        (0.12, 0.14), (0.33, 0.11), (0.57, 0.16), (0.75, 0.12), (0.90, 0.19),
        (0.03, 0.23), (0.28, 0.26), (0.48, 0.22), (0.70, 0.29), (0.87, 0.24),
        (0.18, 0.35), (0.40, 0.32), (0.60, 0.38), (0.82, 0.33), (0.95, 0.40),
        (0.07, 0.44), (0.25, 0.48), (0.52, 0.45), (0.73, 0.43), (0.88, 0.50),
        (0.15, 0.56), (0.37, 0.53), (0.62, 0.58), (0.80, 0.55), (0.96, 0.60),
        (0.04, 0.64), (0.22, 0.67), (0.45, 0.62), (0.68, 0.66), (0.85, 0.70),
        (0.10, 0.75), (0.32, 0.72), (0.55, 0.76), (0.78, 0.73), (0.93, 0.78),
        (0.02, 0.84), (0.20, 0.80), (0.42, 0.85), (0.65, 0.82), (0.83, 0.87),
        (0.12, 0.91), (0.35, 0.94), (0.57, 0.90), (0.75, 0.96), (0.92, 0.93),

        // Left-edge column — peek out beside post cards while scrolling
        (0.02, 0.06), (0.04, 0.18), (0.01, 0.31), (0.03, 0.42), (0.02, 0.52),
        (0.05, 0.61), (0.01, 0.70), (0.04, 0.79), (0.02, 0.88), (0.03, 0.95),
        (0.06, 0.12), (0.01, 0.25), (0.05, 0.37), (0.02, 0.47), (0.04, 0.57),
        (0.01, 0.66), (0.03, 0.74), (0.05, 0.83), (0.02, 0.91),

        // Right-edge column — mirror of the left
        (0.98, 0.06), (0.96, 0.18), (0.99, 0.31), (0.97, 0.42), (0.98, 0.52),
        (0.95, 0.61), (0.99, 0.70), (0.96, 0.79), (0.98, 0.88), (0.97, 0.95),
        (0.94, 0.12), (0.99, 0.25), (0.95, 0.37), (0.98, 0.47), (0.96, 0.57),
        (0.99, 0.66), (0.97, 0.74), (0.95, 0.83), (0.98, 0.91),
    ]

    private static let sparkleStyles: [OrbStyle] = [
        OrbStyle(color: Color(hex: "#FFF8C0"), opacity: 0.90),
        OrbStyle(color: Color(hex: "#F5C451"), opacity: 0.85),
        OrbStyle(color: Color(hex: "#FFFFFF"), opacity: 0.95),
        OrbStyle(color: Color(hex: "#FFE08A"), opacity: 0.80),
        OrbStyle(color: Color(hex: "#F5C451"), opacity: 0.88),
        OrbStyle(color: Color(hex: "#FFF8C0"), opacity: 0.92),
        OrbStyle(color: Color(hex: "#FFFFFF"), opacity: 0.78),
        OrbStyle(color: Color(hex: "#FFE08A"), opacity: 0.85),
    ]

    // Sunset sparkle styles — coral, rose, and pale orange glints
    private static let sunsetSparkleStyles: [OrbStyle] = [
        OrbStyle(color: Color(hex: "#FFB347"), opacity: 0.88),  // warm peach
        OrbStyle(color: Color(hex: "#FF6B6B"), opacity: 0.82),  // coral
        OrbStyle(color: Color(hex: "#FFCBA4"), opacity: 0.90),  // pale orange
        OrbStyle(color: Color(hex: "#E84060"), opacity: 0.78),  // rose
        OrbStyle(color: Color(hex: "#FFB347"), opacity: 0.85),  // warm peach
        OrbStyle(color: Color(hex: "#FFCBA4"), opacity: 0.92),  // pale orange
        OrbStyle(color: Color(hex: "#FF6B6B"), opacity: 0.75),  // coral
        OrbStyle(color: Color(hex: "#E84060"), opacity: 0.80),  // rose
    ]

    private static let goldBaseGradient = LinearGradient(
        colors: [
            Color(hex: "#0A0800"),
            Color(hex: "#100C00"),
            Color(hex: "#080600"),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Night theme — pure deep black with a very faint cool-blue tint at the top
    // to evoke the subtle indigo of a real night sky.
    private static let nightBaseGradient = LinearGradient(
        colors: [
            Color(hex: "#00000F"),
            Color(hex: "#000008"),
            Color(hex: "#000000"),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    // Space theme — vivid nebula color washes, dense star field, planets, and shooting stars.
    // Nebula orbs are large and heavily blurred but at higher opacity than before so the
    // purple/blue/magenta color is clearly visible against the black void.
    private static let spaceOrbStyles: [OrbStyle] = [
        OrbStyle(color: Color(hex: "#4A0E9E"), opacity: 0.72),  // vivid violet nebula
        OrbStyle(color: Color(hex: "#0E2A8A"), opacity: 0.65),  // electric deep blue
        OrbStyle(color: Color(hex: "#7A0A60"), opacity: 0.68),  // hot magenta nebula
        OrbStyle(color: Color(hex: "#0A1858"), opacity: 0.62),  // deep navy core
        OrbStyle(color: Color(hex: "#2A0A7A"), opacity: 0.60),  // indigo cloud
        OrbStyle(color: Color(hex: "#5A0A8A"), opacity: 0.58),  // purple-violet bloom
    ]

    private static let spaceBaseGradient = LinearGradient(
        colors: [
            Color(hex: "#000008"),
            Color(hex: "#00000E"),
            Color(hex: "#000005"),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Dense background star field — 70 tiny points for a real galaxy feel
    fileprivate let spaceStarPositions: [(x: CGFloat, y: CGFloat)] = [
        (0.03, 0.02), (0.14, 0.06), (0.28, 0.01), (0.42, 0.05), (0.58, 0.03), (0.72, 0.08), (0.85, 0.02), (0.96, 0.07),
        (0.07, 0.12), (0.20, 0.16), (0.35, 0.10), (0.50, 0.14), (0.65, 0.11), (0.80, 0.17), (0.93, 0.13),
        (0.02, 0.22), (0.18, 0.26), (0.32, 0.20), (0.47, 0.24), (0.63, 0.19), (0.76, 0.27), (0.90, 0.22),
        (0.10, 0.33), (0.25, 0.30), (0.40, 0.36), (0.55, 0.31), (0.70, 0.35), (0.84, 0.29), (0.97, 0.34),
        (0.05, 0.43), (0.22, 0.40), (0.38, 0.46), (0.52, 0.42), (0.67, 0.44), (0.82, 0.39), (0.94, 0.47),
        (0.12, 0.54), (0.28, 0.50), (0.44, 0.56), (0.60, 0.52), (0.75, 0.57), (0.88, 0.51), (0.99, 0.55),
        (0.04, 0.64), (0.19, 0.60), (0.36, 0.66), (0.51, 0.62), (0.66, 0.67), (0.81, 0.61), (0.95, 0.65),
        (0.08, 0.74), (0.24, 0.70), (0.40, 0.76), (0.56, 0.72), (0.71, 0.77), (0.86, 0.71), (0.98, 0.75),
        (0.02, 0.84), (0.16, 0.80), (0.33, 0.86), (0.48, 0.82), (0.63, 0.88), (0.78, 0.83), (0.92, 0.87),
        (0.10, 0.93), (0.26, 0.90), (0.44, 0.95), (0.60, 0.91), (0.76, 0.96), (0.90, 0.92), (0.99, 0.97),
    ]

    // Bright foreground stars — fewer, larger, with a soft glow halo
    fileprivate let spaceBrightStarPositions: [(x: CGFloat, y: CGFloat)] = [
        (0.18, 0.09), (0.74, 0.05), (0.45, 0.22), (0.88, 0.31), (0.08, 0.48),
        (0.62, 0.41), (0.30, 0.65), (0.82, 0.58), (0.52, 0.78), (0.15, 0.85),
        (0.70, 0.88), (0.40, 0.94),
    ]

    // Planets — fixed positions (normalized), each with its own character
    fileprivate let spacePlanetDefs: [(x: CGFloat, y: CGFloat, size: CGFloat, colorHex: String, hasRing: Bool)] = [
        (0.78, 0.18, 38, "#C87A3A", true),   // ringed amber planet, upper right
        (0.14, 0.62, 28, "#3A6AC8", false),  // blue-grey planet, mid left
    ]

    // Distant galaxy smears — tiny elongated blobs at fixed positions
    fileprivate let spaceGalaxyPositions: [(x: CGFloat, y: CGFloat, angle: Double)] = [
        (0.62, 0.15, 28),
        (0.22, 0.42, -15),
        (0.85, 0.68, 40),
    ]

    // Backyard theme — earthy dark greens and warm browns, like a humid summer night outdoors.
    private static let backyardOrbStyles: [OrbStyle] = [
        OrbStyle(color: Color(hex: "#3B5E2A"), opacity: 0.52),  // deep forest green
        OrbStyle(color: Color(hex: "#6B4A1E"), opacity: 0.48),  // warm bark brown
        OrbStyle(color: Color(hex: "#2E4A1A"), opacity: 0.44),  // dark olive green
        OrbStyle(color: Color(hex: "#7A5230"), opacity: 0.42),  // earthy sienna
        OrbStyle(color: Color(hex: "#4A6832"), opacity: 0.40),  // mossy green
        OrbStyle(color: Color(hex: "#5C3C18"), opacity: 0.38),  // deep mahogany
    ]

    private static let backyardBaseGradient = LinearGradient(
        colors: [
            Color(hex: "#080C04"),
            Color(hex: "#0A0D05"),
            Color(hex: "#060804"),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // ─── Forest / Green theme ────────────────────────────────────────────────
    // Deep emerald base with mint and lime orbs — lush, vibrant, alive.
    private static let greenBaseGradient = LinearGradient(
        colors: [
            Color(hex: "#030A04"),
            Color(hex: "#050D05"),
            Color(hex: "#030803"),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static let greenOrbStyles: [OrbStyle] = [
        OrbStyle(color: Color(hex: "#16A34A"), opacity: 0.54),  // emerald
        OrbStyle(color: Color(hex: "#4ADE80"), opacity: 0.40),  // mint glow
        OrbStyle(color: Color(hex: "#065F46"), opacity: 0.50),  // deep forest
        OrbStyle(color: Color(hex: "#86EFAC"), opacity: 0.32),  // pale mint shimmer
        OrbStyle(color: Color(hex: "#15803D"), opacity: 0.46),  // rich green
        OrbStyle(color: Color(hex: "#34D399"), opacity: 0.36),  // teal-green accent
    ]

    // ─── Rose / Pink theme ───────────────────────────────────────────────────
    // Dark berry base with rose, magenta, and blush orbs — bold and electric.
    private static let pinkBaseGradient = LinearGradient(
        colors: [
            Color(hex: "#0A0307"),
            Color(hex: "#0D0408"),
            Color(hex: "#080206"),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static let pinkOrbStyles: [OrbStyle] = [
        OrbStyle(color: Color(hex: "#EC4899"), opacity: 0.54),  // hot pink
        OrbStyle(color: Color(hex: "#BE185D"), opacity: 0.48),  // deep rose
        OrbStyle(color: Color(hex: "#F472B6"), opacity: 0.40),  // blush
        OrbStyle(color: Color(hex: "#9D174D"), opacity: 0.46),  // dark berry
        OrbStyle(color: Color(hex: "#FB7185"), opacity: 0.36),  // coral pink
        OrbStyle(color: Color(hex: "#E879F9"), opacity: 0.38),  // fuchsia accent
    ]

    // ─── Ocean / Blue theme ──────────────────────────────────────────────────
    // Dark navy base with restrained blue/cyan orbs — cool, deep, immersive.
    private static let blueBaseGradient = LinearGradient(
        colors: [
            Color(hex: "#000205"),
            Color(hex: "#01030A"),
            Color(hex: "#000103"),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static let blueOrbStyles: [OrbStyle] = [
        OrbStyle(color: Color(hex: "#1D4ED8"), opacity: 0.42),  // deep vivid blue
        OrbStyle(color: Color(hex: "#0369A1"), opacity: 0.34),  // muted ocean blue
        OrbStyle(color: Color(hex: "#1E40AF"), opacity: 0.40),  // ink blue
        OrbStyle(color: Color(hex: "#0EA5E9"), opacity: 0.26),  // restrained cyan glow
        OrbStyle(color: Color(hex: "#075985"), opacity: 0.38),  // dark ocean blue
        OrbStyle(color: Color(hex: "#22D3EE"), opacity: 0.20),  // subtle aqua shimmer
    ]

    // ─── Speakeasy theme ────────────────────────────────────────────────────
    // Velvet-red folds over midnight black with restrained brass highlights.
    private static let speakeasyBaseGradient = LinearGradient(
        colors: [
            Color(hex: "#030102"),
            Color(hex: "#120307"),
            Color(hex: "#23060C"),
            Color(hex: "#071014"),
            Color(hex: "#020202"),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // Original theme — the MVP-era black canvas with warm bronze glass light.
    private static let originalBaseGradient = LinearGradient(
        colors: [
            Color(hex: "#000000"),
            Color(hex: "#030201"),
            Color(hex: "#090403"),
            Color(hex: "#000000"),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )


    // Firefly positions — dense, spread across full screen like a summer backyard
    fileprivate let backyardFireflyPositions: [(x: CGFloat, y: CGFloat)] = [
        (0.08, 0.06), (0.22, 0.12), (0.45, 0.04), (0.67, 0.09), (0.83, 0.05), (0.95, 0.15),
        (0.14, 0.20), (0.38, 0.17), (0.58, 0.23), (0.76, 0.18), (0.91, 0.26),
        (0.04, 0.32), (0.30, 0.28), (0.52, 0.35), (0.72, 0.30), (0.88, 0.38),
        (0.18, 0.44), (0.42, 0.40), (0.63, 0.47), (0.80, 0.42), (0.96, 0.50),
        (0.06, 0.55), (0.28, 0.52), (0.50, 0.58), (0.74, 0.54), (0.90, 0.62),
        (0.16, 0.68), (0.36, 0.64), (0.60, 0.70), (0.82, 0.66), (0.94, 0.74),
        (0.02, 0.78), (0.24, 0.75), (0.48, 0.80), (0.68, 0.77), (0.86, 0.82),
        (0.12, 0.88), (0.34, 0.85), (0.56, 0.91), (0.78, 0.87), (0.92, 0.94),
    ]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                switch backgroundTheme {
                case .night:
                    Self.nightBaseGradient

                    // Star field — tiny white point flashes, no large orbs
                    ForEach(Array(nightStarPositions.enumerated()), id: \.offset) { index, pt in
                        NightStarFlash(position: pt, index: index, screenSize: geo.size)
                    }

                case .orange:
                    Self.orangeBaseGradient

                    ForEach(Array(orbs.enumerated()), id: \.offset) { index, orb in
                        AnimatedOrb(
                            orb: Orb(
                                size: orb.size * 1.6,
                                blur: orb.blur * 2.2,
                                fromX: orb.fromX,
                                fromY: orb.fromY,
                                toX: orb.toX,
                                toY: orb.toY
                            ),
                            style: Self.orangeOrbStyles[index],
                            index: index,
                            screenSize: geo.size
                        )
                    }

                    ForEach(Array(sparkles.enumerated()), id: \.offset) { index, sparkle in
                        TwinklingSparkle(
                            orb: Orb(
                                size: sparkle.size * 1.4,
                                blur: sparkle.blur * 2.0,
                                fromX: sparkle.fromX,
                                fromY: sparkle.fromY,
                                toX: sparkle.toX,
                                toY: sparkle.toY
                            ),
                            style: Self.orangeSparkleStyles[index],
                            index: index,
                            screenSize: geo.size
                        )
                    }

                    Rectangle()
                        .fill(.black.opacity(0.20))

                case .green:
                    Self.greenBaseGradient

                    ForEach(Array(orbs.enumerated()), id: \.offset) { index, orb in
                        AnimatedOrb(
                            orb: orb,
                            style: Self.greenOrbStyles[index],
                            index: index,
                            screenSize: geo.size
                        )
                    }

                    Rectangle()
                        .fill(.black.opacity(0.22))

                case .pink:
                    Self.pinkBaseGradient

                    ForEach(Array(orbs.enumerated()), id: \.offset) { index, orb in
                        AnimatedOrb(
                            orb: orb,
                            style: Self.pinkOrbStyles[index],
                            index: index,
                            screenSize: geo.size
                        )
                    }

                    Rectangle()
                        .fill(.black.opacity(0.24))

                case .blue:
                    Self.blueBaseGradient

                    ForEach(Array(orbs.enumerated()), id: \.offset) { index, orb in
                        AnimatedOrb(
                            orb: orb,
                            style: Self.blueOrbStyles[index],
                            index: index,
                            screenSize: geo.size
                        )
                    }

                    Rectangle()
                        .fill(.black.opacity(0.28))

                case .standard:
                    StandardNightlifeBackdrop(screenSize: geo.size, phase: defaultPhase)

                case .original, .speakeasy:
                    AppTheme.backgroundGradient

                    ForEach(Array(orbs.enumerated()), id: \.offset) { index, orb in
                        AnimatedOrb(
                            orb: orb,
                            style: Self.launchOrbStyles[index],
                            index: index,
                            screenSize: geo.size
                        )
                    }

                    Rectangle()
                        .fill(.black.opacity(0.52))

                }
            }
            // GeometryReader positions children at (0,0) top-left by default.
            // Giving the ZStack an explicit frame matching geo.size forces it to
            // fill the full reader area so that all offset-from-center calculations
            // (used by every star, orb, planet, and firefly) resolve correctly
            // relative to the actual screen center rather than the top-left corner.
            .frame(width: geo.size.width, height: geo.size.height)
            .modifier(BackgroundThemeCrossfade(theme: backgroundTheme))
        }
        .ignoresSafeArea()
    }
}

/// Separate pools of colored light keep the default theme vivid through glass.
/// A radial falloff avoids the muddy overlap of heavily blurred, clamped circles.
private struct StandardNightlifeBackdrop: View {
    let screenSize: CGSize
    let phase: DefaultBackgroundPhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Light {
        let color: Color
        let position: UnitPoint
        let intensity: Double
    }

    private let lights: [Light] = [
        Light(color: Color(hex: "#2463FF"), position: UnitPoint(x: 0.10, y: 0.13), intensity: 0.55),
        Light(color: Color(hex: "#FF286E"), position: UnitPoint(x: 0.94, y: 0.17), intensity: 0.48),
        Light(color: Color(hex: "#00D89C"), position: UnitPoint(x: 0.03, y: 0.47), intensity: 0.39),
        Light(color: Color(hex: "#7848FF"), position: UnitPoint(x: 0.95, y: 0.51), intensity: 0.50),
        Light(color: Color(hex: "#F52F73"), position: UnitPoint(x: 0.12, y: 0.86), intensity: 0.39),
        Light(color: Color(hex: "#13C881"), position: UnitPoint(x: 0.94, y: 0.91), intensity: 0.36),
    ]

    var body: some View {
        let radius = min(screenSize.width, screenSize.height) * phase.lightRadius

        ZStack {
            Color.black

            ForEach(lights.indices, id: \.self) { index in
                let light = lights[index]
                Circle()
                    .fill(RadialGradient(
                        stops: [
                            .init(color: light.color.opacity(light.intensity), location: 0),
                            .init(color: light.color.opacity(light.intensity * 0.78), location: 0.24),
                            .init(color: light.color.opacity(light.intensity * 0.30), location: 0.58),
                            .init(color: light.color.opacity(0), location: 1),
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: radius
                    ))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(x: screenSize.width * light.position.x, y: screenSize.height * light.position.y)
                    .opacity(phase.lightIntensity)
                    .blendMode(.screen)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.20), value: phase)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct OriginalBackdrop: View {
    let screenSize: CGSize

    var body: some View {
        ZStack {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            Color(hex: "#B56B35").opacity(0.22),
                            Color(hex: "#6B351C").opacity(0.14),
                            .clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: screenSize.width * 1.35, height: screenSize.height * 0.48)
                .rotationEffect(.degrees(-8))
                .offset(x: screenSize.width * 0.10, y: screenSize.height * 0.14)
                .blur(radius: 56)
                .blendMode(.screen)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .clear,
                            Color(hex: "#E0A35D").opacity(0.12),
                            .clear,
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: screenSize.width * 1.08, height: screenSize.height * 0.38)
                .offset(y: screenSize.height * 0.30)
                .blur(radius: 44)
                .blendMode(.screen)

            HStack(spacing: screenSize.width * 0.055) {
                ForEach(0..<7, id: \.self) { index in
                    Rectangle()
                        .fill(Color.white.opacity(index.isMultiple(of: 2) ? 0.030 : 0.016))
                        .frame(width: screenSize.width * 0.075, height: screenSize.height * 1.12)
                }
            }
            .rotationEffect(.degrees(8))
            .offset(x: -screenSize.width * 0.08)
            .blendMode(.overlay)
            .opacity(0.55)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            .black.opacity(0.66),
                            .clear,
                            .black.opacity(0.74),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }
}

private struct SpeakeasyVelvetBackdrop: View {
    let screenSize: CGSize

    private let foldCount = 9

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ForEach(0..<foldCount, id: \.self) { index in
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: foldColors(for: index),
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: screenSize.width / CGFloat(foldCount))
                        .opacity(index.isMultiple(of: 2) ? 0.34 : 0.22)
                }
            }
            .blendMode(.screen)
            .opacity(0.44)

            Canvas { context, size in
                let spacing = max(size.width / 18, 18)
                for x in stride(from: -spacing, through: size.width + spacing, by: spacing) {
                    var stripe = Path()
                    stripe.move(to: CGPoint(x: x, y: 0))
                    stripe.addLine(to: CGPoint(x: x + size.height * 0.14, y: size.height))
                    context.stroke(stripe, with: .color(Color.white.opacity(0.035)), lineWidth: 0.7)
                }
            }
            .blendMode(.overlay)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.clear,
                            Color(hex: "#C8A45D").opacity(0.16),
                            Color.clear,
                        ],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    )
                )
                .blendMode(.screen)

            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: "#6E1625").opacity(0.38),
                            Color.clear,
                        ],
                        center: .topLeading,
                        startRadius: 18,
                        endRadius: max(screenSize.width, screenSize.height) * 0.82
                    )
                )
                .blendMode(.screen)

            Rectangle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: "#071A1D").opacity(0.46),
                            Color.clear,
                        ],
                        center: .bottomTrailing,
                        startRadius: 24,
                        endRadius: max(screenSize.width, screenSize.height) * 0.76
                    )
                )
                .blendMode(.screen)

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.34),
                            Color.clear,
                            Color.black.opacity(0.52),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }

    private func foldColors(for index: Int) -> [Color] {
        if index.isMultiple(of: 3) {
            return [
                Color(hex: "#3A0711").opacity(0.24),
                Color(hex: "#7A1A2A").opacity(0.40),
                Color(hex: "#150307").opacity(0.18),
            ]
        }

        if index.isMultiple(of: 2) {
            return [
                Color(hex: "#1B0509").opacity(0.18),
                Color(hex: "#4C0C18").opacity(0.34),
                Color(hex: "#080203").opacity(0.20),
            ]
        }

        return [
            Color(hex: "#050203").opacity(0.18),
            Color(hex: "#260711").opacity(0.28),
            Color(hex: "#040304").opacity(0.22),
        ]
    }
}

/// Renders one static orb at the midpoint of its old drift path. Keeping the
/// `AnimatedOrb` name avoids touching every theme call site, but the view no
/// longer runs a repeating position animation.
private struct AnimatedOrb: View {
    let orb: AmbientBackground.Orb
    let style: AmbientBackground.OrbStyle
    let index: Int
    let screenSize: CGSize
    var clamp: Bool = true

    // Resolve a unit-fraction position to a screen-space offset from center.
    // When clamp is true the orb edge is kept within the screen boundary.
    // When clamp is false the raw mapping is used so nebulas can drift across
    // the full width without being pinched toward the safe interior.
    private func resolvedOffset(unitX: CGFloat, unitY: CGFloat) -> CGSize {
        let rawX = (unitX - 0.5) * screenSize.width
        let rawY = (unitY - 0.5) * screenSize.height

        guard clamp else {
            return CGSize(width: rawX, height: rawY)
        }

        let halfOrb = orb.size / 2
        let minX = halfOrb - screenSize.width / 2
        let maxX = screenSize.width / 2 - halfOrb
        let minY = halfOrb - screenSize.height / 2
        let maxY = screenSize.height / 2 - halfOrb

        return CGSize(
            width:  min(max(rawX, minX), maxX),
            height: min(max(rawY, minY), maxY)
        )
    }

    var body: some View {
        let midX = (orb.fromX + orb.toX) / 2
        let midY = (orb.fromY + orb.toY) / 2
        let offset = resolvedOffset(unitX: midX, unitY: midY)

        Circle()
            .fill(style.color.opacity(style.opacity))
            .frame(width: orb.size, height: orb.size)
            .blur(radius: orb.blur)
            .offset(x: offset.width, y: offset.height)
    }
}

/// A sparkle that stays fixed in place. Non-night backgrounds avoid repeating
/// animations so the feed can scroll without background work competing for frames.
private struct TwinklingSparkle: View {
    let orb: AmbientBackground.Orb
    let style: AmbientBackground.OrbStyle
    let index: Int
    let screenSize: CGSize

    var body: some View {
        AnimatedOrb(orb: orb, style: style, index: index + 6, screenSize: screenSize)
    }
}

/// A tiny bright point that reads as glitter without running an opacity loop.
private struct GoldPointFlash: View {
    let position: (x: CGFloat, y: CGFloat)
    let index: Int
    let screenSize: CGSize

    private var resolvedOffset: CGSize {
        CGSize(
            width:  (position.x - 0.5) * screenSize.width,
            height: (position.y - 0.5) * screenSize.height
        )
    }

    // Alternate between a warm white and champagne so each point has its
    // own character rather than all flashing the same color.
    private var pointColor: Color {
        index % 3 == 0 ? Color(hex: "#FFFFFF") :
        index % 3 == 1 ? Color(hex: "#FFF8C0") :
                         Color(hex: "#F5C451")
    }

    private var pointOpacity: Double {
        index % 4 == 0 ? 0.82 :
        index % 4 == 1 ? 0.68 :
        index % 4 == 2 ? 0.74 :
                         0.58
    }

    var body: some View {
        Circle()
            .fill(pointColor)
            .frame(width: 4, height: 4)
            .blur(radius: 1.5)
            .opacity(pointOpacity)
            .offset(x: resolvedOffset.width, y: resolvedOffset.height)
    }
}

/// A tiny static star point. Opacity and scale are seeded pseudo-randomly
/// from the index so the field looks natural without any running animations.
private struct NightStarFlash: View {
    let position: (x: CGFloat, y: CGFloat)
    let index: Int
    let screenSize: CGSize
    var animates: Bool = false  // kept for call-site compatibility, ignored

    private var resolvedOffset: CGSize {
        CGSize(
            width:  (position.x - 0.5) * screenSize.width,
            height: (position.y - 0.5) * screenSize.height
        )
    }

    private var starColor: Color {
        index % 4 == 0 ? Color(hex: "#FFFFFF") :
        index % 4 == 1 ? Color(hex: "#D0E8FF") :
        index % 4 == 2 ? Color(hex: "#E8F4FF") :
                         Color(hex: "#FFFFFF")
    }

    private var starSize: CGFloat {
        index % 5 == 0 ? 3.5 :
        index % 5 == 1 ? 2.5 :
        index % 5 == 2 ? 4.0 :
        index % 5 == 3 ? 2.0 :
                         3.0
    }

    private var staticOpacity: Double {
        let peak: Double = index % 5 == 0 ? 0.95 :
                           index % 5 == 1 ? 0.60 :
                           index % 5 == 2 ? 0.80 :
                           index % 5 == 3 ? 0.45 : 0.88
        let fraction = Double((index * 37 + 11) % 100) / 100.0
        return 0.15 + fraction * peak
    }

    private var staticScale: CGFloat {
        let fraction = Double((index * 37 + 11) % 100) / 100.0
        return 0.5 + fraction * 0.5
    }

    var body: some View {
        Circle()
            .fill(starColor)
            .frame(width: starSize, height: starSize)
            .blur(radius: starSize > 3 ? 0.8 : 0.4)
            .scaleEffect(staticScale)
            .opacity(staticOpacity)
            .offset(x: resolvedOffset.width, y: resolvedOffset.height)
    }
}

/// A planet with a soft atmospheric glow and an optional ring.
/// Sits at a fixed position — planets don't drift, they hang in the void.
private struct SpacePlanet: View {
    let position: (x: CGFloat, y: CGFloat)
    let size: CGFloat
    let colorHex: String
    let hasRing: Bool
    let screenSize: CGSize

    private var resolvedOffset: CGSize {
        CGSize(
            width:  (position.x - 0.5) * screenSize.width,
            height: (position.y - 0.5) * screenSize.height
        )
    }

    var body: some View {
        ZStack {
            // Atmospheric glow — soft halo around the planet
            Circle()
                .fill(Color(hex: colorHex).opacity(0.25))
                .frame(width: size * 2.8, height: size * 2.8)
                .blur(radius: size * 0.9)

            // Ring — slightly wider ellipse rotated behind the planet
            if hasRing {
                Ellipse()
                    .fill(Color(hex: colorHex).opacity(0.0))
                    .frame(width: size * 2.4, height: size * 0.5)
                    .overlay(
                        Ellipse()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color(hex: colorHex).opacity(0.70),
                                        Color(hex: colorHex).opacity(0.30),
                                        Color(hex: colorHex).opacity(0.55),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                lineWidth: size * 0.12
                            )
                    )
                    .rotationEffect(.degrees(-18))
                    .blur(radius: 0.8)
            }

            // Planet body — radial gradient for a lit-from-upper-left look
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(hex: colorHex).opacity(0.95),
                            Color(hex: colorHex).opacity(0.60),
                            Color(hex: colorHex).opacity(0.30),
                        ],
                        center: UnitPoint(x: 0.35, y: 0.30),
                        startRadius: 0,
                        endRadius: size * 0.9
                    )
                )
                .frame(width: size, height: size)
                .blur(radius: 0.5)
        }
        .offset(x: resolvedOffset.width, y: resolvedOffset.height)
    }
}

/// A tiny distant galaxy — a small elongated smear of pale blue-white light,
/// slightly rotated to suggest depth and structure in the void.
private struct SpaceGalaxySmear: View {
    let position: (x: CGFloat, y: CGFloat)
    let angle: Double
    let index: Int
    let screenSize: CGSize

    private var resolvedOffset: CGSize {
        CGSize(
            width:  (position.x - 0.5) * screenSize.width,
            height: (position.y - 0.5) * screenSize.height
        )
    }

    private var glowOpacity: Double {
        index % 3 == 0 ? 0.82 :
        index % 3 == 1 ? 0.66 :
                         0.74
    }

    var body: some View {
        ZStack {
            // Outer soft halo
            Ellipse()
                .fill(Color(hex: "#A0B8FF").opacity(0.12))
                .frame(width: 48, height: 14)
                .blur(radius: 6)

            // Inner brighter core
            Ellipse()
                .fill(Color(hex: "#C8D8FF").opacity(0.28))
                .frame(width: 28, height: 7)
                .blur(radius: 2.5)

            // Bright nucleus
            Ellipse()
                .fill(Color.white.opacity(0.55))
                .frame(width: 6, height: 3)
                .blur(radius: 0.8)
        }
        .rotationEffect(.degrees(angle))
        .opacity(glowOpacity)
        .offset(x: resolvedOffset.width, y: resolvedOffset.height)
    }
}

/// A firefly-style warm yellow-green point. Kept static for the non-night
/// background performance budget.
private struct FireflyFlash: View {
    let position: (x: CGFloat, y: CGFloat)
    let index: Int
    let screenSize: CGSize

    private var resolvedOffset: CGSize {
        CGSize(
            width:  (position.x - 0.5) * screenSize.width,
            height: (position.y - 0.5) * screenSize.height
        )
    }

    // Warm yellow, yellow-green, and pale chartreuse — real firefly palette
    private var fireflyColor: Color {
        index % 3 == 0 ? Color(hex: "#E8D44D") :   // warm yellow
        index % 3 == 1 ? Color(hex: "#C8E040") :   // yellow-green
                         Color(hex: "#F0E060")      // pale gold-yellow
    }

    private var fireflySize: CGFloat {
        index % 4 == 0 ? 4.5 :
        index % 4 == 1 ? 3.5 :
        index % 4 == 2 ? 5.0 :
                         3.0
    }

    private var peakOpacity: Double {
        index % 4 == 0 ? 0.92 :
        index % 4 == 1 ? 0.70 :
        index % 4 == 2 ? 0.80 :
                         0.55
    }

    var body: some View {
        Circle()
            .fill(fireflyColor)
            .frame(width: fireflySize, height: fireflySize)
            .blur(radius: 1.8)
            .opacity(peakOpacity)
            .offset(x: resolvedOffset.width, y: resolvedOffset.height)
    }
}

/// A bright foreground star with a soft glow halo — layered circle + blurred halo
/// to simulate stars that are close enough to show apparent size against the void.
private struct SpaceBrightStar: View {
    let position: (x: CGFloat, y: CGFloat)
    let index: Int
    let screenSize: CGSize

    private let opacity: Double
    private let glowOpacity: Double

    init(position: (x: CGFloat, y: CGFloat), index: Int, screenSize: CGSize) {
        self.position = position
        self.index = index
        self.screenSize = screenSize
        // Scatter initial state so all bright stars are visible immediately.
        let fraction = Double((index * 53 + 17) % 100) / 100.0
        let peak: Double = index % 3 == 0 ? 1.0 : index % 3 == 1 ? 0.90 : 0.95
        opacity = 0.3 + fraction * peak
        glowOpacity = 0.2 + fraction * 0.8
    }

    private var resolvedOffset: CGSize {
        CGSize(
            width:  (position.x - 0.5) * screenSize.width,
            height: (position.y - 0.5) * screenSize.height
        )
    }

    // Mix of pure white, faint blue-white, and warm white — real star color temperatures
    private var starColor: Color {
        index % 4 == 0 ? Color(hex: "#FFFFFF") :
        index % 4 == 1 ? Color(hex: "#C8DCFF") :   // blue-white (hot star)
        index % 4 == 2 ? Color(hex: "#FFF4E0") :   // warm white (cooler star)
                         Color(hex: "#E0EEFF")      // pale blue
    }

    private var glowColor: Color {
        index % 4 == 0 ? Color(hex: "#8899FF") :
        index % 4 == 1 ? Color(hex: "#6688FF") :
        index % 4 == 2 ? Color(hex: "#FF9944") :
                         Color(hex: "#7799FF")
    }

    private var coreSize: CGFloat {
        index % 3 == 0 ? 4.5 : index % 3 == 1 ? 5.5 : 4.0
    }

    var body: some View {
        ZStack {
            // Soft glow halo
            Circle()
                .fill(glowColor.opacity(0.35))
                .frame(width: coreSize * 5, height: coreSize * 5)
                .blur(radius: coreSize * 2.5)
                .opacity(glowOpacity)

            // Sharp core point
            Circle()
                .fill(starColor)
                .frame(width: coreSize, height: coreSize)
                .blur(radius: 0.5)
                .opacity(opacity)
        }
        .offset(x: resolvedOffset.width, y: resolvedOffset.height)
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
        // (e.g. prominent permission pitches with a warm-gold hint).
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
        // NightPanel maps to the primary glass tier. It rolls its own
        // .glassEffect call instead of using `.primaryGlass(in:)` so it can
        // pass through the optional accent tint and interactive flag —
        // shared modifier doesn't expose those. Keep the fill/stroke values
        // in sync with PrimaryGlassModifier (0.05 / 0.10).
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .glassEffect(.regular.tint(tint).interactive(interactive), in: .rect(cornerRadius: cornerRadius))
    }
}

// MARK: - Glass tier system
//
// The app uses two semantic tiers of liquid glass:
//
//   • PRIMARY  (0.05 fill, 0.10 stroke) — the default surface chrome.
//     Cards, panels, search fields, toolbar buttons, post overlays. Reads
//     as the most transparent option and lets system glass dominate.
//
//   • SECONDARY (0.09 fill, 0.14 stroke) — selection-indication chrome.
//     The pill behind the active tab bar item; the active option in any
//     mode toggle or segmented control. Needs to read as more present
//     than primary so the user can locate themselves at a glance, while
//     still being glass.
//
// Use `.primaryGlass(in:)` / `.secondaryGlass(in:)` instead of writing
// `.background(.white.opacity(...)) + .overlay(strokeBorder) + .glassEffect`
// triplets at every call site. Centralizing here means one place to tune
// the system, and a clear semantic contract at the call site about which
// tier a surface belongs to.

/// Geometry for a glass surface. Supports the three shapes used across
/// the app: capsule, rounded rect with explicit corner radius, and circle.
enum GlassShape {
    case capsule
    case roundedRect(cornerRadius: CGFloat)
    case circle
}

private struct PrimaryGlassModifier: ViewModifier {
    let shape: GlassShape
    let interactive: Bool

    func body(content: Content) -> some View {
        switch shape {
        case .capsule:
            content
                .background(.white.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                .glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        case .roundedRect(let radius):
            content
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
                .glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: radius))
        case .circle:
            content
                .background(.white.opacity(0.05), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                .glassEffect(interactive ? .regular.interactive() : .regular, in: .circle)
        }
    }
}

private struct SecondaryGlassModifier: ViewModifier {
    let shape: GlassShape
    let interactive: Bool

    func body(content: Content) -> some View {
        switch shape {
        case .capsule:
            content
                .background(.white.opacity(0.09), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        case .roundedRect(let radius):
            content
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
                .glassEffect(interactive ? .regular.interactive() : .regular, in: .rect(cornerRadius: radius))
        case .circle:
            content
                .background(.white.opacity(0.09), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .glassEffect(interactive ? .regular.interactive() : .regular, in: .circle)
        }
    }
}

extension View {
    /// Pushed Duo pages share their title treatment with the main panes.
    /// Regular iPhones retain their native inline navigation title.
    func appSecondaryPageNavigation(title: String, isScrolled: Bool = false) -> some View {
        modifier(AppSecondaryPageNavigation(title: title, isScrolled: isScrolled))
    }

    /// Fades the clipped edges of a horizontal ScrollView only while there is
    /// hidden content in that direction.
    func horizontalScrollEdgeFade(width: CGFloat = 48, tolerance: CGFloat = 4) -> some View {
        modifier(HorizontalScrollEdgeFadeModifier(fadeWidth: width, edgeTolerance: tolerance))
    }

    /// Applies the primary glass tier (most transparent — used for default
    /// surface chrome like cards, panels, toolbar buttons, post overlays).
    func primaryGlass(in shape: GlassShape, interactive: Bool = false) -> some View {
        modifier(PrimaryGlassModifier(shape: shape, interactive: interactive))
    }

    /// Applies the secondary glass tier (more present — used for
    /// selection-indication chrome like the active tab capsule or the
    /// active option in a mode toggle).
    func secondaryGlass(in shape: GlassShape, interactive: Bool = true) -> some View {
        modifier(SecondaryGlassModifier(shape: shape, interactive: interactive))
    }

    /// Adds breathing room between the sheet's drag indicator and the first
    /// piece of content inside the sheet. iOS draws the drag handle at a
    /// fixed offset from the sheet's top edge with no public API to move it,
    /// so we push the content down instead. Apply this to the root view of
    /// every sheet body where `.presentationDragIndicator(.visible)` is set.
    /// The 14pt value matches the breathing room iOS-native apps like
    /// Instagram and Photos use, where the drag handle reads as decorative
    /// rather than crowding the first headline or avatar.
    func appSheetDragIndicatorInset() -> some View {
        padding(.top, 14)
    }

    /// Shows the native system sheet grabber. UIKit owns the grabber's pan
    /// gesture, so keeping this native preserves the expected Apple sheet
    /// behavior across the app.
    func appSheetDragHandle(contentWidth: CGFloat = AppLayout.phoneColumnMaximumWidth) -> some View {
        modifier(AppSheetDragHandleModifier())
            .modifier(DuoPanePresentation(compactWidth: contentWidth))
    }

    /// Lets pushed destinations inside a sheet hide the decorative sheet
    /// handle so they read as real navigation pages instead of nested sheets.
    func appSheetDragHandleHidden(_ hidden: Bool = true) -> some View {
        preference(key: AppSheetDragHandleHiddenPreferenceKey.self, value: hidden)
    }
}

private struct HorizontalScrollEdgeFadeState: Equatable {
    let offset: CGFloat
    let maxOffset: CGFloat
}

private struct HorizontalScrollEdgeFadeModifier: ViewModifier {
    let fadeWidth: CGFloat
    let edgeTolerance: CGFloat

    @State private var scrollOffset: CGFloat = 0
    @State private var maxScrollOffset: CGFloat = 0

    private var isOverflowing: Bool { maxScrollOffset > edgeTolerance }
    private var shouldFadeLeading: Bool { isOverflowing && scrollOffset > edgeTolerance }
    private var shouldFadeTrailing: Bool { isOverflowing && scrollOffset < maxScrollOffset - edgeTolerance }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: HorizontalScrollEdgeFadeState.self) { geometry in
                let offset = max(0, geometry.contentOffset.x + geometry.contentInsets.leading)
                let maxOffset = max(
                    0,
                    geometry.contentSize.width
                        + geometry.contentInsets.leading
                        + geometry.contentInsets.trailing
                        - geometry.containerSize.width
                )

                return HorizontalScrollEdgeFadeState(
                    offset: min(offset, maxOffset),
                    maxOffset: maxOffset
                )
            } action: { _, newValue in
                scrollOffset = newValue.offset
                maxScrollOffset = newValue.maxOffset
            }
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: shouldFadeLeading ? fadeWidth : 0)
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: shouldFadeTrailing ? fadeWidth : 0)
                }
            }
    }
}

private struct AppSheetDragHandleHiddenPreferenceKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

private struct AppSheetDragHandleModifier: ViewModifier {
    @State private var isHandleHidden = false

    func body(content: Content) -> some View {
        content
            .presentationDragIndicator(isHandleHidden ? .hidden : .visible)
            .onPreferenceChange(AppSheetDragHandleHiddenPreferenceKey.self) { hidden in
                isHandleHidden = hidden
            }
    }
}

struct SectionEyebrow: View {
    @Environment(\.appAccent) private var accent
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(AppTypography.metadataEmphasis)
                .foregroundStyle(accent.opacity(0.86))
                .tracking(1.8)
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(AppTypography.sectionTitle)
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
        .font(AppTypography.chipEmphasis)
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

// MARK: - Background Theme Environment Key

/// Two lifecycle treatments of the same saved default theme. Default Background
/// 1 welcomes people in; Default Background 2 lets their friends' content lead.
enum DefaultBackgroundPhase {
    case default1
    case default2

    var lightIntensity: Double {
        self == .default1 ? 1 : 0.42
    }

    /// The centers stay fixed; only the pools of light contract as loading ends.
    /// Smaller radii leave real black space between neighboring bar lights.
    var lightRadius: CGFloat { self == .default1 ? 0.62 : 0.36 }
}

private struct DefaultBackgroundPhaseKey: EnvironmentKey {
    static let defaultValue: DefaultBackgroundPhase = .default1
}

struct AppBackgroundThemeKey: EnvironmentKey {
    static let defaultValue: BackgroundTheme = .standard
}

extension EnvironmentValues {
    var defaultBackgroundPhase: DefaultBackgroundPhase {
        get { self[DefaultBackgroundPhaseKey.self] }
        set { self[DefaultBackgroundPhaseKey.self] = newValue }
    }

    var appBackgroundTheme: BackgroundTheme {
        get { self[AppBackgroundThemeKey.self] }
        set { self[AppBackgroundThemeKey.self] = newValue }
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
