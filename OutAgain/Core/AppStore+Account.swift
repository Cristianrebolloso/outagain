import Foundation

extension AppStore {
    func deleteCurrentAccount() async throws {
        try await backend.deleteCurrentAccount()
        finishSessionEndedLocally()
    }

    func reportPost(_ post: MomentPost) async throws {
        try await backend.submitContentReport(
            ContentReportRequest(
                target: .post,
                postID: post.id,
                commentID: nil,
                targetAuthorID: post.author.id,
                targetAuthorUsername: moderationUsername(for: post.author),
                targetExcerpt: moderationExcerpt(for: post)
            )
        )
    }

    func reportComment(_ comment: Comment, inPostID postID: UUID) async throws {
        guard posts.contains(where: { $0.id == postID }) else {
            throw SupabaseBackendError.invalidResponse
        }

        try await backend.submitContentReport(
            ContentReportRequest(
                target: .comment,
                postID: postID,
                commentID: comment.id,
                targetAuthorID: comment.author.id,
                targetAuthorUsername: moderationUsername(for: comment.author),
                targetExcerpt: moderationExcerpt(for: comment)
            )
        )
    }

    private func moderationUsername(for profile: UserProfile) -> String {
        let handle = profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !handle.isEmpty {
            return handle
        }
        return profile.displayName
    }

    private func moderationExcerpt(for post: MomentPost) -> String {
        let caption = post.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !caption.isEmpty {
            return caption
        }

        if let venueName = post.venue?.name, !venueName.isEmpty {
            return "\(post.drink.name) at \(venueName)"
        }

        return post.drink.name
    }

    private func moderationExcerpt(for comment: Comment) -> String {
        let body = comment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            return body
        }

        switch comment.kind {
        case .text:
            return "(empty comment)"
        case .photo:
            return "[Photo comment]"
        case .gif:
            return "[GIF comment]"
        }
    }
}
