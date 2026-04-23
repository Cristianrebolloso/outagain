import AuthenticationServices
import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    var authState: AuthState = .signedOut
    var onboardingStep: OnboardingStep = .welcome
    var onboardingDraft = OnboardingDraft()
    var selectedTab: AppTab = .home
    var feedScope: FeedScope = .friends
    var selectedPresenceClusterID: UUID?
    var isNotificationsPresented = false
    var isPostFlowPresented = false
    var postDraft = PostDraft()
    var viewer: UserProfile?

    var friends = SampleData.friends
    var suggestedFriends = SampleData.suggestedFriends
    var drinks = SampleData.drinks
    var venues = SampleData.venues
    var posts = SampleData.posts.sorted { $0.createdAt > $1.createdAt }
    var presenceSignals = SampleData.presenceSignals.sorted { $0.createdAt > $1.createdAt }
    var notifications = SampleData.notifications.sorted { $0.createdAt > $1.createdAt }

    @ObservationIgnored private let backend: SocialBackendClient

    init(backend: SocialBackendClient? = nil) {
        self.backend = backend ?? MockSocialBackendClient(environment: .placeholder)
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

    var favoriteDrinks: [DrinkTag] {
        Array(drinks.prefix(3))
    }

    var recentDrinks: [DrinkTag] {
        Array(drinks.prefix(4))
    }

    var viewerIdentity: UserProfile {
        viewer ?? SampleData.seedViewer
    }

    var viewerPosts: [MomentPost] {
        guard let viewer else { return [] }
        return posts.filter { $0.author.id == viewer.id }
    }

    var activeVenueActivities: [VenueActivity] {
        let grouped = Dictionary(grouping: posts.compactMap { post -> (UUID, MomentPost)? in
            guard let venue = post.venue else { return nil }
            return (venue.id, post)
        }, by: \.0)

        return grouped.compactMap { venueID, items in
            guard let venue = venues.first(where: { $0.id == venueID }) else { return nil }
            return VenueActivity(venue: venue, posts: items.map(\.1).sorted { $0.createdAt > $1.createdAt })
        }
        .sorted { lhs, rhs in
            (lhs.posts.first?.createdAt ?? .distantPast) > (rhs.posts.first?.createdAt ?? .distantPast)
        }
    }

    var livePosts: [MomentPost] {
        posts.filter { $0.createdAt > .now.addingTimeInterval(-4 * 60 * 60) }
    }

    private var directFriendIDs: Set<UUID> {
        Set(friends.map(\.id)).union([viewerIdentity.id])
    }

    private var friendOfFriendIDs: Set<UUID> {
        Set(suggestedFriends.map(\.id))
    }

    private var scopedPresenceSignals: [PresenceSignal] {
        switch feedScope {
        case .friends:
            presenceSignals.filter { directFriendIDs.contains($0.user.id) }
        case .friendsOfFriends:
            presenceSignals.filter { friendOfFriendIDs.contains($0.user.id) }
        }
    }

    private var scopedPosts: [MomentPost] {
        switch feedScope {
        case .friends:
            posts.filter { directFriendIDs.contains($0.author.id) }
        case .friendsOfFriends:
            posts.filter { isFriendsOfFriendsPost($0) }
        }
    }

    private var scopedLivePosts: [MomentPost] {
        scopedPosts.filter { $0.createdAt > .now.addingTimeInterval(-4 * 60 * 60) }
    }

    private var allPresenceClusters: [PresenceCluster] {
        let grouped = Dictionary(grouping: livePosts) { post in
            post.venue?.id ?? post.id
        }

        return grouped.compactMap { _, posts in
            guard let newest = posts.max(by: { $0.createdAt < $1.createdAt }) else { return nil }

            var seen = Set<UUID>()
            let friends = posts
                .flatMap { [ $0.author ] + $0.taggedFriends }
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
        let basePosts = scopedLivePosts.isEmpty ? scopedPosts : scopedLivePosts

        if let cluster = selectedPresenceCluster {
            let clusterPosts = basePosts.filter { cluster.relatedPostIDs.contains($0.id) }
            if !clusterPosts.isEmpty {
                return clusterPosts + basePosts.filter { !cluster.relatedPostIDs.contains($0.id) }
            }
        }

        if basePosts.isEmpty {
            return Array(scopedPosts.prefix(3))
        }

        return basePosts
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

    var selectedDrinkForDraft: DrinkTag? {
        drinks.first(where: { $0.id == postDraft.selectedDrinkID })
    }

    var selectedVenueForDraft: Venue? {
        venues.first(where: { $0.id == postDraft.selectedVenueID })
    }

    var taggedFriendsForDraft: [UserProfile] {
        friends.filter { postDraft.taggedFriendIDs.contains($0.id) }
    }

    var canPublishDraft: Bool {
        selectedDrinkForDraft != nil && (postDraft.capturedPhotoData != nil || postDraft.isUsingSampleCapture)
    }

    var weeklyRecap: WeeklyRecap {
        let posts = viewerPosts
        let momentsPosted = posts.count
        let favoriteDrink = mostFrequentDrink(in: posts) ?? drinks[0]
        let commonVenue = mostFrequentVenue(in: posts)
        let totalInteractions = posts.reduce(0) { partialResult, post in
            partialResult + post.reactions.reduce(0) { $0 + $1.count } + post.comments.count
        }
        let nightsActive = Set(posts.map { Calendar.current.startOfDay(for: $0.createdAt) }).count

        return WeeklyRecap(
            momentsPosted: momentsPosted,
            favoriteDrink: favoriteDrink,
            commonVenue: commonVenue,
            nightsActive: nightsActive,
            totalInteractions: totalInteractions
        )
    }

    func selectFeedScope(_ scope: FeedScope) {
        feedScope = scope

        if !presenceClusters.contains(where: { $0.id == selectedPresenceClusterID }) {
            selectedPresenceClusterID = presenceClusters.first?.id
        }
    }

    func selectPresenceCluster(_ cluster: PresenceCluster?) {
        selectedPresenceClusterID = cluster?.id
    }

    func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        // The UI prototype advances after the Apple handoff; token exchange belongs in the Supabase adapter.
        if case .failure = result {
            authState = .signedIn
            onboardingStep = .profile
            return
        }

        authState = .signedIn
        onboardingStep = .profile
    }

    func continueFromProfile() {
        guard !onboardingDraft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        if onboardingDraft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onboardingDraft.displayName = onboardingDraft.username
        }

        if onboardingDraft.inviteLink.isEmpty {
            onboardingDraft.inviteLink = backend.createInviteLink(for: onboardingDraft.username).absoluteString
        }

        onboardingStep = .permissions
    }

    func continueFromPermissions() {
        onboardingStep = .invite
    }

    func enterApp() {
        let username = onboardingDraft.username.lowercased()
        viewer = UserProfile(
            id: SampleData.seedViewer.id,
            displayName: onboardingDraft.displayName,
            username: username,
            avatar: AvatarStyle(
                symbol: "moon.stars.fill",
                primaryHex: "#D98B3D",
                secondaryHex: "#281916",
                imageData: onboardingDraft.profileImageData
            ),
            isCloseFriend: true
        )

        onboardingStep = .done
        selectedTab = .home
        feedScope = .friends
        selectedPresenceClusterID = presenceClusters.first?.id
    }

    func openNotifications() {
        notifications = notifications.map {
            var copy = $0
            copy.isRead = true
            return copy
        }
        isNotificationsPresented = true
    }

    func openPostFlow() {
        resetDraft()
        isPostFlowPresented = true
    }

    func closePostFlow() {
        isPostFlowPresented = false
        resetDraft()
    }

    func applyCapturedPhoto(_ data: Data?, lensMode: CameraCaptureMode) {
        postDraft.capturedPhotoData = data
        postDraft.lensMode = lensMode
        postDraft.isUsingSampleCapture = false
    }

    func useSampleCapture() {
        postDraft.capturedPhotoData = nil
        postDraft.sampleSymbol = "sparkles.tv"
        postDraft.isUsingSampleCapture = true
    }

    func selectDrink(_ drink: DrinkTag) {
        postDraft.selectedDrinkID = drink.id
    }

    func selectVenue(_ venue: Venue) {
        postDraft.selectedVenueID = venue.id
    }

    func toggleTaggedFriend(_ friend: UserProfile) {
        if postDraft.taggedFriendIDs.contains(friend.id) {
            postDraft.taggedFriendIDs.remove(friend.id)
        } else {
            postDraft.taggedFriendIDs.insert(friend.id)
        }
    }

    func publishDraft() {
        guard let viewer, let drink = selectedDrinkForDraft, canPublishDraft else { return }

        let venue = selectedVenueForDraft
        let taggedFriends = taggedFriendsForDraft
        let trimmedCaption = postDraft.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let companionSummary = taggedFriends.isEmpty
            ? nil
            : "With \(taggedFriends.first?.displayName ?? "friends")\(taggedFriends.count > 1 ? " +\(taggedFriends.count - 1)" : "")"

        let newPost = MomentPost(
            id: UUID(),
            author: viewer,
            drink: drink,
            venue: venue,
            caption: trimmedCaption.isEmpty ? "Pulled into the night fast." : trimmedCaption,
            createdAt: .now,
            taggedFriends: taggedFriends,
            isSharedMoment: postDraft.isSharedMoment,
            media: MomentMedia(
                photoData: postDraft.capturedPhotoData,
                primaryHex: drink.primaryHex,
                secondaryHex: drink.secondaryHex,
                symbol: postDraft.sampleSymbol
            ),
            reactions: [ReactionSummary(kind: .cheers, count: 1)],
            comments: [],
            presenceNote: taggedFriends.isEmpty ? nil : "\(taggedFriends.first?.displayName ?? "Friends") is in the moment",
            connectionPath: nil,
            contextReason: companionSummary ?? (venue == nil ? "Live right now" : "Just checked in")
        )

        posts.insert(newPost, at: 0)
        notifications.insert(
            AppNotification(
                id: UUID(),
                kind: .sharedMoment,
                title: "Moment posted",
                detail: venue.map { "You just checked in at \($0.name)." } ?? "Your camera-first post is live.",
                createdAt: .now,
                isRead: false
            ),
            at: 0
        )

        selectedTab = .home
        feedScope = .friends
        selectedPresenceClusterID = presenceClusters.first?.id
        isPostFlowPresented = false
        resetDraft()
    }

    func addReaction(_ kind: ReactionKind, to post: MomentPost) {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }

        if let reactionIndex = posts[index].reactions.firstIndex(where: { $0.kind == kind }) {
            posts[index].reactions[reactionIndex].count += 1
        } else {
            posts[index].reactions.append(ReactionSummary(kind: kind, count: 1))
        }
    }

    func addComment(
        _ text: String,
        kind: CommentKind = .text,
        toPostID postID: UUID,
        replyingTo replyTarget: Comment? = nil
    ) {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }

        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackText: String = switch kind {
        case .text:
            ""
        case .photo:
            "Photo reply"
        case .gif:
            "GIF reply"
        }

        guard kind != .text || !trimmedText.isEmpty else { return }

        posts[index].comments.insert(
            Comment(
                id: UUID(),
                author: viewerIdentity,
                text: trimmedText.isEmpty ? fallbackText : trimmedText,
                createdAt: .now,
                kind: kind,
                replyToCommentID: replyTarget?.id,
                replyToDisplayName: replyTarget?.author.displayName
            ),
            at: 0
        )
    }

    func toggleCommentLike(commentID: UUID, inPostID postID: UUID) {
        guard let postIndex = posts.firstIndex(where: { $0.id == postID }),
              let commentIndex = posts[postIndex].comments.firstIndex(where: { $0.id == commentID })
        else { return }

        posts[postIndex].comments[commentIndex].isLikedByViewer.toggle()
        if posts[postIndex].comments[commentIndex].isLikedByViewer {
            posts[postIndex].comments[commentIndex].likeCount += 1
        } else {
            posts[postIndex].comments[commentIndex].likeCount = max(posts[postIndex].comments[commentIndex].likeCount - 1, 0)
        }
    }

    private func resetDraft() {
        postDraft = PostDraft(
            capturedPhotoData: nil,
            selectedDrinkID: drinks.first?.id,
            selectedVenueID: nil,
            caption: "",
            taggedFriendIDs: [],
            isSharedMoment: false,
            sampleSymbol: "camera.aperture",
            lensMode: .single,
            isUsingSampleCapture: false
        )
    }

    private func mostFrequentDrink(in posts: [MomentPost]) -> DrinkTag? {
        let counts = Dictionary(grouping: posts, by: \.drink.id)
            .mapValues(\.count)
        guard let bestID = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return drinks.first(where: { $0.id == bestID })
    }

    private func mostFrequentVenue(in posts: [MomentPost]) -> Venue? {
        let counts = Dictionary(grouping: posts.compactMap(\.venue), by: \.id)
            .mapValues(\.count)
        guard let bestID = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        return venues.first(where: { $0.id == bestID })
    }

    private func uniqueUsers(from posts: [MomentPost]) -> [UserProfile] {
        var seen = Set<UUID>()

        return posts
            .flatMap { [$0.author] + $0.taggedFriends }
            .filter { user in
                guard user.id != viewer?.id else { return false }
                return seen.insert(user.id).inserted
            }
    }

    private func isFriendsOfFriendsPost(_ post: MomentPost) -> Bool {
        if friendOfFriendIDs.contains(post.author.id) {
            return true
        }

        if post.connectionPath != nil {
            return true
        }

        return post.taggedFriends.contains { friendOfFriendIDs.contains($0.id) }
    }
}
