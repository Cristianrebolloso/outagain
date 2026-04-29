import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    static let pendingDeletedNotificationIDsKey = "OutAgain.pendingDeletedNotificationIDs"

    var authState: AuthState = .signedOut
    var onboardingStep: OnboardingStep = .welcome
    var authDraft = EmailPasswordAuthDraft()
    var onboardingDraft = OnboardingDraft()

    var selectedTab: AppTab = .home
    /// Incremented every time the Home tab is tapped so the feed can
    /// react even when Home is already the selected tab.
    var homeTabSelectionTrigger = 0
    var friendsPageMode: FriendsPageMode = .discover
    // When non-nil, the Friends tab auto-presents this profile on appear.
    var friendsTabPendingProfile: UserProfile? = nil
    var feedScope: FeedScope = .friends
    var selectedPresenceClusterID: UUID?
    var isPostFlowPresented = false
    var isMaddoxPlayerPresented = false
    /// Set to true when the user posts a Maddox drink. AppRootView watches
    /// isPostFlowPresented and presents the player once the cover is gone.
    var pendingMaddoxPlayer = false
    var isTabBarMinimized = false

    var postDraft = PostDraft()
    var viewer: UserProfile?
    var usernameAvailability: UsernameAvailability = .unchecked
    var profileEditor = ProfileEditorDraft()
    var profileUsernameAvailability: UsernameAvailability = .unchecked
    var notificationPreferences = AppStore.loadNotificationPreferences() {
        didSet {
            persistNotificationPreferences()
        }
    }
    var liveActivityPreferences = AppStore.loadLiveActivityPreferences() {
        didSet {
            persistLiveActivityPreferences()
        }
    }
    var accentColorChoice: AccentColorChoice = AppStore.loadAccentColorChoice() {
        didSet {
            UserDefaults.standard.set(accentColorChoice.rawValue, forKey: "OutAgain.accentColor")
        }
    }
    var isSavingProfile = false
    var profileEditorMessage: String?
    var friendSearchQuery = ""
    var friendSearchResults: [UserProfile] = []
    var contactMatches: [UserProfile] = []
    var isSearchingContactMatches = false
    var outboundNotificationDeliveries: [OutboundNotificationDelivery] = []
    var socialErrorMessage: String?
    var isLiveActivityPromptPresented = false
    var pendingLiveActivityPromptPost: MomentPost?

    /// Night groups: sourced from the backend `night_groups` table and synced
    /// on every bootstrap. All members of a group see it via RLS policy.
    var nightGroups: [NightGroup] = []
    /// Controls presentation of the group creation sheet from HomeFeedView.
    var isGroupCreationPresented = false
    /// The group whose feed is currently being viewed (nil = none open).
    var activeGroupID: UUID? = nil

    var friends: [UserProfile] = []
    var suggestedFriends: [UserProfile] = []
    var friendOfFriendIDsStore: Set<UUID> = []
    var incomingFriendRequests: [FriendRequest] = []
    var outgoingFriendRequests: [FriendRequest] = []
    var blockedUserIDs: Set<UUID> = []
    var blockedUsers: [UserProfile] = []
    var drinkCatalogPreferences = DrinkCatalogPreferences()
    var drinks = SeedCatalog.drinks
    var venues = SeedCatalog.venues
    var posts: [MomentPost] = []
    var notifications: [AppNotification] = []

    // Distinguishes "still loading" from "finished loading, user is signed out."
    // Without this, the root view renders the onboarding UI for the brief window
    // between process start and the first bootstrap returning, which looks like a
    // flash of the login screen on every cold launch.
    var bootstrapPhase: BootstrapPhase = .pending

    @ObservationIgnored let backend: SocialBackendClient
    @ObservationIgnored var didAttemptBootstrap = false
    @ObservationIgnored var pendingAPNsToken: Data?
    @ObservationIgnored var lastRegisteredAPNsToken: Data?
    @ObservationIgnored var friendSearchDebounceTask: Task<Void, Never>?
    @ObservationIgnored var foregroundPollTask: Task<Void, Never>?
    @ObservationIgnored var lastFullRefreshAt: Date?
    /// URL string → (width / height) aspect ratio, populated the first time
    /// each remote photo loads. Survives refreshAppData and view recreation
    /// so placeholders stay correctly sized across the app's lifetime.
    @ObservationIgnored var photoAspectRatioCache: [String: CGFloat] = [:]
    @ObservationIgnored var pendingDeletedNotificationIDs = AppStore.loadPendingDeletedNotificationIDs()
    @ObservationIgnored var lastSyncedDrinkCatalogPreferences = DrinkCatalogPreferences()

    init(backend: SocialBackendClient) {
        self.backend = backend
        resetDraft()
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

    var pendingIncomingRequestCount: Int {
        incomingFriendRequests.count
    }

    var favoriteDrinks: [DrinkTag] {
        Array(drinks.prefix(3))
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
        EmailAddressRules.normalized(authDraft.email)
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
            email: authDraft.email,
            password: authDraft.password
        ) != nil {
            return true
        }

        guard normalizedOnboardingEmail != nil else { return false }

        switch authDraft.mode {
        case .signUp:
            return PasswordRules.isValid(authPassword)
        case .signIn:
            return !authPassword.isEmpty
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
        let windowStart = currentNightWindowStart
        let authorPosts = sortPostsByRecency(
            posts.filter { $0.author.id == authorID }
        )
        let tonightPosts = authorPosts.filter { post in
            guard post.createdAt >= windowStart else { return false }
            guard let postID else { return true }
            guard let cutoffIndex = authorPosts.firstIndex(where: { $0.id == postID }),
                  let postIndex = authorPosts.firstIndex(where: { $0.id == post.id })
            else { return false }
            return postIndex >= cutoffIndex
        }
        // Newest-first so the first occurrence of a drink name maps to
        // the most-recently-posted instance — that pill appears first.
        var seen: [String: (drink: DrinkTag, count: Int)] = [:]
        var order: [String] = []
        for post in tonightPosts {
            let key = post.drink.name
            if seen[key] == nil {
                seen[key] = (post.drink, 0)
                order.append(key)
            }
            seen[key]!.count += 1
        }
        return order.compactMap { seen[$0] }
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

    var friendOfFriendIDs: Set<UUID> {
        friendOfFriendIDsStore
    }

    var scopedPresenceSignals: [PresenceSignal] {
        switch feedScope {
        case .friends:
            presenceSignals.filter { directFriendIDs.contains($0.user.id) }
        case .friendsOfFriends:
            presenceSignals.filter { friendOfFriendIDs.contains($0.user.id) }
        }
    }

    var scopedPosts: [MomentPost] {
        switch feedScope {
        case .friends:
            sortPostsByRecency(
                posts.filter { directFriendIDs.contains($0.author.id) }
            )
        case .friendsOfFriends:
            sortPostsByRecency(
                posts.filter { isFriendsOfFriendsPost($0) }
            )
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
        // The feed is continuous and never resets — show all posts the
        // viewer is allowed to see, newest first. scopedLivePosts (4-hour
        // window) is intentionally NOT used here; that filter only makes
        // sense for presence clusters ("who's out right now"), not the
        // scrollable feed which should persist across days.
        sortPostsByRecency(scopedPosts)
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
        postDraft.capturedPhotoData != nil || postDraft.isUsingSampleCapture
    }

    var weeklyRecap: WeeklyRecap {
        let posts = viewerPosts
        let favoriteDrink = mostFrequentDrink(in: posts) ?? drinks[0]
        let totalInteractions = posts.reduce(0) { partialResult, post in
            partialResult + post.reactions.reduce(0) { $0 + $1.count } + post.commentCount
        }
        let nightsActive = Set(posts.map { Calendar.current.startOfDay(for: $0.createdAt) }).count

        return WeeklyRecap(
            momentsPosted: posts.count,
            favoriteDrink: favoriteDrink,
            commonVenue: mostFrequentVenue(in: posts),
            nightsActive: nightsActive,
            totalInteractions: totalInteractions
        )
    }
}
