import Foundation
import SwiftUI
import UIKit

extension AppStore {
    func openPostFlow() {
        guard !isPostFlowPresented else { return }
        postFlowDismissalRepinTask?.cancel()
        postFlowDismissalRepinTask = nil
        didPublishDuringPostFlow = false
        resetDraft()
        // Sync our binding to .post so SwiftUI agrees with iOS's internal
        // search-tab selection. Without this, our binding stays on the
        // previous tab while iOS thinks the search tab is selected, and the
        // dismissal-time write to selectedTab isn't a real transition — so
        // iOS never deselects the search tab and the user gets stranded on
        // the empty placeholder. The didSet on selectedTab skips updating
        // lastRegularTab when the value is .post, so the previous tab is
        // preserved for the dismissal route.
        selectedTab = .post
        let cameraPresentationID = UUID()
        postFlowCameraPresentationID = sharedCamera.beginPresentation(id: cameraPresentationID)
        // Pre-warm the camera before the cover animation starts.
        // prepare() is idempotent — if the session is already running (second
        // open in the same app session) it calls startSessionIfNeeded() only.
        if !isLayoutPreview { Task { await sharedCamera.prepare(supportsSubjectPreview: isDuoDevice) } }
        isPostFlowPresented = true
    }

    func closePostFlow() {
        isPostFlowPresented = false
        finishPostFlowDismissal()
    }

    func finishPostFlowDismissal() {
        let target: AppTab = didPublishDuringPostFlow ? .home : lastRegularTab
        selectedTab = target
        if target == .home {
            feedScope = .friends
            ensureSelectedPresenceCluster()
        }
        didPublishDuringPostFlow = false
        resetDraft()

        // The search-role Tab can momentarily reselect itself after the
        // cover dismisses. Re-pin selectedTab across the dismissal frames
        // so backing out doesn't strand the user on the empty placeholder.
        postFlowDismissalRepinTask?.cancel()
        postFlowDismissalRepinTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            if !isPostFlowPresented, selectedTab == .post { selectedTab = target }
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            if !isPostFlowPresented, selectedTab == .post { selectedTab = target }
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            if !isPostFlowPresented, selectedTab == .post { selectedTab = target }
            postFlowDismissalRepinTask = nil
        }
    }

    func applyCapturedPhoto(_ data: Data?, lensMode: CameraCaptureMode) {
        postDraft.capturedPhotoData = data
        postDraft.lensMode = lensMode
        postDraft.isUsingSampleCapture = false
    }

    func clearDraftCapture(preservingDetails: Bool = false) {
        postDraft.capturedPhotoData = nil
        postDraft.isUsingSampleCapture = false
        guard !preservingDetails else { return }
        postDraft.caption = ""
        postDraft.taggedFriendIDs = []
        postDraft.selectedDrinkIDs = []
    }

    func applyDraftLocation(_ location: LocationSnapshot?, suggestedVenue: Venue?) {
        postDraft.location = location
        postDraft.selectedVenueID = suggestedVenue?.id
    }

    func useSampleCapture() {
        postDraft.capturedPhotoData = nil
        postDraft.sampleSymbol = "sparkles.tv"
        postDraft.isUsingSampleCapture = true
    }

    /// Toggles the single selected drink for the draft.
    /// Tapping a new drink replaces the previous choice; tapping the currently
    /// selected drink clears the choice.
    func toggleDrink(_ drink: DrinkTag) {
        if postDraft.selectedDrinkIDs.first == drink.id {
            postDraft.selectedDrinkIDs = []
        } else {
            postDraft.selectedDrinkIDs = [drink.id]
        }
    }

    /// Convenience for callers that need a forced single-select
    /// (e.g. Vision suggestion or quick-add).
    func selectDrink(_ drink: DrinkTag) {
        postDraft.selectedDrinkIDs = [drink.id]
    }

    func deselectDrink(_ drink: DrinkTag) {
        postDraft.selectedDrinkIDs.removeAll { $0 == drink.id }
    }

    func deselectAllDrinks() {
        postDraft.selectedDrinkIDs = []
    }

    func selectVenue(_ venue: Venue) {
        postDraft.selectedVenueID = venue.id
    }

    func toggleTaggedFriend(_ friend: UserProfile) {
        if postDraft.taggedFriendIDs.contains(friend.id) {
            postDraft.taggedFriendIDs.remove(friend.id)
        } else {
            postDraft.taggedFriendIDs.insert(friend.id)
        }
    }

    func publishDraft() async {
        guard let viewer, canPublishDraft else { return }
        isPublishingDraft = true
        postPublishError = nil
        defer { isPublishingDraft = false }

        let venue = selectedVenueForDraft
        let request = makeDraftCreateRequest(viewer: viewer, drink: selectedDrinkForDraft, venue: venue)
        let optimisticPost = makeOptimisticDraftPost(from: request)
        let postCountInCycle = viewerPosts.filter {
            isInSameLiveActivityCycle($0.createdAt, as: optimisticPost.createdAt)
        }.count + 1

        if request.shareLocally { localFeedIDs.insert(optimisticPost.id, at: 0) }
        posts.insert(optimisticPost, at: 0)
        pendingPostCreates[optimisticPost.id] = optimisticPost
        do {
            var publishedPost = try await backend.publishMoment(request)
            guard self.viewer?.id == viewer.id else { return }
            // Carry the local photoData forward into the published post so
            // the feed card never flickers through a placeholder while
            // AsyncImage fetches the remote URL. The server response sets
            // photoData: nil (it only knows the remote path), which caused
            // the card to collapse to the gradient placeholder during load.
            if publishedPost.media.photoData == nil {
                publishedPost.media.photoData = optimisticPost.media.photoData
            }
            if publishedPost.media.photoAspectRatio == nil {
                publishedPost.media.photoAspectRatio = optimisticPost.media.photoAspectRatio
            }
            if let index = posts.firstIndex(where: { $0.id == optimisticPost.id }) {
                posts[index] = publishedPost
            } else if !posts.contains(where: { $0.id == publishedPost.id }) {
                posts.insert(publishedPost, at: 0)
            }
            if let index = localFeedIDs.firstIndex(of: optimisticPost.id) { localFeedIDs[index] = publishedPost.id }
            pendingPostCreates[optimisticPost.id] = nil

            // Capture the confirmed or optimistic post before any state
            // mutation. The server may not have indexed the new post yet
            // (replication lag, CDN caching), so we preserve it locally.
            let postedPostID = posts.first(where: {
                $0.id == optimisticPost.id || $0.author.id == optimisticPost.author.id
                    && $0.createdAt >= optimisticPost.createdAt
            })?.id ?? optimisticPost.id
            let postToPreserve = posts.first(where: { $0.id == postedPostID })
            // Hold onto the local image so we can re-inject it after any
            // refresh that strips photoData (server records never carry it).
            let localPhotoData = optimisticPost.media.photoData
            let localAspectRatio = optimisticPost.media.photoAspectRatio

            // Add the new post to tonightActivityPosts immediately so the
            // activity strip reflects the publish without a full bootstrap.
            // Use the confirmed server post if available; fall back to the
            // optimistic copy (which has all the same fields the strip needs).
            let postForStrip = postToPreserve ?? optimisticPost
            let tonightWindow = AppStore.tonightWindow(reference: .now)
            if tonightWindow.contains(postForStrip.createdAt),
               !tonightActivityPosts.contains(where: { $0.id == postForStrip.id }) {
                tonightActivityPosts = sortPostsByRecency([postForStrip] + tonightActivityPosts)
            }

            // Re-inject the local photoData so the feed card renders from
            // local memory rather than collapsing to a gradient placeholder
            // while AsyncImage fetches the remote URL.
            if let localPhotoData,
               let index = posts.firstIndex(where: { $0.id == postedPostID }) {
                posts[index].media.photoData = localPhotoData
                if let ratio = localAspectRatio {
                    posts[index].media.photoAspectRatio = ratio
                }

                // Seed the aspect ratio cache from local pixel data so the
                // placeholder is pre-sized correctly on every future refresh
                // even after photoData is no longer held in memory.
                if let remoteURL = posts[index].media.remotePhotoURL,
                   let image = UIImage(data: localPhotoData),
                   image.size.height > 0 {
                    photoAspectRatioCache[remoteURL.absoluteString] =
                        image.size.width / image.size.height
                }
            }

            // Skip the full bootstrap on publish. The optimistic post is
            // already in the feed and the activity strip. The next 60-second
            // poll tick will pick up any engagement that accumulates before
            // then. A full bootstrap here doubled egress on every post for
            // no visible benefit to the publisher.
            // Exception: if the server post ID differs from the optimistic ID
            // (shouldn't happen, but defensive), re-insert the server copy.
            if let post = postToPreserve,
               !posts.contains(where: { $0.id == post.id }) {
                posts.insert(post, at: 0)
            }
            handleLiveActivityAfterPublishing(publishedPost, postCountInCycle: postCountInCycle)
        } catch {
            guard self.viewer?.id == viewer.id else { return }
            pendingPostCreates[optimisticPost.id] = nil
            removePostEverywhere(optimisticPost.id)
            postPublishError = "Your photo and details are still here. Check your connection and tap Post to retry."
            pendingMaddoxPlayer = false
            return
        }

        didPublishDuringPostFlow = true
        // If the Maddox easter egg is taking over the dismiss transition,
        // leave isPostFlowPresented alone — MaddoxPlayerView handles it.
        // Otherwise, dismissing the cover triggers finishPostFlowDismissal,
        // which routes to Home because didPublishDuringPostFlow is true.
        if !isMaddoxPlayerPresented {
            isPostFlowPresented = false
        } else {
            selectedTab = .home
            feedScope = .friends
            ensureSelectedPresenceCluster()
        }
        resetDraft()
    }

    func handleIncomingURL(_ url: URL) {
        if receiveSocialInvite(url.absoluteString) { return }
        guard url.scheme == QuickPostDeepLink.quickPostURL.scheme else { return }

        let host = url.host?.lowercased()
        let path = url.path.lowercased()
        if host == "quick-post" || path == "/quick-post" {
            openPostFlow()
        }
    }

    func setLiveActivitiesEnabled(_ isEnabled: Bool) {
        liveActivityPreferences.setEnabled(isEnabled)
        if isEnabled {
            if let payload = liveActivityTogglePayload() {
                startLiveActivity(with: payload, showsFailureMessage: true)
            }
        } else {
            Task {
                guard !liveActivityPreferences.isEnabled else { return }
                await QuickPostLiveActivityManager.endAll()
            }
        }
    }

    private func handleLiveActivityAfterPublishing(_ post: MomentPost, postCountInCycle: Int) {
        guard liveActivityPreferences.isEnabled else { return }
        // Default-on needs no extra app prompt. An iOS-level opt-out should
        // also stay quiet instead of showing an error after every post.
        startLiveActivity(with: liveActivityPayload(for: post, postCountToday: postCountInCycle))
    }

    func refreshCurrentLiveActivity() {
        guard liveActivityPreferences.isEnabled else { return }
        guard let latestPost = viewerPosts.first(where: {
            isInSameLiveActivityCycle($0.createdAt, as: .now)
        }) else { return }

        let postCountToday = viewerPosts.filter {
            isInSameLiveActivityCycle($0.createdAt, as: latestPost.createdAt)
        }.count

        startLiveActivity(with: liveActivityPayload(for: latestPost, postCountToday: max(postCountToday, 1)))
    }

    func liveActivityPayload(
        for post: MomentPost,
        postCountToday: Int
    ) -> QuickPostLiveActivityPayload {
        return QuickPostLiveActivityPayload(
            postCountToday: postCountToday,
            createdAt: post.createdAt,
            cycleEnd: liveActivityCycleEnd(for: post.createdAt)
        )
    }

    private func liveActivityTogglePayload() -> QuickPostLiveActivityPayload? {
        if let latestPost = viewerPosts.first(where: {
            isInSameLiveActivityCycle($0.createdAt, as: .now)
        }) {
            let postCountToday = viewerPosts.filter {
                isInSameLiveActivityCycle($0.createdAt, as: latestPost.createdAt)
            }.count
            return liveActivityPayload(for: latestPost, postCountToday: max(postCountToday, 1))
        }

        return nil
    }

    private func startLiveActivity(with payload: QuickPostLiveActivityPayload, showsFailureMessage: Bool = false) {
        let userID = viewer?.id
        Task {
            guard viewer?.id == userID, liveActivityPreferences.isEnabled else { return }
            let didStart = await QuickPostLiveActivityManager.startOrUpdate(with: payload)
            guard viewer?.id == userID, liveActivityPreferences.isEnabled else {
                await QuickPostLiveActivityManager.endAll()
                return
            }
            if !didStart {
                await MainActor.run {
                    if showsFailureMessage {
                        socialErrorMessage = "Live Activities are enabled, but iOS couldn't start one on this device right now."
                    }
                }
            }
        }
    }

    private func isInSameLiveActivityCycle(_ candidate: Date, as reference: Date) -> Bool {
        let window = AppStore.tonightWindow(reference: reference)
        return candidate >= window.lowerBound && candidate < window.upperBound
    }

    private func liveActivityCycleEnd(for date: Date) -> Date {
        AppStore.tonightWindow(reference: date).upperBound
    }

    func canDeletePost(_ post: MomentPost) -> Bool {
        guard let viewer else { return false }
        return post.author.id == viewer.id || isViewerAdmin
    }

    func removePostsEverywhere(
        _ postIDs: Set<UUID>,
        rememberDeleted: Bool = false,
        persist: Bool = true
    ) {
        guard !postIDs.isEmpty else { return }

        localFeedIDs.removeAll { postIDs.contains($0) }
        posts.removeAll { postIDs.contains($0.id) }
        tonightActivityPosts.removeAll { postIDs.contains($0.id) }
        nightSummaryPosts.removeAll { postIDs.contains($0.id) }
        notifications.removeAll { notification in
            notification.postID.map { postIDs.contains($0) } ?? false
        }

        if rememberDeleted {
            locallyDeletedPostIDs.formUnion(postIDs)
        }

        removeDeliveredNotifications(forPostIDs: postIDs)

        if let selectedID = selectedPresenceClusterID,
           allPresenceClusters.first(where: { $0.id == selectedID }) == nil {
            selectedPresenceClusterID = nil
        }

        refreshCatalogs()
        if persist {
            persistFeedCache()
        }
    }

    func removePostEverywhere(
        _ postID: UUID,
        rememberDeleted: Bool = false,
        persist: Bool = true
    ) {
        removePostsEverywhere([postID], rememberDeleted: rememberDeleted, persist: persist)
    }

    /// Removes one post the viewer is allowed to moderate. Optimistic: drop it from the
    /// local array immediately so the UI feels instant, then hit the
    /// backend. If the delete fails, we refetch rather than restoring the
    /// stale copy — the server's view of the post is authoritative, and
    /// partial failures (e.g. post was already deleted from another
    /// device) would be confusing to unwind by hand.
    func deletePost(_ post: MomentPost) {
        guard canDeletePost(post) else { return }

        removePostEverywhere(post.id, rememberDeleted: true)

        let viewerProfile = viewerIdentity
        Task {
            do {
                if isViewerAdmin {
                    try await backend.deletePostAsAdmin(post.id)
                } else {
                    try await backend.deletePost(post, by: viewerProfile)
                }
                // Storage cleanup runs client-side because Supabase blocks
                // direct DELETEs on storage.objects from SECURITY DEFINER RPCs.
                // Best-effort: failures are swallowed inside deletePostMedia.
                await backend.deletePostMedia(post)
                // Local state already reflects the delete (posts array,
                // notifications, and presence cluster were all updated
                // optimistically above). No full bootstrap needed — the
                // next 60-second poll tick will confirm server truth for
                // friends' feeds. A full refresh here was costing a
                // complete bootstrap egress on every delete.
                removePostEverywhere(post.id, rememberDeleted: true)
                pendingPostCreates[post.id] = nil
            } catch {
                // Rollback the optimistic removal on failure.
                locallyDeletedPostIDs.remove(post.id)
                socialErrorMessage = "Couldn't delete that post."
                // Re-insert the post so local state doesn't silently diverge.
                if !posts.contains(where: { $0.id == post.id }) {
                    posts = sortPostsByRecency([post] + posts)
                }
                refreshCatalogs()
                persistFeedCache()
            }
        }
    }

    func addReaction(_ kind: ReactionKind, to post: MomentPost) {
        guard ReactionKind.allCases.contains(kind) else { return }
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }

        let isRemovingExistingReaction = posts[index].viewerReactionKinds.contains(kind)

        if isRemovingExistingReaction {
            applyLocalReactionRemoval(kind, at: index)

            let updatedPost = posts[index]
            let viewer = viewerIdentity
            let reactionKey = PendingPostReactionKey(postID: updatedPost.id, kind: kind)
            pendingReactionStates[reactionKey] = false

            // Optimistically remove the reaction notification from the local
            // store so the Activity tab updates immediately without a refresh.
            // Only applies when the viewer is NOT the post author (we never
            // push self-reaction notifications, so there's nothing to remove).
            if updatedPost.author.id != viewer.id {
                notifications.removeAll {
                    $0.kind == .reaction
                        && $0.actor?.id == viewer.id
                        && $0.postID == updatedPost.id
                }
            }

            Task {
                do {
                    // Remove the reaction row and delete the notification the
                    // backend pushed to the post author when the like was added.
                    try await backend.removeReaction(kind, from: updatedPost, by: viewer)
                    try? await backend.deleteReactionNotification(kind, on: updatedPost, by: viewer)
                    if pendingReactionStates[reactionKey] == false {
                        pendingReactionStates[reactionKey] = nil
                    }
                } catch {
                    guard pendingReactionStates[reactionKey] == false else { return }
                    pendingReactionStates[reactionKey] = nil
                    applyLocalReactionState(kind, inPostID: updatedPost.id, isPresent: true)
                    socialErrorMessage = "Couldn't update that like."
                }
            }
            return
        }

        applyLocalReactionAddition(kind, at: index)

        let updatedPost = posts[index]
        let viewer = viewerIdentity
        let reactionKey = PendingPostReactionKey(postID: updatedPost.id, kind: kind)
        pendingReactionStates[reactionKey] = true

        Task {
            do {
                if let delivery = try await backend.recordReaction(kind, to: updatedPost, by: viewer) {
                    outboundNotificationDeliveries.insert(delivery, at: 0)
                }
                if pendingReactionStates[reactionKey] == true {
                    pendingReactionStates[reactionKey] = nil
                }
            } catch {
                var shouldShowError = false
                if pendingReactionStates[reactionKey] == true {
                    pendingReactionStates[reactionKey] = nil
                    applyLocalReactionState(kind, inPostID: updatedPost.id, isPresent: false)
                    shouldShowError = true
                }
                if shouldShowError {
                    socialErrorMessage = "Couldn't update that like."
                }
            }
        }
    }

    func addComment(
        _ text: String,
        kind: CommentKind = .text,
        photoData: Data? = nil,
        toPostID postID: UUID,
        replyingTo replyTarget: Comment? = nil
    ) {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }

        let newComment = makeCommentDraft(
            text: text,
            kind: kind,
            photoData: photoData,
            replyTarget: replyTarget
        )

        guard let newComment else { return }

        posts[index].comments.append(newComment)
        posts[index].commentCount += 1

        let post = posts[index]
        let viewer = viewerIdentity
        let commentKey = PendingCommentKey(postID: postID, commentID: newComment.id)
        pendingCommentCreates[commentKey] = newComment
        Task {
            do {
                if let delivery = try await backend.recordComment(newComment, on: post, by: viewer) {
                    outboundNotificationDeliveries.insert(delivery, at: 0)
                }
                if pendingCommentCreates[commentKey]?.id == newComment.id {
                    pendingCommentCreates[commentKey] = nil
                }
            } catch {
                guard pendingCommentCreates[commentKey]?.id == newComment.id else { return }
                pendingCommentCreates[commentKey] = nil
                removeLocalPendingComment(commentID: newComment.id, inPostID: postID)
                socialErrorMessage = "Couldn't post that comment."
            }
        }
    }

    func toggleCommentLike(commentID: UUID, inPostID postID: UUID) {
        guard let viewer,
              let postIndex = posts.firstIndex(where: { $0.id == postID }),
              let commentIndex = posts[postIndex].comments.firstIndex(where: { $0.id == commentID })
        else { return }

        let post = posts[postIndex]
        let comment = posts[postIndex].comments[commentIndex]
        let wasLiked = comment.isLikedByViewer
        let desiredLikeState = !wasLiked
        let likeKey = PendingCommentLikeKey(postID: postID, commentID: commentID)

        applyLocalCommentLikeState(commentID: commentID, inPostID: postID, isLiked: desiredLikeState)
        pendingCommentLikeStates[likeKey] = desiredLikeState

        Task {
            do {
                if wasLiked {
                    try await backend.removeCommentLike(comment, on: post, by: viewer)
                    try? await backend.deleteCommentLikeNotification(comment, by: viewer)
                } else if let delivery = try await backend.recordCommentLike(comment, on: post, by: viewer) {
                    outboundNotificationDeliveries.insert(delivery, at: 0)
                }
                if pendingCommentLikeStates[likeKey] == desiredLikeState {
                    pendingCommentLikeStates[likeKey] = nil
                }
            } catch {
                guard pendingCommentLikeStates[likeKey] == desiredLikeState else { return }
                pendingCommentLikeStates[likeKey] = nil
                applyLocalCommentLikeState(commentID: commentID, inPostID: postID, isLiked: wasLiked)
                socialErrorMessage = "Couldn't update that comment like."
            }
        }
    }

    func canDeleteComment(_ comment: Comment, inPostID postID: UUID) -> Bool {
        guard let viewer,
              let post = posts.first(where: { $0.id == postID })
        else { return false }

        return isViewerAdmin || comment.author.id == viewer.id || post.author.id == viewer.id
    }

    func deleteComment(commentID: UUID, inPostID postID: UUID) {
        guard let postIndex = posts.firstIndex(where: { $0.id == postID }),
              let commentIndex = posts[postIndex].comments.firstIndex(where: { $0.id == commentID }),
              let viewer
        else { return }

        let post = posts[postIndex]
        let comment = post.comments[commentIndex]
        guard canDeleteComment(comment, inPostID: postID) else { return }

        posts[postIndex].comments.remove(at: commentIndex)
        posts[postIndex].commentCount = max(posts[postIndex].commentCount - 1, 0)

        Task {
            do {
                if isViewerAdmin {
                    try await backend.deleteCommentAsAdmin(comment.id)
                } else {
                    try await backend.deleteComment(comment, on: post, by: viewer)
                }
                await backend.deleteCommentMedia(comment)
                _ = await refreshPost(id: postID)
            } catch {
                socialErrorMessage = "Couldn't delete that comment."
                // Re-insert the comment optimistically on failure so local
                // state doesn't silently diverge.
                if let postIndex = posts.firstIndex(where: { $0.id == postID }) {
                    posts[postIndex].comments.insert(comment, at: commentIndex)
                    posts[postIndex].commentCount += 1
                }
            }
        }
    }

    @discardableResult
    func ensureFullCommentsLoaded(
        for postID: UUID,
        requiring requiredCommentID: UUID? = nil,
        fallbackPost: MomentPost? = nil
    ) async -> Bool {
        if let fallbackPost, fallbackPost.id == postID {
            if let existing = posts.first(where: { $0.id == postID }) {
                let fallbackHasNewerPreview = fallbackPost.comments.count > existing.comments.count
                let fallbackHasNewerCount = fallbackPost.commentCount > existing.commentCount
                if fallbackHasNewerPreview || fallbackHasNewerCount {
                    cacheProfilePosts([fallbackPost])
                }
            } else {
                cacheProfilePosts([fallbackPost])
            }
        }

        guard let viewer,
              let postIndex = posts.firstIndex(where: { $0.id == postID })
        else { return false }

        let post = posts[postIndex]
        let isMissingRequiredComment = requiredCommentID.map { requiredCommentID in
            !post.comments.contains(where: { $0.id == requiredCommentID })
        } ?? false

        guard isMissingRequiredComment
                || !post.hasLoadedFullCommentThread
                || post.comments.count < post.commentCount
        else {
            return true
        }

        do {
            let serverComments = visibleComments(
                try await backend.loadFullComments(for: post, viewer: viewer)
            )
            let serverIDs = Set(serverComments.map(\.id))
            let optimisticTail = post.comments.filter { !serverIDs.contains($0.id) }
            let merged = applyingPendingCommentChanges(
                to: visibleComments(serverComments + optimisticTail),
                postID: postID
            )

            guard let refreshedIndex = posts.firstIndex(where: { $0.id == postID }) else { return false }
            posts[refreshedIndex].comments = merged
            posts[refreshedIndex].commentCount = merged.count
            posts[refreshedIndex].hasLoadedFullCommentThread = true
            guard let requiredCommentID else { return true }
            return merged.contains(where: { $0.id == requiredCommentID })
        } catch {
            // Leave the preview comments in place on failure.
            return false
        }
    }

    func ensurePostLoaded(id postID: UUID) async -> Bool {
        if posts.contains(where: { $0.id == postID }) { return true }
        guard let viewer else { return false }

        do {
            guard let loadedPost = try await backend.loadPost(id: postID, viewer: viewer),
                  let visible = visiblePost(loadedPost)
            else {
                removePostEverywhere(postID)
                return false
            }

            let mergedVisible = applyingPendingEngagement(to: visible)
            if let existingIndex = posts.firstIndex(where: { $0.id == mergedVisible.id }) {
                posts[existingIndex] = mergedVisible
            } else {
                posts.append(mergedVisible)
            }
            posts = sortPostsByRecency(posts)
            refreshCatalogs()
            persistFeedCache()
            return true
        } catch {
            return false
        }
    }

    /// Fetches fresh data for a post that is already in the local cache and
    /// updates it in place. Unlike `ensurePostLoaded`, this always hits the
    /// network so engagement counts (likes, comments, reactions) reflect the
    /// latest server state. Used when opening a post from a push notification
    /// to ensure the triggering event (like, comment, etc.) is visible.
    @discardableResult
    func refreshPost(id postID: UUID) async -> Bool {
        guard let viewer else { return false }
        do {
            guard let loadedPost = try await backend.loadPost(id: postID, viewer: viewer),
                  let visible = visiblePost(loadedPost)
            else {
                removePostEverywhere(postID)
                return false
            }

            let mergedVisible = applyingPendingEngagement(to: visible)
            if let existingIndex = posts.firstIndex(where: { $0.id == mergedVisible.id }) {
                posts[existingIndex] = mergedVisible
            } else {
                posts.append(mergedVisible)
            }
            posts = sortPostsByRecency(posts)
            refreshCatalogs()
            persistFeedCache()
            return true
        } catch {
            return false
        }
    }

    /// Push notifications can arrive while the app has an older copy of the
    /// post in memory. Refresh the targeted post immediately so the opened
    /// detail reflects the like/comment/tag that caused the notification.
    @discardableResult
    func refreshPostFromNotification(postID: UUID, commentID: UUID?) async -> Bool {
        let refreshedPost = await refreshPost(id: postID)
        if let commentID {
            let loadedTargetComment = await ensureFullCommentsLoaded(
                for: postID,
                requiring: commentID
            )
            return refreshedPost && loadedTargetComment
        }
        return refreshedPost
    }

    func ensureReactorsLoaded(for kind: ReactionKind, inPostID postID: UUID) async {
        guard let viewer,
              let postIndex = posts.firstIndex(where: { $0.id == postID })
        else { return }

        let post = posts[postIndex]
        guard !post.fullyLoadedReactionKinds.contains(kind) else { return }

        do {
            var reactors = visibleProfiles(
                try await backend.loadReactors(for: post, kind: kind, viewer: viewer)
            )
            let viewerProfile = viewerIdentity
            if post.viewerReactionKinds.contains(kind),
               !reactors.contains(where: { $0.id == viewerProfile.id }) {
                reactors.insert(viewerProfile, at: 0)
            }

            guard let refreshedIndex = posts.firstIndex(where: { $0.id == postID }) else { return }
            if let summaryIndex = posts[refreshedIndex].reactions.firstIndex(where: { $0.kind == kind }) {
                let preservedCount = max(posts[refreshedIndex].reactions[summaryIndex].count, reactors.count)
                posts[refreshedIndex].reactions[summaryIndex].reactors = reactors
                posts[refreshedIndex].reactions[summaryIndex].count = preservedCount
                posts[refreshedIndex].fullyLoadedReactionKinds.insert(kind)
            } else if !reactors.isEmpty {
                posts[refreshedIndex].reactions.append(
                    ReactionSummary(kind: kind, count: reactors.count, reactors: reactors)
                )
                posts[refreshedIndex].fullyLoadedReactionKinds.insert(kind)
            }
        } catch {
            // Keep the preview reactor list on failure.
        }
    }

    func resetDraft() {
        postDraft = PostDraft(
            capturedPhotoData: nil,
            selectedDrinkIDs: [],
            selectedVenueID: nil,
            location: nil,
            caption: "",
            taggedFriendIDs: [],
            isSharedMoment: false,
            sampleSymbol: "camera.aperture",
            lensMode: .back,
            isUsingSampleCapture: false
        )
    }
}

extension AppStore {
    func sortCommentsByCreatedAt(_ comments: [Comment]) -> [Comment] {
        comments.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func makeDraftCreateRequest(viewer: UserProfile, drink: DrinkTag?, venue: Venue?) -> MomentCreateRequest {
        let trimmedCaption = PostDraft.limitedCaption(
            postDraft.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        var sharedLocation = postDraft.location
        if postDraft.shareLocally, var location = sharedLocation {
            location.latitude = (location.latitude * 100).rounded() / 100
            location.longitude = (location.longitude * 100).rounded() / 100
            location.horizontalAccuracy = max(location.horizontalAccuracy, 1100)
            sharedLocation = location
        }

        return MomentCreateRequest(
            id: postDraft.id,
            shareLocally: postDraft.shareLocally,
            author: viewer,
            drink: drink,
            venue: postDraft.shareLocally ? nil : venue,
            location: sharedLocation,
            caption: trimmedCaption,
            taggedFriends: taggedFriendsForDraft,
            isSharedMoment: postDraft.isSharedMoment,
            media: {
                var m = MomentMedia(
                    photoData: postDraft.capturedPhotoData,
                    primaryHex: drink?.primaryHex ?? "#2A1815",
                    secondaryHex: drink?.secondaryHex ?? "#B86831",
                    symbol: postDraft.sampleSymbol
                )
                // Derive the aspect ratio through the same EXIF-aware path the
                // compressor uses, so the value cached client-side matches the
                // bytes that ultimately land in Storage. Using `UIImage(data:)`
                // here directly *also* respects EXIF, so the two used to
                // agree by accident — but routing both through one helper
                // makes the invariant explicit and surviveable to future
                // compressor changes.
                if let data = postDraft.capturedPhotoData,
                   let ratio = ImageCompressor.aspectRatio(of: data) {
                    m.photoAspectRatio = ratio
                }
                return m
            }()
        )
    }

    func makeOptimisticDraftPost(from request: MomentCreateRequest) -> MomentPost {
        let taggedFriends = request.taggedFriends
        let companionSummary = taggedFriends.isEmpty
            ? nil
            : "With \(taggedFriends.first?.displayName ?? "friends")\(taggedFriends.count > 1 ? " +\(taggedFriends.count - 1)" : "")"

        return MomentPost(
            id: request.id,
            author: request.author,
            drink: request.drink,
            venue: request.venue,
            location: request.location,
            caption: request.caption,
            createdAt: .now,
            taggedFriends: taggedFriends,
            isSharedMoment: request.isSharedMoment,
            media: request.media,
            reactions: [],
            comments: [],
            commentCount: 0,
            hasLoadedFullCommentThread: true,
            presenceNote: taggedFriends.isEmpty ? nil : "\(taggedFriends.first?.displayName ?? "Friends") is in the post",
            connectionPath: nil,
            contextReason: companionSummary ?? (request.venue == nil ? "Live right now" : "Just checked in"),
            isSharedLocally: request.shareLocally
        )
    }

    func makeCommentDraft(
        text: String,
        kind: CommentKind,
        photoData: Data?,
        replyTarget: Comment?
    ) -> Comment? {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackText: String = switch kind {
        case .text:
            ""
        case .photo:
            "Photo reply"
        case .gif:
            "GIF reply"
        }

        if kind == .text, trimmedText.isEmpty {
            return nil
        }

        if kind == .photo, photoData == nil {
            return nil
        }

        return Comment(
            id: UUID(),
            author: viewerIdentity,
            text: trimmedText.isEmpty ? fallbackText : trimmedText,
            createdAt: .now,
            kind: kind,
            photoData: photoData,
            replyToCommentID: replyTarget?.id,
            replyToDisplayName: replyTarget?.author.displayName
        )
    }

    func applyLocalReactionAddition(_ kind: ReactionKind, at index: Int) {
        posts[index].viewerReactionKinds.insert(kind)

        let me = viewerIdentity

        if let reactionIndex = posts[index].reactions.firstIndex(where: { $0.kind == kind }) {
            posts[index].reactions[reactionIndex].count += 1
            // Prepend the viewer so the optimistic reactor sheet shows
            // them at the top immediately. Dedup by id to protect
            // against a double-tap producing two entries before the
            // next server refresh collapses them.
            if !posts[index].reactions[reactionIndex].reactors.contains(where: { $0.id == me.id }) {
                posts[index].reactions[reactionIndex].reactors.insert(me, at: 0)
            }
        } else {
            posts[index].reactions.append(
                ReactionSummary(kind: kind, count: 1, reactors: [me])
            )
        }
    }

    func applyLocalReactionRemoval(_ kind: ReactionKind, at index: Int) {
        posts[index].viewerReactionKinds.remove(kind)

        guard let reactionIndex = posts[index].reactions.firstIndex(where: { $0.kind == kind }) else {
            return
        }

        posts[index].reactions[reactionIndex].count = max(posts[index].reactions[reactionIndex].count - 1, 0)
        posts[index].reactions[reactionIndex].reactors.removeAll { $0.id == viewerIdentity.id }

        if posts[index].reactions[reactionIndex].count == 0 {
            posts[index].reactions.remove(at: reactionIndex)
        }
    }

    func applyLocalReactionState(_ kind: ReactionKind, inPostID postID: UUID, isPresent: Bool) {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        let currentlyPresent = posts[index].viewerReactionKinds.contains(kind)
        guard currentlyPresent != isPresent else { return }

        if isPresent {
            applyLocalReactionAddition(kind, at: index)
        } else {
            applyLocalReactionRemoval(kind, at: index)
        }

        refreshCatalogs()
        persistFeedCache()
    }

    func applyLocalCommentLikeState(commentID: UUID, inPostID postID: UUID, isLiked: Bool) {
        guard let postIndex = posts.firstIndex(where: { $0.id == postID }),
              let commentIndex = posts[postIndex].comments.firstIndex(where: { $0.id == commentID })
        else { return }

        applyCommentLikeState(isLiked, to: &posts[postIndex].comments[commentIndex])
        refreshCatalogs()
        persistFeedCache()
    }

    func removeLocalPendingComment(commentID: UUID, inPostID postID: UUID) {
        guard let postIndex = posts.firstIndex(where: { $0.id == postID }),
              let commentIndex = posts[postIndex].comments.firstIndex(where: { $0.id == commentID })
        else { return }

        posts[postIndex].comments.remove(at: commentIndex)
        posts[postIndex].commentCount = max(posts[postIndex].commentCount - 1, 0)
        refreshCatalogs()
        persistFeedCache()
    }

    func applyingPendingEngagement(to post: MomentPost) -> MomentPost {
        var updated = post

        for (key, isPresent) in pendingReactionStates where key.postID == updated.id {
            applyReactionState(isPresent, kind: key.kind, to: &updated)
        }

        updated.comments = applyingPendingCommentChanges(to: updated.comments, postID: updated.id)
        updated.commentCount = max(updated.commentCount, updated.comments.count)
        return updated
    }

    func applyingPendingCommentChanges(to comments: [Comment], postID: UUID) -> [Comment] {
        var merged = comments
        var mergedIDs = Set(merged.map(\.id))

        let pendingComments = pendingCommentCreates
            .filter { $0.key.postID == postID }
            .map(\.value)
            .sorted { $0.createdAt < $1.createdAt }

        for comment in pendingComments where mergedIDs.insert(comment.id).inserted {
            merged.append(comment)
        }

        for index in merged.indices {
            let key = PendingCommentLikeKey(postID: postID, commentID: merged[index].id)
            if let isLiked = pendingCommentLikeStates[key] {
                applyCommentLikeState(isLiked, to: &merged[index])
            }
        }

        return merged
    }

    private func applyReactionState(_ isPresent: Bool, kind: ReactionKind, to post: inout MomentPost) {
        let currentlyPresent = post.viewerReactionKinds.contains(kind)
        guard currentlyPresent != isPresent else { return }

        if isPresent {
            post.viewerReactionKinds.insert(kind)
            let me = viewerIdentity
            if let reactionIndex = post.reactions.firstIndex(where: { $0.kind == kind }) {
                post.reactions[reactionIndex].count += 1
                if !post.reactions[reactionIndex].reactors.contains(where: { $0.id == me.id }) {
                    post.reactions[reactionIndex].reactors.insert(me, at: 0)
                }
            } else {
                post.reactions.append(ReactionSummary(kind: kind, count: 1, reactors: [me]))
            }
        } else {
            post.viewerReactionKinds.remove(kind)
            guard let reactionIndex = post.reactions.firstIndex(where: { $0.kind == kind }) else { return }
            post.reactions[reactionIndex].count = max(post.reactions[reactionIndex].count - 1, 0)
            post.reactions[reactionIndex].reactors.removeAll { $0.id == viewerIdentity.id }
            if post.reactions[reactionIndex].count == 0 {
                post.reactions.remove(at: reactionIndex)
            }
        }
    }

    private func applyCommentLikeState(_ isLiked: Bool, to comment: inout Comment) {
        guard comment.isLikedByViewer != isLiked else { return }
        comment.isLikedByViewer = isLiked
        if isLiked {
            comment.likeCount += 1
        } else {
            comment.likeCount = max(comment.likeCount - 1, 0)
        }
    }
}
