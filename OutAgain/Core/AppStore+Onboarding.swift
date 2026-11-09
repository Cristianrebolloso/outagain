import Foundation

extension AppStore {
    func submitAuth() {
        guard !authDraft.isSubmitting else { return }
        socialErrorMessage = nil

        // Local debug shortcut: typing `1` in both fields resolves to locally
        // configured credentials when this device has
        // OUTAGAIN_DEV_SHORTCUT_EMAIL/PASSWORD set outside the repo.
        // The call still hits the normal `POST /auth/v1/token` backend path.
        let devShortcut = DeveloperTestAccount.resolve(
            email: authDraft.identifier,
            password: authDraft.password
        )

        let resolvedIdentifier: String
        let resolvedPassword: String
        let effectiveMode: AuthEntryMode

        if let devShortcut {
            resolvedIdentifier = devShortcut.email
            resolvedPassword = devShortcut.password
            // Always attempt sign-in for the shortcut. It targets an already
            // provisioned local account, never a sign-up flow.
            effectiveMode = .signIn
        } else {
            guard let normalizedIdentifier = isSignInMode ? normalizedSignInIdentifier : normalizedOnboardingEmail else {
                socialErrorMessage = isSignInMode ? "Enter your username or email address." : SupabaseBackendError.invalidEmailAddress.errorDescription
                return
            }
            guard canSubmitAuth else {
                socialErrorMessage = SupabaseBackendError.invalidPassword.errorDescription
                return
            }
            resolvedIdentifier = normalizedIdentifier
            resolvedPassword = authPassword
            effectiveMode = authDraft.mode
        }

        authDraft.isSubmitting = true
        Task {
            defer { authDraft.isSubmitting = false }

            do {
                switch effectiveMode {
                case .signUp:
                    do {
                        try await backend.signUp(email: resolvedIdentifier, password: resolvedPassword)
                    } catch {
                        // If sign-up fails because the account already exists,
                        // silently fall through to sign-in with the same
                        // credentials — no error shown, no retying required.
                        let message = error.localizedDescription.lowercased()
                        let isAlreadyRegistered = message.contains("already registered")
                            || message.contains("already exists")
                            || message.contains("user already")
                            || message.contains("email address is already")
                        guard isAlreadyRegistered else { throw error }
                        try await backend.signIn(identifier: resolvedIdentifier, password: resolvedPassword)
                    }
                case .signIn:
                    try await backend.signIn(identifier: resolvedIdentifier, password: resolvedPassword)
                }

                if onboardingDraft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    onboardingDraft.displayName = EmailAddressRules.displaySeed(from: resolvedIdentifier)
                }

                try await finishAuthentication()
            } catch {
                socialErrorMessage = error.localizedDescription
            }
        }
    }

    func submitPasskeySignIn() {
        guard arePasskeysEnabled, !authDraft.isSubmitting else { return }
        socialErrorMessage = nil
        authDraft.isSubmitting = true
        Task {
            defer { authDraft.isSubmitting = false }
            do {
                try await backend.signInWithPasskey()
                try await finishAuthentication()
            } catch PasskeyError.cancelled {
                // Dismissing the system sheet is not a sign-in failure.
            } catch {
                socialErrorMessage = error.localizedDescription
            }
        }
    }

    func toggleAuthMode() {
        guard !authDraft.isSubmitting else { return }
        authDraft.mode = isSignInMode ? .signUp : .signIn
        authDraft.password = ""
        socialErrorMessage = nil
    }

    func refreshUsernameAvailability() async {
        socialErrorMessage = nil
        let username = normalizedOnboardingUsername

        guard !username.isEmpty else {
            usernameAvailability = .unchecked
            return
        }

        usernameAvailability = .checking

        do {
            let result = try await backend.checkUsernameAvailability(username)

            // Easter egg: if the username is available but matches a friend's
            // name, keep it available but sneak in a joke suggestion.
            let jokeSuggestion: String? = {
                switch username.lowercased() {
                case "landon": return "landonisgay"
                case "carson": return "carsonisgay"
                case "lauren": return "laurenisgay"
                default:       return nil
                }
            }()

            if let joke = jokeSuggestion, case .available(let u, _) = result {
                usernameAvailability = .available(u, jokeSuggestion: joke)
            } else {
                usernameAvailability = result
            }
        } catch {
            usernameAvailability = .failed("Couldn't check that username right now.")
        }
    }

    func continueFromProfile() {
        Task {
            await completeProfileOnboarding()
        }
    }

    func continueFromPermissions() {
        onboardingStep = .invite
        searchForFriends()
    }

    func enterApp() {
        guard viewer != nil else {
            socialErrorMessage = "Finish creating your profile before entering the app."
            return
        }

        promoteToLiveSession()
        refreshAppDataInBackground()
    }
}

private extension AppStore {
    func finishAuthentication() async throws {
        let bootstrap = try await backend.loadAppData()
        applyBootstrap(bootstrap)
        authState = .signedIn

        if let backendViewer = bootstrap.viewer,
           !backendViewer.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if onboardingDraft.inviteLink.isEmpty {
                onboardingDraft.inviteLink = backend.createInviteLink(for: backendViewer.username).absoluteString
            }
            promoteToLiveSession()
        } else {
            onboardingStep = .profile
            await refreshUsernameAvailability()
        }
        authDraft.password = ""
    }

    func completeProfileOnboarding() async {
        socialErrorMessage = nil

        if onboardingDraft.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onboardingDraft.displayName = normalizedOnboardingUsername
        }

        if normalizedOnboardingUsername.isEmpty {
            usernameAvailability = .invalid("Choose a username to keep going.")
            return
        }

        let availableUsername = await confirmAvailableOnboardingUsername()
        guard let availableUsername else { return }

        do {
            viewer = try await backend.createProfile(
                ProfileCreateRequest(
                    email: normalizedOnboardingEmail,
                    displayName: onboardingDraft.displayName,
                    username: availableUsername,
                    profileImageData: onboardingDraft.profileImageData,
                    backgroundTheme: backgroundTheme
                )
            )
        } catch {
            socialErrorMessage = "Couldn't save your profile yet."
            return
        }

        if onboardingDraft.inviteLink.isEmpty {
            onboardingDraft.inviteLink = backend.createInviteLink(for: availableUsername).absoluteString
        }

        // Get to people first. Camera/location are requested when posting or
        // using nearby features; notification opt-in sits beside invitations.
        onboardingStep = .invite
    }

    func confirmAvailableOnboardingUsername() async -> String? {
        if case .available(let username, _) = usernameAvailability, username == normalizedOnboardingUsername {
            return username
        }

        await refreshUsernameAvailability()

        guard case .available(let refreshedUsername, _) = usernameAvailability,
              refreshedUsername == normalizedOnboardingUsername
        else {
            return nil
        }

        return refreshedUsername
    }
}
