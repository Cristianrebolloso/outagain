import Foundation
import UIKit

extension AppStore {
    private var todayPromptDayKey: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    func openPostFlow() {
        resetDraft()
        selectedTab = .home
        isPostFlowPresented = true
    }

    func closePostFlow() {
        isPostFlowPresented = false
        resetDraft()
    }

    func applyCapturedPhoto(_ data: Data?, lensMode: CameraCaptureMode) {
        postDraft.capturedPhotoData = data
        postDraft.lensMode = lensMode
        postDraft.isUsingSampleCapture = false
    }

    func clearDraftCapture() {
        postDraft.capturedPhotoData = nil
        postDraft.isUsingSampleCapture = false
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

    /// Toggles a drink in/out of the multi-select set. Newly selected drinks are
    /// inserted at the front so the latest tap becomes the primary drink shown
    /// on the post, while older selections remain available for nightly tally UI.
    func toggleDrink(_ drink: DrinkTag) {
        if let idx = postDraft.selectedDrinkIDs.firstIndex(of: drink.id) {
            postDraft.selectedDrinkIDs.remove(at: idx)
        } else {
            postDraft.selectedDrinkIDs.insert(drink.id, at: 0)
        }
    }

    /// Convenience for callers that still want a single forced-select (e.g. Vision suggestion).
    /// Adds the drink without removing others; if already present, moves it to front as primary.
    func selectDrink(_ drink: DrinkTag) {
        if let idx = postDraft.selectedDrinkIDs.firstIndex(of: drink.id) {
            postDraft.selectedDrinkIDs.remove(at: idx)
        }
        postDraft.selectedDrinkIDs.insert(drink.id, at: 0)
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

    func publishDraft() {
        // Drink is optional for posting — fall back to first catalog drink if
        // the viewer hasn't selected one. Only the photo/sample is required.
        let drink = selectedDrinkForDraft ?? drinks.first
        guard let viewer, let drink, canPublishDraft else { return }

        let venue = selectedVenueForDraft
        let request = makeDraftCreateRequest(viewer: viewer, drink: drink, venue: venue)
        let optimisticPost = makeOptimisticDraftPost(from: request)
        let hadPostEarlierToday = viewerPosts.contains { post in
            Calendar.current.isDate(post.createdAt, inSameDayAs: optimisticPost.createdAt)
        }
        let postCountToday = viewerPosts.filter {
            Calendar.current.isDate($0.createdAt, inSameDayAs: optimisticPost.createdAt)
        }.count + 1

        posts.insert(optimisticPost, at: 0)
        handleLiveActivityAfterPublishing(
            optimisticPost,
            isFirstPostToday: !hadPostEarlierToday,
            postCountToday: postCountToday
        )

        Task {
            if var publishedPost = try? await backend.publishMoment(request),
               let index = posts.firstIndex(where: { $0.id == optimisticPost.id }) {
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
                posts[index] = publishedPost
            }

            // Capture the confirmed or optimistic post before refreshAppData
            // overwrites the posts array. The server may not have indexed the
            // new post yet (replication lag, CDN caching), so we re-insert it
            // if it doesn't appear in the bootstrap response.
            let postedPostID = posts.first(where: {
                $0.id == optimisticPost.id || $0.author.id == optimisticPost.author.id
                    && $0.createdAt >= optimisticPost.createdAt
            })?.id ?? optimisticPost.id
            let postToPreserve = posts.first(where: { $0.id == postedPostID })
            // Hold onto the local image so we can re-inject it after the
            // bootstrap wipes photoData (server records never carry it).
            let localPhotoData = optimisticPost.media.photoData

            // Delay the post-publish bootstrap slightly so the DB has time
            // to index the new row before we re-fetch. Without the delay, the
            // bootstrap often returns before the insert is visible, causing us
            // to re-insert the optimistic post unnecessarily and triggering a
            // second UI update cycle.
            try? await Task.sleep(for: .seconds(2))
            await refreshAppData(silenceErrors: true)

            // If the server response didn't include the new post yet, put it
            // back at the top so the viewer sees their own post immediately.
            if let post = postToPreserve,
               !posts.contains(where: { $0.id == post.id }) {
                posts.insert(post, at: 0)
            }

            // Re-inject the local photoData after bootstrap. applyBootstrap
            // replaces the entire posts array with server records that always
            // have photoData: nil — causing the card to collapse to the
            // gradient placeholder while AsyncImage fetches the remote URL.
            // Keeping photoData alive in-memory means the card renders
            // instantly from local data for the rest of the session.
            let localAspectRatio = optimisticPost.media.photoAspectRatio
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
        }

        selectedTab = .home
        feedScope = .friends
        ensureSelectedPresenceCluster()
        // If the Maddox easter egg is taking over the dismiss transition,
        // leave isPostFlowPresented alone — MaddoxPlayerView handles it.
        if !isMaddoxPlayerPresented {
            isPostFlowPresented = false
        }
        resetDraft()
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme == QuickPostDeepLink.quickPostURL.scheme else { return }

        let host = url.host?.lowercased()
        let path = url.path.lowercased()
        if host == "quick-post" || path == "/quick-post" {
            openPostFlow()
        }
    }

    func enableLiveActivities() {
        setLiveActivitiesEnabled(true)
    }

    func setLiveActivitiesEnabled(_ isEnabled: Bool) {
        liveActivityPreferences.isEnabled = isEnabled
        isLiveActivityPromptPresented = false

        if isEnabled {
            let payload = liveActivityTogglePayload()
            pendingLiveActivityPromptPost = nil
            startLiveActivity(with: payload)
        } else {
            pendingLiveActivityPromptPost = nil

            Task {
                await QuickPostLiveActivityManager.endAll()
            }
        }
    }

    func declineLiveActivitiesPrompt() {
        isLiveActivityPromptPresented = false
        pendingLiveActivityPromptPost = nil
    }

    private func handleLiveActivityAfterPublishing(
        _ post: MomentPost,
        isFirstPostToday: Bool,
        postCountToday: Int
    ) {
        if liveActivityPreferences.isEnabled {
            startLiveActivity(with: liveActivityPayload(for: post, postCountToday: postCountToday))
            return
        }
    }

    func refreshCurrentLiveActivity() {
        guard liveActivityPreferences.isEnabled else { return }
        guard let latestPost = viewerPosts.first else { return }

        let postCountToday = viewerPosts.filter {
            Calendar.current.isDate($0.createdAt, inSameDayAs: latestPost.createdAt)
        }.count

        startLiveActivity(with: liveActivityPayload(for: latestPost, postCountToday: max(postCountToday, 1)))
    }

    func liveActivityPayload(
        for post: MomentPost,
        postCountToday: Int
    ) -> QuickPostLiveActivityPayload {
        let headline = postCountToday == 1 ? "1 post tonight" : "\(postCountToday) posts tonight"
        let detail = "Tap here to add a post!"
        let liveAvatar = viewer?.avatar ?? post.author.avatar

        return QuickPostLiveActivityPayload(
            headline: headline,
            detail: detail,
            primaryHex: post.drink.primaryHex,
            secondaryHex: post.drink.secondaryHex,
            avatarSymbol: liveAvatar.symbol,
            avatarPrimaryHex: liveAvatar.primaryHex,
            avatarSecondaryHex: liveAvatar.secondaryHex,
            avatarImageData: liveAvatar.imageData,
            avatarRemoteURL: liveAvatar.remoteURL?.absoluteString,
            postCountToday: postCountToday,
            createdAt: post.createdAt
        )
    }

    private func liveActivityTogglePayload() -> QuickPostLiveActivityPayload {
        if let pendingLiveActivityPromptPost {
            let postCountToday = posts.filter {
                $0.author.id == pendingLiveActivityPromptPost.author.id
                    && Calendar.current.isDate($0.createdAt, inSameDayAs: pendingLiveActivityPromptPost.createdAt)
            }.count
            return liveActivityPayload(for: pendingLiveActivityPromptPost, postCountToday: max(postCountToday, 1))
        }

        if let latestPost = viewerPosts.first {
            let postCountToday = viewerPosts.filter {
                Calendar.current.isDate($0.createdAt, inSameDayAs: latestPost.createdAt)
            }.count
            return liveActivityPayload(for: latestPost, postCountToday: max(postCountToday, 1))
        }

        let avatar = viewer?.avatar ?? UserProfile.placeholderCurrentUser.avatar
        return QuickPostLiveActivityPayload(
            headline: "Ready to post",
            detail: "Tap here to add a post!",
            primaryHex: avatar.primaryHex,
            secondaryHex: avatar.secondaryHex,
            avatarSymbol: avatar.symbol,
            avatarPrimaryHex: avatar.primaryHex,
            avatarSecondaryHex: avatar.secondaryHex,
            avatarImageData: avatar.imageData,
            avatarRemoteURL: avatar.remoteURL?.absoluteString,
            postCountToday: 0,
            createdAt: .now
        )
    }

    private func startLiveActivity(with payload: QuickPostLiveActivityPayload) {
        Task {
            let didStart = await QuickPostLiveActivityManager.startOrUpdate(with: payload)
            if !didStart {
                await MainActor.run {
                    liveActivityPreferences.isEnabled = false
                    socialErrorMessage = "Couldn't start a Live Activity on this device right now."
                }
            }
        }
    }

    /// Removes one of the viewer's own posts. Optimistic: drop it from the
    /// local array immediately so the UI feels instant, then hit the
    /// backend. If the delete fails, we refetch rather than restoring the
    /// stale copy — the server's view of the post is authoritative, and
    /// partial failures (e.g. post was already deleted from another
    /// device) would be confusing to unwind by hand.
    func deletePost(_ post: MomentPost) {
        // Ownership check. This is defensive — the UI layer already hides
        // the delete affordance for other people's posts — but a double
        // check here means a future code path can't accidentally call
        // this with somebody else's post and get a silent RLS rejection.
        guard let viewer, post.author.id == viewer.id else { return }

        posts.removeAll { $0.id == post.id }

        // Immediately prune any notifications tied to this post so the
        // Activity tab doesn't show tappable rows for content that no longer
        // exists. The next bootstrap will confirm the same state from the server.
        notifications.removeAll { $0.postID == post.id }

        // If the viewer was focused on this post's cluster, clear the
        // selection so the feed doesn't leave them staring at an empty
        // detail state.
        if let selectedID = selectedPresenceClusterID,
           allPresenceClusters.first(where: { $0.id == selectedID }) == nil {
            selectedPresenceClusterID = nil
        }

        let viewerProfile = viewerIdentity
        Task {
            do {
                try await backend.deletePost(post, by: viewerProfile)
                // Local state already reflects the delete. Schedule a
                // background refresh after a short delay so friends' feeds
                // and presence clusters update, but don't block the UI.
                try? await Task.sleep(for: .seconds(2))
                await refreshAppData(silenceErrors: true)
            } catch {
                socialErrorMessage = "Couldn't delete that post."
                // Re-fetch on failure so local state matches server truth.
                await refreshAppData(silenceErrors: true)
            }
        }
    }

    func addReaction(_ kind: ReactionKind, to post: MomentPost) {
        guard let index = posts.firstIndex(where: { $0.id == post.id }) else { return }

        if posts[index].viewerReactionKinds.contains(kind) {
            applyLocalReactionRemoval(kind, at: index)

            let updatedPost = posts[index]
            let viewer = viewerIdentity

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
                // Remove the reaction row and delete the notification the
                // backend pushed to the post author when the like was added.
                try? await backend.removeReaction(kind, from: updatedPost, by: viewer)
                try? await backend.deleteReactionNotification(kind, on: updatedPost, by: viewer)
            }
            return
        }

        applyLocalReactionAddition(kind, at: index)

        let updatedPost = posts[index]
        let viewer = viewerIdentity
        Task {
            // Fire-and-forget: the optimistic addition is already applied.
            // Deliver the outbound notification banner, but skip the full
            // bootstrap — reactions are cheap local state.
            if let delivery = try? await backend.recordReaction(kind, to: updatedPost, by: viewer) {
                outboundNotificationDeliveries.insert(delivery, at: 0)
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

        posts[index].comments.insert(newComment, at: 0)
        posts[index].commentCount += 1

        let post = posts[index]
        let viewer = viewerIdentity
        Task {
            // Fire-and-forget: comment is already inserted optimistically.
            // Deliver the outbound notification banner, but skip the full
            // bootstrap — comment state is local until the next polling cycle.
            if let delivery = try? await backend.recordComment(newComment, on: post, by: viewer) {
                outboundNotificationDeliveries.insert(delivery, at: 0)
            }
        }
    }

    func toggleCommentLike(commentID: UUID, inPostID postID: UUID) {
        guard let postIndex = posts.firstIndex(where: { $0.id == postID }),
              let commentIndex = posts[postIndex].comments.firstIndex(where: { $0.id == commentID })
        else { return }

        posts[postIndex].comments[commentIndex].isLikedByViewer.toggle()
        if posts[postIndex].comments[commentIndex].isLikedByViewer {
            posts[postIndex].comments[commentIndex].likeCount += 1
        } else {
            posts[postIndex].comments[commentIndex].likeCount = max(
                posts[postIndex].comments[commentIndex].likeCount - 1,
                0
            )
        }
    }

    func canDeleteComment(_ comment: Comment, inPostID postID: UUID) -> Bool {
        guard let viewer,
              let post = posts.first(where: { $0.id == postID })
        else { return false }

        return comment.author.id == viewer.id || post.author.id == viewer.id
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
                try await backend.deleteComment(comment, on: post, by: viewer)
                // Comment is already removed from local state. No bootstrap
                // needed — the next polling cycle will confirm server truth.
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

    func ensureFullCommentsLoaded(for postID: UUID) async {
        guard let viewer,
              let postIndex = posts.firstIndex(where: { $0.id == postID })
        else { return }

        let post = posts[postIndex]
        guard !post.hasLoadedFullCommentThread || post.comments.count < post.commentCount else { return }

        do {
            let serverComments = visibleComments(
                try await backend.loadFullComments(for: post, viewer: viewer)
            )
            let serverIDs = Set(serverComments.map(\.id))
            let optimisticTail = post.comments.filter { !serverIDs.contains($0.id) }
            let merged = visibleComments(serverComments + optimisticTail)

            guard let refreshedIndex = posts.firstIndex(where: { $0.id == postID }) else { return }
            posts[refreshedIndex].comments = merged
            posts[refreshedIndex].commentCount = merged.count
            posts[refreshedIndex].hasLoadedFullCommentThread = true
        } catch {
            // Leave the preview comments in place on failure.
        }
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
                posts[refreshedIndex].reactions[summaryIndex].reactors = reactors
                posts[refreshedIndex].reactions[summaryIndex].count = reactors.count
                if posts[refreshedIndex].reactions[summaryIndex].reactors.count
                    >= posts[refreshedIndex].reactions[summaryIndex].count {
                    posts[refreshedIndex].fullyLoadedReactionKinds.insert(kind)
                }
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

private extension AppStore {
    func sortCommentsByCreatedAt(_ comments: [Comment]) -> [Comment] {
        comments.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    func makeDraftCreateRequest(viewer: UserProfile, drink: DrinkTag, venue: Venue?) -> MomentCreateRequest {
        let trimmedCaption = postDraft.caption.trimmingCharacters(in: .whitespacesAndNewlines)

        return MomentCreateRequest(
            author: viewer,
            drink: drink,
            venue: venue,
            location: postDraft.location,
            caption: trimmedCaption,
            taggedFriends: taggedFriendsForDraft,
            isSharedMoment: postDraft.isSharedMoment,
            media: {
                var m = MomentMedia(
                    photoData: postDraft.capturedPhotoData,
                    primaryHex: drink.primaryHex,
                    secondaryHex: drink.secondaryHex,
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
            id: UUID(),
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
            contextReason: companionSummary ?? (request.venue == nil ? "Live right now" : "Just checked in")
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
}
