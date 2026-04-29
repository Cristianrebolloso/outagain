import CoreLocation
import SwiftUI
import UIKit

extension Date {
    /// Human-readable relative time at minute granularity — "Just now" for
    /// anything under a minute, then "5 min ago", "2 hr ago", etc. Used by
    /// activity surfaces where second-by-second precision reads as jitter
    /// rather than signal.
    var minuteGranularityRelative: String {
        let secondsElapsed = -timeIntervalSinceNow
        if secondsElapsed < 60 {
            return "Just now"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric

        // Round to the nearest minute so the output never includes seconds.
        let flooredDate = Date(timeIntervalSinceNow: -floor(secondsElapsed / 60) * 60)
        return formatter.localizedString(for: flooredDate, relativeTo: Date())
    }

    var postClockTimeLabel: String {
        let formatted = formatted(
            .dateTime
                .hour(.defaultDigits(amPM: .abbreviated))
                .minute()
        )

        return formatted
            .replacingOccurrences(of: " AM", with: "am")
            .replacingOccurrences(of: " PM", with: "pm")
    }
}

extension CLLocationDistance {
    var milesAwayLabel: String {
        let miles = Measurement(value: self, unit: UnitLength.meters)
            .converted(to: .miles)
            .value

        if miles < 0.15 {
            return "<0.1 mi away"
        }

        if miles < 10 {
            return String(format: "%.1f mi away", miles)
        }

        return String(format: "%.0f mi away", miles)
    }
}

struct AvatarView: View {
    let avatar: AvatarStyle
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            if let imageData = avatar.imageData, let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let remoteURL = avatar.remoteURL {
                AsyncImage(url: remoteURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        avatarPlaceholder
                    }
                }
            } else {
                avatarPlaceholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(AppTheme.line, lineWidth: 1))
    }

    private var avatarPlaceholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: avatar.primaryHex), Color(hex: avatar.secondaryHex)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: avatar.symbol)
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
        }
    }
}

/// Drop-in replacement for `AvatarView` that overlays the tonight
/// activity ring and post-count pill when the user has posted tonight.
/// Looks up the user's `TonightEntry` from the store automatically —
/// callers just pass a `userID` and the desired `size`.
struct TonightAvatarView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    let avatar: AvatarStyle
    let userID: UUID
    var size: CGFloat = 60

    private var ringInset: CGFloat { 3 }

    private var entry: AppStore.TonightEntry? {
        store.tonightEntries.first(where: { $0.id == userID })
    }

    var body: some View {
        let active = entry?.hasPostedTonight ?? false
        let count = entry?.postsTonightCount ?? 0

        ZStack {
            // Ring
            if active {
                Circle()
                    .strokeBorder(accent, lineWidth: 2.5)
                    .frame(width: size + ringInset * 2, height: size + ringInset * 2)
            } else {
                Circle()
                    .strokeBorder(AppTheme.line, lineWidth: 1)
                    .frame(width: size + ringInset * 2, height: size + ringInset * 2)
            }

            AvatarView(avatar: avatar, size: size)
                .opacity(active ? 1 : 0.9)
        }
        .frame(width: size + ringInset * 2, height: size + ringInset * 2)
        .overlay(alignment: .bottom) {
            if active {
                Text("\(count) \(count == 1 ? "post" : "posts")")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(accent, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                .offset(y: 10)
            }
        }
        .padding(.bottom, active ? 10 : 0)
    }
}

struct AvatarPile: View {
    let avatars: [AvatarStyle]
    var size: CGFloat = 34
    var overlap: CGFloat = 12
    var limit: Int = 3

    var body: some View {
        let visible = Array(avatars.prefix(limit))
        let extraCount = max(avatars.count - visible.count, 0)

        HStack(spacing: -overlap) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, avatar in
                AvatarView(avatar: avatar, size: size)
            }

            if extraCount > 0 {
                Text("+\(extraCount)")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(AppTheme.line, lineWidth: 1))
            }
        }
    }
}

struct MomentMediaView: View {
    let media: MomentMedia
    /// When nil the view sizes to the image's natural aspect ratio (no crop).
    /// Pass a fixed height only for contexts that need prescriptive sizing.
    var height: CGFloat? = nil

    @Environment(AppStore.self) private var store

    /// Best-known aspect ratio (width ÷ height) for the placeholder frame.
    /// Priority: (1) value baked into MomentMedia at post time from local
    /// pixel data — always available for the viewer's own posts; (2) the
    /// store cache populated on first remote load for friends' posts;
    /// (3) 4:5 portrait fallback for brand-new posts not yet scrolled.
    private var placeholderRatio: CGFloat {
        if let r = media.photoAspectRatio { return r }
        if let url = media.remotePhotoURL,
           let r = store.photoAspectRatioCache[url.absoluteString] { return r }
        return 0.80
    }

    var body: some View {
        Group {
            if let data = media.photoData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: height != nil ? .fill : .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipped()
            } else if let remotePhotoURL = media.remotePhotoURL {
                AsyncImage(url: remotePhotoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: height != nil ? .fill : .fit)
                            .frame(maxWidth: .infinity)
                            .frame(height: height)
                            .clipped()
                            .background(
                                GeometryReader { geo in
                                    Color.clear.onAppear {
                                        guard store.photoAspectRatioCache[remotePhotoURL.absoluteString] == nil,
                                              geo.size.height > 0 else { return }
                                        store.photoAspectRatioCache[remotePhotoURL.absoluteString] =
                                            geo.size.width / geo.size.height
                                    }
                                }
                            )
                    default:
                        mediaPlaceholder
                    }
                }
            } else {
                mediaPlaceholder
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var mediaPlaceholder: some View {
        let gradient = ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [Color(hex: media.primaryHex), Color(hex: media.secondaryHex)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { geo in
                let size = geo.size.height * 0.55
                Circle()
                    .fill(.white.opacity(0.13))
                    .frame(width: size, height: size)
                    .blur(radius: 24)
                    .offset(x: geo.size.height * 0.2, y: -geo.size.height * 0.1)
            }
        }

        if let h = height {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: h)
                .overlay(gradient)
        } else {
            Color.clear
                .aspectRatio(placeholderRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(gradient)
        }
    }
}

/// Renders the icon for a DrinkTag. If the drink has a named asset-catalog
/// image (`imageName`), that is shown as a square image clipped to a circle.
/// Otherwise falls back to the SF Symbol string in `symbol`.
struct DrinkIconView: View {
    let drink: DrinkTag
    var size: CGFloat = 20

    var body: some View {
        if let imageName = drink.imageName {
            // Render at 1.45× the frame size before clipping so the subject
            // fills the circle — PNG assets have surrounding transparency that
            // makes them look small at 1:1. This matches the optical weight of
            // SF Symbols rendered at size * 0.75 in the same pill.
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(width: size * 1.45, height: size * 1.45)
                .clipShape(Circle())
                .frame(width: size, height: size)   // collapse back to the layout slot
        } else {
            Image(systemName: drink.symbol)
                .font(.system(size: size * 0.75, weight: .semibold))
        }
    }
}

struct EmptyStateCard: View {
    @Environment(\.appAccent) private var accent
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        NightPanel {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(accent)
                Text(title)
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
            }
        }
    }
}
