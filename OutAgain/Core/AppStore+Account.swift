import Foundation

extension AppStore {
    func registerPasskey() async throws { try await backend.registerPasskey() }
    func listPasskeys() async throws -> [AccountPasskey] { try await backend.listPasskeys() }
    func deletePasskey(id: UUID) async throws { try await backend.deletePasskey(id: id) }

    func changePassword(currentPassword: String, newPassword: String) async throws {
        try await backend.changePassword(
            currentPassword: currentPassword,
            newPassword: newPassword
        )
    }

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
                targetUserID: nil
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
                targetUserID: nil
            )
        )
    }
}
