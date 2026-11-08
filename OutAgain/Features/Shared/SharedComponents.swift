import CoreLocation
import ImageIO
import SwiftUI
import UIKit

extension Date {
    private static let minuteRelativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.dateTimeStyle = .numeric
        return formatter
    }()

    /// Human-readable relative time at minute granularity — "Just now" for
    /// anything under a minute, then "5 min ago", "2 hr ago", etc. Used by
    /// activity surfaces where second-by-second precision reads as jitter
    /// rather than signal.
    var minuteGranularityRelative: String {
        let secondsElapsed = -timeIntervalSinceNow
        if secondsElapsed < 60 {
            return "Just now"
        }

        // Round to the nearest minute so the output never includes seconds.
        let flooredDate = Date(timeIntervalSinceNow: -floor(secondsElapsed / 60) * 60)
        return Self.minuteRelativeFormatter.localizedString(for: flooredDate, relativeTo: Date())
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

enum MainTabRefreshFeedback {
    static let minimumVisibleDuration: TimeInterval = 0.55

    static func waitForMinimumVisibleDuration(since startedAt: Date) async {
        let remaining = minimumVisibleDuration - Date().timeIntervalSince(startedAt)
        guard remaining > 0 else { return }

        try? await Task.sleep(for: .milliseconds(Int(remaining * 1000)))
    }
}

struct MainTabRefreshIndicator: View {
    @Environment(\.appAccent) private var accent

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(accent)
            .controlSize(.regular)
            .padding(10)
            .background(.black.opacity(0.58), in: Circle())
            .overlay(Circle().strokeBorder(AppTheme.line, lineWidth: 1))
            .shadow(color: .black.opacity(0.24), radius: 12, y: 6)
            .accessibilityLabel("Refreshing")
            .allowsHitTesting(false)
    }
}

struct AvatarView: View {
    let avatar: AvatarStyle
    var size: CGFloat = 48

    var body: some View {
        ZStack {
            if let imageData = avatar.imageData,
               let image = ImageDecodeCache.image(for: imageData, key: ImageDecodeCache.cacheKey(forLocalData: imageData, prefix: "avatar")) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let remoteURL = avatar.remoteURL {
                RemoteDecodedImageView(url: remoteURL, contentMode: .fill) {
                    avatarPlaceholder
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
    var showsPostCount = true

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
            if active && showsPostCount {
                Text("\(count) \(count == 1 ? "post" : "posts")")
                    .font(AppTypography.badgeStrong)
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
        .padding(.bottom, active && showsPostCount ? 10 : 0)
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
                    .font(AppTypography.metadataEmphasis)
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(AppTheme.line, lineWidth: 1))
            }
        }
    }
}

struct VerifiedBadgeView: View {
    var size: CGFloat = 12
    var offsetY: CGFloat = 0  // kept for API compatibility; no longer applied

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size, weight: .bold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
            .offset(x: size * 0.06)
            .frame(width: size, height: size)
            .accessibilityLabel("Verified")
    }
}

struct VerifiedProfileLabel<Label: View>: View {
    let profile: UserProfile
    var spacing: CGFloat = 6
    var badgeSize: CGFloat = 12
    private let label: () -> Label

    init(
        profile: UserProfile,
        spacing: CGFloat = 6,
        badgeSize: CGFloat = 12,
        badgeOffsetY: CGFloat = 0,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.profile = profile
        self.spacing = spacing
        self.badgeSize = badgeSize
        self.label = label
    }

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            label()

            if profile.isVerified {
                VerifiedBadgeView(size: badgeSize, offsetY: 0)
                    .fixedSize()
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            }
        }
        .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] }
    }
}

struct VerifiedUsernameLabel: View {
    let profile: UserProfile
    var font: Font = AppTypography.usernameCompact
    var color: Color = AppTheme.softText
    var spacing: CGFloat = 3
    var badgeSize: CGFloat = 10
    var badgeOffsetY: CGFloat = 0  // kept for API compatibility; no longer applied

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Text("@\(profile.username)")
                .font(font)
                .foregroundStyle(color)
                .lineLimit(1)

            if profile.isVerified {
                VerifiedBadgeView(size: badgeSize)
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
                    .fixedSize()
            }
        }
    }
}

struct RemoteDecodedImageView<Placeholder: View>: View {
    let url: URL
    var contentMode: ContentMode = .fill
    var onImageLoaded: ((UIImage) -> Void)? = nil
    let placeholder: () -> Placeholder

    @State private var loadedImage: UIImage? = nil
    @State private var loadedURLString: String? = nil

    init(
        url: URL,
        contentMode: ContentMode = .fill,
        onImageLoaded: ((UIImage) -> Void)? = nil,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.contentMode = contentMode
        self.onImageLoaded = onImageLoaded
        self.placeholder = placeholder

        let cachedImage = Self.cachedImage(for: url)
        _loadedImage = State(initialValue: cachedImage)
        _loadedURLString = State(initialValue: cachedImage == nil ? nil : url.absoluteString)
    }

    var body: some View {
        Group {
            if loadedURLString == url.absoluteString, let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder()
                    .task(id: url.absoluteString) {
                        loadedImage = nil
                        loadedURLString = nil
                        await load()
                    }
            }
        }
    }

    private func load() async {
        if let cachedImage = Self.cachedImage(for: url) {
            await MainActor.run {
                loadedURLString = url.absoluteString
                loadedImage = cachedImage
                onImageLoaded?(cachedImage)
            }
            return
        }

        do {
            let request = Self.imageRequest(for: url)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  200 ..< 300 ~= http.statusCode,
                  let image = ImageDecodeCache.image(for: data, key: url.absoluteString) else {
                return
            }
            URLCache.shared.storeCachedResponse(
                CachedURLResponse(response: response, data: data),
                for: request
            )
            await MainActor.run {
                loadedURLString = url.absoluteString
                loadedImage = image
                onImageLoaded?(image)
            }
        } catch {
            // Keep the placeholder on-screen. A later refresh or view rebuild
            // retries naturally without crashing the feed surface.
        }
    }

    private static func cachedImage(for url: URL) -> UIImage? {
        if let image = ImageDecodeCache.cachedImage(forKey: url.absoluteString) {
            return image
        }
        let request = imageRequest(for: url)
        guard let cached = URLCache.shared.cachedResponse(for: request) else { return nil }
        return ImageDecodeCache.image(for: cached.data, key: url.absoluteString)
    }

    private static func imageRequest(for url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
    }
}

enum ImageDecodeCache {
    private static let maxPixelDimension: CGFloat = 1_800

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1_024 * 1_024
        cache.countLimit = 180
        return cache
    }()

    static func cachedImage(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    static func image(for data: Data, key: String) -> UIImage? {
        if let cached = cachedImage(forKey: key) {
            return cached
        }

        guard let image = downsampledImage(from: data) ?? UIImage(data: data) else {
            return nil
        }

        cache.setObject(image, forKey: key as NSString, cost: image.cacheCost)
        return image
    }

    static func cacheKey(forLocalData data: Data, prefix: String) -> String {
        var samples: [UInt8] = []
        data.withUnsafeBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = rawBuffer.count
            let offsets = [0, count / 2, max(count - 16, 0)]
            for offset in offsets where offset < count {
                let length = min(16, count - offset)
                samples.append(contentsOf: UnsafeBufferPointer(start: bytes + offset, count: length))
            }
        }

        let signature = samples.map { String(format: "%02x", $0) }.joined()
        return "\(prefix)-\(data.count)-\(signature)"
    }

    private static func downsampledImage(from data: Data) -> UIImage? {
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary

        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }

        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension
        ] as CFDictionary

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }
}

private extension UIImage {
    var cacheCost: Int {
        guard let cgImage else { return 1 }
        return cgImage.bytesPerRow * cgImage.height
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
            if let data = media.photoData,
               let image = ImageDecodeCache.image(for: data, key: ImageDecodeCache.cacheKey(forLocalData: data, prefix: "moment")) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: height != nil ? .fill : .fit)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .clipped()
            } else if let remotePhotoURL = media.remotePhotoURL {
                RemoteDecodedImageView(
                    url: remotePhotoURL,
                    contentMode: height != nil ? .fill : .fit,
                    onImageLoaded: { image in
                        guard store.photoAspectRatioCache[remotePhotoURL.absoluteString] == nil,
                              image.size.height > 0 else { return }
                        store.photoAspectRatioCache[remotePhotoURL.absoluteString] =
                            image.size.width / image.size.height
                    }
                ) {
                    mediaPlaceholder
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()
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

/// Renders the icon for a DrinkTag.
/// Priority: emoji → SF Symbol fallback for custom drinks.
/// The imageName path is retained for the Maddox easter-egg asset but
/// is no longer used for standard catalog drinks now that emojis cover them.
struct DrinkIconView: View {
    let drink: DrinkTag
    var size: CGFloat = 20

    var body: some View {
        if let emoji = drink.emoji ?? DrinkTag.resolvedEmoji(for: drink.name) {
            Text(emoji)
                .font(.system(size: size * 0.88))
                .frame(width: size, height: size)
        } else if let imageName = drink.imageName {
            Image(imageName)
                .resizable()
                .scaledToFill()
                .frame(width: size * 1.60, height: size * 1.60)
                .clipShape(Circle())
                .frame(width: size, height: size)
        } else {
            Image(systemName: drink.symbol)
                .font(.system(size: size * 0.75, weight: .semibold))
        }
    }
}

struct EmptyStateCard: View {
    @Environment(\.appAccent) private var accent
    let title: String
    var detail: String? = nil
    let symbol: String

    var body: some View {
        NightPanel {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(accent)
                Text(title)
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(.white)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(AppTypography.rowSubtitle)
                        .foregroundStyle(AppTheme.softText)
                }
            }
        }
    }
}
