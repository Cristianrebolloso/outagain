import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    static let pendingDeletedNotificationIDsKey = "OutAgain.pendingDeletedNotificationIDs"
    static let homeFeedPageSize = 6
    static let profilePostsPageSize = 12
    /// Foreground feed polling intentionally overlaps the newest known post by
    /// a small time window. This lets the client recover posts that become
    /// visible a little late (replication lag, poll timing, app resume) even
    /// when their `createdAt` is older than the current newest loaded post.
    static let feedDeltaOverlapDuration: TimeInterval = 2 * 60 * 60

    var authState: AuthState = .signedOut
    var onboardingStep: OnboardingStep = .welcome
    var authDraft = EmailPasswordAuthDraft()
    var onboardingDraft = OnboardingDraft()

    var selectedTab: AppTab = .home {
        didSet {
            // Continuously track the last non-camera tab so the camera
            // dismissal flow can restore it without relying on a one-shot
            // capture at openPostFlow time (which has proven racy with the
            // search-role Tab's selection lifecycle).
            if selectedTab != .post {
                lastRegularTab = selectedTab
            }
        }
    }
    /// Mirrors selectedTab whenever it is anything other than the camera tab.
    @ObservationIgnored var lastRegularTab: AppTab = .home
    /// Incremented every time the Home tab is tapped so the feed can
    /// react even when Home is already the selected tab.
    var homeTabSelectionTrigger = 0
    /// Home keeps its feed alive while a profile slides into the continuing pane.
    var homeProfile: UserProfile?
    /// Incremented every time the People tab is selected so its preserved
    /// ScrollView can return to the top instead of reopening mid-list.
    var friendsTabSelectionTrigger = 0
    /// Incremented every time Activity is selected from the native tab bar.
    var activityTabSelectionTrigger = 0
    /// Incremented when Profile is reselected from the native tab bar.
    var profileTabSelectionTrigger = 0
    /// Incremented every time the admin broadcast tab is selected.
    var adminTabSelectionTrigger = 0
    var friendsPageMode: FriendsPageMode = .discover
    var pendingSocialInviteCode: String? = UserDefaults.standard.string(forKey: "OutAgain.pendingSocialInvite") {
        didSet {
            UserDefaults.standard.set(pendingSocialInviteCode, forKey: "OutAgain.pendingSocialInvite")
        }
    }
    var isSocialInvitePresented = false
    @ObservationIgnored var lastAutoPresentedSocialInviteCode: String?
    // When non-nil, the People tab auto-presents this profile on appear.
    var friendsTabPendingProfile: UserProfile? = nil
    var localFeedIDs: [UUID] = []
    var isLoadingLocalFeed = false
    var hasOlderLocalPosts = false
    var localFeedError: String?
    var localFeedLocation: LocationSnapshot?
    var localFeedLoadedAt: Date?
    var localFeedRequestID = UUID()
    var notificationDestination: NotificationDestination?
    var pendingPushTarget: PendingPushTarget?
    var feedScope: FeedScope = .friends
    var selectedPresenceClusterID: UUID?
    var isPostFlowPresented = false
    var isMaddoxPlayerPresented = false
    /// Set to true when the user posts a Maddox drink. AppRootView watches
    /// isPostFlowPresented and presents the player once the cover is gone.
    var pendingMaddoxPlayer = false
    /// Keeps post-flow dismissal idempotent after a successful publish.
    @ObservationIgnored var didPublishDuringPostFlow = false
    @ObservationIgnored var postFlowDismissalRepinTask: Task<Void, Never>?
    var isTabBarMinimized = false
    var profileOverlayRoute: ProfileOverlayRoute?
    var profileSavedConfirmationTrigger = 0

    var postDraft = PostDraft()
    var isPublishingDraft = false
    var postPublishError: String?
    var viewer: UserProfile? {
        didSet {
            if oldValue?.id != viewer?.id {
                isSocialInvitePresented = false
                purchases.switchAccount(to: viewer?.id)
                commentComposerDrafts.removeAll()
                feedDiscussion.reset()
                homeProfile = nil
                if let userID = viewer?.id { prepareNotificationPreferences(for: userID) }
            }
        }
    }
    let feedDiscussion = FeedDiscussionState()
    let purchases = PurchaseStore()
    var appDisplayName: String { purchases.isPlus ? "Out Again+" : "Out Again" }
    /// Enabled only by the system hinge interaction, never by screen width.
    var isDuoDevice = false
    @ObservationIgnored var commentComposerDrafts: [UUID: CommentComposerDraft] = [:]
    var usernameAvailability: UsernameAvailability = .unchecked
    var profileEditor = ProfileEditorDraft()
    var profileUsernameAvailability: UsernameAvailability = .unchecked
    var notificationPreferences = NotificationPreferences() {
        didSet {
            persistNotificationPreferences()
        }
    }
    var isLoadingNotificationPreferences = false
    var isSavingNotificationPreferences = false
    var notificationPreferenceError: String?
    @ObservationIgnored var notificationPreferenceUserID: UUID?
    @ObservationIgnored var notificationPreferenceRevision = UUID()
    var liveActivityPreferences = LiveActivityPreferences() {
        didSet {
            persistLiveActivityPreferences()
        }
    }
    var accentColorChoice: AccentColorChoice = AppStore.loadAccentColorChoice() {
        didSet {
            if let userID = viewer?.id {
                UserDefaults.standard.set(accentColorChoice.rawValue, forKey: "OutAgain.accentColor.\(userID.uuidString)")
            }
            UserDefaults.standard.set(accentColorChoice.rawValue, forKey: "OutAgain.accentColor")
        }
    }
    var backgroundTheme: BackgroundTheme = AppStore.loadBackgroundTheme() {
        didSet {
            UserDefaults.standard.set(backgroundTheme.rawValue, forKey: "OutAgain.backgroundTheme")
            handleBackgroundThemeChanged(backgroundTheme)
        }
    }
    var isSavingProfile = false
    var profileEditorMessage: String?
    var friendSearchQuery = ""
    var friendSearchResults: [UserProfile] = []
    var isSearchingFriends = false
    var friendSearchError: String?
    var outboundNotificationDeliveries: [OutboundNotificationDelivery] = []
    var socialErrorMessage: String?
    /// True when the most recent bootstrap or refresh failed with a network
    /// transport error (no connectivity, DNS failure, timeout). Cleared as
    /// soon as a subsequent refresh succeeds. Used to show a non-blocking
    /// offline banner in the feed rather than trapping the user on the splash.
    let offlineNotice = OfflineNoticeState()
    var isOffline = false {
        didSet { offlineNotice.update(isOffline: isOffline) }
    }

    /// Night groups: sourced from the backend `night_groups` table and synced
    /// on every bootstrap. All members of a group see it via RLS policy.
    var nightGroups: [NightGroup] = []
    /// Night groups from the just-finished 7am-to-7am cycle. Kept separate
    /// from `nightGroups` so the home strip can stay current while the recap
    /// can still summarize yesterday's group.
    var nightSummaryGroups: [NightGroup] = []
    /// Controls presentation of the group creation sheet from HomeFeedView.
    var isGroupCreationPresented = false
    /// The group whose feed is currently being viewed (nil = none open).
    var activeGroupID: UUID? = nil

    var friends: [UserProfile] = []
    var suggestedFriends: [UserProfile] = []

    // Admin user browser
    var adminAllUsers: [UserProfile] = []
    var isLoadingAdminUsers = false
    var hasMoreAdminUsers = true
    var adminBusyUserIDs: Set<UUID> = []
    var adminStatusMessage: String?
    static let adminUserPageSize = 10
    var adminReports: [ContentReport] = []
    var isLoadingAdminReports = false
    var hasMoreAdminReports = true
    var adminReportsMessage: String?
    static let adminReportPageSize = 25
    var adminAppAnnouncements: [AdminAppAnnouncement] = []
    var isLoadingAdminAppAnnouncements = false
    var friendOfFriendIDsStore: Set<UUID> = []
    /// Mutual friend count for each FoF/suggested candidate. Populated from the
    /// friends_of_friends_ids RPC which counts shared accepted friendships.
    var mutualCounts: [UUID: Int] = [:]
    var incomingFriendRequests: [FriendRequest] = []
    var outgoingFriendRequests: [FriendRequest] = []
    var blockedUserIDs: Set<UUID> = []
    var blockedUsers: [UserProfile] = []
    var drinkCatalogPreferences = DrinkCatalogPreferences()
    var drinks = SeedCatalog.drinks
    var venues = SeedCatalog.venues
    var posts: [MomentPost] = []
    var tonightActivityPosts: [MomentPost] = []
    var nightSummaryPosts: [MomentPost] = []
    var notifications: [AppNotification] = []
    var appAnnouncements: [AppAnnouncement] = []
    var appConfig: [String: String] = [:]
    var isLoadingOlderHomeFeedPosts = false
    var hasOlderHomeFeedPosts = true
    var locallyDeletedPostIDs: Set<UUID> = []

    // Distinguishes "still loading" from "finished loading, user is signed out."
    // Without this, the root view renders the onboarding UI for the brief window
    // between process start and the first bootstrap returning, which looks like a
    // flash of the login screen on every cold launch.
    var bootstrapPhase: BootstrapPhase = .pending

    /// Shared camera pipeline, kept alive across post-flow presentations so
    /// the session is pre-warmed before the fullScreenCover finishes animating.
    /// openPostFlow() calls prepare() eagerly; the view just awaits completion.
    var sharedCamera = CameraPipeline()
    @ObservationIgnored var postFlowCameraPresentationID: UUID?

    @ObservationIgnored let backend: SocialBackendClient
    @ObservationIgnored var didAttemptBootstrap = false
    @ObservationIgnored var pendingAPNsToken: Data?
    @ObservationIgnored var lastRegisteredAPNsToken: Data?
    @ObservationIgnored var friendSearchDebounceTask: Task<Void, Never>?
    @ObservationIgnored var foregroundPollTask: Task<Void, Never>?
    @ObservationIgnored var maintenanceConfigPollTask: Task<Void, Never>?
    @ObservationIgnored var lastFullRefreshAt: Date?
    /// URL string → (width / height) aspect ratio, populated the first time
    /// each remote photo loads. Survives refreshAppData and view recreation
    /// so placeholders stay correctly sized across the app's lifetime.
    @ObservationIgnored var photoAspectRatioCache: [String: CGFloat] = [:]
    /// Lazy ID→index cache for `posts`. Built on the first miss in any body
    /// pass and validated on every lookup (`posts[idx].id == id`), so a stale
    /// entry triggers exactly one rebuild before falling through to a valid
    /// O(1) hit. Replaces a per-property linear scan that was running 15× per
    /// card per body — turns 30 cards × 80 posts × 15 reads (~36 000 UUID
    /// comparisons per redraw) into ~80 + 450 dictionary lookups.
    @ObservationIgnored var postsIndexCache: [UUID: Int] = [:]
    /// Memoization for `nightlyDrinkCounts(for:through:)`. Validated by a
    /// cheap fingerprint over `tonightActivitySourcePosts`; on a miss the
    /// cache is cleared and rebuilt. Eliminates a per-card-per-redraw O(N²)
    /// recompute when the underlying source data hasn't changed.
    @ObservationIgnored var nightlyDrinkCountsCache: [String: [(drink: DrinkTag, count: Int)]] = [:]
    @ObservationIgnored var nightlyDrinkCountsFingerprint: Int = 0
    /// Reverse-geocoded city/state strings keyed by a coordinate rounded to
    /// 3 decimals (~110m granularity, fine for locality lookups). Without
    /// this, every post card without a venue but with a coordinate fires a
    /// fresh CLGeocoder request — Apple throttles aggressive callers and a
    /// busy feed easily makes dozens of identical round-trips.
    @ObservationIgnored var geocodedLocalityCache: [String: String] = [:]
    @ObservationIgnored var pendingDeletedNotificationIDs = AppStore.loadPendingDeletedNotificationIDs()
    @ObservationIgnored var lastSyncedDrinkCatalogPreferences = DrinkCatalogPreferences()
    @ObservationIgnored var homeFeedCursorDate: Date?
    @ObservationIgnored var pendingPostCreates: [UUID: MomentPost] = [:]
    @ObservationIgnored var pendingCommentCreates: [PendingCommentKey: Comment] = [:]
    @ObservationIgnored var pendingReactionStates: [PendingPostReactionKey: Bool] = [:]
    @ObservationIgnored var pendingCommentLikeStates: [PendingCommentLikeKey: Bool] = [:]
    @ObservationIgnored var pendingSeenAppAnnouncementIDs: Set<UUID> = []
    @ObservationIgnored var syncingSeenAppAnnouncementIDs: Set<UUID> = []

    init(backend: SocialBackendClient) {
        self.backend = backend
        resetDraft()
    }

    var isLayoutPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--duo-layout-preview")
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        #else
        false
        #endif
    }

    var isLive: Bool {
        authState == .signedIn && onboardingStep == .done
    }

    var closeFriends: [UserProfile] {
        friends.filter(\.isCloseFriend)
    }

    var unreadNotificationCount: Int {
        notifications.filter { !$0.isRead }.count
    }

    func isNotificationPendingDeletion(_ id: UUID) -> Bool {
        pendingDeletedNotificationIDs.contains(id)
    }

    /// Returns the most up-to-date version of `post` from `posts` via an
    /// O(1) cached lookup. The cache is opportunistically rebuilt when a
    /// lookup returns a stale entry (e.g. after `posts` is reordered), so
    /// callers never need to invalidate it explicitly.
    func livePost(matching id: UUID) -> MomentPost? {
        if let idx = postsIndexCache[id], idx < posts.count, posts[idx].id == id {
            return posts[idx]
        }
        postsIndexCache = Dictionary(uniqueKeysWithValues: posts.enumerated().map { ($1.id, $0) })
        if let idx = postsIndexCache[id], idx < posts.count, posts[idx].id == id {
            return posts[idx]
        }
        return nil
    }

    /// Returns a previously-resolved locality string for the given
    /// coordinate, if any. Callers should fall through to
    /// `storeResolvedLocality(...)` after a successful reverse-geocode.
    func cachedLocality(forLatitude latitude: Double, longitude: Double) -> String? {
        geocodedLocalityCache[Self.localityCacheKey(latitude: latitude, longitude: longitude)]
    }

    func storeResolvedLocality(_ value: String, forLatitude latitude: Double, longitude: Double) {
        geocodedLocalityCache[Self.localityCacheKey(latitude: latitude, longitude: longitude)] = value
    }

    private static func localityCacheKey(latitude: Double, longitude: Double) -> String {
        // 3 decimal places ≈ 110m at the equator — coarse enough that all
        // posts from a venue share a cache entry, fine enough never to
        // collide between distinct cities.
        let lat = (latitude * 1000).rounded() / 1000
        let lng = (longitude * 1000).rounded() / 1000
        return "\(lat),\(lng)"
    }

    var pendingIncomingRequestCount: Int {
        incomingFriendRequests.count
    }

    var recentDrinks: [DrinkTag] {
        Array(drinks.prefix(4))
    }

    var viewerIdentity: UserProfile {
        viewer ?? .placeholderCurrentUser
    }

    var normalizedOnboardingUsername: String {
        onboardingDraft.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var normalizedOnboardingEmail: String? {
        EmailAddressRules.normalized(authDraft.identifier)
    }

    var normalizedSignInIdentifier: String? {
        SignInIdentifierRules.normalized(authDraft.identifier)
    }

    var areFeedAdsEnabled: Bool {
        FeedAdConfiguration.isEnabled(in: appConfig)
            && (isLayoutPreview || purchases.hasLoadedEntitlements)
            && !purchases.isPlus
    }

    var arePasskeysEnabled: Bool {
        appConfig["passkeys_enabled"] == "true"
    }

    var authPassword: String {
        authDraft.password
    }

    var canSubmitAuth: Bool {
        guard !authDraft.isSubmitting else { return false }

        // Debug-only: when local shortcut credentials are configured outside
        // the repo, `1`/`1` should remain tappable even though it is neither
        // a valid email nor a valid password.
        if DeveloperTestAccount.resolve(
            email: authDraft.identifier,
            password: authDraft.password
        ) != nil {
            return true
        }

        switch authDraft.mode {
        case .signUp:
            return normalizedOnboardingEmail != nil && PasswordRules.isValid(authPassword)
        case .signIn:
            return normalizedSignInIdentifier != nil && !authPassword.isEmpty
        }
    }

    var isSignInMode: Bool {
        authDraft.mode == .signIn
    }

    var canContinueFromProfile: Bool {
        guard !onboardingDraft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        if case .available(let username, _) = usernameAvailability {
            return username == normalizedOnboardingUsername
        }

        return false
    }

    var normalizedProfileEditorUsername: String {
        profileEditor.username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var canSaveProfileEdits: Bool {
        guard !isSavingProfile else { return false }
        guard !profileEditor.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        if case .available(let username, _) = profileUsernameAvailability {
            return username == normalizedProfileEditorUsername
        }

        return false
    }

    var viewerPosts: [MomentPost] {
        guard let viewer else { return [] }
        return sortPostsByRecency(
            posts.filter { $0.author.id == viewer.id }
        )
    }

    func handleHomeTabTap() {
        selectedTab = .home
        homeTabSelectionTrigger &+= 1
    }

    func handleFriendsTabTap() {
        selectedTab = .friends
        friendsTabSelectionTrigger &+= 1
    }

    func handleActivityTabTap() {
        selectedTab = .activity
        activityTabSelectionTrigger &+= 1
    }

    func handleProfileTabTap() {
        selectedTab = .profile
        profileTabSelectionTrigger &+= 1
    }

    func handleAdminTabTap() {
        guard isViewerAdmin else {
            handleHomeTabTap()
            return
        }

        selectedTab = .activity
        activityTabSelectionTrigger &+= 1
    }

    /// Start of the current "night window": 7 AM today, or 7 AM yesterday
    /// if it's currently before 7 AM (i.e. still last night).
    private var currentNightWindowStart: Date {
        let cal = Calendar.current
        let now = Date()
        let sevenAMToday = cal.date(
            bySettingHour: 7, minute: 0, second: 0, of: now
        ) ?? now
        return now >= sevenAMToday
            ? sevenAMToday
            : cal.date(byAdding: .day, value: -1, to: sevenAMToday) ?? sevenAMToday
    }

    /// Drink tally for the current night window (7 AM → 7 AM cycle).
    /// Most-recently-posted drink type appears first. Multiple posts of
    /// the same drink accumulate into a single pill with a count.
    var viewerDrinkCounts: [(drink: DrinkTag, count: Int)] {
        guard let viewer else { return [] }
        return nightlyDrinkCounts(for: viewer.id)
    }

    /// Drink tally for any author within the current night window.
    /// Same accumulation logic as `viewerDrinkCounts` but parameterised
    /// by author so friend post cards can show the same nightly summary.
    func nightlyDrinkCounts(for authorID: UUID) -> [(drink: DrinkTag, count: Int)] {
        nightlyDrinkCounts(for: authorID, through: nil)
    }

    /// Drink tally for an author within the current night window, optionally
    /// capped at a specific post so older cards reflect the order as of that
    /// moment rather than the author's latest total for the night.
    func nightlyDrinkCounts(for authorID: UUID, through postID: UUID?) -> [(drink: DrinkTag, count: Int)] {
        let sources = tonightActivitySourcePosts
        let fingerprint = sources.count
            &+ (sources.first?.id.hashValue ?? 0)
            &+ (sources.last?.id.hashValue ?? 0)
        if fingerprint != nightlyDrinkCountsFingerprint {
            nightlyDrinkCountsCache.removeAll(keepingCapacity: true)
            nightlyDrinkCountsFingerprint = fingerprint
        }
        let cacheKey = "\(authorID.uuidString):\(postID?.uuidString ?? "")"
        if let cached = nightlyDrinkCountsCache[cacheKey] {
            return cached
        }

        let windowStart = currentNightWindowStart
        let authorPosts = sortPostsByRecency(
            sources.filter { $0.author.id == authorID && $0.createdAt >= windowStart }
        )

        // Slice the author's posts at the cutoff instead of nesting two
        // `firstIndex(where:)` calls inside a filter (the previous O(N²)
        // shape). `sortPostsByRecency` returns newest-first, so the cutoff
        // post and everything older share indices ≥ cutoffIndex.
        let tonightPosts: ArraySlice<MomentPost>
        if let postID {
            guard let cutoffIndex = authorPosts.firstIndex(where: { $0.id == postID }) else {
                nightlyDrinkCountsCache[cacheKey] = []
                return []
            }
            tonightPosts = authorPosts[cutoffIndex...]
        } else {
            tonightPosts = authorPosts[...]
        }

        // Newest-first so the first occurrence of a drink name maps to
        // the most-recently-posted instance — that pill appears first.
        var seen: [String: (drink: DrinkTag, count: Int)] = [:]
        var order: [String] = []
        for post in tonightPosts {
            guard let drink = post.drink else { continue }
            let key = drink.name
            if seen[key] == nil {
                seen[key] = (drink, 0)
                order.append(key)
            }
            seen[key]!.count += 1
        }
        let result = order.compactMap { seen[$0] }
        nightlyDrinkCountsCache[cacheKey] = result
        return result
    }

    var presenceSignals: [PresenceSignal] {
        Self.makePresenceSignals(from: posts, excluding: viewer?.id)
    }

    var activeVenueActivities: [VenueActivity] {
        let grouped = Dictionary(
            grouping: posts.compactMap { post -> (UUID, MomentPost)? in
                guard let venue = post.venue else { return nil }
                return (venue.id, post)
            },
            by: \.0
        )

        return grouped.compactMap { _, items in
            guard let venue = items.first?.1.venue else { return nil }
            return VenueActivity(
                venue: venue,
                posts: items.map(\.1).sorted { $0.createdAt > $1.createdAt }
            )
        }
        .sorted { lhs, rhs in
            (lhs.posts.first?.createdAt ?? .distantPast) > (rhs.posts.first?.createdAt ?? .distantPast)
        }
    }

    var livePosts: [MomentPost] {
        posts.filter { $0.createdAt > .now.addingTimeInterval(-4 * 60 * 60) }
    }

    var directFriendIDs: Set<UUID> {
        var ids = Set(friends.map(\.id))
        if let viewer {
            ids.insert(viewer.id)
        }
        return ids
    }

    var homeFeedAuthorIDs: Set<UUID> {
        if isViewerAdmin {
            var ids = Set(posts.map(\.author.id))
            if let viewer {
                ids.insert(viewer.id)
            }
            return ids
        }
        return directFriendIDs
    }

    var friendOfFriendIDs: Set<UUID> {
        return friendOfFriendIDsStore
    }

    var scopedPresenceSignals: [PresenceSignal] {
        switch feedScope {
        case .friends:
            presenceSignals.filter { directFriendIDs.contains($0.user.id) }
        case .local:
            []
        }
    }

    var scopedPosts: [MomentPost] {
        switch feedScope {
        case .friends:
            sortPostsByRecency(
                posts.filter { directFriendIDs.contains($0.author.id) }
            )
        case .local:
            localFeedPosts
        }
    }

    var scopedLivePosts: [MomentPost] {
        scopedPosts.filter { $0.createdAt > .now.addingTimeInterval(-4 * 60 * 60) }
    }

    var allPresenceClusters: [PresenceCluster] {
        let grouped = Dictionary(grouping: livePosts) { post in
            post.venue?.id ?? post.id
        }

        return grouped.compactMap { _, posts in
            guard let newest = posts.max(by: { $0.createdAt < $1.createdAt }) else { return nil }

            var seen = Set<UUID>()
            let friends = posts
                .flatMap { [$0.author] + $0.taggedFriends }
                .filter { friend in
                    guard friend.id != viewer?.id else { return false }
                    return seen.insert(friend.id).inserted
                }

            guard let anchor = friends.first ?? posts.first?.author else { return nil }

            return PresenceCluster(
                id: newest.venue?.id ?? newest.id,
                anchor: anchor,
                friends: friends.isEmpty ? [anchor] : friends,
                venue: newest.venue,
                updatedAt: newest.createdAt,
                connectionPath: posts.compactMap(\.connectionPath).first,
                contextReason: posts.compactMap(\.contextReason).first,
                relatedPostIDs: posts.map(\.id)
            )
        }
        .sorted { $0.updatedAt > $1.updatedAt }
    }

    var presenceClusters: [PresenceCluster] {
        let visiblePostIDs = Set(scopedLivePosts.map(\.id))

        return allPresenceClusters.filter { cluster in
            !Set(cluster.relatedPostIDs).isDisjoint(with: visiblePostIDs)
        }
    }

    var selectedPresenceCluster: PresenceCluster? {
        guard let selectedPresenceClusterID else { return nil }
        return presenceClusters.first(where: { $0.id == selectedPresenceClusterID })
    }

    var homeFeedPosts: [MomentPost] {
        if feedScope == .local {
            return localFeedPosts
        }
        // Home uses cursor-based pagination. Profile screens may hydrate older
        // authored posts into `store.posts`; once Home has paged older content,
        // clip the visible feed to the oldest cursor date Home explicitly
        // loaded so those profile-only rows do not leak into the main feed.
        let visible = posts.filter { post in
            guard !locallyDeletedPostIDs.contains(post.id) else { return false }
            guard isViewerAdmin || homeFeedAuthorIDs.contains(post.author.id) else { return false }
            guard let homeFeedCursorDate else { return true }
            return post.createdAt >= homeFeedCursorDate
        }
        return sortPostsByRecency(visible)
    }

    var hasLiveSignal: Bool {
        !presenceClusters.isEmpty || !scopedPresenceSignals.isEmpty
    }

    var activeNowCount: Int {
        let liveUsers = uniqueUsers(from: scopedLivePosts)
        let signalUsers = scopedPresenceSignals.map(\.user)
        var seen = Set<UUID>()

        return (liveUsers + signalUsers).filter { seen.insert($0.id).inserted }.count
    }

    var recentPresenceClusters: [PresenceCluster] {
        Array(presenceClusters.prefix(3))
    }

    var isLowDensityNight: Bool {
        activeNowCount <= 2
    }

    var chromeTintHex: String {
        homeFeedPosts.first?.media.primaryHex ?? "#D98B3D"
    }

    /// The primary (first-selected) drink for this draft.
    var selectedDrinkForDraft: DrinkTag? {
        guard let primaryID = postDraft.selectedDrinkIDs.first else { return nil }
        return drinks.first(where: { $0.id == primaryID })
    }

    /// All selected drinks in selection order.
    var selectedDrinksForDraft: [DrinkTag] {
        postDraft.selectedDrinkIDs.compactMap { id in drinks.first(where: { $0.id == id }) }
    }

    var selectedVenueForDraft: Venue? {
        venues.first(where: { $0.id == postDraft.selectedVenueID })
    }

    var taggedFriendsForDraft: [UserProfile] {
        friends.filter { postDraft.taggedFriendIDs.contains($0.id) }
    }

    var canPublishDraft: Bool {
        !isPublishingDraft && (postDraft.capturedPhotoData != nil || postDraft.isUsingSampleCapture)
            && (!postDraft.shareLocally || postDraft.location.map { abs($0.capturedAt.timeIntervalSinceNow) < 300 } == true)
    }

}

struct PendingPostReactionKey: Hashable {
    var postID: UUID
    var kind: ReactionKind
}

struct PendingCommentKey: Hashable {
    var postID: UUID
    var commentID: UUID
}

struct PendingCommentLikeKey: Hashable {
    var postID: UUID
    var commentID: UUID
}
