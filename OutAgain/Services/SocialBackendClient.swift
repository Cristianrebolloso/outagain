import Foundation

struct ProfileCreateRequest: Hashable {
    var email: String?
    var displayName: String
    var username: String
    var profileImageData: Data?
    var backgroundTheme: BackgroundTheme
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
    var id = UUID()
    var shareLocally = false
    var author: UserProfile
    var drink: DrinkTag?
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
    case user
}

struct ContentReportRequest: Hashable {
    var target: ContentReportTarget
    var postID: UUID?
    var commentID: UUID?
    var targetUserID: UUID?
    var detail: String = ""
}

enum DeviceEnvironment: String {
    case development
    case production
}

struct UserPostsPage {
    var posts: [MomentPost]
    var totalCount: Int?
    var hasMore: Bool
}

struct AdminContentDeletionSummary: Hashable {
    var postsDeleted: Int
    var commentsDeleted: Int
    var reactionsDeleted: Int
    var commentLikesDeleted: Int
    var friendshipsDeleted: Int
    var notificationsDeleted: Int
    var contentReportsDeleted: Int
    var groupsDeleted: Int
    var groupsUpdated: Int
    var devicesDeleted: Int
    var storageObjectsDeleted: Int

    var totalDeletedRows: Int {
        postsDeleted
        + commentsDeleted
        + reactionsDeleted
        + commentLikesDeleted
        + friendshipsDeleted
        + notificationsDeleted
        + contentReportsDeleted
        + groupsDeleted
        + devicesDeleted
        + storageObjectsDeleted
    }
}

struct ProfileStats: Hashable {
    struct DrinkTagEvent: Identifiable, Hashable {
        let id: UUID
        var name: String
        var taggedAt: Date
    }

    struct DrinkSummary: Identifiable, Hashable {
        var id: String { normalizedName }
        var name: String
        var count: Int
        var mostRecentTagDate: Date

        private var normalizedName: String {
            name
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }
    }

    var drinksTagged: Int
    var nightsOut: Int
    var longestPostingStreak: Int
    var longestPostingStreakStart: Date?
    var longestPostingStreakEnd: Date?
    var mostTaggedDrinkName: String?
    var mostTaggedDrinkCount: Int
    var drinkTagEvents: [DrinkTagEvent]

    private struct DrinkFrequency {
        var name: String
        var count: Int
        var mostRecentPostDate: Date
    }

    static let empty = ProfileStats(
        drinksTagged: 0,
        nightsOut: 0,
        longestPostingStreak: 0,
        longestPostingStreakStart: nil,
        longestPostingStreakEnd: nil,
        mostTaggedDrinkName: nil,
        mostTaggedDrinkCount: 0,
        drinkTagEvents: []
    )

    static func make<Record>(
        from records: [Record],
        calendar: Calendar = .current,
        id: (Record) -> UUID,
        date: (Record) -> Date,
        drinkName: (Record) -> String?
    ) -> ProfileStats {
        let dates = records.map(date)
        let nightKeys = Set(dates.map { postingNightKey(for: $0, calendar: calendar) })
        let postingDays = nightKeys
            .sorted()

        var drinksTagged = 0
        var frequencies: [String: DrinkFrequency] = [:]
        var drinkTagEvents: [DrinkTagEvent] = []

        for record in records {
            let postedAt = date(record)
            guard let rawDrinkName = drinkName(record)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawDrinkName.isEmpty
            else { continue }

            drinksTagged += 1
            drinkTagEvents.append(
                DrinkTagEvent(
                    id: id(record),
                    name: rawDrinkName,
                    taggedAt: postedAt
                )
            )
            let key = rawDrinkName.lowercased()
            if var existing = frequencies[key] {
                existing.count += 1
                if postedAt > existing.mostRecentPostDate {
                    existing.name = rawDrinkName
                    existing.mostRecentPostDate = postedAt
                }
                frequencies[key] = existing
            } else {
                frequencies[key] = DrinkFrequency(
                    name: rawDrinkName,
                    count: 1,
                    mostRecentPostDate: postedAt
                )
            }
        }

        let mostTagged = frequencies.values
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                return $0.mostRecentPostDate > $1.mostRecentPostDate
            }
            .first

        let streakResult = longestPostingStreak(in: postingDays, calendar: calendar)
        return ProfileStats(
            drinksTagged: drinksTagged,
            nightsOut: nightKeys.count,
            longestPostingStreak: streakResult.count,
            longestPostingStreakStart: streakResult.start,
            longestPostingStreakEnd: streakResult.end,
            mostTaggedDrinkName: mostTagged?.name,
            mostTaggedDrinkCount: mostTagged?.count ?? 0,
            drinkTagEvents: drinkTagEvents
        )
    }

    func drinkSummaries(in period: ProfileDrinkStatsPeriod = .allTime) -> [DrinkSummary] {
        let events = drinkTagEvents.filter { period.contains($0.taggedAt) }
        var summaries: [String: DrinkSummary] = [:]

        for event in events {
            let key = event.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }

            if var existing = summaries[key] {
                existing.count += 1
                if event.taggedAt > existing.mostRecentTagDate {
                    existing.name = event.name
                    existing.mostRecentTagDate = event.taggedAt
                }
                summaries[key] = existing
            } else {
                summaries[key] = DrinkSummary(
                    name: event.name,
                    count: 1,
                    mostRecentTagDate: event.taggedAt
                )
            }
        }

        return summaries.values.sorted {
            if $0.count != $1.count {
                return $0.count > $1.count
            }
            if $0.mostRecentTagDate != $1.mostRecentTagDate {
                return $0.mostRecentTagDate > $1.mostRecentTagDate
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func drinkCount(in period: ProfileDrinkStatsPeriod = .allTime) -> Int {
        drinkTagEvents.filter { period.contains($0.taggedAt) }.count
    }

    static func postingNightKey(for date: Date, calendar: Calendar = .current) -> Date {
        let hour = calendar.component(.hour, from: date)
        let anchorDate = hour < 7
            ? calendar.date(byAdding: .day, value: -1, to: date) ?? date
            : date
        return calendar.startOfDay(for: anchorDate)
    }

    private static func longestPostingStreak(
        in postingDays: [Date],
        calendar: Calendar
    ) -> (count: Int, start: Date?, end: Date?) {
        guard !postingDays.isEmpty else { return (0, nil, nil) }

        var longestCount = 0
        var longestStart: Date?
        var longestEnd: Date?

        var currentCount = 0
        var currentStart: Date?
        var previousDay: Date?

        for day in postingDays {
            if let prev = previousDay,
               let expectedNextDay = calendar.date(byAdding: .day, value: 1, to: prev),
               calendar.isDate(day, inSameDayAs: expectedNextDay) {
                currentCount += 1
            } else {
                currentCount = 1
                currentStart = day
            }

            if currentCount > longestCount {
                longestCount = currentCount
                longestStart = currentStart
                longestEnd = day
            }

            previousDay = day
        }

        return (longestCount, longestStart, longestEnd)
    }
}

struct ProfileDrinkStatsPeriod: Identifiable, Hashable {
    enum Kind: Hashable {
        case allTime
        case month(year: Int, month: Int)
        case year(Int)
        case academic(AcademicSeason, year: Int)
    }

    enum AcademicSeason: String, CaseIterable, Hashable {
        case spring
        case summer
        case fall
        case winter
    }

    let kind: Kind
    let title: String
    let interval: DateInterval?
    let sortDate: Date

    var id: String {
        switch kind {
        case .allTime:
            return "all-time"
        case .month(let year, let month):
            return "month-\(year)-\(month)"
        case .year(let year):
            return "year-\(year)"
        case .academic(let season, let year):
            return "academic-\(season.rawValue)-\(year)"
        }
    }

    static let allTime = ProfileDrinkStatsPeriod(
        kind: .allTime,
        title: "All time",
        interval: nil,
        sortDate: .distantFuture
    )

    func contains(_ date: Date) -> Bool {
        guard let interval else { return true }
        return interval.contains(date)
    }

    static func options(
        for events: [ProfileStats.DrinkTagEvent],
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> [ProfileDrinkStatsPeriod] {
        let eventDates = events.map(\.taggedAt)
        let eventYears = Set(eventDates.map { calendar.component(.year, from: $0) })
        let referenceYear = calendar.component(.year, from: referenceDate)
        let years = eventYears.union([referenceYear])

        var periodsByID: [String: ProfileDrinkStatsPeriod] = [allTime.id: allTime]

        for date in eventDates + [referenceDate] {
            let components = calendar.dateComponents([.year, .month], from: date)
            guard let year = components.year, let month = components.month else { continue }
            let period = Self.month(year: year, month: month, calendar: calendar)
            periodsByID[period.id] = period
        }

        for year in years {
            let yearPeriod = Self.year(year, calendar: calendar)
            periodsByID[yearPeriod.id] = yearPeriod

            for season in AcademicSeason.allCases {
                let period = Self.academic(season, year: year, calendar: calendar)
                if period.contains(referenceDate) || eventDates.contains(where: period.contains) {
                    periodsByID[period.id] = period
                }
            }
        }

        return periodsByID.values.sorted {
            if $0.kind == .allTime { return true }
            if $1.kind == .allTime { return false }
            if $0.sortDate != $1.sortDate { return $0.sortDate > $1.sortDate }
            return $0.title < $1.title
        }
    }

    private static let monthTitleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter
    }()

    static func month(year: Int, month: Int, calendar: Calendar = .current) -> ProfileDrinkStatsPeriod {
        let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)) ?? .distantPast
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return ProfileDrinkStatsPeriod(
            kind: .month(year: year, month: month),
            title: Self.monthTitleFormatter.string(from: start),
            interval: DateInterval(start: start, end: end),
            sortDate: start
        )
    }

    static func year(_ year: Int, calendar: Calendar = .current) -> ProfileDrinkStatsPeriod {
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .distantPast
        let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1)) ?? start
        return ProfileDrinkStatsPeriod(
            kind: .year(year),
            title: "\(year)",
            interval: DateInterval(start: start, end: end),
            sortDate: start
        )
    }

    static func academic(
        _ season: AcademicSeason,
        year: Int,
        calendar: Calendar = .current
    ) -> ProfileDrinkStatsPeriod {
        let range: (start: DateComponents, end: DateComponents)
        let title: String

        switch season {
        case .spring:
            range = (
                DateComponents(year: year, month: 1, day: 1),
                DateComponents(year: year, month: 6, day: 1)
            )
            title = "Spring Semester \(year)"
        case .summer:
            range = (
                DateComponents(year: year, month: 6, day: 1),
                DateComponents(year: year, month: 8, day: 16)
            )
            title = "Summer \(year)"
        case .fall:
            range = (
                DateComponents(year: year, month: 8, day: 16),
                DateComponents(year: year, month: 12, day: 16)
            )
            title = "Fall Semester \(year)"
        case .winter:
            range = (
                DateComponents(year: year - 1, month: 12, day: 16),
                DateComponents(year: year, month: 1, day: 16)
            )
            let shortEndYear = String(format: "%02d", year % 100)
            title = "Winter Break \(year - 1)-\(shortEndYear)"
        }

        let start = calendar.date(from: range.start) ?? .distantPast
        let end = calendar.date(from: range.end) ?? start
        return ProfileDrinkStatsPeriod(
            kind: .academic(season, year: year),
            title: title,
            interval: DateInterval(start: start, end: end),
            sortDate: start
        )
    }
}

struct ProfileFriendRank: Hashable {
    var rank: Int
    var groupSize: Int

    static func make(targetNightsOut: Int, friendNightsOut: [Int]) -> ProfileFriendRank {
        let rank = friendNightsOut.filter { $0 > targetNightsOut }.count + 1
        return ProfileFriendRank(rank: rank, groupSize: friendNightsOut.count + 1)
    }
}

protocol SocialBackendClient {
    /// True when the client has a stored auth session (access + refresh token).
    /// Used to distinguish "no profile row returned" (transient) from
    /// "genuinely not authenticated" (should sign out).
    var hasStoredSession: Bool { get }

    func signUp(email: String, password: String) async throws
    func signIn(identifier: String, password: String) async throws
    @MainActor func signInWithPasskey() async throws
    @MainActor func registerPasskey() async throws
    func listPasskeys() async throws -> [AccountPasskey]
    func deletePasskey(id: UUID) async throws
    func beginSignOut() -> Task<Void, Never>
    func signOut() async throws
    func changePassword(currentPassword: String, newPassword: String) async throws
    func loadAppData() async throws -> SocialBootstrap
    func fetchAppConfig() async throws -> [String: String]
    func checkUsernameAvailability(_ username: String) async throws -> UsernameAvailability
    func createProfile(_ request: ProfileCreateRequest) async throws -> UserProfile
    func updateProfile(_ request: ProfileUpdateRequest, for viewer: UserProfile) async throws -> UserProfile
    func updateBackgroundTheme(_ theme: BackgroundTheme, for viewer: UserProfile) async throws
    func updateDrinkCatalogPreferences(_ preferences: DrinkCatalogPreferences, for viewer: UserProfile) async throws
    func createInviteLink(for username: String) -> URL
    func searchUsers(matching query: String, excluding viewer: UserProfile?) async throws -> [UserProfile]
    func loadUserProfile(id: UUID) async throws -> UserProfile?
    func loadFriendCount(of profile: UserProfile, for viewer: UserProfile) async throws -> Int
    /// Total number of posts authored by `profile`. Visible to any signed-in
    /// viewer regardless of friendship so non-friend profile views can display
    /// the count without exposing the posts themselves.
    func loadPostCount(of profile: UserProfile) async throws -> Int
    func loadFriends(of profile: UserProfile, for viewer: UserProfile) async throws -> [UserProfile]
    /// Profile grid pagination: fetch just one authored page newest-first so
    /// profile screens can start light and only request older history as
    /// the viewer scrolls deeper.
    func loadUserPostsPage(
        for profile: UserProfile,
        viewer: UserProfile,
        before: Date?,
        limit: Int
    ) async throws -> UserPostsPage
    /// Tagged grid pagination: fetch posts where `profile` appears in
    /// `tagged_user_ids`, newest-first. Separate from `loadUserPostsPage`
    /// because the authored and tagged grids are independent with no overlap.
    func loadTaggedPostsPage(
        for profile: UserProfile,
        viewer: UserProfile,
        before: Date?,
        limit: Int
    ) async throws -> UserPostsPage
    /// All-time profile stats computed from lightweight post metadata. This
    /// intentionally does not hydrate media, comments, or reactions.
    func loadProfileStats(for profile: UserProfile, viewer: UserProfile) async throws -> ProfileStats
    /// 1-based all-time nights-out rank for `profile` among their accepted
    /// friends plus the profile itself. Kept server-side so friend-profile
    /// rank is computed against that person's graph without exposing every
    /// friend's post history to the viewer.
    func loadProfileFriendRank(
        for profile: UserProfile,
        viewer: UserProfile,
        timeZoneIdentifier: String
    ) async throws -> ProfileFriendRank
    /// Hydrated feed page — newest-first cursor pagination, matching the profile
    /// posts pattern. `before` is the `createdAt` of the oldest currently-loaded
    /// post; pass nil for the first page. Returns `limit + 1` items from the
    /// backend so the caller can detect whether more pages exist.
    func loadFeedPosts(
        authorIDs: [UUID],
        viewer: UserProfile,
        before: Date?,
        limit: Int
    ) async throws -> [MomentPost]
    /// Fetches one post by ID if it still exists and is visible to `viewer`.
    /// Used by notification deep links because those can point outside the
    /// normal feed bootstrap window.
    func updateDiscoveryContext(location: LocationSnapshot?) async throws
    func loadLocalFeedPosts(viewer: UserProfile, before: MomentPost?, limit: Int) async throws -> [MomentPost]
    func loadNightRecapPosts(viewer: UserProfile, start: Date, end: Date, groupID: UUID?) async throws -> [MomentPost]
    func markNightRecapSeen(through end: Date) async throws
    func loadPost(id: UUID, viewer: UserProfile) async throws -> MomentPost?
    /// Returns the subset of IDs that still exist and are visible to the current
    /// session. Used by foreground polling to reconcile local cached posts after
    /// a friend deletes content on another device.
    func loadVisiblePostIDs(_ postIDs: [UUID]) async throws -> Set<UUID>
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
    func reportUser(_ user: UserProfile, for viewer: UserProfile) async throws
    func unfriend(_ friend: UserProfile, for viewer: UserProfile) async throws

    // Activity
    func publishMoment(_ request: MomentCreateRequest) async throws -> MomentPost
    func deletePost(_ post: MomentPost, by viewer: UserProfile) async throws
    /// Best-effort storage cleanup for the post's image after the DB row has
    /// been deleted. Supabase blocks direct deletes on storage.objects from
    /// SECURITY DEFINER RPCs, so this must run client-side via the Storage API.
    /// Failures are swallowed: an orphaned image is preferable to surfacing an
    /// error after the post itself is already gone.
    func deletePostMedia(_ post: MomentPost) async
    /// Best-effort cleanup for a single comment photo/GIF attachment.
    func deleteCommentMedia(_ comment: Comment) async
    func recordReaction(_ kind: ReactionKind, to post: MomentPost, by viewer: UserProfile) async throws -> OutboundNotificationDelivery?
    func removeReaction(_ kind: ReactionKind, from post: MomentPost, by viewer: UserProfile) async throws
    /// Deletes the notification that was pushed to the post author when the
    /// viewer reacted. Called on unlike so the recipient's Activity tab cleans
    /// up automatically without requiring a full bootstrap on their end.
    func deleteReactionNotification(_ kind: ReactionKind, on post: MomentPost, by actor: UserProfile) async throws
    func recordComment(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws -> OutboundNotificationDelivery?
    func recordCommentLike(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws -> OutboundNotificationDelivery?
    func removeCommentLike(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws
    func deleteCommentLikeNotification(_ comment: Comment, by actor: UserProfile) async throws
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
    /// Records that the viewer dismissed a server-driven app announcement so
    /// it never appears for that account again.
    func markAppAnnouncementSeen(id: UUID, for viewer: UserProfile) async throws
    /// Fetches unseen server-driven app announcements without requiring a full
    /// feed bootstrap. Used by foreground polling.
    func loadUnseenAppAnnouncements(limit: Int) async throws -> [AppAnnouncement]

    // Push notifications
    func registerDeviceToken(_ token: Data, environment: DeviceEnvironment, for viewer: UserProfile) async throws
    func unregisterDeviceToken(_ token: Data, for viewer: UserProfile) async throws
    func fetchNotificationPreferences(for userID: UUID) async throws -> NotificationPreferences
    func setNotificationPreference(_ category: PushNotificationCategory, enabled: Bool, for userID: UUID) async throws
    func deleteCurrentAccount() async throws

    // Night groups (backed by `night_groups` table; visible to all members via RLS)
    /// Writes a new group row. The caller pre-generates the UUID so the client
    /// can optimistically insert into `nightGroups` before the round-trip returns.
    func createNightGroup(_ group: NightGroup) async throws
    /// Inserts a `groupAdded` notification row for each member ID in `recipientIDs`.
    /// The existing APNs push-dispatch trigger fires automatically on insert, so
    /// this is the only client-side step needed to deliver the push.
    func insertGroupNotifications(group: NightGroup, recipientIDs: [UUID], creator: UserProfile) async throws
    /// Saves name plus membership additions through an RPC. Existing members
    /// are preserved server-side; callers cannot remove or rewrite member_ids.
    func updateNightGroup(_ group: NightGroup) async throws
    /// Renames a group without touching member_ids. Any member may call this;
    /// the RPC checks membership before updating the name.
    func renameNightGroup(id: UUID, name: String) async throws
    /// Deletes the group row. RLS enforces creator-only.
    func deleteNightGroup(id: UUID) async throws
    /// Fetches all groups where auth.uid() is in member_ids and whose
    /// created_at falls within the provided tonight window.
    func fetchNightGroups(createdAfter windowStart: Date) async throws -> [NightGroup]

    // Diagnostics (Debug builds only; server guards to auth.uid() = self)
    func sendSelfTestNotification() async throws

    // Admin
    func setVerified(_ isVerified: Bool, for profile: UserProfile) async throws
    func setFeedAdsEnabled(_ enabled: Bool) async throws -> [String: String]
    func setMaintenanceMode(enabled: Bool, title: String, message: String) async throws -> [String: String]
    func publishAppAnnouncement(
        requestID: UUID,
        title: String,
        message: String,
        audience: AppAnnouncementAudience,
        targetUsernames: [String],
        delivery: AppAnnouncementDelivery
    ) async throws
    func fetchAdminAppAnnouncements(limit: Int) async throws -> [AdminAppAnnouncement]
    func deactivateAppAnnouncement(id: UUID) async throws
    func fetchAllUsersPage(offset: Int, limit: Int) async throws -> [UserProfile]
    func fetchAdminReports(limit: Int, offset: Int) async throws -> [ContentReport]
    func resolveReport(id: UUID) async throws
    func deletePostAsAdmin(_ postID: UUID, reportID: UUID?) async throws
    func deleteCommentAsAdmin(_ commentID: UUID, reportID: UUID?) async throws
    func banUser(_ userID: UUID) async throws
    func setUserBanned(_ isBanned: Bool, userID: UUID) async throws -> UserProfile
    func deleteUserContent(userID: UUID) async throws -> AdminContentDeletionSummary
}

extension SocialBackendClient {
    func beginSignOut() -> Task<Void, Never> {
        Task {
            try? await signOut()
        }
    }

    func deletePostAsAdmin(_ postID: UUID) async throws {
        try await deletePostAsAdmin(postID, reportID: nil)
    }

    /// Default no-op so backends without storage (e.g. UnconfiguredBackend)
    /// don't need a custom implementation.
    func deletePostMedia(_ post: MomentPost) async {}
    func deleteCommentMedia(_ comment: Comment) async {}

    func deleteCommentAsAdmin(_ commentID: UUID) async throws {
        try await deleteCommentAsAdmin(commentID, reportID: nil)
    }
}


extension SocialBackendClient {
    func updateDiscoveryContext(location: LocationSnapshot?) async throws {}
    func loadLocalFeedPosts(viewer: UserProfile, before: MomentPost?, limit: Int) async throws -> [MomentPost] { [] }
    func loadNightRecapPosts(viewer: UserProfile, start: Date, end: Date, groupID: UUID?) async throws -> [MomentPost] { [] }
    func markNightRecapSeen(through end: Date) async throws {}
}
