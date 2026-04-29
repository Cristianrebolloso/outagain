import Foundation

extension AppStore {
    func beginProfileEditing() {
        profileEditor = ProfileEditorDraft(profile: viewerIdentity)
        profileUsernameAvailability = .unchecked
        profileEditorMessage = nil
    }

    func refreshProfileUsernameAvailability() async {
        profileEditorMessage = nil
        let username = normalizedProfileEditorUsername

        guard !username.isEmpty else {
            profileUsernameAvailability = .unchecked
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
                    currentAvatarPath: viewer?.avatar.remoteURL.flatMap { url in
                        // Extract just the object path from the full storage URL.
                        // The path is the suffix after /object/public/<bucket>/.
                        let str = url.absoluteString
                        guard let range = str.range(of: "/object/public/[^/]+/",
                                                     options: .regularExpression) else { return nil }
                        return String(str[range.upperBound...].prefix(while: { $0 != "?" }))
                    }
                ),
                for: viewerIdentity
            )

            if let imageData = profileEditor.profileImageData {
                updatedViewer.avatar.imageData = imageData
            }

            applyProfileUpdate(updatedViewer)
            return true
        } catch {
            profileEditorMessage = "Couldn't save your profile yet."
            return false
        }
    }
}

private extension AppStore {
    func confirmAvailableProfileUsername() async -> String? {
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
        onboardingDraft.displayName = updatedViewer.displayName
        onboardingDraft.username = updatedViewer.username
        onboardingDraft.profileImageData = updatedViewer.avatar.imageData
        onboardingDraft.inviteLink = backend.createInviteLink(for: updatedViewer.username).absoluteString

        posts = posts.map { post in
            var updatedPost = post

            if updatedPost.author.id == updatedViewer.id {
                updatedPost.author = updatedViewer
            }

            updatedPost.taggedFriends = updatedPost.taggedFriends.map { friend in
                friend.id == updatedViewer.id ? updatedViewer : friend
            }

            updatedPost.comments = updatedPost.comments.map { comment in
                var updatedComment = comment
                if updatedComment.author.id == updatedViewer.id {
                    updatedComment.author = updatedViewer
                }
                return updatedComment
            }

            return updatedPost
        }

        refreshCurrentLiveActivity()
    }
}
