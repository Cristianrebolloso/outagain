import Foundation

extension AppStore {
    struct UserPostsLoadResult {
        let posts: [MomentPost]
        let didLoadAuthoritatively: Bool
    }

    /// Debounce window between the last keystroke and the actual network call.
    /// 250ms is the sweet spot: short enough that the user perceives the search
    /// as responsive, long enough that a typical typing cadence (~100–150ms
    /// between keys) collapses into a single request instead of N.
    private static let friendSearchDebounce: Duration = .milliseconds(250)

    func searchForFriends() {
        // Cancel any in-flight debounce from the prior keystroke so we never
        // have two pending requests racing. If the user keeps typing, each
        // call extends the quiet window; only the final stroke survives.
        friendSearchDebounceTask?.cancel()

        let query = UsernameRules.searchFragment(friendSearchQuery)

        // Under the two-character threshold there's nothing to fetch — clear
        // results synchronously so the UI reflects the empty state instantly,
        // without waiting for a debounce cycle.
        guard query.count >= 2 else {
            friendSearchResults = []
            return
        }

        friendSearchDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.friendSearchDebounce)
            guard !Task.isCancelled, let self else { return }
            await self.performFriendSearch(for: query)
        }
    }

    private func performFriendSearch(for query: String) async {
        do {
            let results = try await backend.searchUsers(matching: query, excluding: viewer)
                .filter { candidate in
                    !friends.contains(where: { $0.id == candidate.id })
                        && !blockedUserIDs.contains(candidate.id)
                }

            // The query may have changed during the network round-trip (user
            // kept typing after debounce fired). Drop stale results rather
            // than clobbering a newer query's state.
            guard query == UsernameRules.searchFragment(friendSearchQuery) else { return }
            friendSearchResults = results
        } catch {
            guard query == UsernameRules.searchFragment(friendSearchQuery) else { return }
            socialErrorMessage = "Couldn't search for friends right now."
        }
    }

    /// Sends a pending friend request. The backend auto-accepts if a reciprocal request already exists.
    func sendFriendRequest(to friend: UserProfile) {
        guard !friends.contains(where: { $0.id == friend.id }) else { return }
        guard !outgoingFriendRequests.contains(where: { $0.counterpart.id == friend.id }) else { return }
        guard !blockedUserIDs.contains(friend.id) else { return }

        // Optimistic UI: if there's an incoming request from this user, treat as immediate accept.
        if let incoming = incomingFriendRequests.first(where: { $0.counterpart.id == friend.id }) {
            acceptIncomingRequest(incoming)
            return
        }

        let optimisticRequest = FriendRequest(
            id: UUID(),
            counterpart: friend,
            direction: .outgoing,
            createdAt: .now
        )
        outgoingFriendRequests.insert(optimisticRequest, at: 0)
        suggestedFriends.removeAll { $0.id == friend.id }
        friendSearchResults.removeAll { $0.id == friend.id }
        contactMatches.removeAll { $0.id == friend.id }

        let viewer = viewerIdentity
        Task {
            do {
                try await backend.sendFriendRequest(to: friend, for: viewer)
                await refreshAppData(silenceErrors: true)
            } catch {
                outgoingFriendRequests.removeAll { $0.id == optimisticRequest.id }
                socialErrorMessage = "Couldn't send that friend request."
            }
        }
    }

    func acceptIncomingRequest(_ request: FriendRequest) {
        guard request.direction == .incoming else { return }

        // Optimistic: promote counterpart to friends, clear the pending row.
        if !friends.contains(where: { $0.id == request.counterpart.id }) {
            friends.insert(request.counterpart, at: 0)
        }
        incomingFriendRequests.removeAll { $0.id == request.id }
        suggestedFriends.removeAll { $0.id == request.counterpart.id }

        let viewer = viewerIdentity
        Task {
            do {
                try await backend.acceptFriendRequest(request, for: viewer)
                await refreshAppData(silenceErrors: true)
            } catch {
                socialErrorMessage = "Couldn't accept that friend request."
                await refreshAppData(silenceErrors: true)
            }
        }
    }

    func rejectIncomingRequest(_ request: FriendRequest) {
        guard request.direction == .incoming else { return }

        incomingFriendRequests.removeAll { $0.id == request.id }

        let viewer = viewerIdentity
        Task {
            do {
                try await backend.rejectFriendRequest(request, for: viewer)
            } catch {
                socialErrorMessage = "Couldn't reject that friend request."
                await refreshAppData(silenceErrors: true)
            }
        }
    }

    func cancelOutgoingRequest(_ request: FriendRequest) {
        guard request.direction == .outgoing else { return }

        outgoingFriendRequests.removeAll { $0.id == request.id }

        let viewer = viewerIdentity
        Task {
            do {
                // Cancelling an outgoing request is the same DB operation as rejecting an incoming one.
                try await backend.rejectFriendRequest(request, for: viewer)
            } catch {
                socialErrorMessage = "Couldn't cancel that request."
                await refreshAppData(silenceErrors: true)
            }
        }
    }

    func unfriend(_ friend: UserProfile) {
        friends.removeAll { $0.id == friend.id }

        let viewer = viewerIdentity
        Task {
            do {
                try await backend.unfriend(friend, for: viewer)
                await refreshAppData(silenceErrors: true)
            } catch {
                socialErrorMessage = "Couldn't remove that friend."
                await refreshAppData(silenceErrors: true)
            }
        }
    }

    func blockUser(_ user: UserProfile) {
        friends.removeAll { $0.id == user.id }
        suggestedFriends.removeAll { $0.id == user.id }
        friendSearchResults.removeAll { $0.id == user.id }
        contactMatches.removeAll { $0.id == user.id }
        incomingFriendRequests.removeAll { $0.counterpart.id == user.id }
        outgoingFriendRequests.removeAll { $0.counterpart.id == user.id }
        blockedUserIDs.insert(user.id)
        blockedUsers.removeAll { $0.id == user.id }
        blockedUsers = sortProfilesByDisplayName(blockedUsers + [user])
        posts = sortPostsByRecency(visiblePosts(posts))
        notifications = visibleNotifications(notifications)
        ensureSelectedPresenceCluster()
        persistFeedCache()

        let viewer = viewerIdentity
        Task {
            do {
                try await backend.blockUser(user, for: viewer)
                await refreshAppData(silenceErrors: true)
            } catch {
                socialErrorMessage = "Couldn't block that user."
                await refreshAppData(silenceErrors: true)
            }
        }
    }

    func unblockUser(_ user: UserProfile) {
        guard blockedUserIDs.contains(user.id) else { return }
        blockedUserIDs.remove(user.id)
        let removedProfiles = blockedUsers.filter { $0.id == user.id }
        blockedUsers.removeAll { $0.id == user.id }

        let viewer = viewerIdentity
        Task {
            do {
                try await backend.unfriend(user, for: viewer)
                await refreshAppData(silenceErrors: true)
            } catch {
                blockedUserIDs.insert(user.id)
                blockedUsers = sortProfilesByDisplayName(blockedUsers + removedProfiles)
                socialErrorMessage = "Couldn't unblock that user."
                await refreshAppData(silenceErrors: true)
            }
        }
    }

    /// Removes a single notification optimistically from the local list, then
    /// deletes it from the backend so it doesn't reappear on the next bootstrap.
    func dismissNotification(_ notification: AppNotification) {
        markNotificationsPendingDeletion([notification.id])
        notifications.removeAll { $0.id == notification.id }
        Task {
            do {
                try await backend.deleteNotification(id: notification.id)
                clearPendingDeletedNotificationIDs([notification.id])
            } catch {
                socialErrorMessage = "Couldn't clear that notification yet."
            }
        }
    }

    func clearAllNotifications() {
        let ids = notifications.map(\.id)
        guard !ids.isEmpty else { return }

        markNotificationsPendingDeletion(ids)
        notifications = []
        Task {
            do {
                try await backend.deleteNotifications(ids: ids)
                clearPendingDeletedNotificationIDs(ids)
            } catch {
                socialErrorMessage = "Couldn't clear notifications yet."
            }
        }
    }

    func openNotifications() {
        // Activity is now a real tab, not a sheet. Route there and let the
        // view's onAppear hand off to markActivityAsSeen so the read-state
        // side effect is idempotent regardless of how the user got here
        // (tab tap, deep link, push tap, etc.).
        selectedTab = .activity
    }

    func markActivityAsSeen() {
        let unreadIDs = notifications.filter { !$0.isRead }.map(\.id)
        guard !unreadIDs.isEmpty else { return }

        notifications = notifications.map {
            var copy = $0
            copy.isRead = true
            return copy
        }

        Task {
            try? await backend.markNotificationsRead(unreadIDs)
        }
    }

    func openAddFriends() {
        friendSearchQuery = ""
        friendSearchResults = []
        contactMatches = []
        friendsPageMode = .discover
        selectedTab = .friends
    }

    func loadFriendCount(of profile: UserProfile) async -> Int? {
        if profile.id == viewerIdentity.id {
            return friends.count
        }

        do {
            return try await backend.loadFriendCount(of: profile, for: viewerIdentity)
        } catch {
            return nil
        }
    }

    func loadFriends(of profile: UserProfile) async -> [UserProfile] {
        if profile.id == viewerIdentity.id {
            return visibleProfiles(friends)
        }

        do {
            return visibleProfiles(
                try await backend.loadFriends(of: profile, for: viewerIdentity)
            )
        } catch {
            socialErrorMessage = "Couldn't load \(profile.displayName)'s friends."
            return []
        }
    }

    /// Fetches posts authored by `profile` from the backend.
    /// For friends, we return what's already in `store.posts` (already in
    /// the feed bootstrap) to avoid a redundant network round-trip.
    /// For non-friends, we go to the backend since their posts were never
    /// included in the viewer's bootstrap.
    func loadUserPosts(for profile: UserProfile) async -> UserPostsLoadResult {
        guard !blockedUserIDs.contains(profile.id) else {
            return UserPostsLoadResult(posts: [], didLoadAuthoritatively: true)
        }

        // Always fetch from the backend rather than short-circuiting when
        // local posts exist. The bootstrap may only contain a subset of a
        // friend's posts (e.g. only their most recent one from the feed),
        // so returning early produces incorrect nightly drink counts and
        // incomplete profile grids. We fetch, merge fresh posts, and
        // return the full authoritative list every time.
        do {
            let loaded = visiblePosts(
                try await backend.loadUserPosts(for: profile, viewer: viewerIdentity)
            )
            // Merge into store.posts so CommentThreadSheet (which looks up
            // posts by ID from store.posts) can find them. Deduplicate by ID
            // so we never double-insert if the user views the same profile twice.
            if !loaded.isEmpty {
                let existingIDs = Set(posts.map(\.id))
                let fresh = loaded.filter { !existingIDs.contains($0.id) }
                if !fresh.isEmpty {
                    posts.append(contentsOf: fresh)
                    refreshCatalogs()
                }
            }
            return UserPostsLoadResult(
                posts: sortPostsByRecency(loaded),
                didLoadAuthoritatively: true
            )
        } catch {
            // On failure, fall back to whatever we already have locally
            // so the UI doesn't go blank for a transient network error.
            return UserPostsLoadResult(
                posts: sortPostsByRecency(posts.filter { $0.author.id == profile.id }),
                didLoadAuthoritatively: false
            )
        }
    }
}
