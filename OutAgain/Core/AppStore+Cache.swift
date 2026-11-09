import Foundation

/// Disk cache for the last-known feed posts.
///
/// On cold launch the cache is pre-loaded into memory before the first network
/// request fires so that when the live bootstrap returns, `applyBootstrap` can
/// merge immediately without a separate round-trip. The splash stays visible
/// until the real network bootstrap completes — `bootstrapPhase = .ready` is
/// set exclusively by `refreshAppData` after live data has been applied.
///
/// The cache is intentionally write-through: every successful `applyBootstrap`
/// overwrites it, so it always reflects the last good server state.
///
/// Cache size is bounded to the 60 most recent posts to keep the file small
/// (typically <200 KB) and the read/write cheap.
extension AppStore {

    nonisolated private static let cacheKey = "OutAgain.feedCache.v2"
    nonisolated private static let viewerCacheKey = "OutAgain.viewerCache.v1"
    nonisolated private static let maxCached = 60

    // MARK: - Public API

    /// Pre-populate the store with cached data so the feed renders the moment
    /// the live bootstrap lands — without an extra network round-trip to fetch
    /// data we already have on disk.
    ///
    /// Deliberately does NOT set `bootstrapPhase = .ready`. The splash screen
    /// stays visible until `refreshAppData` finishes so the user always sees
    /// fully-fresh content (profile pictures, names, feed) on first paint.
    func hydrateFeedFromCacheIfAvailable() {
        guard let cached = Self.loadCachedPosts(), !cached.isEmpty else { return }
        guard posts.isEmpty else { return }

        posts = cached
        resetHomeFeedPagination()

        // Pre-restore the viewer shell so `applyBootstrap` can skip the viewer
        // fetch entirely if the cached profile is still current. This does NOT
        // flip isLive — the splash remains until the real bootstrap sets .ready.
        if viewer == nil, let cachedViewer = Self.loadCachedViewer() {
            viewer = cachedViewer
            onboardingStep = .done
        }
    }

    /// Prefetch images visible in the initial app shell into URLCache so avatar
    /// and media views render from cache the moment the splash fades out.
    ///
    /// Collects every unique avatar remoteURL from the full bootstrap graph, plus
    /// the media URLs for the first Home batch. We intentionally keep post media
    /// scoped to the newest six so cold launch does not download older pages the
    /// user has not reached yet.
    func prefetchInitialImages(bootstrap: SocialBootstrap) async {
        var urls = Set<URL>()

        func collectProfile(_ profile: UserProfile?) {
            guard let url = profile?.avatar.remoteURL else { return }
            urls.insert(url)
        }

        // Viewer + direct social graph — always prefetch these because they
        // appear in the nav bar, friend list, and friend strip.
        collectProfile(bootstrap.viewer)
        for friend in bootstrap.friends {
            collectProfile(friend)
        }

        // Suggestions, blocked users, and pending requests are secondary UI —
        // cap to the first 10 of each so one large FoF set doesn't balloon
        // the prefetch budget.
        for suggestion in bootstrap.suggestedFriends.prefix(10) {
            collectProfile(suggestion)
        }
        for request in (bootstrap.incomingRequests + bootstrap.outgoingRequests).prefix(10) {
            collectProfile(request.counterpart)
        }
        for blockedUser in bootstrap.blockedUsers.prefix(10) {
            collectProfile(blockedUser)
        }
        for notification in bootstrap.notifications.prefix(10) {
            collectProfile(notification.actor)
        }

        // Feed posts: prefetch author avatars and media for the first page
        // only. Skip per-post comment authors and reactor avatars — they're
        // loaded lazily when the detail view opens and prefetching them up
        // front can spawn 200+ concurrent requests on an active feed.
        for post in bootstrap.posts.prefix(Self.homeFeedPageSize) {
            collectProfile(post.author)
            for tagged in post.taggedFriends {
                collectProfile(tagged)
            }
            if let url = post.media.remotePhotoURL {
                urls.insert(url)
            }
        }

        guard !urls.isEmpty else { return }

        // Hard cap on simultaneous prefetch connections so we don't saturate
        // the user's uplink or compete with live app traffic on startup.
        // 8 concurrent tasks saturates a typical cellular connection without
        // blocking the feed's first meaningful paint.
        let maxConcurrent = 8
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            for url in urls {
                if inFlight >= maxConcurrent {
                    await group.next()
                    inFlight -= 1
                }
                group.addTask {
                    await Self.prefetchURLIntoSharedCache(url)
                }
                inFlight += 1
            }
            await group.waitForAll()
        }
    }

    nonisolated private static func prefetchURLIntoSharedCache(_ url: URL) async {
        let request = URLRequest(
            url: url,
            cachePolicy: .returnCacheDataElseLoad,
            timeoutInterval: 30
        )

        if URLCache.shared.cachedResponse(for: request) != nil { return }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  200 ..< 300 ~= http.statusCode,
                  !data.isEmpty
            else { return }

            URLCache.shared.storeCachedResponse(
                CachedURLResponse(response: response, data: data),
                for: request
            )
        } catch {
            // Missing one image should not trap the app on the splash forever;
            // the view-level loader will retry naturally if the network blips.
        }
    }

    /// Persist the current post list and viewer to disk after a successful bootstrap.
    /// Called from `applyBootstrap` so the cache always mirrors server truth.
    func persistFeedCache() {
        let slice = Array(posts.prefix(Self.maxCached))
        let currentViewer = viewer
        let encoder = JSONEncoder()
        let postsData = try? encoder.encode(slice)
        let viewerData = currentViewer.flatMap { try? encoder.encode($0) }

        Task(priority: .utility) { @MainActor in
            if let postsData {
                UserDefaults.standard.set(postsData, forKey: Self.cacheKey)
            }
            if let viewerData {
                UserDefaults.standard.set(viewerData, forKey: Self.viewerCacheKey)
            }
        }
    }

    // MARK: - Private

    private static func loadCachedPosts() -> [MomentPost]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return (try? JSONDecoder().decode([MomentPost].self, from: data))?.map { cached in
            var post = cached
            post.reactions.removeAll { !ReactionKind.allCases.contains($0.kind) }
            post.viewerReactionKinds = post.viewerReactionKinds.intersection(ReactionKind.allCases)
            post.fullyLoadedReactionKinds = post.fullyLoadedReactionKinds.intersection(ReactionKind.allCases)
            return post
        }
    }

    static func loadCachedViewer() -> UserProfile? {
        guard let data = UserDefaults.standard.data(forKey: viewerCacheKey) else { return nil }
        return try? JSONDecoder().decode(UserProfile.self, from: data)
    }
}
