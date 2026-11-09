import Foundation
import UIKit

extension AppStore {
    var isMaintenanceModeActive: Bool {
        Self.boolConfigValue(
            appConfig["maintenance_mode_enabled"]
                ?? appConfig["maintenance_enabled"]
                ?? appConfig["app_unavailable"]
        )
    }

    var shouldPresentMaintenanceScreen: Bool {
        isMaintenanceModeActive && isLive && !isViewerAdmin
    }

    var maintenanceTitle: String {
        Self.nonEmptyConfigValue(
            appConfig["maintenance_title"],
            fallback: "Out Again is currently unavailable"
        )
    }

    var maintenanceMessage: String {
        Self.nonEmptyConfigValue(
            appConfig["maintenance_message"],
            fallback: "We're doing some work behind the scenes. Please check back soon."
        )
    }

    private static func boolConfigValue(_ value: String?) -> Bool {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "true"
            || normalized == "1"
            || normalized == "yes"
            || normalized == "on"
    }

    private static func nonEmptyConfigValue(_ value: String?, fallback: String) -> String {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return fallback }
        return trimmed
    }

    func sortPostsByRecency(_ posts: [MomentPost]) -> [MomentPost] {
        posts
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.createdAt != rhs.element.createdAt {
                    return lhs.element.createdAt > rhs.element.createdAt
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    func persistNotificationPreferences() {
        guard let userID = notificationPreferenceUserID else { return }
        NotificationPreferenceStorage.savePush(notificationPreferences, for: userID)
    }

    func persistLiveActivityPreferences() {
        guard let userID = notificationPreferenceUserID else { return }
        NotificationPreferenceStorage.saveLiveActivity(liveActivityPreferences, for: userID)
    }

    static func loadAccentColorChoice() -> AccentColorChoice {
        loadAccentColorChoice(for: nil)
    }

    static func loadAccentColorChoice(for userID: UUID?) -> AccentColorChoice {
        if let userID,
           let raw = UserDefaults.standard.string(forKey: "OutAgain.accentColor.\(userID.uuidString)"),
           let choice = AccentColorChoice(rawValue: raw) {
            return choice
        }
        guard let raw = UserDefaults.standard.string(forKey: "OutAgain.accentColor"),
              let choice = AccentColorChoice(rawValue: raw)
        else { return .purple }
        return choice
    }

    static func loadBackgroundTheme() -> BackgroundTheme {
        // One-time local companion to the account reset. Accent preferences
        // have separate keys and are deliberately never changed here.
        let resetKey = "OutAgain.backgroundPurchaseReset.v1"
        if !UserDefaults.standard.bool(forKey: resetKey) {
            UserDefaults.standard.set(BackgroundTheme.standard.rawValue, forKey: "OutAgain.backgroundTheme")
            UserDefaults.standard.set(true, forKey: resetKey)
            return .standard
        }
        guard let raw = UserDefaults.standard.string(forKey: "OutAgain.backgroundTheme"),
              let theme = BackgroundTheme(rawValue: raw)
        else { return .standard }
        return theme.availableTheme
    }

    func profileStats(in posts: [MomentPost]) -> ProfileStats {
        ProfileStats.make(
            from: posts,
            id: { $0.id },
            date: { $0.createdAt },
            drinkName: { $0.drink?.name }
        )
    }

    func mostFrequentDrink(in posts: [MomentPost]) -> DrinkTag? {
        struct DrinkFrequency {
            var drink: DrinkTag
            var count: Int
            var mostRecentPostDate: Date
        }

        var frequencies: [String: DrinkFrequency] = [:]
        for post in posts {
            guard let drink = post.drink else { continue }
            let key = drink.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }

            if var existing = frequencies[key] {
                existing.count += 1
                if post.createdAt > existing.mostRecentPostDate {
                    existing.drink = drink
                    existing.mostRecentPostDate = post.createdAt
                }
                frequencies[key] = existing
            } else {
                frequencies[key] = DrinkFrequency(
                    drink: drink,
                    count: 1,
                    mostRecentPostDate: post.createdAt
                )
            }
        }

        return frequencies.values
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                return $0.mostRecentPostDate > $1.mostRecentPostDate
            }
            .first?
            .drink
    }

    func mostFrequentVenue(in posts: [MomentPost]) -> Venue? {
        Dictionary(grouping: posts.compactMap(\.venue), by: \.self)
            .max(by: { $0.value.count < $1.value.count })?
            .key
    }

    /// Total number of drinks the user has tagged across their posts.
    /// Each post can carry one drink, so this is equivalent to the count of
    /// posts that have a drink attached. Posts without a drink are excluded
    /// so the number reflects intentional drink tags rather than bare moments.
    func taggedDrinkCount(in posts: [MomentPost]) -> Int {
        profileStats(in: posts).drinksTagged
    }

    /// Count of unique calendar nights the user has posted on. Treats anything
    /// before 7 AM as belonging to the previous night so a 1 AM post doesn't
    /// register as a fresh night relative to a midnight post the same evening.
    /// This mirrors the "tonight" window semantics elsewhere in the app and
    /// avoids inflating the number for late-night runs.
    func uniqueNightsCount(in posts: [MomentPost]) -> Int {
        profileStats(in: posts).nightsOut
    }

    func longestPostingStreakCount(in posts: [MomentPost]) -> Int {
        profileStats(in: posts).longestPostingStreak
    }

    func uniqueUsers(from posts: [MomentPost]) -> [UserProfile] {
        var seen = Set<UUID>()

        return posts
            .flatMap { [$0.author] + $0.taggedFriends }
            .filter { user in
                guard user.id != viewer?.id else { return false }
                return seen.insert(user.id).inserted
            }
    }

    func isFriendsOfFriendsPost(_ post: MomentPost) -> Bool {
        if friendOfFriendIDs.contains(post.author.id) {
            return true
        }

        if post.connectionPath != nil {
            return true
        }

        return post.taggedFriends.contains { friendOfFriendIDs.contains($0.id) }
    }

    static func makePresenceSignals(from posts: [MomentPost], excluding viewerID: UUID?) -> [PresenceSignal] {
        let livePosts = posts.filter { $0.createdAt > .now.addingTimeInterval(-4 * 60 * 60) }
        var seen = Set<UUID>()
        var signals: [PresenceSignal] = []

        for post in livePosts.sorted(by: { $0.createdAt > $1.createdAt }) {
            for user in [post.author] + post.taggedFriends {
                guard user.id != viewerID else { continue }
                guard seen.insert(user.id).inserted else { continue }
                signals.append(
                    PresenceSignal(
                        id: UUID(),
                        user: user,
                        createdAt: post.createdAt
                    )
                )
            }
        }

        return signals.sorted { $0.createdAt > $1.createdAt }
    }

    func visibleProfiles(_ profiles: [UserProfile]) -> [UserProfile] {
        guard !isViewerAdmin else { return profiles }
        return profiles.filter { !blockedUserIDs.contains($0.id) }
    }

    func sortProfilesByDisplayName(_ profiles: [UserProfile]) -> [UserProfile] {
        return profiles.sorted {
            if $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedSame {
                return $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func visibleComments(_ comments: [Comment]) -> [Comment] {
        if isViewerAdmin {
            return comments.sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt < rhs.createdAt
            }
        }

        return comments
            .filter { !blockedUserIDs.contains($0.author.id) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func visibleNotifications(_ notifications: [AppNotification]) -> [AppNotification] {
        guard !isViewerAdmin else { return notifications }
        return notifications.filter { notification in
            guard let actorID = notification.actor?.id else { return true }
            return !blockedUserIDs.contains(actorID)
        }
    }

    func visiblePosts(_ posts: [MomentPost]) -> [MomentPost] {
        posts.compactMap(visiblePost)
    }

    func visiblePost(_ post: MomentPost) -> MomentPost? {
        guard isViewerAdmin || !blockedUserIDs.contains(post.author.id) else { return nil }

        var filtered = post
        filtered.taggedFriends = visibleProfiles(post.taggedFriends)

        let filteredComments = visibleComments(post.comments)
        let hiddenCommentCount = post.comments.count - filteredComments.count
        filtered.comments = filteredComments
        if post.hasLoadedFullCommentThread {
            filtered.commentCount = filteredComments.count
        } else {
            filtered.commentCount = max(filteredComments.count, post.commentCount - hiddenCommentCount)
        }

        filtered.reactions = post.reactions.compactMap { summary in
            let filteredReactors = visibleProfiles(summary.reactors)
            let hiddenReactorCount = summary.reactors.count - filteredReactors.count
            let isExact = post.fullyLoadedReactionKinds.contains(summary.kind)
                || summary.reactors.count >= summary.count
            let visibleCount = isExact
                ? filteredReactors.count
                : max(filteredReactors.count, summary.count - hiddenReactorCount)

            guard visibleCount > 0 else { return nil }
            return ReactionSummary(
                kind: summary.kind,
                count: visibleCount,
                reactors: filteredReactors
            )
        }

        return filtered
    }
}
