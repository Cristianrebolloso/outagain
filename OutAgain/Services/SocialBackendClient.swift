import Foundation

struct ProfileCreateRequest: Hashable {
    var email: String?
    var displayName: String
    var username: String
    var profileImageData: Data?
}

struct ProfileUpdateRequest: Hashable {
    var displayName: String
    var username: String
    var profileImageData: Data?
    /// The viewer's current avatar storage path, if known. When provided and
    /// `profileImageData` is nil, `updateProfile` skips the `fetchCurrentProfile`
    /// round-trip that was previously needed to obtain the existing path.
    var currentAvatarPath: String?
}

struct MomentCreateRequest: Hashable {
    var author: UserProfile
    var drink: DrinkTag
    var venue: Venue?
    var location: LocationSnapshot?
    var caption: String
    var taggedFriends: [UserProfile]
    var isSharedMoment: Bool
    var media: MomentMedia
}

enum ContentReportTarget: String, Hashable, Codable {
    case post
    case comment
}

struct ContentReportRequest: Hashable {
    var target: ContentReportTarget
    var postID: UUID?
    var commentID: UUID?
    var targetAuthorID: UUID
    var targetAuthorUsername: String
    var targetExcerpt: String
    var detail: String = ""
}

enum DeviceEnvironment: String {
    case development
    case production
}

protocol SocialBackendClient {
    /// True when the client has a stored auth session (access + refresh token).
    /// Used to distinguish "no profile row returned" (transient) from
    /// "genuinely not authenticated" (should sign out).
    var hasStoredSession: Bool { get }

    func signUp(email: String, password: String) async throws
    func signIn(email: String, password: String) async throws
    func signOut() async throws
    func loadAppData() async throws -> SocialBootstrap
    func checkUsernameAvailability(_ username: String) async throws -> UsernameAvailability
    func createProfile(_ request: ProfileCreateRequest) async throws -> UserProfile
    func updateProfile(_ request: ProfileUpdateRequest, for viewer: UserProfile) async throws -> UserProfile
    func updateDrinkCatalogPreferences(_ preferences: DrinkCatalogPreferences, for viewer: UserProfile) async throws
    func createInviteLink(for username: String) -> URL
    func searchUsers(matching query: String, excluding viewer: UserProfile?) async throws -> [UserProfile]
    func searchContacts(matching contacts: [ContactLookupSeed], excluding viewer: UserProfile?) async throws -> [UserProfile]
    func loadFriendCount(of profile: UserProfile, for viewer: UserProfile) async throws -> Int
    func loadFriends(of profile: UserProfile, for viewer: UserProfile) async throws -> [UserProfile]
    /// Fetches all posts authored by `profile`, including comments and reactions.
    /// Used when viewing a non-friend's profile where posts aren't in the
    /// viewer's feed bootstrap.
    func loadUserPosts(for profile: UserProfile, viewer: UserProfile) async throws -> [MomentPost]
    /// Lightweight feed delta used while the app is foregrounded. Returns only
    /// posts newer than `since`, already hydrated into feed-ready `MomentPost`s.
    func fetchNewFeedPosts(since: Date, viewer: UserProfile) async throws -> [MomentPost]
    /// Full comment thread for a single post. Used when the user opens the
    /// thread so the UI can avoid fetching every comment during bootstrap.
    func loadFullComments(for post: MomentPost, viewer: UserProfile) async throws -> [Comment]
    /// Full reactor list for one reaction kind on one post.
    func loadReactors(for post: MomentPost, kind: ReactionKind, viewer: UserProfile) async throws -> [UserProfile]

    // Friendship workflow
    func sendFriendRequest(to friend: UserProfile, for viewer: UserProfile) async throws
    func acceptFriendRequest(_ request: FriendRequest, for viewer: UserProfile) async throws
    func rejectFriendRequest(_ request: FriendRequest, for viewer: UserProfile) async throws
    func blockUser(_ user: UserProfile, for viewer: UserProfile) async throws
    func unfriend(_ friend: UserProfile, for viewer: UserProfile) async throws

    // Activity
    func publishMoment(_ request: MomentCreateRequest) async throws -> MomentPost
    func deletePost(_ post: MomentPost, by viewer: UserProfile) async throws
    func recordReaction(_ kind: ReactionKind, to post: MomentPost, by viewer: UserProfile) async throws -> OutboundNotificationDelivery?
    func removeReaction(_ kind: ReactionKind, from post: MomentPost, by viewer: UserProfile) async throws
    /// Deletes the notification that was pushed to the post author when the
    /// viewer reacted. Called on unlike so the recipient's Activity tab cleans
    /// up automatically without requiring a full bootstrap on their end.
    func deleteReactionNotification(_ kind: ReactionKind, on post: MomentPost, by actor: UserProfile) async throws
    func recordComment(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws -> OutboundNotificationDelivery?
    func deleteComment(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws
    func submitContentReport(_ request: ContentReportRequest) async throws
    func markNotificationsRead(_ notificationIDs: [UUID]) async throws
    /// Deletes a single notification row so it no longer appears on this or
    /// any other device after the next bootstrap.
    func deleteNotification(id: UUID) async throws
    /// Deletes many notification rows in one request so bulk clear operations
    /// don't race a manual refresh with a slow per-row delete loop.
    func deleteNotifications(ids: [UUID]) async throws
    /// Lightweight delta poll — returns only AppNotifications created after
    /// `since`. Actor profiles are embedded via the join so no separate
    /// profile fetch is needed.
    func fetchNewNotifications(since: Date) async throws -> [AppNotification]

    // Push notifications
    func registerDeviceToken(_ token: Data, environment: DeviceEnvironment, for viewer: UserProfile) async throws
    func unregisterDeviceToken(_ token: Data, for viewer: UserProfile) async throws
    func deleteCurrentAccount() async throws

    // Night groups (backed by `night_groups` table; visible to all members via RLS)
    /// Writes a new group row. The caller pre-generates the UUID so the client
    /// can optimistically insert into `nightGroups` before the round-trip returns.
    func createNightGroup(_ group: NightGroup) async throws
    /// Inserts a `groupAdded` notification row for each member ID in `recipientIDs`.
    /// The existing APNs push-dispatch trigger fires automatically on insert, so
    /// this is the only client-side step needed to deliver the push.
    func insertGroupNotifications(group: NightGroup, recipientIDs: [UUID], creator: UserProfile) async throws
    /// Replaces the mutable fields (name, member_ids) of an existing group.
    /// Only the creator's device succeeds — RLS rejects other callers.
    func updateNightGroup(_ group: NightGroup) async throws
    /// Renames a group without touching member_ids. Any member may call this;
    /// the `member_update` RLS policy permits the write for all members.
    func renameNightGroup(id: UUID, name: String) async throws
    /// Deletes the group row. RLS enforces creator-only.
    func deleteNightGroup(id: UUID) async throws
    /// Fetches all groups where auth.uid() is in member_ids and whose
    /// created_at falls within the provided tonight window.
    func fetchNightGroups(createdAfter windowStart: Date) async throws -> [NightGroup]

    // Diagnostics (Debug builds only; server guards to auth.uid() = self)
    func sendSelfTestNotification() async throws
}
