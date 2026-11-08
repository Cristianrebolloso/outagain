import Foundation
import Observation

@MainActor
@Observable
final class CommentComposerDraft {
    var text = ""
    var photoData: Data?
    var photoIsGIF = false
    var replyTarget: Comment?

    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || photoData != nil || replyTarget != nil
    }
}

extension AppStore {
    func commentComposerDraft(for postID: UUID) -> CommentComposerDraft {
        if let draft = commentComposerDrafts[postID] { return draft }
        let draft = CommentComposerDraft()
        commentComposerDrafts[postID] = draft
        return draft
    }
}
