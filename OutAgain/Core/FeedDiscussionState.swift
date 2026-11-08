import CoreGraphics
import Foundation
import Observation

/// The ad is anchored to a real post but must have a distinct visibility ID.
enum FeedVisibleItem: Hashable, Sendable {
    case post(UUID)
    case advertisement(UUID)
}

/// Selection is independent of the feed's scroll position so an in-progress
/// reply cannot silently change its destination when the feed moves.
@MainActor
@Observable
final class FeedDiscussionState {
    var visiblePostID: UUID?
    private(set) var visibleAdAnchorID: UUID?
    var selectedPostID: UUID?
    var isPinned = false
    var isInteracting = false
    var focusRequestID = 0
    var focusPostID: UUID?
    private(set) var postsWithDrafts: Set<UUID> = []

    var isShowingAd: Bool { visibleAdAnchorID != nil }

    var visibleItem: FeedVisibleItem? {
        if let visibleAdAnchorID { return .advertisement(visibleAdAnchorID) }
        return visiblePostID.map(FeedVisibleItem.post)
    }

    var holdsCurrentThread: Bool {
        isPinned || isInteracting || selectedPostID.map(postsWithDrafts.contains) == true
    }

    func follow(_ postID: UUID) {
        visibleAdAnchorID = nil
        visiblePostID = postID
        guard !holdsCurrentThread else { return }
        if selectedPostID != postID { focusPostID = nil }
        selectedPostID = postID
    }

    func followAdvertisement(after anchorID: UUID) {
        visibleAdAnchorID = anchorID
        visiblePostID = nil
        focusPostID = nil
        isInteracting = false
        // Preserve selection, drafts, and any pinned submission confirmation.
        // The companion is hidden, not replaced with an ad's comment thread.
    }

    func clearVisibleAdvertisement() {
        visibleAdAnchorID = nil
    }

    func select(_ postID: UUID, focusComposer: Bool = false) {
        visibleAdAnchorID = nil
        selectedPostID = postID
        isPinned = false
        focusPostID = focusComposer ? postID : nil
        if focusComposer { focusRequestID += 1 }
    }

    func setDraftPresent(_ hasDraft: Bool, for postID: UUID) {
        if hasDraft { postsWithDrafts.insert(postID) } else { postsWithDrafts.remove(postID) }
    }

    func resumeFollowing() {
        isPinned = false
        isInteracting = false
        focusPostID = nil
        if let visiblePostID { selectedPostID = visiblePostID }
    }

    func didSubmit(to postID: UUID) {
        // Keep the confirmation in view when the feed has moved elsewhere.
        if visiblePostID != postID { isPinned = true }
    }

    func reconcile(postIDs: [UUID]) {
        let valid = Set(postIDs)
        if let visibleAdAnchorID, !valid.contains(visibleAdAnchorID) { self.visibleAdAnchorID = nil }
        if let visiblePostID, !valid.contains(visiblePostID) { self.visiblePostID = postIDs.first }
        if let selectedPostID, !valid.contains(selectedPostID) {
            self.selectedPostID = visiblePostID ?? postIDs.first
            isPinned = false
            isInteracting = false
        }
        if selectedPostID == nil { selectedPostID = postIDs.first }
    }

    func reset() {
        visiblePostID = nil
        visibleAdAnchorID = nil
        selectedPostID = nil
        isPinned = false
        isInteracting = false
        focusRequestID = 0
        focusPostID = nil
        postsWithDrafts.removeAll()
    }
}

/// Choose by visible area on every scroll update, with a small tie margin.
enum FeedVisibleItemSelection {
    nonisolated static func dominantItem<Item: Hashable>(
        frames: [Item: CGRect], viewportHeight: CGFloat, current: Item?
    ) -> Item? {
        guard viewportHeight.isFinite, viewportHeight > 0 else { return nil }
        let viewport = CGRect(x: 0, y: 0, width: 10_000, height: viewportHeight)
        let visible = frames.mapValues { $0.intersection(viewport).height }
            .filter { $0.value.isFinite && $0.value > 0 }
        guard let candidate = visible.max(by: { $0.value < $1.value }) else { return nil }
        if let current, let height = visible[current], candidate.value - height < 8 {
            return current
        }
        return candidate.key
    }
}
