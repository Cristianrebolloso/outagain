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
    func signIn(email: String, password: String) async throws { throw error }
    func signOut() async throws {}
    func loadAppData() async throws -> SocialBootstrap { throw error }
    func checkUsernameAvailability(_ username: String) async throws -> UsernameAvailability {
        throw error
    }
    func createProfile(_ request: ProfileCreateRequest) async throws -> UserProfile { throw error }
    func updateProfile(_ request: ProfileUpdateRequest, for viewer: UserProfile) async throws -> UserProfile {
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
    func searchContacts(matching contacts: [ContactLookupSeed], excluding viewer: UserProfile?) async throws -> [UserProfile] {
        throw error
    }
    func loadFriendCount(of profile: UserProfile, for viewer: UserProfile) async throws -> Int {
        throw error
    }
    func loadFriends(of profile: UserProfile, for viewer: UserProfile) async throws -> [UserProfile] {
        throw error
    }
    func loadUserPosts(for profile: UserProfile, viewer: UserProfile) async throws -> [MomentPost] {
        throw error
    }
    func fetchNewFeedPosts(since: Date, viewer: UserProfile) async throws -> [MomentPost] { throw error }
    func loadFullComments(for post: MomentPost, viewer: UserProfile) async throws -> [Comment] { throw error }
    func loadReactors(for post: MomentPost, kind: ReactionKind, viewer: UserProfile) async throws -> [UserProfile] {
        throw error
    }
    func sendFriendRequest(to friend: UserProfile, for viewer: UserProfile) async throws { throw error }
    func acceptFriendRequest(_ request: FriendRequest, for viewer: UserProfile) async throws { throw error }
    func rejectFriendRequest(_ request: FriendRequest, for viewer: UserProfile) async throws { throw error }
    func blockUser(_ user: UserProfile, for viewer: UserProfile) async throws { throw error }
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
    func deleteComment(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws { throw error }
    func submitContentReport(_ request: ContentReportRequest) async throws { throw error }
    func markNotificationsRead(_ notificationIDs: [UUID]) async throws { throw error }
    func deleteNotification(id: UUID) async throws { throw error }
    func deleteNotifications(ids: [UUID]) async throws { throw error }
    func fetchNewNotifications(since: Date) async throws -> [AppNotification] { throw error }
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
}
