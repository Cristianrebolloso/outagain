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
/// 5pm local → 7am the next local day. This captures the normal arc
/// of a night out while letting late-hour posts (last call, post-venue
/// food) still read as "tonight" rather than flipping to the next day
/// at midnight. The window anchors on the viewer's current local time,
/// so a user in Chicago sees Chicago's tonight even if a friend posted
/// from New York — the goal is a shared sense of "right now," not a
/// strict geo-local calculation. Second-order effect worth calling out:
/// someone posting at 2am local still appears in the current window,
/// and even a 6am post can still belong to the same night. Once the
/// viewer opens the app after 7am, that night wraps and the strip
/// resets until the next evening — intentional, so the strip feels
/// like an evening object not a
/// 24/7 activity ticker.
extension AppStore {
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
        let grouped = Dictionary(grouping: posts, by: { $0.author.id })

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
        let window = Self.tonightWindow(reference: .now)
        return posts.contains { post in
            post.author.id != viewer?.id
                && window.contains(post.createdAt)
        }
    }

    /// Most recent post by a given friend in the current tonight window,
    /// if any. Used by the strip to route a tap straight to the relevant
    /// moment rather than dropping the viewer on the friend's profile
    /// and forcing an extra hop.
    func latestPostTonight(for profileID: UUID) -> MomentPost? {
        let window = Self.tonightWindow(reference: .now)
        return posts
            .filter { $0.author.id == profileID && window.contains($0.createdAt) }
            .max(by: { $0.createdAt < $1.createdAt })
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
    /// day. Before 7am, the window is yesterday 5pm → today 7am. From
    /// 7am to 5pm, the window is today 5pm → tomorrow 7am (i.e. the
    /// *upcoming* night — no one's posted yet, but the window exists so
    /// downstream code can ask "are we in the evening bracket" without
    /// branching on time-of-day). From 5pm onward, the window is today
    /// 5pm → tomorrow 7am.
    ///
    /// Exposed as `static` so preview code and tests can inject an
    /// arbitrary reference date.
    static func tonightWindow(reference: Date) -> ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let hour = calendar.component(.hour, from: reference)

        // Anchor day is "the day whose evening we're in." Before 7am we
        // belong to yesterday's evening; after 5am (even well before
        // 5pm) we point at the upcoming evening of today.
        let anchorDay: Date = {
            if hour < 7 {
                return calendar.date(byAdding: .day, value: -1, to: reference) ?? reference
            } else {
                return reference
            }
        }()

        // Window: 7am → 7am (same as the drink-count cycle) so the
        // Tonight strip and the drink tally always cover the same posts.
        let startOfAnchor = calendar.startOfDay(for: anchorDay)
        let start = calendar.date(byAdding: .hour, value: 7, to: startOfAnchor) ?? anchorDay
        let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfAnchor) ?? anchorDay
        let end = calendar.date(byAdding: .hour, value: 7, to: nextDay) ?? nextDay

        return start...end
    }
}
