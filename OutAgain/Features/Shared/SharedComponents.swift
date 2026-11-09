import CoreLocation
import ImageIO
import SwiftUI
import UIKit

/// Retains the native switch while giving a white accent a contrasting thumb.
struct AppAccentToggleStyle: ToggleStyle {
    let accent: Color
    var showsLabel = true

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            if showsLabel {
                configuration.label
                Spacer(minLength: 0)
            }
            AccentNativeSwitch(isOn: configuration.$isOn, accent: accent)
                .fixedSize()
        }
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

private struct AccentNativeSwitch: UIViewRepresentable {
    @Binding var isOn: Bool
    let accent: Color
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> UISwitch {
        let control = UISwitch()
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        return control
    }

    func updateUIView(_ control: UISwitch, context: Context) {
        context.coordinator.isOn = $isOn
        control.isEnabled = isEnabled
        control.onTintColor = UIColor(accent)
        control.thumbTintColor = accent == .white && isOn ? UIColor(white: 0.12, alpha: 1) : nil
        control.setOn(isOn, animated: control.window != nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(isOn: $isOn) }

    final class Coordinator: NSObject {
        var isOn: Binding<Bool>
        init(isOn: Binding<Bool>) { self.isOn = isOn }
        @objc func changed(_ control: UISwitch) { isOn.wrappedValue = control.isOn }
    }
}

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
    var progress: CGFloat = 1
    var isRefreshing = true

    var body: some View {
        ZStack {
            if isRefreshing {
                ProgressView().progressViewStyle(.circular).tint(.white)
            } else {
                Circle().trim(from: 0, to: min(0.95, max(0.02, progress)))
                    .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90 + 180 * Double(progress)))
                    .frame(width: 19, height: 19)
            }
        }
            .frame(width: 44, height: 44)
            .glassEffect(.regular, in: Circle())
            .accessibilityLabel("Refreshing")
            .allowsHitTesting(false)
    }
}

struct GlassRefreshPosition {
    private(set) var pull: CGFloat = 0
    private var pinnedOffset: CGFloat?
    private(set) var gestureRefreshID: UUID?
    private(set) var isRunningAction = false

    var offset: CGFloat { pinnedOffset ?? min(28, pull * 0.3) }

    mutating func updatePull(_ distance: CGFloat) { pull = max(0, distance) }
    mutating func beginDrag() { pinnedOffset = nil }
    mutating func pinForRefresh(at offset: CGFloat? = nil) {
        pinnedOffset = offset ?? self.offset
    }

    mutating func beginGestureRefresh() -> UUID {
        let id = UUID()
        pinForRefresh()
        gestureRefreshID = id
        isRunningAction = true
        return id
    }

    /// Call from a view update, after the caller's latest loading flag arrives.
    /// Some actions start an externally tracked request and return immediately.
    mutating func completeAction(_ id: UUID, isRefreshing: Bool) {
        guard gestureRefreshID == id else { return }
        isRunningAction = false
        if !isRefreshing { gestureRefreshID = nil }
    }

    mutating func observeExternalRefresh(_ refreshing: Bool, isInteracting: Bool) {
        if refreshing {
            if gestureRefreshID == nil {
                pinForRefresh(at: isInteracting ? offset : 0)
            }
        } else if !isRunningAction {
            gestureRefreshID = nil
        }
        // Retain the final offset through the disappearance animation. The next
        // drag or programmatic refresh chooses its own position.
    }
}

private struct GlassPullToRefresh: ViewModifier {
    let isRefreshing: Bool
    let action: () async -> Void
    @State private var position = GlassRefreshPosition()
    @State private var isInteracting = false
    @State private var isArmed = false
    @State private var completedRefreshID: UUID?
    @State private var refreshTask: Task<Void, Never>?

    private var isRefreshActive: Bool { isRefreshing || position.isRunningAction }

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, -(geometry.contentOffset.y + geometry.contentInsets.top))
            } action: { _, distance in
                position.updatePull(distance)
                if isInteracting && !isRefreshActive {
                    let armed = distance >= 60
                    if armed && !isArmed { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
                    isArmed = armed
                }
            }
            .onScrollPhaseChange { oldPhase, newPhase in
                isInteracting = newPhase == .interacting
                if newPhase == .interacting && !isRefreshActive {
                    position.beginDrag()
                }
                if oldPhase == .interacting, newPhase != .tracking, isArmed, !isRefreshActive {
                    isArmed = false
                    // Keep this same glass view at the release position while
                    // the scroll view springs back and the async work starts.
                    let refreshID = position.beginGestureRefresh()
                    refreshTask = Task { @MainActor in
                        await action()
                        completedRefreshID = refreshID
                    }
                }
            }
            .onChange(of: completedRefreshID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    position.completeAction(id, isRefreshing: isRefreshing)
                }
                resumeDragIfNeeded()
            }
            .onChange(of: isRefreshing) { _, refreshing in
                position.observeExternalRefresh(refreshing, isInteracting: isInteracting)
                resumeDragIfNeeded()
            }
            .overlay(alignment: .top) {
                if isRefreshActive || (isInteracting && position.pull > 6) {
                    MainTabRefreshIndicator(progress: min(1, position.pull / 60), isRefreshing: isRefreshActive)
                        .padding(.top, 8)
                        .offset(y: position.offset)
                        .transition(.opacity)
                }
            }
            .onDisappear { refreshTask?.cancel() }
    }

    private func resumeDragIfNeeded() {
        guard isInteracting, !isRefreshActive else { return }
        position.beginDrag()
        isArmed = position.pull >= 60
    }
}

extension View {
    func glassPullToRefresh(isRefreshing: Bool, action: @escaping () async -> Void) -> some View {
        modifier(GlassPullToRefresh(isRefreshing: isRefreshing, action: action))
    }

    func glassPullToRefresh(action: @escaping () async -> Void) -> some View {
        modifier(ManagedGlassRefresh(action: action))
    }
}

private struct ManagedGlassRefresh: ViewModifier {
    let action: () async -> Void
    @State private var isRefreshing = false

    func body(content: Content) -> some View {
        content.glassPullToRefresh(isRefreshing: isRefreshing) {
            guard !isRefreshing else { return }
            let startedAt = Date()
            withAnimation(.easeInOut(duration: 0.18)) { isRefreshing = true }
            await action()
            await MainTabRefreshFeedback.waitForMinimumVisibleDuration(since: startedAt)
            withAnimation(.easeInOut(duration: 0.18)) { isRefreshing = false }
        }
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
    var isPlusMember = false

    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: size, weight: .bold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
            .offset(x: size * 0.06)
            .frame(width: size, height: size)
            .accessibilityLabel(isPlusMember ? "Out Again+ member" : "Verified")
    }
}

struct VerifiedProfileLabel<Label: View>: View {
    @Environment(AppStore.self) private var store
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

            if profile.isVerified || store.purchases.isPlusMember(profile.id) {
                VerifiedBadgeView(size: badgeSize, offsetY: 0, isPlusMember: store.purchases.isPlusMember(profile.id))
                    .fixedSize()
                    .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] }
            }
        }
        .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] }
    }
}

struct VerifiedUsernameLabel: View {
    @Environment(AppStore.self) private var store
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

            if profile.isVerified || store.purchases.isPlusMember(profile.id) {
                VerifiedBadgeView(size: badgeSize, isPlusMember: store.purchases.isPlusMember(profile.id))
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
