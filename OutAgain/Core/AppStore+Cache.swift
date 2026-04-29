import Foundation

/// Disk cache for the last-known feed posts.
///
/// On cold launch the cache is loaded synchronously before the first network
/// request fires, so the feed renders immediately with stale-but-fast data
/// while the real bootstrap runs in the background and replaces it.
///
/// The cache is intentionally write-through: every successful `applyBootstrap`
/// overwrites it, so it always reflects the last good server state.
///
/// Cache size is bounded to the 60 most recent posts to keep the file small
/// (typically <200 KB) and the read/write cheap.
extension AppStore {

    private static let cacheKey      = "OutAgain.feedCache.v2"
    private static let viewerCacheKey = "OutAgain.viewerCache.v1"
    private static let maxCached     = 60

    // MARK: - Public API

    /// Load cached posts into the feed synchronously.
    /// Called once at startup, before the first network round-trip.
    ///
    /// If the viewer has a stored session AND we have cached posts, we also
    /// flip `bootstrapPhase` to `.ready` and restore a minimal viewer shell
    /// so the main feed renders immediately. The real bootstrap running in
    /// the background will overwrite everything with fresh server data.
    func hydrateFeedFromCacheIfAvailable() {
        guard let cached = Self.loadCachedPosts(), !cached.isEmpty else { return }
        guard posts.isEmpty else { return }

        posts = cached

        // Only show the cached feed if the session is still alive — no point
        // flipping to .ready and showing a signed-out shell.
        guard authState == .signedIn || backend.hasStoredSession else { return }

        // Restore a lightweight viewer shell so `isLive` evaluates to true
        // and MainShellView renders. The full viewer profile arrives with the
        // real bootstrap moments later.
        if viewer == nil, let cachedViewer = Self.loadCachedViewer() {
            viewer = cachedViewer
            onboardingStep = .done
        }

        // Cached viewer + stored session should route straight into the live
        // shell while the real bootstrap refreshes in the background.
        authState = .signedIn

        bootstrapPhase = .ready
        // Record that cached content is on screen — this is the "first
        // meaningful paint" metric. The live bootstrap will land shortly after.
        trackCachedFeedVisible()
    }

    /// Persist the current post list and viewer to disk after a successful bootstrap.
    /// Called from `applyBootstrap` so the cache always mirrors server truth.
    func persistFeedCache() {
        let slice = Array(posts.prefix(Self.maxCached))
        let currentViewer = viewer
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(slice) {
                UserDefaults.standard.set(data, forKey: Self.cacheKey)
            }
            if let v = currentViewer, let data = try? encoder.encode(v) {
                UserDefaults.standard.set(data, forKey: Self.viewerCacheKey)
            }
        }
    }

    // MARK: - Private

    private static func loadCachedPosts() -> [MomentPost]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode([MomentPost].self, from: data)
    }

    static func loadCachedViewer() -> UserProfile? {
        guard let data = UserDefaults.standard.data(forKey: viewerCacheKey) else { return nil }
        return try? JSONDecoder().decode(UserProfile.self, from: data)
    }
}
