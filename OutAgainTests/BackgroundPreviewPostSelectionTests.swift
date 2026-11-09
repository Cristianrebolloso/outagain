import XCTest
@testable import OutAgain

@MainActor
final class BackgroundPreviewPostSelectionTests: XCTestCase {
    func testNewestAuthoredPostWinsEvenWhenFeedHasANewerFriendPost() throws {
        let store = DuoLayoutFixtures.makeStore()
        let viewer = try XCTUnwrap(store.viewer)
        let friend = try XCTUnwrap(store.friends.first)
        var olderOwn = store.posts[0]
        olderOwn.author = viewer
        olderOwn.createdAt = .now.addingTimeInterval(-300)
        var newestOwn = store.posts[1]
        newestOwn.author = viewer
        newestOwn.createdAt = .now.addingTimeInterval(-200)
        var newerFriend = store.posts[2]
        newerFriend.author = friend
        newerFriend.createdAt = .now.addingTimeInterval(-100)
        store.posts = [olderOwn, newerFriend, newestOwn]
        store.homeFeedCursorDate = newerFriend.createdAt

        XCTAssertEqual(BackgroundPreviewPostSelection.post(in: store)?.id, newestOwn.id)
    }

    func testFeedFallbackExcludesDeletedBlockedAndProfileOnlyCachedPosts() throws {
        let store = DuoLayoutFixtures.makeStore()
        let friend = store.friends[0]
        let blockedFriend = store.friends[1]
        let profileOnly = store.friends[2]
        let hiddenTag = blockedFriend
        var visible = store.posts[0]
        visible.author = friend
        visible.createdAt = .now.addingTimeInterval(-400)
        visible.taggedFriends = [hiddenTag]
        // Keep a real card even when its photo is unavailable; MomentMediaView
        // supplies the same image placeholder used in the Home feed.
        visible.media.photoData = nil
        visible.media.remotePhotoURL = nil
        var deleted = store.posts[1]
        deleted.author = friend
        deleted.createdAt = .now.addingTimeInterval(-300)
        var blocked = store.posts[2]
        blocked.author = blockedFriend
        blocked.createdAt = .now.addingTimeInterval(-200)
        var cached = store.posts[3]
        cached.author = profileOnly
        cached.createdAt = .now.addingTimeInterval(-100)
        store.friends = [friend, blockedFriend]
        store.blockedUserIDs = [blockedFriend.id]
        store.locallyDeletedPostIDs = [deleted.id]
        store.posts = [cached, blocked, deleted, visible]
        store.feedScope = .friends
        let themeBefore = store.backgroundTheme

        let chosen = try XCTUnwrap(BackgroundPreviewPostSelection.post(in: store))
        XCTAssertEqual(chosen.id, visible.id)
        XCTAssertTrue(chosen.taggedFriends.isEmpty)
        XCTAssertNil(chosen.media.photoData)
        XCTAssertNil(chosen.media.remotePhotoURL)
        XCTAssertEqual(store.backgroundTheme, themeBefore)
        XCTAssertEqual(store.posts.count, 4)
    }

    func testLocalFallbackUsesOnlyTheCurrentLocalFeedAndSortsByRecency() throws {
        let store = DuoLayoutFixtures.makeStore()
        let friend = try XCTUnwrap(store.friends.first)
        var older = store.posts[0]
        older.author = friend
        older.createdAt = .now.addingTimeInterval(-300)
        older.isSharedLocally = true
        var newer = store.posts[1]
        newer.author = friend
        newer.createdAt = .now.addingTimeInterval(-200)
        newer.isSharedLocally = true
        var outsideLocalFeed = store.posts[2]
        outsideLocalFeed.author = friend
        outsideLocalFeed.createdAt = .now.addingTimeInterval(-100)
        outsideLocalFeed.isSharedLocally = false
        store.posts = [outsideLocalFeed, older, newer]
        store.localFeedIDs = [older.id, newer.id]
        store.feedScope = .local

        XCTAssertEqual(BackgroundPreviewPostSelection.post(in: store)?.id, newer.id)
    }

    func testNoEligiblePostOrSignedInViewerUsesTonightFallback() {
        let store = DuoLayoutFixtures.makeStore()
        store.locallyDeletedPostIDs = Set(store.posts.map(\.id))
        XCTAssertNil(BackgroundPreviewPostSelection.post(in: store))
        store.locallyDeletedPostIDs = []
        store.viewer = nil
        XCTAssertNil(BackgroundPreviewPostSelection.post(in: store))
    }
}
