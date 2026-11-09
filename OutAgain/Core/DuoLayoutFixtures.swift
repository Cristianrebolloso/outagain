#if DEBUG
import SwiftUI
import UIKit
import ImageIO
import AVFoundation

/// Explicit local layout testing. The throwing backend has no session and
/// cannot read or mutate production data. This file is absent from Release.
@MainActor
enum DuoLayoutFixtures {
    static var initialContinuityPostID: UUID? {
        ProcessInfo.processInfo.arguments.contains("--duo-scrolled") ? id(22) : nil
    }

    static func makeStore() -> AppStore {
        if ProcessInfo.processInfo.arguments.contains("--feed-ad-switch-checks") {
            Task {
                let ads = FeedAdStore()
                let ids = (0..<20).map { _ in UUID() }
                await ads.prepare(postIDs: ids, isLayoutPreview: true, enabled: false)
                precondition(ads.slots.isEmpty)
                await ads.prepare(postIDs: ids, isLayoutPreview: true, enabled: true)
                precondition(ads.slots.count == 3)
                precondition(ads.slots.values.allSatisfy { $0.ad == nil })
                await ads.prepare(postIDs: ids, isLayoutPreview: true, enabled: false)
                precondition(ads.slots.isEmpty)
                await ads.prepare(postIDs: ids, isLayoutPreview: true, enabled: true)
                precondition(ads.slots.count == 3)
                ads.clearFeed()
                precondition(ads.slots.isEmpty)
                FileHandle.standardError.write(Data("PASS: feed ad switch off/on/off/on, house fallback slots, session clearing\n".utf8))
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--backend-reliability-checks") {
            Task { await BackendReliabilityChecks.run() }
        }
        if ProcessInfo.processInfo.arguments.contains("--duo-camera-preview-checks") { checkCameraPreviewHosting() }
        if ProcessInfo.processInfo.arguments.contains("--duo-photo-crop-checks") { checkPhotoCrops() }
        let store = AppStore(backend: UnconfiguredBackend(environment: .placeholder))
        // Exercise the real split-pane views on an isolated wide simulator
        // when Device Hub's physical fold controls are in use by the user.
        if ProcessInfo.processInfo.arguments.contains("--duo-theme-wide-check") {
            store.isDuoDevice = true
        }
        if ProcessInfo.processInfo.arguments.contains("--launch-splash-preview") {
            // Hold the real loading view for visual review without a network session.
            store.didAttemptBootstrap = true
            return store
        }
        if ProcessInfo.processInfo.arguments.contains("--welcome-preview") ||
            ProcessInfo.processInfo.arguments.contains("--setup-preview") {
            store.didAttemptBootstrap = true
            store.bootstrapPhase = .ready
            store.onboardingStep = ProcessInfo.processInfo.arguments.contains("--setup-preview") ? .profile : .welcome
            store.authDraft.identifier = ""
            store.authDraft.password = ""
            return store
        }
        let isAnnouncementAdminPreview = ProcessInfo.processInfo.arguments.contains("--announcement-admin-preview")
        let viewer = profile(1, name: isAnnouncementAdminPreview ? "Admin Preview" : "Preview User", username: isAnnouncementAdminPreview ? "admin" : "preview")
        var friends = [profile(2, name: "Mia", username: "mia"), profile(3, name: "Ethan", username: "ethan"), profile(4, name: "Jordan", username: "jordan")]
        if ProcessInfo.processInfo.arguments.contains("--duo-theme-preview") {
            for (index, theme) in [BackgroundTheme.orange, .blue, .green].enumerated() {
                friends[index].backgroundTheme = theme
            }
            checkProfileThemeRestoration()
        }
        store.viewer = viewer
        if ProcessInfo.processInfo.arguments.contains("--white-accent-preview") { store.accentColorChoice = .white }
        store.authState = .signedIn
        store.onboardingStep = .done
        store.bootstrapPhase = .ready
        store.didAttemptBootstrap = true
        if ProcessInfo.processInfo.arguments.contains("--feed-ads-preview") ||
            ProcessInfo.processInfo.arguments.contains("--house-ads-preview") {
            store.appConfig["feed_ads_enabled"] = "true"
        }
        if ProcessInfo.processInfo.arguments.contains("--maintenance-preview") {
            store.appConfig["maintenance_mode_enabled"] = "true"
        }
        store.hasOlderHomeFeedPosts = false
        store.friends = friends
        if ProcessInfo.processInfo.arguments.contains("--duo-sheets-preview") {
            store.nightGroups = [NightGroup(
                id: id(450), name: "Friday plans", creatorID: viewer.id,
                memberIDs: [viewer.id] + friends.map(\.id), createdAt: .now
            )]
        }
        let suggestions = [
            profile(5, name: "Casey", username: "casey"),
            profile(6, name: "Alexandra", username: "alexandra_long_username"),
            profile(7, name: "Sam", username: "sam")
        ]
        store.suggestedFriends = suggestions
        store.mutualCounts = [suggestions[0].id: 2, suggestions[1].id: 12, suggestions[2].id: 1]
        if ProcessInfo.processInfo.arguments.contains("--friends-scroll-preview") {
            store.selectedTab = .friends
            store.friends = (0..<18).map { profile(600 + $0, name: "Friend \($0 + 1)", username: "friend\($0 + 1)") }
            store.suggestedFriends = (0..<18).map { profile(700 + $0, name: "Suggestion \($0 + 1)", username: "suggestion\($0 + 1)") }
        }
        let captions = ["One more stop.", "We found the spot.", "Same time next week?"]
        let colors = ["#632A85", "#234F78", "#823E56"]
        let checksContinuity = ProcessInfo.processInfo.arguments.contains("--duo-continuity")
        let hasEmptyTonight = ProcessInfo.processInfo.arguments.contains("--duo-empty-tonight")
        let postCount = (ProcessInfo.processInfo.arguments.contains("--feed-ads-preview") || ProcessInfo.processInfo.arguments.contains("--house-ads-preview")) ? 30
            : ProcessInfo.processInfo.arguments.contains("--duo-profile") ? 18 : 6
        store.posts = (0..<postCount).map { index in
            let friend = friends[index % friends.count]
            let comments = [
                Comment(id: id(100 + index * 2), author: friends[(index + 1) % 3], text: "Be there in five 🙌", createdAt: Date().addingTimeInterval(-180)),
                Comment(id: id(101 + index * 2), author: friends[(index + 2) % 3], text: "Save me a spot", createdAt: Date().addingTimeInterval(-120))
            ]
            return MomentPost(
                id: id(20 + index), author: friend, drink: store.drinks.first,
                venue: nil, caption: captions[index % 3],
                createdAt: Date().addingTimeInterval(-Double(index * 600) - (hasEmptyTonight ? 172_800 : 0)),
                taggedFriends: [], isSharedMoment: false,
                media: MomentMedia(photoData: checksContinuity ? continuityPhoto(index: index) : nil, primaryHex: colors[index % 3], secondaryHex: "#100D1C", symbol: "sparkles", photoAspectRatio: 0.8),
                reactions: [], comments: comments, commentCount: comments.count,
                hasLoadedFullCommentThread: true, presenceNote: nil,
                connectionPath: nil, contextReason: nil
            )
        }
        if ProcessInfo.processInfo.arguments.contains("--comment-photo-preview") {
            let parent = Comment(id: id(400), author: friends[1],
                                 text: "Found the photo from last night. This one deserves a spot in the group!",
                                 createdAt: .now.addingTimeInterval(-3_600))
            let photoReply = Comment(id: id(401), author: viewer, text: "", createdAt: .now,
                                     kind: .photo, photoData: continuityPhoto(index: 3, label: "PHOTO"),
                                     replyToCommentID: parent.id, replyToDisplayName: parent.author.displayName)
            store.posts[0].caption = ""
            store.posts[0].media.photoData = continuityPhoto(index: 0)
            store.posts[0].comments = [parent, photoReply]
            store.posts[0].commentCount = 2
        }
        if ProcessInfo.processInfo.arguments.contains("--post-actions-preview") {
            // Reproduce the post action footer locally.
            store.viewer?.isVerified = true
            store.posts[0].caption = ""
            store.posts[0].media.photoData = continuityPhoto(index: 0)
            store.posts[0].comments = []
            store.posts[0].commentCount = 0
            store.posts[0].reactions = [ReactionSummary(kind: .cheers, count: 3)]
        }
        // Give the remaining tabs realistic, entirely local content too.
        store.notifications = store.posts.enumerated().map { index, post in
            AppNotification(id: id(200 + index), kind: index.isMultiple(of: 2) ? .friendPost : .comment,
                            title: "\(post.author.displayName) \(index.isMultiple(of: 2) ? "just posted" : "commented on your post")",
                            detail: "Be there in five 🙌", createdAt: post.createdAt,
                            isRead: false, actor: post.author, postID: post.id,
                            commentID: index.isMultiple(of: 2) ? nil : post.comments.first?.id)
        }
        if ProcessInfo.processInfo.arguments.contains("--duo-latest-comment") {
            store.notifications[0].kind = .comment
            store.notifications[0].commentID = store.posts[0].comments[0].id
            store.notifications[0].title = "Mia commented on your post"
        }
        if ProcessInfo.processInfo.arguments.contains("--duo-latest-friend") {
            store.notifications[0].kind = .friendRequest
            store.notifications[0].postID = nil
            store.notifications[0].commentID = nil
            store.notifications[0].title = "Mia sent you a friend request"
        }
        if ProcessInfo.processInfo.arguments.contains("--notification-copy-preview") {
            store.selectedTab = .activity
            let examples: [(NotificationKind, String, String)] = [
                (.nightRecap, "Last night's photos are ready", "3 photos to look back on."),
                (.comment, "Mia commented on your post", "Be there in five 🙌"),
                (.friendRequest, "Mia sent you a friend request", "Add them to see their posts."),
                (.commentLike, "Mia liked your comment", "Photo reply"),
                (.groupAdded, "Mia added you to a group", "One shared feed for tonight."),
                (.announcement, "Friday plans", "Meet us at eight. This full message opens when you tap the notification.")
            ]
            store.notifications = examples.enumerated().map { index, example in
                AppNotification(id: id(300 + index), kind: example.0, title: example.1, detail: example.2,
                                createdAt: .now.addingTimeInterval(-Double(index * 300)), isRead: false,
                                actor: [.nightRecap, .announcement].contains(example.0) ? nil : friends[0],
                                postID: [.comment, .commentLike].contains(example.0) ? store.posts[0].id : nil,
                                commentID: [.comment, .commentLike].contains(example.0) ? store.posts[0].comments[0].id : nil,
                                nightStart: example.0 == .nightRecap ? Date().addingTimeInterval(-86400) : nil,
                                nightEnd: example.0 == .nightRecap ? Date() : nil)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--activity-motion-preview") {
            store.selectedTab = .activity
            for index in store.posts.indices {
                store.posts[index].author.isVerified = true
                store.posts[index].media.photoData = continuityPhoto(index: index)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--activity-scroll-preview") {
            store.selectedTab = .activity
            let now = Date()
            store.notifications = (0..<24).map { index in
                let post = store.posts[index % store.posts.count]
                let daysAgo = [0, 1, 4, 40][index / 6]
                let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: now)!
                    .addingTimeInterval(-Double(index % 6) * 600)
                return AppNotification(
                    id: id(500 + index), kind: .friendPost,
                    title: "\(post.author.displayName) just posted", detail: "",
                    createdAt: date, isRead: false, actor: post.author, postID: post.id
                )
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--notification-dates-preview") {
            store.selectedTab = .activity
            let iso = ISO8601DateFormatter()
            let recent = AppStore.lastCompletedNightWindow(reference: .now)!
            store.notifications = [
                AppNotification(id: id(350), kind: .nightRecap, title: "Last night's photos are ready", detail: "", createdAt: .now.addingTimeInterval(-90), isRead: false, nightStart: recent.start, nightEnd: recent.end),
                AppNotification(id: id(351), kind: .nightRecap, title: "Last night's photos are ready", detail: "", createdAt: iso.date(from: "2026-11-01T19:00:00Z")!, isRead: true, nightStart: iso.date(from: "2026-10-31T12:00:00Z")!, nightEnd: iso.date(from: "2026-11-01T13:00:00Z")!),
                AppNotification(id: id(352), kind: .friendPost, title: "Mia just posted", detail: "", createdAt: iso.date(from: "2026-11-01T02:47:00Z")!, isRead: true, actor: friends[0], postID: store.posts[0].id)
            ]
        }
        if ProcessInfo.processInfo.arguments.contains("--duo-profile") {
            for index in store.posts.indices { store.posts[index].author = viewer }
            store.selectedTab = .profile
        }
        if ProcessInfo.processInfo.arguments.contains("--duo-activity") { store.selectedTab = .activity }
        if isAnnouncementAdminPreview { store.selectedTab = .activity }
        if ProcessInfo.processInfo.arguments.contains("--duo-friends") { store.selectedTab = .friends }
        if ProcessInfo.processInfo.arguments.contains("--duo-theme-preview"),
           !ProcessInfo.processInfo.arguments.contains("--duo-theme-cycle") {
            if store.selectedTab != .friends {
                store.homeProfile = friends[0]
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--duo-camera") ||
           ProcessInfo.processInfo.arguments.contains("--post-transition-preview") {
            store.openPostFlow()
        }
        if ProcessInfo.processInfo.arguments.contains("--post-draft-checks") {
            checkQuickPostDraft(store: store, friend: friends[0])
        }
        if ProcessInfo.processInfo.arguments.contains("--duo-review") {
            store.openPostFlow()
            store.sharedCamera.capturedPhotoData = reviewPhoto()
        }
        if ProcessInfo.processInfo.arguments.contains("--composer-preview") {
            store.openPostFlow()
            store.postDraft.capturedPhotoData = reviewPhoto()
            if let drink = store.drinks.first(where: { $0.name == "Margarita" }) ?? store.drinks.first {
                store.postDraft.selectedDrinkIDs = [drink.id]
            }
            store.postDraft.taggedFriendIDs = [friends[0].id]
            store.postDraft.shareLocally = ProcessInfo.processInfo.arguments.contains("--composer-local")
            store.postDraft.location = LocationSnapshot(latitude: 30.12, longitude: -97.12, horizontalAccuracy: 10, capturedAt: .now)
        }
        if ProcessInfo.processInfo.arguments.contains("--post-local-no-location") {
            store.postDraft.shareLocally = true
            store.postDraft.location = nil
        }
        if ProcessInfo.processInfo.arguments.contains("--local-feed-preview") {
            for index in store.posts.indices {
                store.posts[index].author = suggestions[index % suggestions.count]
                store.posts[index].isSharedLocally = true
                store.posts[index].media.photoData = continuityPhoto(index: index)
            }
            store.localFeedIDs = store.posts.map(\.id)
            store.feedScope = .local
        }
        if ProcessInfo.processInfo.arguments.contains("--local-friend-preview") {
            store.posts[0].author = friends[0]
            store.posts[0].isSharedLocally = true
            store.localFeedIDs = [store.posts[0].id]
        }
        if ProcessInfo.processInfo.arguments.contains("--local-profile-preview") {
            store.profileOverlayRoute = .userProfile(suggestions[0])
        }
        if ProcessInfo.processInfo.arguments.contains("--night-recap-preview"), var window = AppStore.lastCompletedNightWindow(reference: .now) {
            let isHistory = ProcessInfo.processInfo.arguments.contains("--night-recap-history")
            if isHistory {
                let iso = ISO8601DateFormatter()
                window = AppStore.NightSummaryWindow(start: iso.date(from: "2026-10-31T12:00:00Z")!, end: iso.date(from: "2026-11-01T13:00:00Z")!)
            }
            if ProcessInfo.processInfo.arguments.contains("--night-recap-single") {
                store.posts = Array(store.posts.prefix(1))
                store.posts[0].taggedFriends = [viewer]
            } else if ProcessInfo.processInfo.arguments.contains("--night-recap-three") {
                store.posts = Array(store.posts.prefix(3))
            }
            let photoSizes = [CGSize(width: 1_200, height: 800), CGSize(width: 800, height: 1_000), CGSize(width: 800, height: 800)]
            for index in store.posts.indices {
                store.posts[index].createdAt = window.start.addingTimeInterval(Double(14 * 3600 + (store.posts.count - index - 1) * 600))
                let size = photoSizes[index % photoSizes.count]
                store.posts[index].media.photoData = continuityPhoto(index: index, size: size)
                store.posts[index].media.photoAspectRatio = size.width / size.height
            }
            precondition(store.viewerPosts.isEmpty)
            if !isHistory { precondition(store.lastNightActivitySummary != nil, "Friends' photos must create a recap for a nonposter") }
            store.notificationDestination = .recap(NightRecapRoute(start: window.start, end: window.end))
        }
        if ProcessInfo.processInfo.arguments.contains("--discovery-checks") {
            let originalPosts = store.posts
            checkLocalAvailability(store: store, stranger: suggestions[0])
            store.posts[0].author = suggestions[0]
            store.posts[0].isSharedLocally = true
            store.localFeedIDs = [store.posts[0].id]
            store.feedScope = .local
            precondition(store.homeFeedPosts.map(\.id) == store.localFeedIDs)
            store.feedScope = .friends
            precondition(!store.homeFeedPosts.contains { $0.author.id == suggestions[0].id })
            store.posts = originalPosts
            store.localFeedIDs = []
            precondition(!store.postDraft.shareLocally)
            store.postDraft.isUsingSampleCapture = true
            precondition(store.canPublishDraft)
            store.postDraft.shareLocally = true
            store.postDraft.location = nil
            precondition(!store.canPublishDraft, "Local cannot publish without location")
            store.postDraft = PostDraft()
            let postID = UUID(), commentID = UUID()
            let target = OutAgainAppDelegate.notificationTarget(from: ["outagain": ["postId": postID.uuidString, "commentId": commentID.uuidString]])
            precondition(target.postID == postID && target.commentID == commentID)
            let recapTarget = OutAgainAppDelegate.notificationTarget(from: ["outagain": ["kind": "nightRecap", "nightStart": "2026-10-26T12:00:00.000Z", "nightEnd": "2026-10-27T12:00:00+00:00"]])
            precondition(recapTarget.recap != nil, "APNs recap dates must accept both timestamp formats")
            FileHandle.standardError.write(Data("PASS: Friends/Local isolation, Local location requirement, default audience and APNs post/comment/recap routing\n".utf8))
        }
        if ProcessInfo.processInfo.arguments.contains("--background-transition-preview") {
            store.bootstrapPhase = .pending
            Task { @MainActor [weak store] in
                try? await Task.sleep(for: .seconds(5))
                store?.bootstrapPhase = .ready
            }
        }
        return store
    }

    private static func checkQuickPostDraft(store: AppStore, friend: UserProfile) {
        guard let viewer = store.viewer else { preconditionFailure("Missing preview viewer") }
        let savedDraft = store.postDraft
        defer { store.postDraft = savedDraft }
        let photo = reviewPhoto()
        store.resetDraft()
        precondition(!store.canPublishDraft)
        store.applyCapturedPhoto(photo, lensMode: .back)
        precondition(store.canPublishDraft, "A photo must be enough to post immediately")
        let quickPost = store.makeDraftCreateRequest(viewer: viewer, drink: nil, venue: nil)
        precondition(quickPost.media.photoData == photo && quickPost.drink == nil)
        precondition(quickPost.caption.isEmpty && quickPost.taggedFriends.isEmpty && !quickPost.shareLocally)

        store.postDraft.caption = "One more stop."
        store.postDraft.taggedFriendIDs = [friend.id]
        store.postDraft.selectedDrinkIDs = store.drinks.first.map { [$0.id] } ?? []
        store.postDraft.shareLocally = true
        store.postDraft.location = LocationSnapshot(latitude: 30.1234, longitude: -97.1234, horizontalAccuracy: 10, capturedAt: .now)
        let details = store.postDraft
        store.clearDraftCapture(preservingDetails: true)
        precondition(!store.canPublishDraft, "Retake must invalidate the previous photo")
        precondition(store.postDraft.caption == details.caption && store.postDraft.taggedFriendIDs == details.taggedFriendIDs)
        precondition(store.postDraft.selectedDrinkIDs == details.selectedDrinkIDs && store.postDraft.shareLocally)
        store.applyCapturedPhoto(photo, lensMode: .front)
        precondition(store.canPublishDraft && store.postDraft.lensMode == .front)
        let localPost = store.makeDraftCreateRequest(viewer: viewer, drink: store.selectedDrinkForDraft, venue: store.venues.first)
        precondition(localPost.shareLocally && localPost.venue == nil)
        precondition(localPost.caption == details.caption && localPost.taggedFriends.map(\.id) == [friend.id])
        precondition(localPost.location?.latitude == 30.12 && localPost.location?.longitude == -97.12)
        store.postDraft.location = nil
        precondition(!store.canPublishDraft, "Local must still require location")
        store.postDraft.shareLocally = false
        precondition(store.canPublishDraft, "Turning Local off must restore instant Friends posting")
        store.resetDraft()
        precondition(!store.postDraft.shareLocally && store.postDraft.taggedFriendIDs.isEmpty && store.postDraft.caption.isEmpty)
        FileHandle.standardError.write(Data("PASS: photo-only Friends post, optional details payload, Retake preservation, Local opt-in/location/privacy, and fresh-draft reset\n".utf8))
    }

    private static func checkLocalAvailability(store: AppStore, stranger: UserProfile) {
        let originalPosts = store.posts
        let originalIDs = store.localFeedIDs
        let originalScope = store.feedScope
        defer {
            store.posts = originalPosts
            store.localFeedIDs = originalIDs
            store.feedScope = originalScope
        }
        let postID = store.posts[0].id
        let authorID = store.posts[0].author.id
        store.localFeedIDs = []
        precondition(!store.hasLocalFeedPosts, "Friends' posts alone must not enable Local")
        store.localFeedIDs = [postID]
        store.posts[0].isSharedLocally = false
        precondition(!store.hasLocalFeedPosts, "A friends-only post cannot enable Local")
        store.posts[0].isSharedLocally = true
        precondition(store.hasLocalFeedPosts, "A qualifying friend's post must enable the picker")
        store.feedScope = .friends
        precondition(store.homeFeedPosts.contains { $0.id == postID }, "Local sharing must preserve the Friends feed")
        store.feedScope = .local
        precondition(store.homeFeedPosts.map(\.id) == [postID], "A nearby friend's Local post must be in both feeds")
        store.posts[0].author = stranger
        precondition(store.hasLocalFeedPosts)
        precondition(!store.canViewPrivateProfileContent(of: stranger),
                     "Viewing a Local post must not unlock the author's private profile")
        store.feedScope = .friends
        precondition(!store.homeFeedPosts.contains { $0.id == postID }, "Local strangers must stay out of Friends")
        store.posts = originalPosts
        store.posts[0].isSharedLocally = true
        store.blockedUserIDs.insert(authorID)
        precondition(!store.hasLocalFeedPosts, "Blocked accounts cannot enable Local")
        store.blockedUserIDs.remove(authorID)
        store.locallyDeletedPostIDs.insert(postID)
        precondition(!store.hasLocalFeedPosts, "Deleted posts cannot enable Local")
        store.locallyDeletedPostIDs.remove(postID)
        store.posts[0].createdAt = .now.addingTimeInterval(-49 * 3600)
        precondition(!store.hasLocalFeedPosts, "Expired posts cannot keep the picker visible")
        store.posts[0].createdAt = .now.addingTimeInterval(3600)
        precondition(!store.hasLocalFeedPosts, "Future posts cannot enable Local")
        store.feedScope = .local
        store.reconcileLocalFeedAvailability()
        precondition(store.feedScope == .friends && store.localFeedIDs.isEmpty,
                     "Losing the last eligible Local post must restore Friends")
        store.localFeedIDs = [UUID()]
        precondition(!store.hasLocalFeedPosts, "Unloaded IDs must not enable an empty Local feed")
        store.clearLocalFeed()
        precondition(!store.hasLocalFeedPosts && store.feedScope == .friends)
        FileHandle.standardError.write(Data("PASS: Local picker eligibility, nearby friend in both feeds, stranger isolation, blocked/deleted/expired/future/missing posts, and empty Local fallback\n".utf8))
    }

    /// Nested presentation and tab isolation are easy to regress with a single
    /// global override. Exercise a late fetch and out-of-order dismissal too.
    private static func checkProfileThemeRestoration() {
        let themes = ProfileSceneThemes()
        let parent = UUID(), nested = UUID(), otherTab = UUID()
        themes.show(parent, theme: .orange, tab: .home)
        themes.show(nested, theme: .blue, tab: .home)
        themes.show(otherTab, theme: .green, tab: .friends)
        themes.show(parent, theme: .pink, tab: .home)
        precondition(themes.theme(for: .home) == .blue, "Late profile fetch replaced the top profile")
        precondition(themes.theme(for: .friends) == .green, "A profile leaked into another tab")
        themes.remove(nested)
        precondition(themes.theme(for: .home) == .pink, "Back did not restore the previous profile")
        themes.show(nested, theme: .blue, tab: .home)
        themes.remove(parent)
        precondition(themes.theme(for: .home) == .blue, "Old profile teardown cleared the current profile")
        themes.remove(nested)
        precondition(themes.theme(for: .home) == nil, "Closing the last profile did not restore the viewer's theme")
        precondition(themes.theme(for: .friends) == .green)
        FileHandle.standardError.write(Data("PASS: profile themes restore after nested navigation, late updates, tab switches, and stale teardown\n".utf8))
    }

    /// Drive the real views in a separate local simulator without sending
    /// taps or changing the Device Hub window the user is working in.
    static func checkProfileThemeFlow(store: AppStore, themes: ProfileSceneThemes) async {
        let savedTheme = store.backgroundTheme
        do {
            try await Task.sleep(for: .seconds(2))
            store.homeProfile = store.friends[0]
            try await Task.sleep(for: .milliseconds(500))
            precondition(themes.theme(for: .home) == .orange, "Home did not adopt the friend's theme")
            try await Task.sleep(for: .seconds(2))
            store.homeProfile = store.friends[1]
            try await Task.sleep(for: .milliseconds(500))
            precondition(themes.theme(for: .home) == .blue, "Switching friends kept the previous theme")
            try await Task.sleep(for: .seconds(2))
            store.homeProfile = nil
            try await Task.sleep(for: .milliseconds(500))
            precondition(themes.theme(for: .home) == nil, "Home's retained outgoing view kept its theme")
            precondition(store.backgroundTheme == savedTheme, "Viewing a friend changed the saved theme")
            try await Task.sleep(for: .seconds(2))
            store.selectedTab = .friends
            try await Task.sleep(for: .milliseconds(500))
            store.friendsTabPendingProfile = store.friends[0]
            try await Task.sleep(for: .seconds(1))
            precondition(themes.theme(for: .friends) == .orange, "People did not adopt the profile theme")
            store.selectedTab = .home
            try await Task.sleep(for: .milliseconds(500))
            precondition(themes.theme(for: .home) == nil, "An inactive tab's profile theme leaked into Home")
            let result = "PASS: rendered Home and People profiles adopt their themes, switch, close, and restore the saved theme\n"
            FileHandle.standardError.write(Data(result.utf8))
            try result.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("profile-theme-checks.txt"), atomically: true, encoding: .utf8)
        } catch {
            // Cancelling this explicit preview run must not affect the next run.
        }
    }

    static func configureThemePreviewScene(store: AppStore) async {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--duo-theme-wide-check") {
            try? await Task.sleep(for: .milliseconds(500))
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            scene?.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            scene?.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeLeft)) { error in
                FileHandle.standardError.write(Data("Theme preview orientation: \(error)\n".utf8))
            }
        }
        if arguments.contains("--duo-theme-preview"),
           !arguments.contains("--duo-theme-cycle"), store.selectedTab == .friends {
            try? await Task.sleep(for: .milliseconds(500))
            store.friendsTabPendingProfile = store.friends[0]
        }
    }

    /// No camera hardware is needed to reproduce the old-host teardown that
    /// happens when SwiftUI moves a live preview between portrait/tabletop views.
    private static func checkCameraPreviewHosting() {
        let camera = CameraPipeline()
        let session = CameraPipeline.makeCaptureSession(supportsSubjectPreview: true)
        precondition(!(session is AVCaptureMultiCamSession), "A second display must not require a MultiCam session")
        let main = camera.primaryPreviewLayer
        let subject = camera.subjectPreview.displayLayer
        precondition((main as CALayer) !== subject)
        main.setSessionWithNoConnection(session)

        precondition(main.session === session, "The main camera session was detached")
        precondition(!(CameraPipeline.makeCaptureSession(supportsSubjectPreview: false) is AVCaptureMultiCamSession))

        let originalMainHost = PreviewContainerView(previewLayer: main)
        let outsideHost = CameraSubjectPreviewContainer(displayLayer: subject)
        let rotatedMainHost = PreviewContainerView(previewLayer: main)
        originalMainHost.detachPreview()
        precondition(main.superlayer === rotatedMainHost.layer, "Old main view detached the replacement preview")
        precondition(subject.superlayer === outsideHost.layer, "Main layout change disturbed the subject preview")

        outsideHost.detachPreview()
        precondition(main.superlayer === rotatedMainHost.layer, "Closing subject preview disturbed the main preview")
        precondition(main.session === session, "Closing subject preview rebuilt the main camera connection")
        let reopenedOutsideHost = CameraSubjectPreviewContainer(displayLayer: subject)
        outsideHost.detachPreview()
        precondition(subject.superlayer === reopenedOutsideHost.layer, "Old subject view detached the reopened preview")

        rotatedMainHost.bounds = CGRect(x: 0, y: 0, width: 440, height: 550)
        rotatedMainHost.layoutSubviews()
        precondition(main.frame == rotatedMainHost.bounds)
        reopenedOutsideHost.bounds = CGRect(x: 0, y: 0, width: 466, height: 678)
        reopenedOutsideHost.layoutSubviews()
        precondition(subject.frame == reopenedOutsideHost.bounds)
        precondition(main.session === session)
        FileHandle.standardError.write(Data("PASS: independent camera layers survive rotation, outside-preview close/reopen, and stale host teardown without reconnecting the session\n".utf8))
    }

    /// Exercise the actual video renderer with local frames. Enabling Preview
    /// must show the newest cached frame even before another camera frame arrives.
    static func checkSubjectFrames(_ renderer: CameraSubjectFrameRenderer) async {
        func send(_ color: UIColor) async {
            let image = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            }
            let frame = sampleBuffer(image.cgImage!)
            await withCheckedContinuation { continuation in
                renderer.queue.async {
                    renderer.consume(frame.sample)
                    continuation.resume()
                }
            }
        }

        func waitForColor(blue: UInt8, red: UInt8) async {
            for _ in 0..<100 {
                if let pixelBuffer = renderer.displayLayer.sampleBufferRenderer.displayedPixelBuffer() {
                    CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                    let bytes = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
                    let matches = abs(Int(bytes[0]) - Int(blue)) < 5 && abs(Int(bytes[2]) - Int(red)) < 5
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                    if matches { return }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            preconditionFailure("Subject viewfinder did not display the newest cached frame")
        }

        renderer.setEnabled(false, clearFrame: true)
        await send(.red)
        await send(.blue)
        renderer.setEnabled(true)
        await waitForColor(blue: 255, red: 0)

        renderer.setEnabled(false)
        await send(.red)
        renderer.setEnabled(true)
        await waitForColor(blue: 0, red: 255)

        renderer.setEnabled(false, clearFrame: true)
        await send(.blue)
        renderer.setEnabled(true)
        await waitForColor(blue: 255, red: 0)

        // Leave a recognizable, asymmetric frame on the exact accessory surface
        // for a visual check of aspect fill and horizontal mirroring.
        let frame = sampleBuffer(UIImage(data: cameraScene())!.cgImage!)
        await withCheckedContinuation { continuation in
            renderer.queue.async {
                renderer.consume(frame.sample)
                continuation.resume()
            }
        }
        let result = "PASS: cached latest frame, preview off/on, and clear/restart render correctly without another capture connection\n"
        FileHandle.standardError.write(Data(result.utf8))
        try? result.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("camera-frame-checks.txt"), atomically: true, encoding: .utf8)
    }

    /// An owned fixture frame is handed to the capture queue exactly once.
    private nonisolated struct TestVideoFrame: @unchecked Sendable {
        let sample: CMSampleBuffer
    }

    private static func sampleBuffer(_ image: CGImage) -> TestVideoFrame {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess)
        let pixels = pixelBuffer!
        CVPixelBufferLockBaseAddress(pixels, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: image.width,
            height: image.height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var description: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixels, formatDescriptionOut: &description) == noErr)
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixels, formatDescription: description!, sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr)
        return TestVideoFrame(sample: sample!)
    }

    private static func profile(_ value: Int, name: String, username: String) -> UserProfile {
        UserProfile(id: id(value), displayName: name, username: username,
                    avatar: AvatarStyle(symbol: "person.fill", primaryHex: "#A855F7", secondaryHex: "#1B1025"),
                    isCloseFriend: true)
    }

    /// Exercises actual encoded EXIF orientations, including all mirrored
    /// cases, through the same capture and upload compression paths as a post.
    private static func checkPhotoCrops() {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 1_200, height: 900), format: format).image { context in
            UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 900))
            UIColor.blue.setFill(); context.fill(CGRect(x: 600, y: 0, width: 600, height: 900))
        }.cgImage!
        for rawOrientation in 1...8 {
            let encoded = NSMutableData()
            let destination = CGImageDestinationCreateWithData(encoded, "public.jpeg" as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, source, [kCGImagePropertyOrientation: rawOrientation] as CFDictionary)
            precondition(CGImageDestinationFinalize(destination))
            for preview: CGSize? in [nil, CGSize(width: 669, height: 450), CGSize(width: 334, height: 850)] {
                let cropped = ImageCompressor.postCapture(from: encoded as Data, previewSize: preview)!
                let uploaded = ImageCompressor.feedDisplayWithRatio(from: cropped)
                precondition(abs((ImageCompressor.aspectRatio(of: cropped) ?? 0) - 0.8) < 0.000_001)
                precondition(abs((uploaded.aspectRatio ?? 0) - 0.8) < 0.000_001)
                precondition(UIImage(data: cropped)?.imageOrientation == .up)
            }
        }
        FileHandle.standardError.write(Data("PASS: all 8 EXIF orientations in 3 preview shapes produce upright 4:5 capture and upload bytes\n".utf8))
    }

    private static func id(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", value))!
    }

    static func cameraScene() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1_600, height: 1_200), format: format)
            .jpegData(withCompressionQuality: 0.9) { context in
                UIColor(red: 0.17, green: 0.30, blue: 0.40, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: 0, width: 1_600, height: 1_200))
                let cg = context.cgContext
                cg.setStrokeColor(UIColor.white.withAlphaComponent(0.35).cgColor)
                cg.setLineWidth(4)
                for x in stride(from: 0, through: 1_600, by: 100) {
                    cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: 1_200))
                }
                for y in stride(from: 0, through: 1_200, by: 100) {
                    cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: 1_600, y: y))
                }
                cg.strokePath()
                ("CAMERA PREVIEW" as NSString).draw(at: CGPoint(x: 420, y: 540), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 80, weight: .bold), .foregroundColor: UIColor.white
                ])
            }
    }

    static func reviewPhoto() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 800, height: 1_000)).jpegData(withCompressionQuality: 0.85) { context in
            UIColor(red: 0.28, green: 0.13, blue: 0.42, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 800, height: 1_000))
            let label = "Layout preview" as NSString
            label.draw(at: CGPoint(x: 200, y: 450), withAttributes: [.font: UIFont.preferredFont(forTextStyle: .largeTitle), .foregroundColor: UIColor.white])
        }
    }

    /// Numbered image landmarks make changes of post or crop obvious during
    /// fold testing, without fetching or modifying anyone's real photos.
    private static func continuityPhoto(index: Int, label: String? = nil, size: CGSize = CGSize(width: 800, height: 1_000)) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format)
            .jpegData(withCompressionQuality: 0.85) { context in
                UIColor(hue: CGFloat(index) / 6, saturation: 0.6, brightness: 0.42, alpha: 1).setFill()
                context.fill(CGRect(origin: .zero, size: size))
                let cg = context.cgContext
                cg.setStrokeColor(UIColor.white.withAlphaComponent(0.22).cgColor)
                cg.setLineWidth(3)
                for x in stride(from: CGFloat.zero, through: size.width, by: 100) {
                    cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: CGFloat.zero, through: size.height, by: 100) {
                    cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: size.width, y: y))
                }
                cg.strokePath()
                ((label ?? "POST \(index + 1)") as NSString).draw(at: CGPoint(x: size.width / 2 - 310, y: size.height * 0.44), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 100, weight: .bold), .foregroundColor: UIColor.white
                ])
            }
    }
}
#endif
