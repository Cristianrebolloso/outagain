import Foundation

extension AppStore {
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
        guard let data = try? JSONEncoder().encode(notificationPreferences) else { return }
        UserDefaults.standard.set(data, forKey: "OutAgain.notificationPreferences")
    }

    func persistLiveActivityPreferences() {
        guard let data = try? JSONEncoder().encode(liveActivityPreferences) else { return }
        UserDefaults.standard.set(data, forKey: "OutAgain.liveActivityPreferences")
    }

    static func loadAccentColorChoice() -> AccentColorChoice {
        guard let raw = UserDefaults.standard.string(forKey: "OutAgain.accentColor"),
              let choice = AccentColorChoice(rawValue: raw)
        else { return .purple }
        return choice
    }

    static func loadNotificationPreferences() -> NotificationPreferences {
        guard let data = UserDefaults.standard.data(forKey: "OutAgain.notificationPreferences"),
              let preferences = try? JSONDecoder().decode(NotificationPreferences.self, from: data)
        else {
            return NotificationPreferences()
        }

        return preferences
    }

    static func loadLiveActivityPreferences() -> LiveActivityPreferences {
        guard let data = UserDefaults.standard.data(forKey: "OutAgain.liveActivityPreferences"),
              let preferences = try? JSONDecoder().decode(LiveActivityPreferences.self, from: data)
        else {
            return LiveActivityPreferences()
        }

        return preferences
    }

    func mostFrequentDrink(in posts: [MomentPost]) -> DrinkTag? {
        Dictionary(grouping: posts, by: \.drink)
            .max(by: { $0.value.count < $1.value.count })?
            .key
    }

    func mostFrequentVenue(in posts: [MomentPost]) -> Venue? {
        Dictionary(grouping: posts.compactMap(\.venue), by: \.self)
            .max(by: { $0.value.count < $1.value.count })?
            .key
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
        profiles.filter { !blockedUserIDs.contains($0.id) }
    }

    func sortProfilesByDisplayName(_ profiles: [UserProfile]) -> [UserProfile] {
        profiles.sorted {
            if $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedSame {
                return $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func visibleComments(_ comments: [Comment]) -> [Comment] {
        comments
            .filter { !blockedUserIDs.contains($0.author.id) }
            .sorted { lhs, rhs in
                if lhs.createdAt == rhs.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func visibleNotifications(_ notifications: [AppNotification]) -> [AppNotification] {
        notifications.filter { notification in
            guard let actorID = notification.actor?.id else { return true }
            return !blockedUserIDs.contains(actorID)
        }
    }

    func visiblePosts(_ posts: [MomentPost]) -> [MomentPost] {
        posts.compactMap(visiblePost)
    }

    func visiblePost(_ post: MomentPost) -> MomentPost? {
        guard !blockedUserIDs.contains(post.author.id) else { return nil }

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
