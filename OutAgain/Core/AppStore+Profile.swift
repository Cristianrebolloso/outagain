import Foundation

extension AppStore {
    func handleBackgroundThemeChanged(_ theme: BackgroundTheme) {
        guard var updatedViewer = viewer else { return }

        updatedViewer.backgroundTheme = theme
        viewer = updatedViewer
        posts = posts.map { replacingViewerProfile(in: $0, with: updatedViewer) }
        tonightActivityPosts = tonightActivityPosts.map { replacingViewerProfile(in: $0, with: updatedViewer) }

        Task {
            do {
                try await backend.updateBackgroundTheme(theme, for: updatedViewer)
            } catch {
                // Theme sharing is nice-to-have; keep the local choice even if
                // a transient network error prevents the server sync.
            }
        }
    }

    func beginProfileEditing() {
        profileEditor = ProfileEditorDraft(profile: viewerIdentity)
        let currentUsername = viewerIdentity.normalizedUsername
        profileUsernameAvailability = currentUsername.isEmpty ? .unchecked : .available(currentUsername)
        profileEditorMessage = nil
    }

    func refreshProfileUsernameAvailability() async {
        profileEditorMessage = nil
        let username = normalizedProfileEditorUsername

        guard !username.isEmpty else {
            profileUsernameAvailability = .unchecked
            return
        }

        if username == viewerIdentity.normalizedUsername {
            profileUsernameAvailability = .available(username)
            return
        }

        profileUsernameAvailability = .checking

        do {
            profileUsernameAvailability = try await backend.checkUsernameAvailability(username)
        } catch {
            profileUsernameAvailability = .failed("Couldn't check that username right now.")
        }
    }

    func saveProfileEdits() async -> Bool {
        profileEditorMessage = nil

        let trimmedDisplayName = profileEditor.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDisplayName.isEmpty else {
            profileEditorMessage = "Add a name before saving."
            return false
        }

        guard let availableUsername = await confirmAvailableProfileUsername() else {
            return false
        }

        isSavingProfile = true
        defer { isSavingProfile = false }

        do {
            var updatedViewer = try await backend.updateProfile(
                ProfileUpdateRequest(
                    displayName: trimmedDisplayName,
                    username: availableUsername,
                    profileImageData: profileEditor.profileImageData,
                    // Pass the current avatar path so updateProfile can skip
                    // a redundant fetchCurrentProfile() call when the avatar
                    // isn't being changed. Saves one DB round-trip per save.
                    currentAvatarPath: currentAvatarPath(from: viewer?.avatar.remoteURL)
                ),
                for: viewerIdentity
            )

            if let imageData = profileEditor.profileImageData {
                updatedViewer.avatar.imageData = imageData
            }

            applyProfileUpdate(updatedViewer)
            return true
        } catch {
            profileEditorMessage = profileSaveMessage(for: error)
            return false
        }
    }

    func replacingViewerProfile(in post: MomentPost, with updatedViewer: UserProfile? = nil) -> MomentPost {
        let viewerProfile = updatedViewer ?? viewerIdentity
        var updatedPost = post

        if updatedPost.author.id == viewerProfile.id {
            updatedPost.author = viewerProfile
        }

        updatedPost.taggedFriends = updatedPost.taggedFriends.map { friend in
            friend.id == viewerProfile.id ? viewerProfile : friend
        }

        updatedPost.reactions = updatedPost.reactions.map { reaction in
            var updatedReaction = reaction
            updatedReaction.reactors = updatedReaction.reactors.map { reactor in
                reactor.id == viewerProfile.id ? viewerProfile : reactor
            }
            return updatedReaction
        }

        let viewerCommentIDs = Set(updatedPost.comments.filter { $0.author.id == viewerProfile.id }.map(\.id))
        updatedPost.comments = updatedPost.comments.map { comment in
            var updatedComment = comment
            if updatedComment.author.id == viewerProfile.id {
                updatedComment.author = viewerProfile
            }
            if let replyToCommentID = updatedComment.replyToCommentID,
               viewerCommentIDs.contains(replyToCommentID) {
                updatedComment.replyToDisplayName = viewerProfile.displayName
            }
            return updatedComment
        }

        return updatedPost
    }

}

private extension AppStore {
    func currentAvatarPath(from url: URL?) -> String? {
        guard let url else { return nil }
        let str = url.absoluteString
        guard let range = str.range(
            of: "/object/public/[^/]+/",
            options: .regularExpression
        ) else { return nil }
        return String(str[range.upperBound...].prefix(while: { $0 != "?" }))
    }

    func confirmAvailableProfileUsername() async -> String? {
        if normalizedProfileEditorUsername == viewerIdentity.normalizedUsername {
            return normalizedProfileEditorUsername
        }

        if case .available(let username, _) = profileUsernameAvailability,
           username == normalizedProfileEditorUsername {
            return username
        }

        await refreshProfileUsernameAvailability()

        guard case .available(let refreshedUsername, _) = profileUsernameAvailability,
              refreshedUsername == normalizedProfileEditorUsername
        else {
            profileEditorMessage = "Choose an available username."
            return nil
        }

        return refreshedUsername
    }

    func applyProfileUpdate(_ updatedViewer: UserProfile) {
        viewer = updatedViewer
        profileEditor = ProfileEditorDraft(profile: updatedViewer)
        onboardingDraft.displayName = updatedViewer.displayName
        onboardingDraft.username = updatedViewer.username
        onboardingDraft.profileImageData = updatedViewer.avatar.imageData
        onboardingDraft.inviteLink = backend.createInviteLink(for: updatedViewer.username).absoluteString

        posts = posts.map { replacingViewerProfile(in: $0, with: updatedViewer) }
        tonightActivityPosts = tonightActivityPosts.map { replacingViewerProfile(in: $0, with: updatedViewer) }

        refreshCurrentLiveActivity()
    }

    func profileSaveMessage(for error: Error) -> String {
        if let backendError = error as? SupabaseBackendError {
            switch backendError {
            case .requestFailed(let message, _), .transport(let message):
                if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return message
                }
            default:
                break
            }
        }

        return "Couldn't save your profile yet."
    }
}
