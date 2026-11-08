import Foundation
import SwiftUI

/// Derivation layer for the "Tonight" stories-style strip on Home.
///
/// Design intent:
/// The strip surfaces *who has posted tonight* — not drink counts, not
/// how much anyone's drinking, not any form of leaderboard. App Review
/// guideline 1.4.3 is unambiguous about not encouraging excessive
/// alcohol use, and a public-facing "drinks tonight" stat walks right
/// up to that line. Moment activity is the right signal anyway: it maps
/// to "something worth seeing happened" rather than "they had N of X,"
/// and the viewer's next action (tap to see the moment) is consistent
/// with the rest of the app.
///
/// "Tonight" window:
/// 7am local → 7am the next local day. This matches the drink tally
/// cycle and captures a full day of night-out activity without making
/// late-hour posts flip to the next bucket at midnight. The window
/// anchors on the viewer's current local time, so a user in Chicago
/// sees Chicago's current cycle even if a friend posted from New York.
extension AppStore {
    static let nightSummaryMinimumViewerPostCount = 3

    /// One entry per friend (plus the viewer) in the Tonight strip.
    struct TonightEntry: Identifiable, Hashable {
        let id: UUID
        let profile: UserProfile
        let postsTonightCount: Int
        let lastPostedAt: Date?
        let latestPostID: UUID?
        let isViewer: Bool

        var hasPostedTonight: Bool {
            postsTonightCount > 0
        }
    }

    /// The just-finished 7am-to-7am cycle used for the in-app recap.
    /// This is intentionally separate from `tonightWindow`: after 7am,
    /// the Tonight strip moves into the new cycle, while the recap looks
    /// back at the cycle that just ended.
    struct NightSummaryWindow: Hashable {
        let start: Date
        let end: Date

        var id: String {
            AppStore.nightCycleID(start: start)
        }

        func contains(_ date: Date) -> Bool {
            date >= start && date < end
        }
    }

    /// Locally-derived recap for the last completed night. It only appears
    /// when the viewer, their friends, or a tagged photo makes a recap meaningful.
    struct NightActivitySummary: Identifiable, Hashable {
        let id: String
        let window: NightSummaryWindow
        let viewer: UserProfile
        let allPosts: [MomentPost]
        let viewerPosts: [MomentPost]
        let taggedViewerPosts: [MomentPost]
        let friendPosts: [MomentPost]
        let featuredPeople: [UserProfile]
        let featuredPosts: [MomentPost]
        let topPersonalPost: MomentPost?

        var personalPosts: [MomentPost] {
            var seen = Set<UUID>()
            return (viewerPosts + taggedViewerPosts + friendPosts).filter { seen.insert($0.id).inserted }
        }

        var momentCount: Int {
            personalPosts.count
        }

        var ownMomentCount: Int {
            viewerPosts.count
        }

        var friendAuthorCount: Int {
            Set(friendPosts.map(\.author.id)).count
        }

        var photoCount: Int {
            personalPosts.filter(\.hasSummaryPhoto).count
        }

        var friendPhotoCount: Int {
            friendPosts.filter(\.hasSummaryPhoto).count
        }

        var responseCount: Int {
            personalPosts.reduce(0) { total, post in
                total + post.summaryPositiveReactionCount + post.commentCount
            }
        }

        var topPostResponseCount: Int {
            guard let topPersonalPost else { return 0 }
            return topPersonalPost.summaryPositiveReactionCount + topPersonalPost.commentCount
        }

        var primaryVenue: Venue? {
            let venues = allPosts.compactMap(\.venue)
            let grouped = Dictionary(grouping: venues, by: \.id)
            return grouped.values
                .compactMap { venues -> (venue: Venue, count: Int)? in
                    guard let venue = venues.first else { return nil }
                    return (venue: venue, count: venues.count)
                }
                .sorted {
                    if $0.count != $1.count { return $0.count > $1.count }
                    return $0.venue.name < $1.venue.name
                }
                .first?.venue
        }

        var latestPersonalPost: MomentPost? {
            personalPosts.max { $0.createdAt < $1.createdAt }
        }

        private static func uniquePosts(_ posts: [MomentPost]) -> [MomentPost] {
            var seen = Set<UUID>()
            return posts.filter { seen.insert($0.id).inserted }
        }
    }

    /// Group-first recap for the just-finished night. When present, this
    /// suppresses the individual recap so users do not get two summaries.
    struct NightGroupActivitySummary: Identifiable, Hashable {
        let id: String
        let window: NightSummaryWindow
        let group: NightGroup
        let viewer: UserProfile
        let allPosts: [MomentPost]
        let viewerPosts: [MomentPost]
        let featuredPeople: [UserProfile]
        let featuredPosts: [MomentPost]

        var momentCount: Int {
            allPosts.count
        }

        var activeMemberCount: Int {
            Set(allPosts.map(\.author.id)).count
        }

        var photoCount: Int {
            allPosts.filter(\.hasSummaryPhoto).count
        }
    }

    /// Ordered list shown in the strip. The viewer appears only when
    /// they've posted tonight — the tab bar already owns the Post CTA,
    /// so a placeholder tile would duplicate that affordance and soften
    /// the incentive. Once the viewer posts, they sort into the strip
    /// by the same rules as everyone else.
    ///
    /// Sort order is bucketed recency rather than pure count. The
    /// intent is to make the strip feel like a live pulse of the
    /// night: whoever just posted gets the front of the strip for a
    /// window of time, which reshuffles the surface every time
    /// someone posts. Pure count-sorting creates a static leaderboard
    /// that only shifts when someone overtakes the leader; that's
    /// emotionally flat and also teaches the wrong behavior (volume
    /// over moment-worthiness).
    ///
    /// Buckets, in order:
    ///   1. Just posted — last post within the last 30 minutes. These
    ///      render at the front sorted by most-recent. The 30-minute
    ///      window is long enough to still feel "current" in bar time
    ///      (where people aren't checking phones every 5 minutes) and
    ///      short enough that posting meaningfully promotes someone.
    ///   2. Active tonight — posted within the tonight window but not
    ///      within the last 30 minutes. Sorted by most-recent, with
    ///      count as a tiebreaker so a 3-post friend with the same
    ///      timestamp outranks a 1-post friend.
    ///   3. Inactive — no post tonight at all. Sorted by most recent
    ///      overall activity so the dim-tile order reflects "who
    ///      usually shows up." Still rendered in the strip, just
    ///      visually quieter.
    var tonightEntries: [TonightEntry] {
        let now = Date.now
        let window = Self.tonightWindow(reference: now)
        let justPostedCutoff = now.addingTimeInterval(-30 * 60)
        let grouped = Dictionary(grouping: tonightActivitySourcePosts, by: { $0.author.id })

        let viewerProfile = viewer ?? .placeholderCurrentUser
        let viewerPostsTonight = (grouped[viewerProfile.id] ?? [])
            .filter { window.contains($0.createdAt) }

        let viewerEntry: TonightEntry? = viewerPostsTonight.isEmpty
            ? nil
            : makeTonightEntry(
                for: viewerProfile,
                posts: grouped[viewerProfile.id] ?? [],
                window: window,
                isViewer: true
            )

        let friendEntries = friends.map { friend in
            makeTonightEntry(
                for: friend,
                posts: grouped[friend.id] ?? [],
                window: window,
                isViewer: false
            )
        }

        // Combine viewer + friends, then apply the bucketed sort so
        // the viewer competes for the front spot on the same terms
        // as everyone else. This is important: if the viewer posted
        // 2 hours ago and a friend just posted, the friend should be
        // first. Self-anchoring by always-top-of-strip would be a
        // worse signal than "look what just happened."
        let all = (viewerEntry.map { [$0] } ?? []) + friendEntries

        return all.sorted { lhs, rhs in
            let lhsBucket = bucket(for: lhs, justPostedCutoff: justPostedCutoff)
            let rhsBucket = bucket(for: rhs, justPostedCutoff: justPostedCutoff)

            if lhsBucket != rhsBucket {
                return lhsBucket.rawValue < rhsBucket.rawValue
            }

            // Same bucket — primary key is recency.
            let lhsDate = lhs.lastPostedAt ?? .distantPast
            let rhsDate = rhs.lastPostedAt ?? .distantPast
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }

            // Recency tied — count breaks it. Higher count wins so a
            // heavy poster with the same timestamp outranks a casual
            // one. This matters mostly in the inactive bucket where
            // many entries may share .distantPast.
            return lhs.postsTonightCount > rhs.postsTonightCount
        }
    }

    /// The summary candidate shown by `NightActivitySummaryOverlay`.
    /// Returns nil before 7:01am, when no cycle has just ended, and when the
    /// completed cycle has no relevant photos.
    var lastNightActivitySummary: NightActivitySummary? {
        guard let viewer,
              let window = Self.lastCompletedNightWindow(reference: .now),
              lastNightGroupActivitySummaryContext == nil
        else { return nil }

        let allPosts = nightSummarySourcePosts(in: window)
        guard !allPosts.isEmpty else { return nil }

        let viewerPosts = allPosts.filter { $0.author.id == viewer.id }
        let taggedPosts = allPosts.filter { $0.author.id != viewer.id && $0.taggedFriends.contains { $0.id == viewer.id } }
        let friendPosts = allPosts.filter { $0.author.id != viewer.id && directFriendIDs.contains($0.author.id) }
        let ownRecap = viewerPosts.count >= Self.nightSummaryMinimumViewerPostCount
        guard ownRecap || !taggedPosts.isEmpty || friendPosts.filter(\.hasSummaryPhoto).count >= 3 else { return nil }
        let personalPosts = ownRecap ? viewerPosts : uniquePosts(viewerPosts + taggedPosts + friendPosts)
        let featuredPeople = uniqueProfiles(
            personalPosts.map(\.author) + personalPosts.flatMap(\.taggedFriends)
        ).filter { $0.id != viewer.id }
        let featuredPosts = featuredNightSummaryPosts(
            viewerPosts: viewerPosts,
            taggedViewerPosts: ownRecap ? [] : taggedPosts,
            friendPosts: ownRecap ? [] : friendPosts
        )
        let topPersonalPost = personalPosts.max { lhs, rhs in
            let lhsScore = summaryEngagementScore(for: lhs)
            let rhsScore = summaryEngagementScore(for: rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return lhs.createdAt < rhs.createdAt
        }

        return NightActivitySummary(
            id: window.id,
            window: window,
            viewer: viewer,
            allPosts: personalPosts,
            viewerPosts: viewerPosts,
            taggedViewerPosts: ownRecap ? [] : taggedPosts,
            friendPosts: ownRecap ? [] : friendPosts,
            featuredPeople: featuredPeople,
            featuredPosts: featuredPosts,
            topPersonalPost: topPersonalPost
        )
    }

    var lastNightGroupActivitySummaryContext: NightGroupActivitySummary? {
        guard let viewer,
              let window = Self.lastCompletedNightWindow(reference: .now)
        else { return nil }

        let groups = uniqueNightGroups(nightSummaryGroups + nightGroups).filter { group in
            window.contains(group.createdAt) && group.memberIDs.contains(viewer.id)
        }
        guard !groups.isEmpty else { return nil }

        let allSummaryPosts = nightSummarySourcePosts(in: window)
        let summaries: [NightGroupActivitySummary] = groups.compactMap { group in
            let memberIDs = Set(group.memberIDs)
            let groupPosts = sortPostsByRecency(
                allSummaryPosts.filter { memberIDs.contains($0.author.id) }
            )
            let viewerPosts = groupPosts.filter { $0.author.id == viewer.id }
            guard groupPosts.filter(\.hasSummaryPhoto).count >= 3 else { return nil }

            let people = uniqueProfiles(
                groupPosts.map(\.author)
                    + groupPosts.flatMap(\.taggedFriends)
            )
            let featuredPosts = uniquePosts(
                groupPosts.filter(\.hasSummaryPhoto) + groupPosts
            )

            return NightGroupActivitySummary(
                id: "\(window.id):group:\(group.id.uuidString)",
                window: window,
                group: group,
                viewer: viewer,
                allPosts: groupPosts,
                viewerPosts: viewerPosts,
                featuredPeople: people,
                featuredPosts: featuredPosts
            )
        }

        return summaries.sorted { lhs, rhs in
            if lhs.viewerPosts.count != rhs.viewerPosts.count {
                return lhs.viewerPosts.count > rhs.viewerPosts.count
            }
            if lhs.momentCount != rhs.momentCount {
                return lhs.momentCount > rhs.momentCount
            }
            return lhs.group.createdAt > rhs.group.createdAt
        }.first
    }

    var lastNightGroupActivitySummary: NightGroupActivitySummary? {
        guard let summary = lastNightGroupActivitySummaryContext,
              !isNightGroupActivitySummaryDismissed(summary)
        else { return nil }

        return summary
    }

    func isNightActivitySummaryDismissed(_ summary: NightActivitySummary) -> Bool {
        guard let viewerID = viewer?.id else { return true }
        let ids = UserDefaults.standard.stringArray(forKey: Self.nightSummaryDismissedKey(for: viewerID)) ?? []
        return ids.contains(summary.id)
    }

    func dismissNightActivitySummary(_ summary: NightActivitySummary) {
        guard let viewerID = viewer?.id else { return }
        let key = Self.nightSummaryDismissedKey(for: viewerID)
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !ids.contains(summary.id) {
            ids.append(summary.id)
        }
        if ids.count > 30 {
            ids = Array(ids.suffix(30))
        }
        UserDefaults.standard.set(ids, forKey: key)
    }

    func isNightGroupActivitySummaryDismissed(_ summary: NightGroupActivitySummary) -> Bool {
        guard let viewerID = viewer?.id else { return true }
        let ids = UserDefaults.standard.stringArray(forKey: Self.nightSummaryDismissedKey(for: viewerID)) ?? []
        return ids.contains(summary.id)
    }

    func dismissNightGroupActivitySummary(_ summary: NightGroupActivitySummary) {
        guard let viewerID = viewer?.id else { return }
        let key = Self.nightSummaryDismissedKey(for: viewerID)
        var ids = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !ids.contains(summary.id) {
            ids.append(summary.id)
        }
        if ids.count > 30 {
            ids = Array(ids.suffix(30))
        }
        UserDefaults.standard.set(ids, forKey: key)
    }

    private enum TonightBucket: Int {
        case justPosted = 0
        case activeTonight = 1
        case inactive = 2
    }

    private func bucket(for entry: TonightEntry, justPostedCutoff: Date) -> TonightBucket {
        guard let lastPosted = entry.lastPostedAt, entry.hasPostedTonight else {
            return .inactive
        }
        return lastPosted >= justPostedCutoff ? .justPosted : .activeTonight
    }

    /// True when at least one friend has posted in the tonight window.
    /// The viewer's own activity is excluded from this check because the
    /// strip's copy ("Nobody's posted tonight yet" vs "Tonight") reads
    /// from the viewer's perspective — if only you have posted, the
    /// strip should still acknowledge that the friend graph is quiet.
    var hasAnyFriendPostedTonight: Bool {
        tonightActivitySourcePosts.contains { post in
            post.author.id != viewer?.id
        }
    }

    /// Most recent post by a given friend in the current tonight window,
    /// if any. Used by the strip to route a tap straight to the relevant
    /// moment rather than dropping the viewer on the friend's profile
    /// and forcing an extra hop.
    func latestPostTonight(for profileID: UUID) -> MomentPost? {
        tonightPosts(for: profileID).first
    }

    var tonightActivitySourcePosts: [MomentPost] {
        let window = Self.tonightWindow(reference: .now)
        var postsByID: [UUID: MomentPost] = [:]

        for post in tonightActivityPosts where window.contains(post.createdAt) {
            postsByID[post.id] = post
        }

        for post in posts where window.contains(post.createdAt) {
            var merged = post
            if merged.media.photoData == nil,
               let activityPost = postsByID[post.id],
               let activityPhotoData = activityPost.media.photoData {
                merged.media.photoData = activityPhotoData
            }
            postsByID[post.id] = merged
        }

        return sortPostsByRecency(
            postsByID.values.filter { !locallyDeletedPostIDs.contains($0.id) }
        )
    }

    func tonightPosts(for authorID: UUID) -> [MomentPost] {
        tonightActivitySourcePosts.filter { $0.author.id == authorID }
    }

    nonisolated static func lastCompletedNightWindow(reference: Date) -> NightSummaryWindow? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let startOfToday = calendar.startOfDay(for: reference)
        guard let sevenAMToday = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: startOfToday),
              let firstAvailableAt = calendar.date(byAdding: .minute, value: 1, to: sevenAMToday),
              reference >= firstAvailableAt,
              let previousSevenAM = calendar.date(byAdding: .day, value: -1, to: sevenAMToday)
        else { return nil }

        return NightSummaryWindow(start: previousSevenAM, end: sevenAMToday)
    }

    private func makeTonightEntry(
        for profile: UserProfile,
        posts: [MomentPost],
        window: ClosedRange<Date>,
        isViewer: Bool
    ) -> TonightEntry {
        let tonightPosts = posts.filter { window.contains($0.createdAt) }
        let latest = tonightPosts.max(by: { $0.createdAt < $1.createdAt })

        return TonightEntry(
            id: profile.id,
            profile: profile,
            postsTonightCount: tonightPosts.count,
            lastPostedAt: latest?.createdAt,
            latestPostID: latest?.id,
            isViewer: isViewer
        )
    }

    /// Compute the current tonight window anchored to `reference`'s local
    /// 7am → 7am cycle. Before 7am, the window is yesterday 7am → today
    /// 7am. At/after 7am, the window is today 7am → tomorrow 7am.
    ///
    /// Exposed as `static` so preview code and tests can inject an
    /// arbitrary reference date.
    nonisolated static func tonightWindow(reference: Date) -> ClosedRange<Date> {
        NightCycleDates.window(containing: reference)
    }

    private func nightSummarySourcePosts(in window: NightSummaryWindow) -> [MomentPost] {
        var postsByID: [UUID: MomentPost] = [:]

        for post in nightSummaryPosts + tonightActivityPosts + posts where window.contains(post.createdAt) {
            var merged = post
            if merged.media.photoData == nil,
               let existing = postsByID[post.id],
               let existingPhotoData = existing.media.photoData {
                merged.media.photoData = existingPhotoData
            }
            if merged.media.photoAspectRatio == nil,
               let existing = postsByID[post.id],
               let existingRatio = existing.media.photoAspectRatio {
                merged.media.photoAspectRatio = existingRatio
            }
            postsByID[post.id] = merged
        }

        return sortPostsByRecency(
            postsByID.values.filter { !locallyDeletedPostIDs.contains($0.id) }
        )
    }

    private func featuredNightSummaryPosts(
        viewerPosts: [MomentPost],
        taggedViewerPosts: [MomentPost],
        friendPosts: [MomentPost]
    ) -> [MomentPost] {
        uniquePosts(
            viewerPosts.filter(\.hasSummaryPhoto)
                + taggedViewerPosts.filter(\.hasSummaryPhoto)
                + friendPosts.filter(\.hasSummaryPhoto)
                + viewerPosts
                + taggedViewerPosts
                + friendPosts
        )
    }

    private func uniqueProfiles(_ profiles: [UserProfile]) -> [UserProfile] {
        var seen = Set<UUID>()
        return profiles.filter { profile in
            guard profile.id != viewer?.id else { return false }
            return seen.insert(profile.id).inserted
        }
    }

    private func uniquePosts(_ posts: [MomentPost]) -> [MomentPost] {
        var seen = Set<UUID>()
        return posts.filter { seen.insert($0.id).inserted }
    }

    private func uniqueNightGroups(_ groups: [NightGroup]) -> [NightGroup] {
        var seen = Set<UUID>()
        return groups.filter { seen.insert($0.id).inserted }
    }

    private func summaryEngagementScore(for post: MomentPost) -> Int {
        post.summaryPositiveReactionCount + post.commentCount
    }

    nonisolated private static func nightSummaryDismissedKey(for viewerID: UUID) -> String {
        "OutAgain.dismissedNightSummaries.\(viewerID.uuidString)"
    }

    nonisolated private static func nightCycleID(start: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: start)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

extension MomentPost {
    var hasSummaryPhoto: Bool {
        media.photoData != nil || media.remotePhotoURL != nil
    }

    var summaryPositiveReactionCount: Int {
        reactions
            .filter { $0.kind != .dislike }
            .reduce(0) { $0 + $1.count }
    }
}
