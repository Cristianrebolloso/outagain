import XCTest
@testable import OutAgain

@MainActor
final class RetiredReactionTests: XCTestCase {
    func testLegacyDislikesAreExcludedFromServerEngagement() throws {
        let data = Data("""
        {"post_id":"00000000-0000-0000-0000-000000000001","comment_count":0,
         "cheers_count":2,"spark_count":0,"fire_count":0,"dislike_count":7,
         "viewer_reaction_kinds":["cheers","dislike"]}
        """.utf8)
        let engagement = try JSONDecoder().decode(SupabasePostEngagementRecord.self, from: data)
        XCTAssertEqual(engagement.reactionCounts, [.cheers: 2])
        XCTAssertEqual(engagement.viewerReactionKinds, [.cheers])
    }

    func testDislikesCannotBeAddedAndLikesStillToggle() throws {
        let store = DuoLayoutFixtures.makeStore()
        let post = try XCTUnwrap(store.posts.first)
        let before = post.viewerReactionKinds
        store.addReaction(.dislike, to: post)
        XCTAssertEqual(store.posts.first?.viewerReactionKinds, before)
        store.addReaction(.cheers, to: post)
        XCTAssertEqual(store.posts.first?.viewerReactionKinds.contains(.cheers), !before.contains(.cheers))
    }
}
