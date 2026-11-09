import Foundation

extension AppStore {
    struct UserPostsPageLoadResult {
        let posts: [MomentPost]
        let totalCount: Int?
        let hasMore: Bool
        let didLoadAuthoritatively: Bool
    }

    struct ProfileStatsLoadResult {
        let stats: ProfileStats
        let didLoadAuthoritatively: Bool
    }

    /// Debounce window between the last keystroke and the actual network call.
    /// 250ms is the sweet spot: short enough that the user perceives the search
    /// as responsive, long enough that a typical typing cadence (~100–150ms
    /// between keys) collapses into a single request instead of N.
    private static let friendSearchDebounce: Duration = .milliseconds(250)

    func canViewPrivateProfileContent(of profile: UserProfile) -> Bool {
        isViewerAdmin || profile.id == viewerIdentity.id || friends.contains { $0.id == profile.id }
    }

    func searchForFriends() {
        // Cancel any in-flight debounce from the prior keystroke so we never
        // have two pending requests racing. If the user keeps typing, each
        // call extends the quiet window; only the final stroke survives.
        friendSearchDebounceTask?.cancel()

        let query = PeopleSearchRules.normalized(friendSearchQuery)
        friendSearchResults = []
        friendSearchError = nil
        isSearchingFriends = query.count >= 2

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

    func loadBackgroundTheme(for profileID: UUID) async -> BackgroundTheme? {
        guard let profile = try? await backend.loadUserProfile(id: profileID) else { return nil }
        return profile.backgroundTheme
    }

    private func performFriendSearch(for query: String) async {
        let searchingViewerID = viewer?.id
        do {
            let results = try await backend.searchUsers(matching: query, excluding: viewer)
                .filter { candidate in
                    !friends.contains(where: { $0.id == candidate.id })
                        && !blockedUserIDs.contains(candidate.id)
                }

            // The query may have changed during the network round-trip (user
            // kept typing after debounce fired). Drop stale results rather
            // than clobbering a newer query's state.
            guard !Task.isCancelled, viewer?.id == searchingViewerID,
                  query == PeopleSearchRules.normalized(friendSearchQuery) else { return }
            friendSearchResults = results
            isSearchingFriends = false
        } catch {
            guard !Task.isCancelled, viewer?.id == searchingViewerID,
                  query == PeopleSearchRules.normalized(friendSearchQuery) else { return }
            isSearchingFriends = false
            friendSearchError = "Couldn't search right now. Check your connection and try again."
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
        mutualCounts.removeValue(forKey: friend.id)
        friendSearchResults.removeAll { $0.id == friend.id }

        let viewer = viewerIdentity
        Task {
            do {
                try await backend.sendFriendRequest(to: friend, for: viewer)
                guard self.viewer?.id == viewer.id else { return }
                await refreshAppData(silenceErrors: true)
            } catch {
                guard self.viewer?.id == viewer.id else { return }
                outgoingFriendRequests.removeAll { $0.id == optimisticRequest.id }
                socialErrorMessage = "Couldn't send that friend request."
            }
        }
    }

    func acceptIncomingRequest(_ request: FriendRequest) {
        guard request.direction == .incoming,
              incomingFriendRequests.contains(where: { $0.id == request.id }),
              !blockedUserIDs.contains(request.counterpart.id) else { return }

        // Optimistic: promote counterpart to friends, clear the pending row.
        let wasAlreadyFriend = friends.contains(where: { $0.id == request.counterpart.id })
        if !wasAlreadyFriend {
            friends.insert(request.counterpart, at: 0)
        }
        incomingFriendRequests.removeAll { $0.id == request.id }
        suggestedFriends.removeAll { $0.id == request.counterpart.id }
        mutualCounts.removeValue(forKey: request.counterpart.id)

        let viewer = viewerIdentity
        Task {
            do {
                try await backend.acceptFriendRequest(request, for: viewer)
                guard self.viewer?.id == viewer.id else { return }
                await refreshAppData(silenceErrors: true)
            } catch {
                guard self.viewer?.id == viewer.id else { return }
                // Restore immediately even if the reconciliation request also
                // fails offline; otherwise a failed acceptance looks successful.
                if !wasAlreadyFriend { friends.removeAll { $0.id == request.counterpart.id } }
                if !blockedUserIDs.contains(request.counterpart.id),
                   !incomingFriendRequests.contains(where: { $0.id == request.id }) {
                    incomingFriendRequests.insert(request, at: 0)
                }
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
                guard self.viewer?.id == viewer.id else { return }
                await refreshAppData(silenceErrors: true)
            } catch {
                guard self.viewer?.id == viewer.id else { return }
                if !blockedUserIDs.contains(request.counterpart.id),
                   !incomingFriendRequests.contains(where: { $0.id == request.id }) {
                    incomingFriendRequests.insert(request, at: 0)
                }
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
                guard self.viewer?.id == viewer.id else { return }
                await refreshAppData(silenceErrors: true)
            } catch {
                guard self.viewer?.id == viewer.id else { return }
                if !blockedUserIDs.contains(request.counterpart.id),
                   !outgoingFriendRequests.contains(where: { $0.id == request.id }) {
                    outgoingFriendRequests.insert(request, at: 0)
                }
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
                guard self.viewer?.id == viewer.id else { return }
                await refreshAppData(silenceErrors: true)
            } catch {
                guard self.viewer?.id == viewer.id else { return }
                if !blockedUserIDs.contains(friend.id), !friends.contains(where: { $0.id == friend.id }) {
                    friends = sortProfilesByDisplayName(friends + [friend])
                }
                socialErrorMessage = "Couldn't remove that friend."
                await refreshAppData(silenceErrors: true)
            }
        }
    }

    func blockUser(_ user: UserProfile) {
        friends.removeAll { $0.id == user.id }
        suggestedFriends.removeAll { $0.id == user.id }
        mutualCounts.removeValue(forKey: user.id)
        friendSearchResults.removeAll { $0.id == user.id }
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

    /// Sends a user report to the backend. Fire-and-forget — the UI doesn't
    /// need to reflect any state change locally since reporting doesn't block
    /// or remove the reported account from the viewer's perspective.
    func reportUser(_ user: UserProfile) {
        let viewer = viewerIdentity
        Task {
            try? await backend.reportUser(user, for: viewer)
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

    /// Marks a single notification read locally and on the server. Used by
    /// the in-app banner overlay so that "I saw the banner" counts as seen
    /// and the next login doesn't re-fire the same notification.
    func markNotificationRead(_ id: UUID) {
        guard let idx = notifications.firstIndex(where: { $0.id == id }),
              !notifications[idx].isRead else { return }

        notifications[idx].isRead = true

        Task {
            try? await backend.markNotificationsRead([id])
        }
    }

    func openAddFriends() {
        friendSearchQuery = ""
        friendSearchResults = []
        friendsPageMode = .discover
        handleFriendsTabTap()
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

    func loadPostCount(of profile: UserProfile) async -> Int? {
        do {
            return try await backend.loadPostCount(of: profile)
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

    // MARK: - Admin

    var isViewerAdmin: Bool {
        viewerIdentity.normalizedUsername == "admin"
    }

    var openAdminReportCount: Int {
        adminReports.filter(\.isOpen).count
    }

    func openReports() {
        selectedTab = .activity
        if adminReports.isEmpty {
            loadAdminReportsNextPage(reset: true)
        }
    }

    func loadAdminReportsNextPage(reset: Bool = false) {
        guard isViewerAdmin else { return }
        guard !isLoadingAdminReports else { return }
        guard reset || hasMoreAdminReports else { return }

        isLoadingAdminReports = true
        adminReportsMessage = nil

        let offset = reset ? 0 : adminReports.count
        let limit = AppStore.adminReportPageSize

        Task {
            do {
                let page = try await backend.fetchAdminReports(limit: limit, offset: offset)
                if reset {
                    adminReports = page
                } else {
                    let existingIDs = Set(adminReports.map(\.id))
                    adminReports.append(contentsOf: page.filter { !existingIDs.contains($0.id) })
                }
                hasMoreAdminReports = page.count == limit
            } catch {
                adminReportsMessage = "Couldn't load reports right now."
            }
            isLoadingAdminReports = false
        }
    }

    func resolveAdminReport(_ report: ContentReport) {
        guard isViewerAdmin else { return }
        adminReportsMessage = nil

        Task {
            do {
                try await backend.resolveReport(id: report.id)
                markAdminReport(report.id, status: "reviewed")
            } catch {
                adminReportsMessage = "Couldn't mark that report reviewed."
            }
        }
    }

    func deleteReportedPost(_ report: ContentReport) {
        guard isViewerAdmin, let postID = report.targetPostID else { return }
        adminReportsMessage = nil

        Task {
            do {
                try await backend.deletePostAsAdmin(postID, reportID: report.id)
                removePostEverywhere(postID, rememberDeleted: true)
                markAdminReport(report.id, status: "actioned")
            } catch {
                adminReportsMessage = "Couldn't delete that post."
            }
        }
    }

    func deleteReportedComment(_ report: ContentReport) {
        guard isViewerAdmin, let commentID = report.targetCommentID else { return }
        adminReportsMessage = nil

        Task {
            do {
                try await backend.deleteCommentAsAdmin(commentID, reportID: report.id)
                posts = posts.map { post in
                    var copy = post
                    copy.comments.removeAll { $0.id == commentID }
                    return copy
                }
                tonightActivityPosts = tonightActivityPosts.map { post in
                    var copy = post
                    copy.comments.removeAll { $0.id == commentID }
                    return copy
                }
                markAdminReport(report.id, status: "actioned")
            } catch {
                adminReportsMessage = "Couldn't delete that comment."
            }
        }
    }

    func banReportedUser(_ report: ContentReport) {
        guard isViewerAdmin else { return }
        adminReportsMessage = nil

        Task {
            do {
                try await backend.banUser(report.targetAuthorID)
                adminAllUsers.removeAll { $0.id == report.targetAuthorID }
                friends.removeAll { $0.id == report.targetAuthorID }
                suggestedFriends.removeAll { $0.id == report.targetAuthorID }
                posts.removeAll { $0.author.id == report.targetAuthorID }
                tonightActivityPosts.removeAll { $0.author.id == report.targetAuthorID }
                markAdminReport(report.id, status: "actioned")
            } catch {
                adminReportsMessage = "Couldn't ban that user."
            }
        }
    }

    private func markAdminReport(_ reportID: UUID, status: String) {
        adminReports = adminReports.map { report in
            guard report.id == reportID else { return report }
            var updated = report
            updated.status = status
            updated.reviewedAt = .now
            return updated
        }
    }

    func loadAdminUsersNextPage() {
        guard !isLoadingAdminUsers, hasMoreAdminUsers else { return }
        isLoadingAdminUsers = true
        let offset = adminAllUsers.count
        let limit = AppStore.adminUserPageSize
        Task {
            do {
                let page = try await backend.fetchAllUsersPage(offset: offset, limit: limit)
                adminAllUsers.append(contentsOf: page)
                hasMoreAdminUsers = page.count == limit
            } catch {
                // Non-critical; leave hasMoreAdminUsers true so the user can retry.
            }
            isLoadingAdminUsers = false
        }
    }

    func setVerified(_ isVerified: Bool, for profile: UserProfile) {
        Task {
            do {
                try await backend.setVerified(isVerified, for: profile)
                // Update the profile in every local collection that might hold it.
                func patch(_ p: UserProfile) -> UserProfile {
                    var updated = p
                    updated.isVerified = isVerified
                    return updated
                }
                friends = friends.map { $0.id == profile.id ? patch($0) : $0 }
                suggestedFriends = suggestedFriends.map { $0.id == profile.id ? patch($0) : $0 }
                adminAllUsers = adminAllUsers.map { $0.id == profile.id ? patch($0) : $0 }
                posts = posts.map { post in
                    var p = post
                    if p.author.id == profile.id { p.author = patch(p.author) }
                    p.taggedFriends = p.taggedFriends.map { $0.id == profile.id ? patch($0) : $0 }
                    p.comments = p.comments.map { comment in
                        var c = comment
                        if c.author.id == profile.id { c.author = patch(c.author) }
                        return c
                    }
                    return p
                }
            } catch {
                socialErrorMessage = "Couldn't update verified status."
            }
        }
    }

    func setUserBanned(_ isBanned: Bool, for profile: UserProfile) {
        guard canAdminModerate(profile) else { return }
        adminBusyUserIDs.insert(profile.id)
        adminStatusMessage = nil

        Task {
            defer { adminBusyUserIDs.remove(profile.id) }

            do {
                let updatedProfile = try await backend.setUserBanned(isBanned, userID: profile.id)
                applyAdminProfilePatch(updatedProfile)
                adminStatusMessage = isBanned
                    ? "@\(updatedProfile.username) is banned."
                    : "@\(updatedProfile.username) is unbanned."
            } catch {
                socialErrorMessage = isBanned ? "Couldn't ban that user." : "Couldn't unban that user."
            }
        }
    }

    func deleteUserContent(_ profile: UserProfile) {
        guard canAdminModerate(profile) else { return }
        adminBusyUserIDs.insert(profile.id)
        adminStatusMessage = nil

        Task {
            defer { adminBusyUserIDs.remove(profile.id) }

            do {
                let summary = try await backend.deleteUserContent(userID: profile.id)
                removeLocalContent(for: profile.id)
                adminStatusMessage = "Deleted \(summary.totalDeletedRows) rows for @\(profile.username)."
                await refreshAppData(silenceErrors: true)
            } catch {
                socialErrorMessage = "Couldn't delete that user's content."
            }
        }
    }

    func canAdminModerate(_ profile: UserProfile) -> Bool {
        isViewerAdmin
        && profile.id != viewerIdentity.id
        && profile.normalizedUsername != "admin"
    }

    private func applyAdminProfilePatch(_ updatedProfile: UserProfile) {
        func patch(_ profile: UserProfile) -> UserProfile {
            guard profile.id == updatedProfile.id else { return profile }
            var merged = updatedProfile
            merged.isCloseFriend = profile.isCloseFriend
            if merged.avatar.imageData == nil {
                merged.avatar.imageData = profile.avatar.imageData
            }
            return merged
        }

        friends = friends.map(patch)
        suggestedFriends = suggestedFriends.map(patch)
        adminAllUsers = adminAllUsers.map(patch)
        blockedUsers = blockedUsers.map(patch)
        incomingFriendRequests = incomingFriendRequests.map { request in
            var updated = request
            updated.counterpart = patch(request.counterpart)
            return updated
        }
        outgoingFriendRequests = outgoingFriendRequests.map { request in
            var updated = request
            updated.counterpart = patch(request.counterpart)
            return updated
        }
        posts = posts.map { post in
            var updated = post
            updated.author = patch(post.author)
            updated.taggedFriends = updated.taggedFriends.map(patch)
            updated.comments = updated.comments.map { comment in
                var updatedComment = comment
                updatedComment.author = patch(comment.author)
                return updatedComment
            }
            updated.reactions = updated.reactions.map { reaction in
                var updatedReaction = reaction
                updatedReaction.reactors = reaction.reactors.map(patch)
                return updatedReaction
            }
            return updated
        }
        tonightActivityPosts = tonightActivityPosts.map { post in
            var updated = post
            updated.author = patch(post.author)
            updated.taggedFriends = updated.taggedFriends.map(patch)
            updated.comments = updated.comments.map { comment in
                var updatedComment = comment
                updatedComment.author = patch(comment.author)
                return updatedComment
            }
            return updated
        }
    }

    private func removeLocalContent(for userID: UUID) {
        let deletedPostIDs = Set(posts.filter { $0.author.id == userID }.map(\.id))

        func scrub(_ post: MomentPost) -> MomentPost? {
            guard post.author.id != userID else { return nil }
            var updated = post
            updated.taggedFriends.removeAll { $0.id == userID }
            updated.comments.removeAll { $0.author.id == userID }
            updated.commentCount = min(updated.commentCount, updated.comments.count)
            updated.reactions = updated.reactions.map { reaction in
                var updatedReaction = reaction
                updatedReaction.reactors.removeAll { $0.id == userID }
                if !updatedReaction.reactors.isEmpty {
                    updatedReaction.count = updatedReaction.reactors.count
                }
                return updatedReaction
            }
            return updated
        }

        posts = posts.compactMap(scrub)
        tonightActivityPosts = tonightActivityPosts.compactMap(scrub)
        notifications.removeAll {
            $0.actor?.id == userID
            || $0.postID.map { deletedPostIDs.contains($0) } == true
        }
        friends.removeAll { $0.id == userID }
        suggestedFriends.removeAll { $0.id == userID }
        incomingFriendRequests.removeAll { $0.counterpart.id == userID }
        outgoingFriendRequests.removeAll { $0.counterpart.id == userID }
        friendOfFriendIDsStore.remove(userID)
        mutualCounts[userID] = nil
    }

    func cacheProfilePosts(_ loadedPosts: [MomentPost]) {
        guard !loadedPosts.isEmpty else { return }

        let existingByID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
        let merged = loadedPosts.map { post -> MomentPost in
            guard let existing = existingByID[post.id] else { return post }
            var hydrated = post
            if hydrated.media.photoData == nil {
                hydrated.media.photoData = existing.media.photoData
            }
            if hydrated.media.photoAspectRatio == nil {
                hydrated.media.photoAspectRatio = existing.media.photoAspectRatio
            }
            return hydrated
        }
        .map { applyingPendingEngagement(to: $0) }

        let mergedIDs = Set(merged.map(\.id))
        let retained = posts.filter { !mergedIDs.contains($0.id) }
        posts = sortPostsByRecency(retained + merged)
        refreshCatalogs()
    }

    func loadUserPostsPage(
        for profile: UserProfile,
        before: Date?,
        limit: Int
    ) async -> UserPostsPageLoadResult {
        guard (isViewerAdmin || !blockedUserIDs.contains(profile.id)),
              canViewPrivateProfileContent(of: profile)
        else {
            return UserPostsPageLoadResult(
                posts: [],
                totalCount: nil,
                hasMore: false,
                didLoadAuthoritatively: true
            )
        }

        do {
            let page = try await backend.loadUserPostsPage(
                for: profile,
                viewer: viewerIdentity,
                before: before,
                limit: limit
            )
            let visible = visiblePosts(page.posts)
                .map { applyingPendingEngagement(to: $0) }
            cacheProfilePosts(visible)
            return UserPostsPageLoadResult(
                posts: sortPostsByRecency(visible),
                totalCount: page.totalCount,
                hasMore: page.hasMore,
                didLoadAuthoritatively: true
            )
        } catch {
            let fallbackAll = sortPostsByRecency(
                posts.filter { $0.author.id == profile.id }
            )
            let fallbackSlice = fallbackAll.filter { post in
                guard let before else { return true }
                return post.createdAt < before
            }
            let fallbackPage = Array(fallbackSlice.prefix(limit))
            if before == nil {
                socialErrorMessage = "Couldn't load \(profile.displayName)'s posts."
            }
            return UserPostsPageLoadResult(
                posts: fallbackPage,
                totalCount: before == nil ? fallbackAll.count : nil,
                hasMore: fallbackSlice.count > limit,
                didLoadAuthoritatively: false
            )
        }
    }

    /// Fetches posts where `profile` appears as a tagged friend, newest-first.
    /// Falls back to scanning `store.posts` (the bootstrap window) so the tab
    /// is never completely empty on a network error.
    func loadTaggedPostsPage(
        for profile: UserProfile,
        before: Date?,
        limit: Int
    ) async -> UserPostsPageLoadResult {
        guard (isViewerAdmin || !blockedUserIDs.contains(profile.id)),
              canViewPrivateProfileContent(of: profile)
        else {
            return UserPostsPageLoadResult(
                posts: [],
                totalCount: nil,
                hasMore: false,
                didLoadAuthoritatively: true
            )
        }

        do {
            let page = try await backend.loadTaggedPostsPage(
                for: profile,
                viewer: viewerIdentity,
                before: before,
                limit: limit
            )
            let visible = visiblePosts(page.posts)
                .map { applyingPendingEngagement(to: $0) }
            cacheProfilePosts(visible)
            return UserPostsPageLoadResult(
                posts: sortPostsByRecency(visible),
                totalCount: page.totalCount,
                hasMore: page.hasMore,
                didLoadAuthoritatively: true
            )
        } catch {
            // Fall back to whatever the bootstrap already loaded.
            let fallbackAll = sortPostsByRecency(
                posts.filter { $0.taggedFriends.contains(where: { $0.id == profile.id }) }
            )
            let fallbackSlice = fallbackAll.filter { post in
                guard let before else { return true }
                return post.createdAt < before
            }
            let fallbackPage = Array(fallbackSlice.prefix(limit))
            return UserPostsPageLoadResult(
                posts: fallbackPage,
                totalCount: before == nil ? fallbackAll.count : nil,
                hasMore: fallbackSlice.count > limit,
                didLoadAuthoritatively: false
            )
        }
    }

    func loadProfileStats(for profile: UserProfile) async -> ProfileStatsLoadResult {
        guard (isViewerAdmin || !blockedUserIDs.contains(profile.id)),
              canViewPrivateProfileContent(of: profile)
        else {
            return ProfileStatsLoadResult(
                stats: .empty,
                didLoadAuthoritatively: true
            )
        }

        do {
            let stats = try await backend.loadProfileStats(
                for: profile,
                viewer: viewerIdentity
            )
            return ProfileStatsLoadResult(
                stats: stats,
                didLoadAuthoritatively: true
            )
        } catch {
            let fallbackPosts = visiblePosts(
                posts.filter { $0.author.id == profile.id }
            )
            return ProfileStatsLoadResult(
                stats: profileStats(in: fallbackPosts),
                didLoadAuthoritatively: false
            )
        }
    }

    func loadProfileFriendRank(for profile: UserProfile) async -> ProfileFriendRank? {
        guard (isViewerAdmin || !blockedUserIDs.contains(profile.id)),
              canViewPrivateProfileContent(of: profile)
        else {
            return nil
        }

        do {
            return try await backend.loadProfileFriendRank(
                for: profile,
                viewer: viewerIdentity,
                timeZoneIdentifier: TimeZone.current.identifier
            )
        } catch {
            return nil
        }
    }
}
