import Foundation

/// Placeholder backend used only when `SupabaseEnvironment.isConfigured` is false.
///
/// Every method throws so the app cannot silently render fake data. The real
/// application path uses `SupabaseSocialBackendClient`. This stub exists only
/// to satisfy the `AppStore`'s `SocialBackendClient` property at construction
/// time while the root view surfaces a configuration-error screen.
struct UnconfiguredBackend: SocialBackendClient {
    let environment: SupabaseEnvironment

    private var error: SupabaseBackendError {
        .requestFailed(
            "Out Again isn't connected to Supabase. Set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY in Info.plist before running.",
            statusCode: 0
        )
    }

    var hasStoredSession: Bool { false }

    func signUp(email: String, password: String) async throws { throw error }
    func signIn(identifier: String, password: String) async throws { throw error }
    @MainActor func signInWithPasskey() async throws { throw error }
    @MainActor func registerPasskey() async throws { throw error }
    func listPasskeys() async throws -> [AccountPasskey] { throw error }
    func deletePasskey(id: UUID) async throws { throw error }
    func signOut() async throws {}
    func changePassword(currentPassword: String, newPassword: String) async throws { throw error }
    func loadAppData() async throws -> SocialBootstrap { throw error }
    func fetchAppConfig() async throws -> [String: String] { throw error }
    func checkUsernameAvailability(_ username: String) async throws -> UsernameAvailability {
        throw error
    }
    func createProfile(_ request: ProfileCreateRequest) async throws -> UserProfile { throw error }
    func updateProfile(_ request: ProfileUpdateRequest, for viewer: UserProfile) async throws -> UserProfile {
        throw error
    }
    func updateBackgroundTheme(_ theme: BackgroundTheme, for viewer: UserProfile) async throws {
        throw error
    }
    func updateDrinkCatalogPreferences(_ preferences: DrinkCatalogPreferences, for viewer: UserProfile) async throws {
        throw error
    }
    func createInviteLink(for username: String) -> URL {
        URL(string: "https://outagain.app")!
    }
    func searchUsers(matching query: String, excluding viewer: UserProfile?) async throws -> [UserProfile] {
        throw error
    }
    func loadUserProfile(id: UUID) async throws -> UserProfile? { throw error }
    func loadFriendCount(of profile: UserProfile, for viewer: UserProfile) async throws -> Int {
        throw error
    }
    func loadPostCount(of profile: UserProfile) async throws -> Int { throw error }
    func loadFriends(of profile: UserProfile, for viewer: UserProfile) async throws -> [UserProfile] {
        throw error
    }
    func loadUserPostsPage(
        for profile: UserProfile,
        viewer: UserProfile,
        before: Date?,
        limit: Int
    ) async throws -> UserPostsPage {
        throw error
    }
    func loadTaggedPostsPage(
        for profile: UserProfile,
        viewer: UserProfile,
        before: Date?,
        limit: Int
    ) async throws -> UserPostsPage {
        throw error
    }
    func loadProfileStats(for profile: UserProfile, viewer: UserProfile) async throws -> ProfileStats {
        throw error
    }
    func loadProfileFriendRank(
        for profile: UserProfile,
        viewer: UserProfile,
        timeZoneIdentifier: String
    ) async throws -> ProfileFriendRank {
        throw error
    }
    func loadFeedPosts(
        authorIDs: [UUID],
        viewer: UserProfile,
        before: Date?,
        limit: Int
    ) async throws -> [MomentPost] {
        throw error
    }
    func loadPost(id: UUID, viewer: UserProfile) async throws -> MomentPost? { throw error }
    func loadVisiblePostIDs(_ postIDs: [UUID]) async throws -> Set<UUID> { throw error }
    func fetchNewFeedPosts(since: Date, viewer: UserProfile) async throws -> [MomentPost] { throw error }
    func loadFullComments(for post: MomentPost, viewer: UserProfile) async throws -> [Comment] { throw error }
    func loadReactors(for post: MomentPost, kind: ReactionKind, viewer: UserProfile) async throws -> [UserProfile] {
        throw error
    }
    func sendFriendRequest(to friend: UserProfile, for viewer: UserProfile) async throws { throw error }
    func acceptFriendRequest(_ request: FriendRequest, for viewer: UserProfile) async throws { throw error }
    func rejectFriendRequest(_ request: FriendRequest, for viewer: UserProfile) async throws { throw error }
    func blockUser(_ user: UserProfile, for viewer: UserProfile) async throws { throw error }
    func reportUser(_ user: UserProfile, for viewer: UserProfile) async throws { throw error }
    func unfriend(_ friend: UserProfile, for viewer: UserProfile) async throws { throw error }
    func publishMoment(_ request: MomentCreateRequest) async throws -> MomentPost { throw error }
    func deletePost(_ post: MomentPost, by viewer: UserProfile) async throws { throw error }
    func recordReaction(_ kind: ReactionKind, to post: MomentPost, by viewer: UserProfile) async throws -> OutboundNotificationDelivery? {
        throw error
    }
    func removeReaction(_ kind: ReactionKind, from post: MomentPost, by viewer: UserProfile) async throws { throw error }
    func deleteReactionNotification(_ kind: ReactionKind, on post: MomentPost, by actor: UserProfile) async throws { throw error }
    func recordComment(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws -> OutboundNotificationDelivery? {
        throw error
    }
    func recordCommentLike(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws -> OutboundNotificationDelivery? {
        throw error
    }
    func removeCommentLike(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws { throw error }
    func deleteCommentLikeNotification(_ comment: Comment, by actor: UserProfile) async throws { throw error }
    func deleteComment(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws { throw error }
    func submitContentReport(_ request: ContentReportRequest) async throws { throw error }
    func markNotificationsRead(_ notificationIDs: [UUID]) async throws { throw error }
    func deleteNotification(id: UUID) async throws { throw error }
    func deleteNotifications(ids: [UUID]) async throws { throw error }
    func fetchNewNotifications(since: Date) async throws -> [AppNotification] { throw error }
    func markAppAnnouncementSeen(id: UUID, for viewer: UserProfile) async throws { throw error }
    func loadUnseenAppAnnouncements(limit: Int) async throws -> [AppAnnouncement] { throw error }
    func registerDeviceToken(_ token: Data, environment: DeviceEnvironment, for viewer: UserProfile) async throws {
        throw error
    }
    func unregisterDeviceToken(_ token: Data, for viewer: UserProfile) async throws { throw error }
    func deleteCurrentAccount() async throws { throw error }
    func createNightGroup(_ group: NightGroup) async throws { throw error }
    func insertGroupNotifications(group: NightGroup, recipientIDs: [UUID], creator: UserProfile) async throws { throw error }
    func updateNightGroup(_ group: NightGroup) async throws { throw error }
    func renameNightGroup(id: UUID, name: String) async throws { throw error }
    func deleteNightGroup(id: UUID) async throws { throw error }
    func fetchNightGroups(createdAfter windowStart: Date) async throws -> [NightGroup] { throw error }
    func sendSelfTestNotification() async throws { throw error }
    func setVerified(_ isVerified: Bool, for profile: UserProfile) async throws { throw error }
    func setMaintenanceMode(enabled: Bool, title: String, message: String) async throws -> [String: String] { throw error }
    func publishAppAnnouncement(
        requestID: UUID,
        title: String,
        message: String,
        audience: AppAnnouncementAudience,
        targetUsernames: [String],
        delivery: AppAnnouncementDelivery
    ) async throws { throw error }
    func fetchAdminAppAnnouncements(limit: Int) async throws -> [AdminAppAnnouncement] { throw error }
    func fetchNotificationPreferences(for userID: UUID) async throws -> NotificationPreferences { throw error }
    func setNotificationPreference(_ category: PushNotificationCategory, enabled: Bool, for userID: UUID) async throws { throw error }
    func deactivateAppAnnouncement(id: UUID) async throws { throw error }
    func fetchAllUsersPage(offset: Int, limit: Int) async throws -> [UserProfile] { throw error }
    func fetchAdminReports(limit: Int, offset: Int) async throws -> [ContentReport] { throw error }
    func resolveReport(id: UUID) async throws { throw error }
    func deletePostAsAdmin(_ postID: UUID, reportID: UUID?) async throws { throw error }
    func deleteCommentAsAdmin(_ commentID: UUID, reportID: UUID?) async throws { throw error }
    func banUser(_ userID: UUID) async throws { throw error }
    func setUserBanned(_ isBanned: Bool, userID: UUID) async throws -> UserProfile { throw error }
    func deleteUserContent(userID: UUID) async throws -> AdminContentDeletionSummary { throw error }
}
