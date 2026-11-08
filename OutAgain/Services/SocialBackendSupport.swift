import Foundation

enum PeopleSearchRules {
    static func normalized(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let unprefixed = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
        return String(unprefixed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(64))
    }
}

struct SupabasePeopleSearchRequest: Encodable {
    var search_query: String
    var result_limit = 24
}

enum UsernameRules {
    static func normalized(_ username: String) -> String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func searchFragment(_ query: String) -> String {
        normalized(query)
            .replacingOccurrences(of: "@", with: "")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func isValid(_ username: String) -> Bool {
        guard (3...20).contains(username.count) else { return false }
        return username.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_"
        }
    }

    static func suggestion(for username: String, reserved: Set<String>) -> String {
        for suffix in ["night", "sips", "out", "afterdark"] {
            let candidate = String((username + suffix).prefix(20))
            if !reserved.contains(candidate) {
                return candidate
            }
        }

        return String((username + UUID().uuidString.prefix(4)).prefix(20))
    }
}

enum SignInIdentifierRules {
    static func normalized(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let email = EmailAddressRules.normalized(value) { return email }
        let username = value.hasPrefix("@") ? String(value.dropFirst()) : value
        return UsernameRules.isValid(username) ? username : nil
    }
}

enum SupabaseBackendError: LocalizedError {
    case invalidEmailAddress
    case invalidPassword
    case invalidUsername
    case accountBanned
    case notAuthenticated
    case invalidResponse
    case requestFailed(String, statusCode: Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidEmailAddress:
            return "Enter a valid email address to keep going."
        case .invalidPassword:
            return "Use at least \(PasswordRules.minimumLength) characters for your password."
        case .invalidUsername:
            return "That username doesn't match the app rules."
        case .accountBanned:
            return "This account has been banned from Out Again."
        case .notAuthenticated:
            return "There isn't an authenticated Supabase session yet."
        case .invalidResponse:
            return "The backend returned an unreadable response."
        case .requestFailed(let message, _):
            return message
        case .transport(let message):
            return message
        }
    }
}

struct SupabaseEmailPasswordAuthRequest: Encodable {
    var email: String
    var password: String
}

struct SupabaseUsernameSignInRequest: Encodable {
    var username: String
    var password: String
}

struct SupabaseRefreshTokenGrantRequest: Encodable {
    var refresh_token: String
}

struct SupabasePasswordUpdateRequest: Encodable {
    var password: String
}

struct SupabaseSignUpResponse: Decodable {
    var access_token: String?
    var refresh_token: String?
    var expires_at: TimeInterval?
    var expires_in: Int?
    var token_type: String?
    var user: SupabaseAuthUser?

    func sessionIfAvailable() -> SupabaseAuthSession? {
        guard let access_token else { return nil }
        return SupabaseAuthSession(
            access_token: access_token,
            refresh_token: refresh_token,
            expires_at: expires_at,
            expires_in: expires_in,
            token_type: token_type,
            user: user
        )
    }
}

struct SupabaseAuthSession: Codable {
    var access_token: String
    var refresh_token: String?
    var expires_at: TimeInterval?
    var expires_in: Int?
    var token_type: String?
    var user: SupabaseAuthUser?
}

struct SupabaseAuthUser: Codable {
    var id: UUID
    var email: String?
}

struct SupabaseErrorEnvelope: Decodable {
    var message: String?
    var error_description: String?
    var msg: String?
    var error: String?
}

struct SupabaseProfileRecord: Codable {
    static let legacySelectList = "id,username,display_name,avatar_path,avatar_version"
    static let verifiedSelectList = "id,username,display_name,avatar_path,avatar_version,is_verified"
    static let selectList = "id,username,display_name,avatar_path,avatar_version,background_theme,is_verified"
    static let viewerLegacySelectList = "\(legacySelectList),custom_drinks,deleted_drink_names,drink_order_names"
    static let viewerVerifiedSelectList = "\(verifiedSelectList),custom_drinks,deleted_drink_names,drink_order_names"
    static let viewerSelectList = "\(selectList),custom_drinks,deleted_drink_names,drink_order_names"

    var id: UUID
    var username: String?
    var display_name: String?
    var avatar_path: String?
    var avatar_version: Int?
    var background_theme: String?
    var is_verified: Bool?
    var is_banned: Bool?
    var custom_drinks: [DrinkTag]?
    var deleted_drink_names: [String]?
    var drink_order_names: [String]?
    var apple_user_identifier: String?
    var mutual_count: Int?

    /// Convenience: the client treats a missing username as "profile needs onboarding."
    var hasCompletedOnboarding: Bool {
        guard let username, !username.isEmpty else { return false }
        return true
    }

    var normalizedUsername: String {
        UsernameRules.normalized(username ?? "")
    }
}

struct SupabasePostIDsRequest: Encodable {
    var post_ids: [UUID]
}

struct SupabaseSinceCursorRequest: Encodable {
    var since: Date
    var lim: Int
}

struct SupabaseProfileUpdateRecord: Encodable {
    var username: String
    var display_name: String
    var avatar_path: String?
}

struct SupabaseExactUsernameProfileRequest: Encodable {
    var search_usernames: [String]
}

struct SupabaseProfileSummariesByIDsRequest: Encodable {
    var profile_ids: [UUID]
}

struct SupabaseUsernameAvailabilityRequest: Encodable {
    var search_username: String
}

struct SupabaseProfileSuggestionsRequest: Encodable {
    var viewer_id: UUID
    var lim: Int
}

struct SupabaseProfileBanRequest: Encodable {
    var user_id: UUID
}

struct SupabaseBackgroundThemeUpdateRecord: Encodable {
    var background_theme: String
}

struct SupabaseDrinkCatalogUpdateRecord: Encodable {
    var custom_drinks: [DrinkTag]
    var deleted_drink_names: [String]
    var drink_order_names: [String]
}

struct SupabaseFriendshipRecord: Encodable {
    var user_id: UUID
    var friend_id: UUID
    var status: String
}

struct SupabaseStoredFriendshipRecord: Decodable {
    static let selectList = "id,user_id,friend_id,status,created_at"

    var id: UUID
    var user_id: UUID
    var friend_id: UUID
    var status: String
    var created_at: Date
}

struct SupabaseFriendshipStatusPatch: Encodable {
    var status: String
}

struct SupabaseProfileFriendsRequest: Encodable {
    var profile_id: UUID
}

struct SupabaseProfileFriendRankRequest: Encodable {
    var profile_id: UUID
    var timezone_name: String
}

struct SupabaseProfileFriendCountResponse: Decodable {
    var count: Int
}

struct SupabaseProfileFriendRankResponse: Decodable {
    var rank: Int
    var group_size: Int
}

struct SupabaseFriendOfFriendIDResponse: Decodable {
    var id: UUID
    /// Number of the viewer's accepted friends who are also friends with this
    /// FoF candidate. Populated by the friends_of_friends_ids RPC v2.
    var mutual_count: Int
}

struct SupabaseViewerIDRequest: Encodable {
    var viewer_id: UUID
}

struct SupabaseTonightFeedRequest: Encodable {
    var viewer_id: UUID
    var lim: Int
}

struct SupabaseDeviceRecord: Encodable {
    var user_id: UUID
    var apns_token: String
    var environment: String
    var last_seen_at: Date
}

struct SupabasePostRecord: Encodable {
    var id: UUID? = nil
    var is_shared_locally = false
    var author_id: UUID
    var drink_name: String
    var drink_subtitle: String
    var drink_symbol: String
    var drink_primary_hex: String
    var drink_secondary_hex: String
    var venue_name: String?
    var venue_neighborhood: String?
    var venue_city: String?
    var venue_latitude: Double?
    var venue_longitude: Double?
    var latitude: Double?
    var longitude: Double?
    var horizontal_accuracy: Double?
    var caption: String
    var image_path: String?
    var tagged_user_ids: [UUID]
    var is_shared_moment: Bool
}

struct SupabaseInsertedRecord: Decodable {
    var id: UUID
}

struct SupabaseFeedPostRecord: Decodable {
    var is_shared_locally: Bool? = nil
    static let selectList = "id,author_id,drink_name,drink_subtitle,drink_symbol,drink_primary_hex,drink_secondary_hex,venue_name,venue_neighborhood,venue_city,venue_latitude,venue_longitude,latitude,longitude,horizontal_accuracy,caption,image_path,tagged_user_ids,is_shared_moment,created_at,is_shared_locally"

    var id: UUID
    var author_id: UUID
    var drink_name: String
    var drink_subtitle: String
    var drink_symbol: String
    var drink_primary_hex: String
    var drink_secondary_hex: String
    var venue_name: String?
    var venue_neighborhood: String?
    var venue_city: String?
    var venue_latitude: Double?
    var venue_longitude: Double?
    var latitude: Double?
    var longitude: Double?
    var horizontal_accuracy: Double?
    var caption: String
    var image_path: String?
    var tagged_user_ids: [UUID]
    var is_shared_moment: Bool
    var created_at: Date
}

struct SupabaseProfileStatsPostRecord: Decodable {
    static let selectList = "id,drink_name,created_at"

    var id: UUID
    var drink_name: String?
    var created_at: Date
}

struct SupabaseReactionRecord: Encodable {
    var post_id: UUID
    var user_id: UUID
    var kind: String
}

struct SupabaseFeedReactionRecord: Decodable {
    static let selectList = "post_id,user_id,kind,created_at"

    var post_id: UUID
    var user_id: UUID
    var kind: String
    var created_at: Date

    var reactionKind: ReactionKind? {
        ReactionKind(rawValue: kind)
    }
}

struct SupabasePostEngagementRecord: Decodable {
    var post_id: UUID
    var comment_count: Int
    var cheers_count: Int
    var spark_count: Int
    var fire_count: Int
    var dislike_count: Int?
    var viewer_reaction_kinds: [String]

    var reactionCounts: [ReactionKind: Int] {
        var counts: [ReactionKind: Int] = [:]
        if cheers_count > 0 { counts[.cheers] = cheers_count }
        if spark_count > 0 { counts[.spark] = spark_count }
        if fire_count > 0 { counts[.fire] = fire_count }
        if let dislike_count, dislike_count > 0 { counts[.dislike] = dislike_count }
        return counts
    }

    var viewerReactionKinds: Set<ReactionKind> {
        Set(viewer_reaction_kinds.compactMap(ReactionKind.init(rawValue:)))
    }
}

struct SupabaseCommentRecord: Encodable {
    var id: UUID
    var post_id: UUID
    var author_id: UUID
    var body: String
    var kind: String
    var image_path: String?
    var reply_to_comment_id: UUID?
    var mentioned_user_ids: [UUID]
}

struct SupabaseFeedCommentRecord: Decodable {
    static let selectList = "id,post_id,author_id,body,kind,image_path,reply_to_comment_id,created_at"

    var id: UUID
    var post_id: UUID
    var author_id: UUID
    var body: String
    var kind: String
    var image_path: String?
    var reply_to_comment_id: UUID?
    var created_at: Date

    var commentKind: CommentKind {
        switch kind {
        case "photo":
            return .photo
        case "gif":
            return .gif
        default:
            return .text
        }
    }
}

struct SupabaseCommentLikeRecord: Codable {
    static let selectList = "comment_id,user_id,created_at"

    var comment_id: UUID
    var user_id: UUID
    var created_at: Date?
}

struct SupabaseNotificationRecord: Decodable {
    static let selectList = "id,kind,title,detail,created_at,read_at,actor_id,post_id,comment_id,night_start,night_end,night_group_id"

    var id: UUID
    var kind: String
    var title: String
    var detail: String
    var created_at: Date
    var read_at: Date?
    var actor_id: UUID?
    var post_id: UUID?
    var comment_id: UUID?
    var night_start: Date? = nil
    var night_end: Date? = nil
    var night_group_id: UUID? = nil

    var notificationKind: NotificationKind {
        NotificationKind(rawValue: kind) ?? .friendPost
    }
}

/// Notification record with actor profile embedded for the delta poll.
/// PostgREST returns the joined profile as a nested object under "actor".
struct SupabaseNotificationWithActorRecord: Decodable {
    struct EmbeddedProfile: Decodable {
        var id: UUID
        var username: String?
        var display_name: String
        var avatar_path: String?
        var avatar_version: Int?
        var is_verified: Bool?
    }

    var id: UUID
    var kind: String
    var title: String
    var detail: String
    var created_at: Date
    var read_at: Date?
    var actor_id: UUID?
    var post_id: UUID?
    var comment_id: UUID?
    var night_start: Date? = nil
    var night_end: Date? = nil
    var night_group_id: UUID? = nil
    var actor: EmbeddedProfile?

    var notificationKind: NotificationKind {
        NotificationKind(rawValue: kind) ?? .friendPost
    }
}

struct SupabaseNotificationReadPatch: Encodable {
    var read_at: Date
}

struct SupabaseAppAnnouncementRecord: Decodable {
    var id: UUID
    var title: String
    var message: String
    var image_url: URL?
    var created_at: Date
}

struct SupabaseAppConfigRecord: Decodable {
    var key: String
    var value: String
}

struct SupabaseAnnouncementLimitRequest: Encodable {
    var limit_count: Int
}

struct SupabaseAnnouncementSeenRequest: Encodable {
    var announcement_id: UUID
}

struct SupabaseMaintenanceConfigUpdateRequest: Encodable {
    var enabled: Bool
    var title: String
    var message: String
}

struct SupabaseAppAnnouncementCreateRequest: Encodable {
    var request_id: UUID
    var title: String
    var message: String
    var audience: String
    var target_usernames: [String]
    var delivery: String
}

struct SupabaseAdminAppAnnouncementRecord: Decodable {
    var announcement_id: UUID
    var title: String
    var message: String
    var audience: String
    var target_usernames: [String]?
    var recipient_count: Int?
    var is_active: Bool
    var created_at: Date
    var delivery: String?
    var push_recipient_count: Int?
    var push_accepted_count: Int?
    var push_failure_count: Int?
    var push_skipped_count: Int?
    var push_pending_count: Int?
}

struct SupabaseAdminAnnouncementIDRequest: Encodable {
    var announcement_id: UUID
}

struct SupabaseAdminPageRequest: Encodable {
    var limit_count: Int
    var offset_count: Int
}

struct SupabaseAdminProfileFlagRequest: Encodable {
    var target_user_id: UUID
    var verified: Bool?
    var banned: Bool?
    var reason: String?
}

struct SupabaseAdminUserIDRequest: Encodable {
    var target_user_id: UUID
}

struct SupabaseAdminContentDeletionRecord: Decodable {
    var posts_deleted: Int
    var comments_deleted: Int
    var reactions_deleted: Int
    var comment_likes_deleted: Int
    var friendships_deleted: Int
    var notifications_deleted: Int
    var content_reports_deleted: Int
    var groups_deleted: Int
    var groups_updated: Int
    var devices_deleted: Int
    var storage_objects_deleted: Int
}

struct SupabaseContentReportSubmitRequest: Encodable {
    var target_type: String
    var target_post_id: UUID?
    var target_comment_id: UUID?
    var target_user_id: UUID?
    var detail: String
}

struct SupabaseEmptyRequest: Encodable {}

struct SupabaseAdminReportIDRequest: Encodable {
    var report_id: UUID
}

struct SupabaseAdminDeletePostRequest: Encodable {
    var target_post_id: UUID
    var report_id: UUID?
}

struct SupabaseDeletePostRequest: Encodable {
    var target_post_id: UUID
}

struct SupabaseAdminDeleteCommentRequest: Encodable {
    var target_comment_id: UUID
    var report_id: UUID?
}

struct SupabaseContentReportRecord: Decodable {
    var id: UUID
    var created_at: Date
    var reporter_id: UUID
    var reporter_username: String
    var target_type: String
    var target_post_id: UUID?
    var target_comment_id: UUID?
    var target_author_id: UUID
    var target_author_username: String
    var target_excerpt: String
    var reason: String
    var detail: String
    var status: String
    var reviewed_at: Date?
    var moderator_note: String?
}

struct ContentReport: Identifiable {
    var id: UUID
    var createdAt: Date
    var reporterUsername: String
    var targetType: String          // "post", "comment", or "user"
    var targetPostID: UUID?
    var targetCommentID: UUID?
    var targetAuthorID: UUID
    var targetAuthorUsername: String
    var targetExcerpt: String
    var reason: String
    var detail: String
    var status: String
    var reviewedAt: Date?
    var moderatorNote: String?

    var isOpen: Bool {
        status == "open"
    }
}

/// Insert payload for a group-added notification. Omits `id` and `created_at`
/// (server sets defaults). One row per recipient; the APNs dispatch trigger
/// fires automatically on insert via the existing push pipeline.
struct SupabaseGroupNotificationInsert: Encodable {
    var user_id: UUID
    var kind: String
    var title: String
    var detail: String
    var actor_id: UUID
}

struct SupabaseCommentNotificationInsert: Encodable {
    var user_id: UUID
    var kind: String
    var title: String
    var detail: String
    var actor_id: UUID
    var post_id: UUID
    var comment_id: UUID
}

enum SupabaseQueryList {
    static func uuidValues(_ values: [UUID]) -> String {
        "(\(values.map { $0.uuidString.lowercased() }.joined(separator: ",")))"
    }

    static func textValues(_ values: [String]) -> String {
        "(\(values.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ",")))"
    }
}

// MARK: - Night Groups

/// Wire record matching the `night_groups` Supabase table.
///
/// Table schema (run once in the Supabase SQL editor):
///
///   create table night_groups (
///     id uuid primary key default gen_random_uuid(),
///     name text not null default '',
///     creator_id uuid not null references auth.users(id) on delete cascade,
///     member_ids uuid[] not null,
///     created_at timestamptz not null default now()
///   );
///
///   alter table night_groups enable row level security;
///
///   -- Any member can read their groups
///   create policy "members_select" on night_groups for select
///     using (auth.uid() = any(member_ids));
///
///   -- Only creator can insert or delete
///   create policy "creator_insert" on night_groups for insert
///     with check (auth.uid() = creator_id);
///
///   -- Direct row updates are intentionally disabled. Name changes and
///   -- member additions go through SECURITY DEFINER RPCs so callers cannot
///   -- rewrite member_ids directly.
///
///   create policy "creator_delete" on night_groups for delete
///     using (auth.uid() = creator_id);
///
///   -- Auto-expire: index to make tonight-window queries fast
///   create index night_groups_created_at_idx on night_groups (created_at desc);
struct SupabaseNightGroupRecord: Codable {
    var id: UUID
    var name: String
    var creator_id: UUID
    var member_ids: [UUID]
    var created_at: Date

    static let selectList = "id,name,creator_id,member_ids,created_at"

    func toNightGroup() -> NightGroup {
        NightGroup(
            id: id,
            name: name,
            creatorID: creator_id,
            memberIDs: member_ids,
            createdAt: created_at
        )
    }
}

/// Insert payload — omits `id` and `created_at` (server sets defaults).
struct SupabaseNightGroupInsert: Encodable {
    var id: UUID            // we set it so the client knows the ID before the round-trip
    var name: String
    var creator_id: UUID
    var member_ids: [UUID]
}

/// Membership update RPC payload. The backend preserves existing members,
/// allows current members to add their own friends, and rejects removals.
struct SupabaseNightGroupUpdateRequest: Encodable {
    var group_id: UUID
    var new_name: String
    var new_member_ids: [UUID]
}

/// Rename-only payload — safe to send from any member because it doesn't
/// touch member_ids. The backend RPC checks that the caller is a member.
struct SupabaseNightGroupRename: Encodable {
    var name: String
}

struct SupabaseNightGroupRenameRequest: Encodable {
    var group_id: UUID
    var new_name: String
}

enum EmailAddressRules {
    static func normalized(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.contains("@") else { return nil }

        let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        guard parts[1].contains(".") else { return nil }
        return normalized
    }

    static func masked(_ rawValue: String?) -> String {
        guard let normalized = normalized(rawValue) else { return rawValue ?? "" }
        let parts = normalized.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return normalized }

        let local = String(parts[0])
        let domain = String(parts[1])
        let visiblePrefix = String(local.prefix(2))
        let hiddenCount = max(local.count - visiblePrefix.count, 0)
        let maskedLocal = visiblePrefix + String(repeating: "•", count: hiddenCount)
        return "\(maskedLocal)@\(domain)"
    }

    static func displaySeed(from rawValue: String) -> String {
        normalized(rawValue)?
            .split(separator: "@")
            .first
            .map(String.init)?
            .replacingOccurrences(of: ".", with: " ")
            .capitalized
            ?? "Out Again"
    }
}

enum PasswordRules {
    static let minimumLength = 8

    static func isValid(_ rawValue: String) -> Bool {
        rawValue.count >= minimumLength
    }
}

enum SupabaseDateCoder {
    static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let iso8601FormatterWithoutFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension CommentKind {
    var databaseValue: String {
        switch self {
        case .text:
            return "text"
        case .photo:
            return "photo"
        case .gif:
            return "gif"
        }
    }
}
