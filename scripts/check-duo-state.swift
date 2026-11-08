import Foundation
import CoreGraphics

@main
struct CheckDuoDiscussionState {
    @MainActor
    static func main() {
        let first = UUID(), second = UUID(), third = UUID()
        let state = FeedDiscussionState()
        state.follow(first)
        state.setDraftPresent(true, for: first)
        state.follow(second)
        precondition(state.selectedPostID == first && state.visiblePostID == second,
                     "Scrolling must not retarget an unfinished reply")
        state.resumeFollowing()
        precondition(state.selectedPostID == second && state.postsWithDrafts.contains(first),
                     "Explicitly following another post must preserve the old draft")
        state.isInteracting = true
        state.follow(third)
        precondition(state.selectedPostID == second, "Keyboard and photo-picker interactions hold the destination")
        state.didSubmit(to: second)
        state.isInteracting = false
        state.follow(first)
        precondition(state.selectedPostID == second && state.isPinned,
                     "A reply confirmation must remain attached to its original post")
        state.reconcile(postIDs: [third])
        precondition(state.selectedPostID == third && !state.isPinned,
                     "Deleting the selected post must release the old thread")
        state.select(third, focusComposer: true)
        precondition(state.focusPostID == third && state.focusRequestID == 1)
        state.follow(second)
        precondition(state.focusPostID == nil, "Scrolling to a new post must not raise its keyboard")
        state.reset()
        precondition(state.selectedPostID == nil && state.postsWithDrafts.isEmpty,
                     "Signing out must clear account-specific discussion state")
        var current: UUID? = first
        var changedDuringGesture = false
        // Continuous slow movement: no stopped-scroll event is supplied.
        for offset in stride(from: 0.0, through: 400.0, by: 2) {
            let frames = [first: CGRect(x: 0, y: -offset, width: 300, height: 600),
                          second: CGRect(x: 0, y: 620 - offset, width: 300, height: 600)]
            current = FeedVisibleItemSelection.dominantItem(frames: frames, viewportHeight: 600, current: current)
            if offset < 400 && current == second { changedDuringGesture = true }
        }
        precondition(changedDuringGesture, "Dominant selection must update during a continuous gesture")
        precondition(FeedVisibleItemSelection.dominantItem(
            frames: [first: CGRect(x: 0, y: -300, width: 300, height: 600),
                     second: CGRect(x: 0, y: 296, width: 300, height: 600)],
            viewportHeight: 600, current: first) == first, "Near ties must not flicker")
        precondition(FeedVisibleItemSelection.dominantItem(frames: [:], viewportHeight: 0, current: first) == nil)
        // An ad and its preceding post share an anchor UUID, but must remain
        // separate rows when deciding which content occupies the viewport.
        let post = FeedVisibleItem.post(first)
        let ad = FeedVisibleItem.advertisement(first)
        let nextPost = FeedVisibleItem.post(second)
        let adFrames: [FeedVisibleItem: CGRect] = [
            post: CGRect(x: 0, y: -450, width: 300, height: 600),
            ad: CGRect(x: 0, y: 172, width: 300, height: 600),
            nextPost: CGRect(x: 0, y: 794, width: 300, height: 600)
        ]
        precondition(adFrames.count == 3, "Ad identity must not overwrite its anchor post")
        precondition(FeedVisibleItemSelection.dominantItem(
            frames: adFrames, viewportHeight: 600, current: post) == ad,
            "A mostly visible ad must clear the previous post's comments")
        precondition(FeedVisibleItemSelection.dominantItem(
            frames: [post: CGRect(x: 0, y: -300, width: 300, height: 600),
                     ad: CGRect(x: 0, y: 296, width: 300, height: 600)],
            viewportHeight: 600, current: post) == post,
            "The pane must not flicker at the post/ad boundary")
        precondition(FeedVisibleItemSelection.dominantItem(
            frames: [ad: CGRect(x: 0, y: -450, width: 300, height: 600),
                     nextPost: CGRect(x: 0, y: 172, width: 300, height: 600)],
            viewportHeight: 600, current: ad) == nextPost,
            "Regular posts must restore the companion after an ad")
        state.follow(first)
        state.select(first, focusComposer: true)
        state.setDraftPresent(true, for: first)
        state.isInteracting = true
        state.followAdvertisement(after: first)
        precondition(state.isShowingAd && state.visiblePostID == nil && state.visibleItem == ad)
        precondition(state.selectedPostID == first && state.postsWithDrafts.contains(first),
                     "Hiding comments for an ad must preserve the draft and its destination")
        precondition(state.focusPostID == nil && !state.isInteracting,
                     "An invisible composer must not retain a focus request")
        state.follow(second)
        precondition(!state.isShowingAd && state.selectedPostID == first,
                     "Returning from an ad must restore an unfinished reply without retargeting it")
        state.setDraftPresent(false, for: first)
        state.follow(second)
        precondition(state.selectedPostID == second)
        state.followAdvertisement(after: first)
        state.select(second, focusComposer: true)
        precondition(!state.isShowingAd && state.focusPostID == second,
                     "An explicit Comment tap must open that post's thread")
        state.followAdvertisement(after: first)
        state.reconcile(postIDs: [second])
        precondition(!state.isShowingAd, "Removing an ad anchor must restore the companion")
        state.followAdvertisement(after: second)
        state.clearVisibleAdvertisement()
        precondition(!state.isShowingAd)
        state.followAdvertisement(after: second)
        state.reset()
        precondition(!state.isShowingAd && state.visibleItem == nil)
        print("PASS: discussion continuity, post/ad dominance, boundary stability, draft preservation, and comment restoration")
    }
}
