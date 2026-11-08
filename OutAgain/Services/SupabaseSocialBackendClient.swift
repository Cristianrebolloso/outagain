import Foundation

final class SupabaseSocialBackendClient: SocialBackendClient {
    enum SessionStorage {
        static let key = "OutAgain.supabase.session"
    }

    let environment: SupabaseEnvironment
    let urlSession: URLSession
    var authSession: SupabaseAuthSession?
    var authRefreshTask: Task<SupabaseAuthSession, Error>?
    var authSessionGeneration = 0

    init(environment: SupabaseEnvironment, urlSession: URLSession = .shared) {
        self.environment = environment
        self.urlSession = urlSession
        self.authSession = Self.loadStoredSession()
    }

    func signUp(email: String, password: String) async throws {
        guard let normalizedEmail = EmailAddressRules.normalized(email) else {
            throw SupabaseBackendError.invalidEmailAddress
        }
        guard PasswordRules.isValid(password) else {
            throw SupabaseBackendError.invalidPassword
        }

        let response: SupabaseSignUpResponse = try await sendAuth(
            path: "signup",
            body: SupabaseEmailPasswordAuthRequest(
                email: normalizedEmail,
                password: password
            )
        )

        guard let session = response.sessionIfAvailable() else {
            throw SupabaseBackendError.requestFailed(
                "Turn off Confirm email in Supabase for the free beta so sign-up can finish instantly.",
                statusCode: 400
            )
        }

        authSession = session
        persistSession(session)
    }

    func signIn(identifier: String, password: String) async throws {
        guard let identifier = SignInIdentifierRules.normalized(identifier) else {
            throw SupabaseBackendError.requestFailed("Enter your username or email address.", statusCode: 400)
        }
        guard !password.isEmpty else {
            throw SupabaseBackendError.invalidPassword
        }

        let session: SupabaseAuthSession
        if let email = EmailAddressRules.normalized(identifier) {
            session = try await sendAuth(
                path: "token",
                queryItems: [URLQueryItem(name: "grant_type", value: "password")],
                body: SupabaseEmailPasswordAuthRequest(email: email, password: password)
            )
        } else {
            // Resolve usernames on the server; never expose an email lookup to clients.
            var request = try makeRequest(
                url: environment.functionURL(name: "sign-in"),
                method: "POST",
                authenticated: false
            )
            request.httpBody = try encode(SupabaseUsernameSignInRequest(username: identifier, password: password))
            session = try decode(SupabaseAuthSession.self, from: await perform(request))
        }

        authSession = session
        persistSession(session)
    }

    func changePassword(currentPassword: String, newPassword: String) async throws {
        guard !currentPassword.isEmpty else {
            throw SupabaseBackendError.requestFailed("Enter your current password first.", statusCode: 400)
        }
        guard PasswordRules.isValid(newPassword) else {
            throw SupabaseBackendError.invalidPassword
        }

        let email = try await currentAuthEmail()

        do {
            try await signIn(identifier: email, password: currentPassword)
        } catch {
            let message = error.localizedDescription.lowercased()
            if message.contains("invalid login") || message.contains("invalid credentials") {
                throw SupabaseBackendError.requestFailed("That current password doesn't look right.", statusCode: 401)
            }
            throw error
        }

        _ = try await updateAuthUserPassword(newPassword)

        // Hosted Supabase projects can revoke sessions after password changes.
        // Refresh this device's session when possible, but don't turn a
        // successful password change into an error if the follow-up sign-in
        // hits a transient network problem.
        try? await signIn(identifier: email, password: newPassword)
    }

    func beginSignOut() -> Task<Void, Never> {
        let sessionToLogout = authSession
        clearSession()
        return Task { [weak self] in
            try? await self?.revokeCurrentDeviceSession(sessionToLogout)
        }
    }

    func loadAppData() async throws -> SocialBootstrap {
        BootstrapTrace.mark("loadAppData: fetchAppConfig start")
        let appConfig = (try? await fetchAppConfig()) ?? [:]
        BootstrapTrace.mark("loadAppData: fetchAppConfig done")
        let isMaintenanceActive = Self.isMaintenanceModeEnabled(in: appConfig)

        BootstrapTrace.mark("loadAppData: ensureAuthenticatedSession start")
        try await ensureAuthenticatedSession()
        BootstrapTrace.mark("loadAppData: ensureAuthenticatedSession done")

        BootstrapTrace.mark("loadAppData: fetchCurrentProfile start")
        guard let viewerRecord = try await fetchCurrentProfile() else {
            BootstrapTrace.mark("loadAppData: no viewer record (signed out)")
            return SocialBootstrap(
                viewer: nil,
                drinkCatalogPreferences: DrinkCatalogPreferences(),
                friends: [],
                suggestedFriends: [],
                posts: [],
                notifications: [],
                appConfig: appConfig
            )
        }
        BootstrapTrace.mark("loadAppData: fetchCurrentProfile done")

        if viewerRecord.is_banned == true {
            clearSession()
            throw SupabaseBackendError.accountBanned
        }

        if isMaintenanceActive,
           viewerRecord.hasCompletedOnboarding,
           viewerRecord.normalizedUsername != "admin" {
            BootstrapTrace.mark("loadAppData: maintenance mode active for non-admin viewer")
            return SocialBootstrap(
                viewer: makeUserProfile(from: viewerRecord, preferredImageData: nil, isCloseFriend: true),
                drinkCatalogPreferences: makeDrinkCatalogPreferences(from: viewerRecord),
                friends: [],
                suggestedFriends: [],
                posts: [],
                notifications: [],
                appConfig: appConfig
            )
        }

        // If onboarding isn't finished, return a bootstrap with only the
        // viewer shell. The app uses this signal to keep the user in the
        // onboarding flow until they pick a username.
        guard viewerRecord.hasCompletedOnboarding else {
            BootstrapTrace.mark("loadAppData: viewer in onboarding, returning shell")
            return SocialBootstrap(
                viewer: makeUserProfile(from: viewerRecord, preferredImageData: nil, isCloseFriend: true),
                drinkCatalogPreferences: makeDrinkCatalogPreferences(from: viewerRecord),
                friends: [],
                suggestedFriends: [],
                posts: [],
                notifications: [],
                appConfig: appConfig
            )
        }

        await refreshAppReviewDemoContentIfNeeded(for: viewerRecord)
        let isAdminViewer = viewerRecord.normalizedUsername == "admin"

        // Single concurrent wave: all independent fetches fire at once.
        // Previously this was 4 sequential phases; collapsing them into one
        // async-let fan-out cuts wall-clock bootstrap time by ~60% on a
        // typical cellular connection (saves 2-3 serial round-trips).
        //
        // The only true dependency is: we need friendIDs before we can pass
        // them to fetchProfilesByIDs. We resolve that by fetching friendships
        // first (fast, one small table) and then launching all remaining
        // fetches in parallel once we have the IDs.
        BootstrapTrace.mark("loadAppData: wave 1 launched (relationships, FoF, notifications)")
        async let allRelationshipsFetch = fetchAllFriendships(for: viewerRecord.id)
        async let fofIDRowsFetch = fetchFriendOfFriendIDs(for: viewerRecord.id)
        async let notificationsFetch = fetchNotifications(limit: 40)
        async let announcementRecordsFetch = fetchUnseenAppAnnouncementRecords(limit: 1)

        let (allRelationships, fofIDRows, notificationRecords, announcementRecords) = try await (
            allRelationshipsFetch,
            fofIDRowsFetch,
            notificationsFetch,
            announcementRecordsFetch
        )
        BootstrapTrace.mark("loadAppData: wave 1 returned")

        let friendIDs = Set(
            allRelationships
                .filter { $0.status == "accepted" }
                .compactMap { record -> UUID? in
                    if record.user_id == viewerRecord.id { return record.friend_id }
                    if record.friend_id == viewerRecord.id { return record.user_id }
                    return nil
                }
        )
        let incomingPending = allRelationships.filter { record in
            record.status == "pending" && record.friend_id == viewerRecord.id
        }
        let outgoingPending = allRelationships.filter { record in
            record.status == "pending" && record.user_id == viewerRecord.id
        }
        let blockedIDs = Set(
            allRelationships
                .filter { $0.status == "blocked" && $0.user_id == viewerRecord.id }
                .map(\.friend_id)
        )
        let friendOfFriendIDs = Set(fofIDRows.map(\.id))
        var mutualCounts = Dictionary(uniqueKeysWithValues: fofIDRows.map { ($0.id, $0.mutual_count) })

        // Home feed is direct friends only (plus the viewer's own posts so the
        // just-posted card stays visible), newest-first. Fetch one extra row so
        // AppStore knows whether the bottom sentinel should request another
        // page.
        let bootstrapPostLimit = AppStore.homeFeedPageSize
        var homeFeedAuthorIDs = friendIDs
        homeFeedAuthorIDs.insert(viewerRecord.id)
        BootstrapTrace.mark("loadAppData: fetching initial direct-friend feed (\(bootstrapPostLimit) posts)")
        let fetchedPostRecords: [SupabaseFeedPostRecord]
        do {
            if isAdminViewer {
                fetchedPostRecords = try await fetchVisibleFeedPosts(
                    limit: bootstrapPostLimit + 1
                )
            } else {
                let rpcPostRecords = try await fetchTonightFeed(
                    viewerID: viewerRecord.id,
                    limit: bootstrapPostLimit + 1
                )
                let returnedNonDirectAuthors = rpcPostRecords.contains { !homeFeedAuthorIDs.contains($0.author_id) }
                // Only fall back to the direct author query when the RPC has
                // returned posts from non-direct authors — a real signal that
                // the server-side function is running in a legacy/misconfigured
                // mode. The previous condition also fired when the result count
                // was ≤ bootstrapPostLimit (i.e. on almost every bootstrap for
                // small graphs), which doubled egress for no benefit.
                if returnedNonDirectAuthors {
                    BootstrapTrace.mark("loadAppData: feed RPC returned non-direct authors, falling back to author query")
                    let fallbackPostRecords = try? await fetchFeedPosts(
                        authorIDs: Array(homeFeedAuthorIDs),
                        limit: bootstrapPostLimit + 1
                    )
                    fetchedPostRecords = fallbackPostRecords
                        ?? rpcPostRecords.filter { homeFeedAuthorIDs.contains($0.author_id) }
                } else {
                    fetchedPostRecords = rpcPostRecords
                }
            }
        } catch {
            BootstrapTrace.mark("loadAppData: direct-friend feed RPC failed, falling back to author query")
            if isAdminViewer {
                fetchedPostRecords = (try? await fetchVisibleFeedPosts(
                    limit: bootstrapPostLimit + 1
                )) ?? []
            } else {
                fetchedPostRecords = (try? await fetchFeedPosts(
                    authorIDs: Array(homeFeedAuthorIDs),
                    limit: bootstrapPostLimit + 1
                )) ?? []
            }
        }
        let hasMoreHomeFeedPosts = fetchedPostRecords.count > bootstrapPostLimit
        let postRecords = Array(fetchedPostRecords.prefix(bootstrapPostLimit))
        BootstrapTrace.mark("loadAppData: direct-friend feed returned (\(postRecords.count) visible records)")

        let tonightWindow = AppStore.tonightWindow(reference: .now)
        let authoritativeWindowFetchCap = 200
        let tonightActivityPostRecords: [SupabaseFeedPostRecord]
        var tonightActivitySnapshotIsAuthoritative = false
        do {
            BootstrapTrace.mark("loadAppData: fetching full tonight activity window")
            // Cap at 200 posts to avoid unbounded egress: a social graph with
            // hundreds of active friends posting all night could otherwise
            // paginate until the table is exhausted. 200 posts covers any
            // realistic active-friend cohort for tonight's window and costs at
            // most ~80 KB instead of an unbounded multi-MB pull.
            if isAdminViewer {
                tonightActivityPostRecords = try await fetchAllVisibleFeedPosts(
                    pageSize: 100,
                    maxTotal: authoritativeWindowFetchCap,
                    createdAfter: tonightWindow.lowerBound,
                    createdBefore: tonightWindow.upperBound
                )
            } else {
                tonightActivityPostRecords = try await fetchAllFeedPosts(
                    authorIDs: Array(homeFeedAuthorIDs),
                    pageSize: 100,
                    maxTotal: authoritativeWindowFetchCap,
                    createdAfter: tonightWindow.lowerBound,
                    createdBefore: tonightWindow.upperBound
                )
            }
            tonightActivitySnapshotIsAuthoritative = tonightActivityPostRecords.count < authoritativeWindowFetchCap
        } catch {
            BootstrapTrace.mark("loadAppData: tonight activity fetch failed, falling back to feed records")
            tonightActivityPostRecords = fetchedPostRecords.filter { tonightWindow.contains($0.created_at) }
        }
        BootstrapTrace.mark("loadAppData: tonight activity returned (\(tonightActivityPostRecords.count) records)")

        let completedNightWindow = AppStore.lastCompletedNightWindow(reference: .now)
        let nightSummaryPostRecords: [SupabaseFeedPostRecord]
        let nightSummaryGroups: [NightGroup]
        var nightSummarySnapshotIsAuthoritative = false
        if let completedNightWindow {
            do {
                BootstrapTrace.mark("loadAppData: fetching completed night summary window")
                if isAdminViewer {
                    nightSummaryPostRecords = try await fetchAllVisibleFeedPosts(
                        pageSize: 100,
                        maxTotal: authoritativeWindowFetchCap,
                        createdAfter: completedNightWindow.start,
                        createdBefore: completedNightWindow.end
                    )
                } else {
                    nightSummaryPostRecords = try await fetchAllFeedPosts(
                        authorIDs: Array(homeFeedAuthorIDs),
                        pageSize: 100,
                        maxTotal: authoritativeWindowFetchCap,
                        createdAfter: completedNightWindow.start,
                        createdBefore: completedNightWindow.end
                    )
                }
                nightSummarySnapshotIsAuthoritative = nightSummaryPostRecords.count < authoritativeWindowFetchCap
            } catch {
                BootstrapTrace.mark("loadAppData: completed night summary fetch failed, falling back to feed records")
                nightSummaryPostRecords = fetchedPostRecords.filter { completedNightWindow.contains($0.created_at) }
            }
            nightSummaryGroups = ((try? await fetchNightGroups(createdAfter: completedNightWindow.start)) ?? [])
                .filter { completedNightWindow.contains($0.createdAt) }
        } else {
            nightSummaryPostRecords = []
            nightSummaryGroups = []
        }
        BootstrapTrace.mark("loadAppData: completed night summary returned (\(nightSummaryPostRecords.count) records)")

        var hydrationPostRecordsByID: [UUID: SupabaseFeedPostRecord] = [:]
        for record in postRecords + tonightActivityPostRecords + nightSummaryPostRecords {
            hydrationPostRecordsByID[record.id] = record
        }
        let hydrationPostRecords = Array(hydrationPostRecordsByID.values)

        // Second concurrent wave: now that we have friendIDs and postIDs,
        // fetch suggestions plus the lightweight engagement preview data in
        // parallel. Exact counts come from a cheap aggregate RPC, while the
        // preview comments/reactors stay capped so bootstrap egress remains low.
        BootstrapTrace.mark("loadAppData: wave 2 launched (suggestions, comments, reactions, engagement, comment likes)")
        let postIDs = hydrationPostRecords.map(\.id)
        async let suggestedProfilesFetch = fetchSuggestedProfiles(
            excluding: [viewerRecord.id] + Array(friendIDs) + Array(blockedIDs)
        )
        async let commentRecordsFetch = fetchComments(for: postIDs)
        async let reactionRecordsFetch = fetchReactions(for: postIDs)
        async let engagementRecordsFetch = fetchPostEngagement(for: postIDs)

        let (suggestedProfiles, commentRecords, reactionRecords, engagementRecords) = try await (
            suggestedProfilesFetch,
            commentRecordsFetch,
            reactionRecordsFetch,
            engagementRecordsFetch
        )
        // fetchCommentLikes depends on commentRecords.map(\.id), so it must
        // follow wave 2's comment fetch. But it has no dependency on the other
        // three wave-2 results, so it runs immediately after comments resolve
        // rather than serializing after the full wave-2 await. For large
        // comment sets this is the same latency; for small sets it's a wash.
        // The key fix is that it no longer serializes *after* wave 2 entirely.
        async let commentLikesFetch = fetchCommentLikes(for: commentRecords.map(\.id))
        let commentLikeRecords = try await commentLikesFetch
        BootstrapTrace.mark("loadAppData: wave 2 returned")

        let pendingCounterpartIDs = Set(
            incomingPending.map(\.user_id) + outgoingPending.map(\.friend_id)
        )

        let relatedProfileIDs = Set(
            [viewerRecord.id]
                + Array(friendIDs)
                + Array(blockedIDs)
                + suggestedProfiles.map(\.id)
                + hydrationPostRecords.map(\.author_id)
                + hydrationPostRecords.flatMap(\.tagged_user_ids)
                + commentRecords.map(\.author_id)
                + reactionRecords.map(\.user_id)
                + notificationRecords.compactMap(\.actor_id)
                + Array(pendingCounterpartIDs)
        )

        BootstrapTrace.mark("loadAppData: wave 3 fetchProfilesByIDs(\(relatedProfileIDs.count) IDs) start")
        let relatedProfiles = try await fetchProfilesByIDs(Array(relatedProfileIDs))
        BootstrapTrace.mark("loadAppData: wave 3 returned, building bootstrap")
        for suggestedProfile in suggestedProfiles {
            if let mutualCount = suggestedProfile.mutual_count {
                mutualCounts[suggestedProfile.id] = mutualCount
            }
        }

        var profileMap: [UUID: UserProfile] = [:]
        for profile in relatedProfiles + suggestedProfiles {
            profileMap[profile.id] = makeUserProfile(
                from: profile,
                preferredImageData: nil,
                isCloseFriend: friendIDs.contains(profile.id) || profile.id == viewerRecord.id
            )
        }

        let viewer = profileMap[viewerRecord.id]
        let friends = Array(friendIDs)
            .compactMap { profileMap[$0] }
            .sorted { $0.displayName < $1.displayName }
        // Suggested friends are sourced through a narrow RPC that returns
        // public profile fields only for friend-of-friend candidates.
        let suggestionExclusions = friendIDs
            .union(blockedIDs)
            .union(pendingCounterpartIDs)
            .union([viewerRecord.id])

        let fofProfiles = fofIDRows
            .sorted { $0.mutual_count > $1.mutual_count }
            .compactMap { profileMap[$0.id] }
            .filter { !suggestionExclusions.contains($0.id) }

        let recentSuggestionProfiles = suggestedProfiles
            .compactMap { profileMap[$0.id] }
            .filter { !suggestionExclusions.contains($0.id) }

        var seenSuggestionIDs = Set<UUID>()
        let suggestedFriends = (fofProfiles + recentSuggestionProfiles)
            .filter { seenSuggestionIDs.insert($0.id).inserted }
        let blockedUsers = Array(blockedIDs)
            .compactMap { profileMap[$0] }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        let incomingRequests = incomingPending.compactMap { record -> FriendRequest? in
            guard let counterpart = profileMap[record.user_id] else { return nil }
            return FriendRequest(
                id: record.id,
                counterpart: counterpart,
                direction: .incoming,
                createdAt: record.created_at
            )
        }
        let outgoingRequests = outgoingPending.compactMap { record -> FriendRequest? in
            guard let counterpart = profileMap[record.friend_id] else { return nil }
            return FriendRequest(
                id: record.id,
                counterpart: counterpart,
                direction: .outgoing,
                createdAt: record.created_at
            )
        }

        let posts = buildMomentPosts(
            from: postRecords,
            profileMap: profileMap,
            commentRecords: commentRecords,
            commentLikeRecords: commentLikeRecords,
            reactionRecords: reactionRecords,
            engagementRecords: engagementRecords,
            viewerID: viewerRecord.id
        )
        let tonightActivityPosts = buildMomentPosts(
            from: tonightActivityPostRecords,
            profileMap: profileMap,
            commentRecords: commentRecords,
            commentLikeRecords: commentLikeRecords,
            reactionRecords: reactionRecords,
            engagementRecords: engagementRecords,
            viewerID: viewerRecord.id
        )
        let nightSummaryPosts = buildMomentPosts(
            from: nightSummaryPostRecords,
            profileMap: profileMap,
            commentRecords: commentRecords,
            commentLikeRecords: commentLikeRecords,
            reactionRecords: reactionRecords,
            engagementRecords: engagementRecords,
            viewerID: viewerRecord.id
        )

        let sortedIncomingRequests = incomingRequests.sorted { $0.createdAt > $1.createdAt }
        let sortedOutgoingRequests = outgoingRequests.sorted { $0.createdAt > $1.createdAt }
        let sortedPosts = posts.sorted { $0.createdAt > $1.createdAt }
        let sortedTonightActivityPosts = tonightActivityPosts.sorted { $0.createdAt > $1.createdAt }
        let sortedNightSummaryPosts = nightSummaryPosts.sorted { $0.createdAt > $1.createdAt }
        let notifications = notificationRecords
            .map { makeNotification(from: $0, profileMap: profileMap) }
            .sorted { $0.createdAt > $1.createdAt }
        let appAnnouncements = announcementRecords
            .map(makeAppAnnouncement)
            .sorted { $0.createdAt > $1.createdAt }

        return SocialBootstrap(
            viewer: viewer,
            drinkCatalogPreferences: makeDrinkCatalogPreferences(from: viewerRecord),
            friends: friends,
            suggestedFriends: suggestedFriends,
            homeFeedHasMore: hasMoreHomeFeedPosts,
            friendOfFriendIDs: friendOfFriendIDs,
            mutualCounts: mutualCounts,
            incomingRequests: sortedIncomingRequests,
            outgoingRequests: sortedOutgoingRequests,
            blockedUserIDs: blockedIDs,
            blockedUsers: blockedUsers,
            posts: sortedPosts,
            tonightActivityPosts: sortedTonightActivityPosts,
            nightSummaryPosts: sortedNightSummaryPosts,
            tonightActivitySnapshotIsAuthoritative: tonightActivitySnapshotIsAuthoritative,
            nightSummarySnapshotIsAuthoritative: nightSummarySnapshotIsAuthoritative,
            nightSummaryGroups: nightSummaryGroups,
            notifications: notifications,
            appAnnouncements: appAnnouncements,
            appConfig: appConfig
        )
    }

    private func refreshAppReviewDemoContentIfNeeded(for viewerRecord: SupabaseProfileRecord) async {
        let username = viewerRecord.username?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard username == "appreview" || username == "appletest" else { return }

        do {
            BootstrapTrace.mark("loadAppData: refreshing App Review demo content")
            try await sendRestWithoutResponse(
                path: "rpc/refresh_app_review_demo_content",
                method: "POST",
                prefer: "return=minimal",
                body: SupabaseEmptyRequest()
            )
        } catch {
            // Do not block review access if an older backend has not received
            // the helper RPC yet; the account can still load its base data.
            print("[AppReviewDemo] Could not refresh demo timestamps: \(error.localizedDescription)")
        }
    }

    private static func isMaintenanceModeEnabled(in appConfig: [String: String]) -> Bool {
        let rawValue = appConfig["maintenance_mode_enabled"]
            ?? appConfig["maintenance_enabled"]
            ?? appConfig["app_unavailable"]
        let normalized = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized == "true"
            || normalized == "1"
            || normalized == "yes"
            || normalized == "on"
    }

    func checkUsernameAvailability(_ username: String) async throws -> UsernameAvailability {
        let normalized = UsernameRules.normalized(username)
        guard UsernameRules.isValid(normalized) else {
            return .invalid("Use 3-20 letters, numbers, or underscores.")
        }

        let reserved = try await fetchReservedUsernames()
        if reserved.contains(normalized) {
            return .unavailable(
                normalized,
                suggestion: UsernameRules.suggestion(for: normalized, reserved: reserved)
            )
        }

        if try await isUsernameAvailable(normalized) {
            return .available(normalized)
        } else {
            let takenUsernames = reserved.union([normalized])
            return .unavailable(
                normalized,
                suggestion: UsernameRules.suggestion(for: normalized, reserved: takenUsernames)
            )
        }
    }

    func createProfile(_ request: ProfileCreateRequest) async throws -> UserProfile {
        let normalized = UsernameRules.normalized(request.username)
        guard UsernameRules.isValid(normalized) else {
            throw SupabaseBackendError.invalidUsername
        }

        let userID = try currentUserID()
        let trimmedDisplayName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedDisplayName.isEmpty ? normalized : trimmedDisplayName
        let avatarPath = try await uploadProfileImageIfNeeded(data: request.profileImageData, userID: userID)

        // The on_auth_user_created trigger already inserted a shell row for
        // this user (id, null username, null display_name). We finish
        // onboarding by UPDATEing that row. If the trigger somehow didn't
        // fire (e.g. older project without the migration), the upsert
        // fallback below creates the row.
        let profiles: [SupabaseProfileRecord] = try await sendRest(
            path: "profiles",
            method: "POST",
            queryItems: [
                URLQueryItem(name: "on_conflict", value: "id"),
                URLQueryItem(name: "select", value: SupabaseProfileRecord.viewerSelectList)
            ],
            prefer: "resolution=merge-duplicates,return=representation",
            body: [
                SupabaseProfileRecord(
                    id: userID,
                    username: normalized,
                    display_name: displayName,
                    avatar_path: avatarPath,
                    avatar_version: nil,
                    background_theme: request.backgroundTheme.rawValue,
                    is_verified: nil,
                    custom_drinks: [],
                    deleted_drink_names: [],
                    drink_order_names: [],
                    apple_user_identifier: nil
                )
            ]
        )

        guard let profile = profiles.first else {
            throw SupabaseBackendError.invalidResponse
        }

        return makeUserProfile(
            from: profile,
            preferredImageData: request.profileImageData,
            isCloseFriend: true
        )
    }

    func updateProfile(_ request: ProfileUpdateRequest, for viewer: UserProfile) async throws -> UserProfile {
        let normalized = UsernameRules.normalized(request.username)
        guard UsernameRules.isValid(normalized) else {
            throw SupabaseBackendError.invalidUsername
        }

        let availability = try await checkUsernameAvailability(normalized)
        switch availability {
        case .available(let availableUsername, _) where availableUsername == normalized:
            break
        case .unavailable:
            throw SupabaseBackendError.requestFailed("That username is already taken.", statusCode: 409)
        case .invalid(let message), .failed(let message):
            throw SupabaseBackendError.requestFailed(message, statusCode: 400)
        case .checking, .unchecked, .available:
            throw SupabaseBackendError.invalidResponse
        }

        let userID = try currentUserID()
        let trimmedDisplayName = request.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = trimmedDisplayName.isEmpty ? normalized : trimmedDisplayName
        let previousAvatarPath = request.currentAvatarPath
        let avatarPath = try await resolveAvatarPath(
            preferredImageData: request.profileImageData,
            userID: userID,
            knownCurrentPath: request.currentAvatarPath
        )

        let queryItems = [
            URLQueryItem(name: "id", value: "eq.\(userID.uuidString.lowercased())"),
            URLQueryItem(name: "select", value: SupabaseProfileRecord.viewerSelectList)
        ]
        let updateBody = SupabaseProfileUpdateRecord(
            username: normalized,
            display_name: displayName,
            avatar_path: avatarPath
        )
        let records: [SupabaseProfileRecord]
        do {
            records = try await sendRest(
                path: "profiles",
                method: "PATCH",
                queryItems: queryItems,
                prefer: "return=representation",
                body: updateBody
            )
        } catch {
            guard let fallbackQueryItems = profileQueryItemsAfterMissingColumn(error, from: queryItems) else {
                throw error
            }
            do {
                records = try await sendRest(
                    path: "profiles",
                    method: "PATCH",
                    queryItems: fallbackQueryItems,
                    prefer: "return=representation",
                    body: updateBody
                )
            } catch {
                guard let legacyQueryItems = profileQueryItemsAfterMissingColumn(error, from: fallbackQueryItems) else {
                    throw error
                }
                records = try await sendRest(
                    path: "profiles",
                    method: "PATCH",
                    queryItems: legacyQueryItems,
                    prefer: "return=representation",
                    body: updateBody
                )
            }
        }

        guard let updatedProfile = records.first else {
            throw SupabaseBackendError.invalidResponse
        }

        var updatedViewer = makeUserProfile(
            from: updatedProfile,
            preferredImageData: request.profileImageData,
            isCloseFriend: viewer.isCloseFriend
        )
        // Older backends may fall back to a legacy profile projection without
        // background_theme. Preserve the already-known theme so editing name,
        // username, or avatar does not quietly strip the profile background.
        if updatedViewer.backgroundTheme == nil {
            updatedViewer.backgroundTheme = viewer.backgroundTheme
        }

        if let previousAvatarPath, let avatarPath, previousAvatarPath != avatarPath {
            await deleteObject(bucket: environment.avatarBucket, objectPath: previousAvatarPath)
        }

        return updatedViewer
    }

    func updateBackgroundTheme(_ theme: BackgroundTheme, for viewer: UserProfile) async throws {
        do {
            try await sendRestWithoutResponse(
                path: "profiles",
                method: "PATCH",
                queryItems: [
                    URLQueryItem(name: "id", value: "eq.\(viewer.id.uuidString.lowercased())")
                ],
                prefer: "return=minimal",
                body: SupabaseBackgroundThemeUpdateRecord(background_theme: theme.rawValue)
            )
        } catch {
            guard case SupabaseBackendError.requestFailed(let message, _) = error,
                  message.localizedCaseInsensitiveContains("background_theme")
            else {
                throw error
            }
        }
    }

    func updateDrinkCatalogPreferences(_ preferences: DrinkCatalogPreferences, for viewer: UserProfile) async throws {
        let userID = try currentUserID()
        let normalized = normalizeDrinkCatalogPreferences(preferences)

        try await sendRestWithoutResponse(
            path: "profiles",
            method: "PATCH",
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(userID.uuidString.lowercased())")
            ],
            prefer: "return=minimal",
            body: SupabaseDrinkCatalogUpdateRecord(
                custom_drinks: normalized.customDrinks,
                deleted_drink_names: normalized.deletedDrinkNames,
                drink_order_names: normalized.orderedDrinkNames
            )
        )
    }

    func createInviteLink(for username: String) -> URL {
        let slug = UUID().uuidString.prefix(8).lowercased()
        let normalized = UsernameRules.normalized(username)
        let base = environment.inviteBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/\(normalized)-\(slug)")!
    }

    func searchUsers(matching query: String, excluding viewer: UserProfile?) async throws -> [UserProfile] {
        let fragment = PeopleSearchRules.normalized(query)
        guard fragment.count >= 2 else { return [] }
        let profiles: [SupabaseProfileRecord] = try await sendRest(
            path: "rpc/search_profiles",
            method: "POST",
            body: SupabasePeopleSearchRequest(search_query: fragment)
        )
        return profiles
            .filter { $0.id != viewer?.id }
            .map { makeUserProfile(from: $0, preferredImageData: nil, isCloseFriend: false) }
    }

    func loadUserProfile(id: UUID) async throws -> UserProfile? {
        guard let record = try await fetchProfilesByIDs([id]).first else { return nil }
        return makeUserProfile(from: record, preferredImageData: nil, isCloseFriend: false)
    }

    func loadFriendCount(of profile: UserProfile, for viewer: UserProfile) async throws -> Int {
        let rows: [SupabaseProfileFriendCountResponse] = try await sendRest(
            path: "rpc/friend_count_for_profile",
            method: "POST",
            body: SupabaseProfileFriendsRequest(profile_id: profile.id)
        )

        return rows.first?.count ?? 0
    }

    func loadPostCount(of profile: UserProfile) async throws -> Int {
        let rows: [SupabaseProfileFriendCountResponse] = try await sendRest(
            path: "rpc/post_count_for_profile",
            method: "POST",
            body: SupabaseProfileFriendsRequest(profile_id: profile.id)
        )

        return rows.first?.count ?? 0
    }

    func loadFriends(of profile: UserProfile, for viewer: UserProfile) async throws -> [UserProfile] {
        let rows: [SupabaseProfileRecord] = try await sendRest(
            path: "rpc/friends_for_profile",
            method: "POST",
            body: SupabaseProfileFriendsRequest(profile_id: profile.id)
        )

        return rows
            .map { record in
                makeUserProfile(
                    from: record,
                    preferredImageData: nil,
                    isCloseFriend: record.id == viewer.id
                )
            }
            .sorted { $0.displayName < $1.displayName }
    }

    func loadUserPostsPage(
        for profile: UserProfile,
        viewer: UserProfile,
        before: Date?,
        limit: Int
    ) async throws -> UserPostsPage {
        let totalCountTask: Task<Int?, Never>? = before == nil
            ? Task { try? await countPosts(authoredBy: profile.id) }
            : nil

        let postRecords = try await fetchFeedPosts(
            authorIDs: [profile.id],
            limit: limit + 1,
            offset: 0,
            createdBefore: before
        )
        let hasMore = postRecords.count > limit
        let visibleRecords = Array(postRecords.prefix(limit))
        let posts = try await hydrateFeedPosts(
            from: visibleRecords,
            viewer: viewer,
            fallbackAuthors: [profile.id: profile]
        )
        let totalCount: Int?
        if let totalCountTask {
            totalCount = await totalCountTask.value
        } else {
            totalCount = nil
        }

        return UserPostsPage(
            posts: posts,
            totalCount: totalCount,
            hasMore: hasMore
        )
    }

    func loadTaggedPostsPage(
        for profile: UserProfile,
        viewer: UserProfile,
        before: Date?,
        limit: Int
    ) async throws -> UserPostsPage {
        let postRecords = try await fetchTaggedPostRecords(
            userID: profile.id,
            limit: limit + 1,
            createdBefore: before
        )
        let hasMore = postRecords.count > limit
        let visibleRecords = Array(postRecords.prefix(limit))
        let posts = try await hydrateFeedPosts(
            from: visibleRecords,
            viewer: viewer
        )
        return UserPostsPage(posts: posts, totalCount: nil, hasMore: hasMore)
    }

    func loadProfileStats(for profile: UserProfile, viewer: UserProfile) async throws -> ProfileStats {
        let records = try await fetchProfileStatsPostRecords(authorID: profile.id)
        return ProfileStats.make(
            from: records,
            id: { $0.id },
            date: { $0.created_at },
            drinkName: { $0.drink_name }
        )
    }

    func loadProfileFriendRank(
        for profile: UserProfile,
        viewer: UserProfile,
        timeZoneIdentifier: String
    ) async throws -> ProfileFriendRank {
        let rows: [SupabaseProfileFriendRankResponse] = try await sendRest(
            path: "rpc/profile_friend_rank",
            method: "POST",
            body: SupabaseProfileFriendRankRequest(
                profile_id: profile.id,
                timezone_name: timeZoneIdentifier
            )
        )

        guard let row = rows.first else {
            throw SupabaseBackendError.requestFailed("Profile friend rank unavailable.", statusCode: 404)
        }

        return ProfileFriendRank(rank: row.rank, groupSize: row.group_size)
    }

    func loadFeedPosts(
        authorIDs: [UUID],
        viewer: UserProfile,
        before: Date?,
        limit: Int
    ) async throws -> [MomentPost] {
        // Fetch limit + 1 so the caller can detect hasMore without a count query.
        let postRecords: [SupabaseFeedPostRecord]
        if viewer.normalizedUsername == "admin" {
            postRecords = try await fetchVisibleFeedPosts(
                limit: limit + 1,
                createdBefore: before
            )
        } else {
            postRecords = try await fetchFeedPosts(
                authorIDs: authorIDs,
                limit: limit + 1,
                createdBefore: before
            )
        }
        let visibleRecords = Array(postRecords.prefix(limit))
        return try await hydrateFeedPosts(from: visibleRecords, viewer: viewer)
    }

    func loadPost(id: UUID, viewer: UserProfile) async throws -> MomentPost? {
        guard let postRecord = try await fetchFeedPost(id: id) else { return nil }
        return try await hydrateFeedPosts(from: [postRecord], viewer: viewer).first
    }

    func fetchNewFeedPosts(since: Date, viewer: UserProfile) async throws -> [MomentPost] {
        // Poll a wider page than the UI shows so the overlap cursor in
        // AppStore can safely recover slightly older posts that became
        // visible late without truncating busy windows.
        let postRecords = try await fetchNewFeedPostRecords(since: since, limit: 100)
        guard !postRecords.isEmpty else { return [] }

        let postIDs = postRecords.map(\.id)
        async let commentRecordsFetch = fetchComments(for: postIDs)
        async let reactionRecordsFetch = fetchReactions(for: postIDs)
        async let engagementRecordsFetch = fetchPostEngagement(for: postIDs)

        let (commentRecords, reactionRecords, engagementRecords) = try await (
            commentRecordsFetch,
            reactionRecordsFetch,
            engagementRecordsFetch
        )
        async let commentLikesFetch = fetchCommentLikes(for: commentRecords.map(\.id))

        let relatedIDs = Array(Set(
            [viewer.id]
                + postRecords.map(\.author_id)
                + postRecords.flatMap(\.tagged_user_ids)
                + commentRecords.map(\.author_id)
                + reactionRecords.map(\.user_id)
        ))
        async let relatedProfilesFetch = fetchProfilesByIDs(relatedIDs)
        let (commentLikeRecords, relatedProfileRecords) = try await (commentLikesFetch, relatedProfilesFetch)
        let profileMap = Dictionary(
            uniqueKeysWithValues: relatedProfileRecords.map { record in
                (
                    record.id,
                    makeUserProfile(from: record, preferredImageData: nil, isCloseFriend: record.id == viewer.id)
                )
            }
        )

        return buildMomentPosts(
            from: postRecords,
            profileMap: profileMap,
            commentRecords: commentRecords,
            commentLikeRecords: commentLikeRecords,
            reactionRecords: reactionRecords,
            engagementRecords: engagementRecords,
            viewerID: viewer.id
        ).sorted { $0.createdAt > $1.createdAt }
    }

    func loadFullComments(for post: MomentPost, viewer: UserProfile) async throws -> [Comment] {
        let commentRecords = try await fetchAllComments(for: post.id)
        let commentLikeRecords = try await fetchCommentLikes(for: commentRecords.map(\.id))
        let relatedIDs = Array(Set(
            [viewer.id, post.author.id]
                + commentRecords.map(\.author_id)
        ))
        let relatedProfileRecords = try await fetchProfilesByIDs(relatedIDs)
        let profileMap = Dictionary(
            uniqueKeysWithValues: relatedProfileRecords.map { record in
                (
                    record.id,
                    makeUserProfile(from: record, preferredImageData: nil, isCloseFriend: record.id == viewer.id)
                )
            }
        )

        return commentsByPostID(
            from: commentRecords,
            commentLikeRecords: commentLikeRecords,
            profileMap: profileMap,
            viewerID: viewer.id
        )[post.id] ?? []
    }

    func loadReactors(for post: MomentPost, kind: ReactionKind, viewer: UserProfile) async throws -> [UserProfile] {
        let reactionRecords = try await fetchAllReactions(for: post.id, kind: kind)
        let relatedIDs = Array(Set([viewer.id] + reactionRecords.map(\.user_id)))
        let relatedProfileRecords = try await fetchProfilesByIDs(relatedIDs)
        let profileMap = Dictionary(
            uniqueKeysWithValues: relatedProfileRecords.map { record in
                (
                    record.id,
                    makeUserProfile(from: record, preferredImageData: nil, isCloseFriend: record.id == viewer.id)
                )
            }
        )

        return reactionRecords.compactMap { profileMap[$0.user_id] }
    }

    func signOut() async throws {
        let sessionToLogout = authSession
        clearSession()
        try? await revokeCurrentDeviceSession(sessionToLogout)
    }

    func sendFriendRequest(to friend: UserProfile, for viewer: UserProfile) async throws {
        // Enforce symmetry: if there is an INCOMING pending request from the
        // other user, accept it rather than creating a duplicate outgoing
        // row. This eliminates the "two rows for one friendship" ambiguity.
        let inbound = try await fetchFriendship(from: friend.id, to: viewer.id)
        if let inbound, inbound.status == "pending" {
            try await updateFriendshipStatus(inbound.id, to: "accepted")
            return
        }

        let payload = [
            SupabaseFriendshipRecord(
                user_id: viewer.id,
                friend_id: friend.id,
                status: "pending"
            )
        ]

        try await sendRestWithoutResponse(
            path: "friendships",
            method: "POST",
            queryItems: [URLQueryItem(name: "on_conflict", value: "user_id,friend_id")],
            prefer: "resolution=merge-duplicates,return=minimal",
            body: payload
        )
    }

    func acceptFriendRequest(_ request: FriendRequest, for viewer: UserProfile) async throws {
        _ = viewer
        try await updateFriendshipStatus(request.id, to: "accepted")
    }

    func rejectFriendRequest(_ request: FriendRequest, for viewer: UserProfile) async throws {
        _ = viewer
        // We delete the row outright rather than marking 'rejected'. This
        // lets the same initiator try again later without being permanently
        // locked out by a soft-rejection row. Blocking is the explicit
        // durable refusal.
        try await deleteRest(
            path: "friendships",
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(request.id.uuidString.lowercased())")
            ]
        )
    }

    func blockUser(_ user: UserProfile, for viewer: UserProfile) async throws {
        // Remove any existing row and insert a fresh blocked row owned by
        // the blocker (viewer). This makes the block visible in RLS
        // regardless of which side originated the friendship.
        try await deleteRest(
            path: "friendships",
            queryItems: [
                URLQueryItem(
                    name: "or",
                    value: "(and(user_id.eq.\(viewer.id.uuidString.lowercased()),friend_id.eq.\(user.id.uuidString.lowercased())),and(user_id.eq.\(user.id.uuidString.lowercased()),friend_id.eq.\(viewer.id.uuidString.lowercased())))"
                )
            ]
        )

        try await sendRestWithoutResponse(
            path: "friendships",
            method: "POST",
            queryItems: [URLQueryItem(name: "on_conflict", value: "user_id,friend_id")],
            prefer: "resolution=merge-duplicates,return=minimal",
            body: [
                SupabaseFriendshipRecord(
                    user_id: viewer.id,
                    friend_id: user.id,
                    status: "blocked"
                )
            ]
        )
    }

    func reportUser(_ user: UserProfile, for viewer: UserProfile) async throws {
        try await submitContentReport(
            ContentReportRequest(
                target: .user,
                postID: nil,
                commentID: nil,
                targetUserID: user.id
            )
        )
    }

    func unfriend(_ friend: UserProfile, for viewer: UserProfile) async throws {
        // A friendship may be represented by either ordering of (user_id,
        // friend_id). Delete any row between the pair that the viewer is
        // allowed to delete under RLS. We issue two deletes because the
        // OR-composite filter on PostgREST is tricky and we prefer
        // correctness over a single round-trip.
        try await deleteRest(
            path: "friendships",
            queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(viewer.id.uuidString.lowercased())"),
                URLQueryItem(name: "friend_id", value: "eq.\(friend.id.uuidString.lowercased())")
            ]
        )
        try await deleteRest(
            path: "friendships",
            queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(friend.id.uuidString.lowercased())"),
                URLQueryItem(name: "friend_id", value: "eq.\(viewer.id.uuidString.lowercased())")
            ]
        )
    }

    func registerDeviceToken(_ token: Data, environment: DeviceEnvironment, for viewer: UserProfile) async throws {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let payload = [
            SupabaseDeviceRecord(
                user_id: viewer.id,
                apns_token: hex,
                environment: environment.rawValue,
                last_seen_at: Date()
            )
        ]

        try await sendRestWithoutResponse(
            path: "devices",
            method: "POST",
            queryItems: [URLQueryItem(name: "on_conflict", value: "user_id,apns_token")],
            prefer: "resolution=merge-duplicates,return=minimal",
            body: payload
        )
    }

    func unregisterDeviceToken(_ token: Data, for viewer: UserProfile) async throws {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        try await deleteRest(
            path: "devices",
            queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(viewer.id.uuidString.lowercased())"),
                URLQueryItem(name: "apns_token", value: "eq.\(hex)")
            ]
        )
    }

    func deleteCurrentAccount() async throws {
        try await sendFunctionWithoutResponse(
            name: "delete-account",
            body: SupabaseEmptyRequest(),
            timeoutInterval: 60
        )
        clearSession()
    }

    // MARK: - Diagnostics

    /// Calls the `public.send_self_test_notification()` RPC, which inserts a
    /// notifications row addressed to `auth.uid()`. The server-side dispatch
    /// trigger then exercises the full pg_net -> edge function -> APNs chain
    /// and records the outcome in `public.push_attempts`. The caller should
    /// inspect that table to confirm success; the RPC itself returns before
    /// APNs has responded.
    func sendSelfTestNotification() async throws {
        try await sendRestWithoutResponse(
            path: "rpc/send_self_test_notification",
            method: "POST",
            prefer: "return=minimal",
            body: SupabaseEmptyRequest()
        )
    }

    // MARK: - Admin

    func fetchAllUsersPage(offset: Int, limit: Int) async throws -> [UserProfile] {
        let records: [SupabaseProfileRecord] = try await sendRest(
            path: "rpc/admin_profiles",
            method: "POST",
            body: SupabaseAdminPageRequest(limit_count: limit, offset_count: offset)
        )
        return records.map { makeUserProfile(from: $0, preferredImageData: nil, isCloseFriend: false) }
    }

    func setVerified(_ isVerified: Bool, for profile: UserProfile) async throws {
        let _: [SupabaseProfileRecord] = try await sendRest(
            path: "rpc/admin_set_profile_verified",
            method: "POST",
            body: SupabaseAdminProfileFlagRequest(
                target_user_id: profile.id,
                verified: isVerified,
                banned: nil,
                reason: nil
            )
        )
    }

    func setMaintenanceMode(enabled: Bool, title: String, message: String) async throws -> [String: String] {
        let records: [SupabaseAppConfigRecord] = try await sendRest(
            path: "rpc/admin_set_app_maintenance_config",
            method: "POST",
            body: SupabaseMaintenanceConfigUpdateRequest(
                enabled: enabled,
                title: title,
                message: message
            )
        )
        return Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0.value) })
    }

    func fetchNotificationPreferences(for userID: UUID) async throws -> NotificationPreferences {
        let rows: [SupabaseNotificationPreferences] = try await sendRest(
            path: "notification_preferences",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "select", value: "user_id,announcements_enabled,friend_requests_enabled,reactions_enabled,comments_enabled,activity_enabled,recaps_enabled"),
                URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString.lowercased())")
            ],
            responseType: [SupabaseNotificationPreferences].self
        )
        return rows.first?.preferences ?? NotificationPreferences()
    }

    func setNotificationPreference(_ category: PushNotificationCategory, enabled: Bool, for userID: UUID) async throws {
        // Encode only the changed column. Saving one category must not reset
        // another category changed on this phone or a second signed-in device.
        try await sendRestWithoutResponse(
            path: "notification_preferences",
            method: "POST",
            queryItems: [URLQueryItem(name: "on_conflict", value: "user_id")],
            prefer: "resolution=merge-duplicates,return=minimal",
            body: SupabaseNotificationPreferenceUpdate(userID: userID, category: category, enabled: enabled)
        )
    }

    func publishAppAnnouncement(
        requestID: UUID,
        title: String,
        message: String,
        audience: AppAnnouncementAudience,
        targetUsernames: [String],
        delivery: AppAnnouncementDelivery
    ) async throws {
        try await sendRestWithoutResponse(
            path: "rpc/admin_publish_announcement",
            method: "POST",
            body: SupabaseAppAnnouncementCreateRequest(
                request_id: requestID,
                title: title,
                message: message,
                audience: audience.rawValue,
                target_usernames: targetUsernames,
                delivery: delivery.rawValue
            )
        )
    }

    func fetchAdminAppAnnouncements(limit: Int) async throws -> [AdminAppAnnouncement] {
        let records: [SupabaseAdminAppAnnouncementRecord] = try await sendRest(
            path: "rpc/admin_announcement_history",
            method: "POST",
            body: SupabaseAnnouncementLimitRequest(limit_count: limit)
        )
        return records.map(makeAdminAppAnnouncement)
    }

    func deactivateAppAnnouncement(id: UUID) async throws {
        try await sendRestWithoutResponse(
            path: "rpc/admin_deactivate_app_announcement",
            method: "POST",
            body: SupabaseAdminAnnouncementIDRequest(announcement_id: id)
        )
    }

    func fetchAdminReports(limit: Int, offset: Int) async throws -> [ContentReport] {
        let records: [SupabaseContentReportRecord] = try await sendRest(
            path: "rpc/admin_content_reports",
            method: "POST",
            body: SupabaseAdminPageRequest(limit_count: limit, offset_count: offset)
        )
        return records.map(makeContentReport)
    }

    func resolveReport(id: UUID) async throws {
        try await sendRestWithoutResponse(
            path: "rpc/admin_resolve_content_report",
            method: "POST",
            body: SupabaseAdminReportIDRequest(report_id: id)
        )
    }

    func deletePostAsAdmin(_ postID: UUID, reportID: UUID?) async throws {
        try await sendRestWithoutResponse(
            path: "rpc/admin_delete_post",
            method: "POST",
            body: SupabaseAdminDeletePostRequest(target_post_id: postID, report_id: reportID)
        )
    }

    func deleteCommentAsAdmin(_ commentID: UUID, reportID: UUID?) async throws {
        try await sendRestWithoutResponse(
            path: "rpc/admin_delete_comment",
            method: "POST",
            body: SupabaseAdminDeleteCommentRequest(target_comment_id: commentID, report_id: reportID)
        )
    }

    func banUser(_ userID: UUID) async throws {
        _ = try await setUserBanned(true, userID: userID)
    }

    func setUserBanned(_ isBanned: Bool, userID: UUID) async throws -> UserProfile {
        let records: [SupabaseProfileRecord] = try await sendRest(
            path: "rpc/admin_set_user_banned",
            method: "POST",
            body: SupabaseAdminProfileFlagRequest(
                target_user_id: userID,
                verified: nil,
                banned: isBanned,
                reason: "admin_action"
            )
        )

        guard let record = records.first else {
            throw SupabaseBackendError.invalidResponse
        }

        return makeUserProfile(from: record, preferredImageData: nil, isCloseFriend: false)
    }

    func deleteUserContent(userID: UUID) async throws -> AdminContentDeletionSummary {
        let records: [SupabaseAdminContentDeletionRecord] = try await sendRest(
            path: "rpc/admin_delete_user_content",
            method: "POST",
            body: SupabaseAdminUserIDRequest(target_user_id: userID)
        )

        guard let record = records.first else {
            throw SupabaseBackendError.invalidResponse
        }

        return AdminContentDeletionSummary(
            postsDeleted: record.posts_deleted,
            commentsDeleted: record.comments_deleted,
            reactionsDeleted: record.reactions_deleted,
            commentLikesDeleted: record.comment_likes_deleted,
            friendshipsDeleted: record.friendships_deleted,
            notificationsDeleted: record.notifications_deleted,
            contentReportsDeleted: record.content_reports_deleted,
            groupsDeleted: record.groups_deleted,
            groupsUpdated: record.groups_updated,
            devicesDeleted: record.devices_deleted,
            storageObjectsDeleted: record.storage_objects_deleted
        )
    }
}

private extension SupabaseSocialBackendClient {
    func currentAuthEmail() async throws -> String {
        if let email = authSession?.user?.email,
           let normalized = EmailAddressRules.normalized(email) {
            return normalized
        }

        let user = try await fetchAuthUser()
        if let email = user.email,
           let normalized = EmailAddressRules.normalized(email) {
            return normalized
        }

        throw SupabaseBackendError.requestFailed(
            "Couldn't confirm the email on this session. Sign out and back in, then try again.",
            statusCode: 400
        )
    }
}

extension SupabaseSocialBackendClient {
    func makeAdminAppAnnouncement(from record: SupabaseAdminAppAnnouncementRecord) -> AdminAppAnnouncement {
        AdminAppAnnouncement(
            id: record.announcement_id,
            title: record.title,
            message: record.message,
            audience: AppAnnouncementAudience(rawValue: record.audience) ?? .all,
            targetUsernames: record.target_usernames ?? [],
            recipientCount: record.recipient_count ?? 0,
            isActive: record.is_active,
            createdAt: record.created_at,
            delivery: AppAnnouncementDelivery(rawValue: record.delivery ?? "in_app") ?? .inApp,
            pushRecipientCount: record.push_recipient_count ?? 0,
            pushAcceptedCount: record.push_accepted_count ?? 0,
            pushFailureCount: record.push_failure_count ?? 0,
            pushSkippedCount: record.push_skipped_count ?? 0,
            pushPendingCount: record.push_pending_count ?? 0
        )
    }

    func makeContentReport(from record: SupabaseContentReportRecord) -> ContentReport {
        ContentReport(
            id: record.id,
            createdAt: record.created_at,
            reporterUsername: record.reporter_username,
            targetType: record.target_type,
            targetPostID: record.target_post_id,
            targetCommentID: record.target_comment_id,
            targetAuthorID: record.target_author_id,
            targetAuthorUsername: record.target_author_username,
            targetExcerpt: record.target_excerpt,
            reason: record.reason,
            detail: record.detail,
            status: record.status,
            reviewedAt: record.reviewed_at,
            moderatorNote: record.moderator_note
        )
    }

    func hydrateFeedPosts(
        from postRecords: [SupabaseFeedPostRecord],
        viewer: UserProfile,
        fallbackAuthors: [UUID: UserProfile] = [:]
    ) async throws -> [MomentPost] {
        guard !postRecords.isEmpty else { return [] }

        let postIDs = postRecords.map(\.id)
        func fetchCommentsSafely() async -> [SupabaseFeedCommentRecord] {
            (try? await fetchComments(for: postIDs)) ?? []
        }

        func fetchReactionsSafely() async -> [SupabaseFeedReactionRecord] {
            (try? await fetchReactions(for: postIDs)) ?? []
        }

        func fetchEngagementSafely() async -> [SupabasePostEngagementRecord] {
            (try? await fetchPostEngagement(for: postIDs)) ?? []
        }

        func fetchCommentLikesSafely(for commentIDs: [UUID]) async -> [SupabaseCommentLikeRecord] {
            (try? await fetchCommentLikes(for: commentIDs)) ?? []
        }

        func fetchProfilesSafely(_ profileIDs: [UUID]) async -> [SupabaseProfileRecord] {
            (try? await fetchProfilesByIDs(profileIDs)) ?? []
        }

        async let commentRecordsFetch = fetchCommentsSafely()
        async let reactionRecordsFetch = fetchReactionsSafely()
        async let engagementRecordsFetch = fetchEngagementSafely()

        let (commentRecords, reactionRecords, engagementRecords) = await (
            commentRecordsFetch,
            reactionRecordsFetch,
            engagementRecordsFetch
        )
        // Run comment-likes and profile fetches concurrently — comment-likes
        // only depends on commentRecords being resolved, and profile IDs can
        // be computed immediately after all three engagement fetches resolve.
        async let commentLikesFetch = fetchCommentLikes(for: commentRecords.map(\.id))

        let relatedIDs = Array(Set(
            [viewer.id]
                + postRecords.map(\.author_id)
                + postRecords.flatMap(\.tagged_user_ids)
                + commentRecords.map(\.author_id)
                + reactionRecords.map(\.user_id)
        ))
        async let relatedProfilesFetch = fetchProfilesSafely(relatedIDs)
        let (commentLikeRecords, relatedProfileRecords) = await (commentLikesFetch, relatedProfilesFetch)
        let profileMap = Dictionary(
            uniqueKeysWithValues: relatedProfileRecords.map { record in
                (
                    record.id,
                    makeUserProfile(
                        from: record,
                        preferredImageData: nil,
                        isCloseFriend: record.id == viewer.id
                    )
                )
            }
        )

        return buildMomentPosts(
            from: postRecords,
            profileMap: profileMap,
            commentRecords: commentRecords,
            commentLikeRecords: commentLikeRecords,
            reactionRecords: reactionRecords,
            engagementRecords: engagementRecords,
            viewerID: viewer.id,
            fallbackAuthors: fallbackAuthors
        )
        .sorted { $0.createdAt > $1.createdAt }
    }

    func commentsByPostID(
        from records: [SupabaseFeedCommentRecord],
        commentLikeRecords: [SupabaseCommentLikeRecord],
        profileMap: [UUID: UserProfile],
        viewerID: UUID
    ) -> [UUID: [Comment]] {
        let commentsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let commentLikesByCommentID = Dictionary(grouping: commentLikeRecords, by: \.comment_id)
        return Dictionary(grouping: records, by: \.post_id).mapValues { postRecords in
            postRecords.compactMap { commentRecord -> Comment? in
                guard let author = profileMap[commentRecord.author_id] else { return nil }
                let likeRecords = commentLikesByCommentID[commentRecord.id] ?? []
                return Comment(
                    id: commentRecord.id,
                    author: author,
                    text: commentRecord.body,
                    createdAt: commentRecord.created_at,
                    kind: commentRecord.commentKind,
                    remotePhotoURL: commentRecord.image_path.map {
                        environment.storageObjectURL(
                            bucket: environment.storageBucket,
                            objectPath: $0,
                            isPublic: true
                        )
                    },
                    likeCount: likeRecords.count,
                    isLikedByViewer: likeRecords.contains(where: { $0.user_id == viewerID }),
                    replyToCommentID: commentRecord.reply_to_comment_id,
                    replyToDisplayName: commentRecord.reply_to_comment_id.flatMap {
                        commentsByID[$0].flatMap { profileMap[$0.author_id]?.displayName }
                    }
                )
            }
        }
    }

    func buildMomentPosts(
        from postRecords: [SupabaseFeedPostRecord],
        profileMap: [UUID: UserProfile],
        commentRecords: [SupabaseFeedCommentRecord],
        commentLikeRecords: [SupabaseCommentLikeRecord],
        reactionRecords: [SupabaseFeedReactionRecord],
        engagementRecords: [SupabasePostEngagementRecord],
        viewerID: UUID,
        fallbackAuthors: [UUID: UserProfile] = [:]
    ) -> [MomentPost] {
        let commentsByPostID = commentsByPostID(
            from: commentRecords,
            commentLikeRecords: commentLikeRecords,
            profileMap: profileMap,
            viewerID: viewerID
        )
        let reactionsByPostID = Dictionary(grouping: reactionRecords, by: \.post_id)
        let engagementByPostID = Dictionary(uniqueKeysWithValues: engagementRecords.map { ($0.post_id, $0) })

        return postRecords.compactMap { record -> MomentPost? in
            // Use the resolved profile, or a stable placeholder if the profile
            // fetch returned an incomplete result (e.g. a mid-edit DB race).
            // Posts should never be silently dropped due to a transient hydration gap.
            let author = profileMap[record.author_id]
                ?? fallbackAuthors[record.author_id]
                ?? UserProfile(
                    id: record.author_id,
                    displayName: "Unknown",
                    username: "unknown",
                    avatar: AvatarStyle(symbol: "person.fill", primaryHex: "#444444", secondaryHex: "#222222"),
                    isCloseFriend: false,
                    isVerified: false
                )

            let comments = commentsByPostID[record.id] ?? []
            let reactionItems = reactionsByPostID[record.id] ?? []
            let engagement = engagementByPostID[record.id]

            let reactionSummaries = ReactionKind.allCases.compactMap { kind -> ReactionSummary? in
                let exactCount = engagement?.reactionCounts[kind]
                    ?? reactionItems.filter { $0.reactionKind == kind }.count
                guard exactCount > 0 else { return nil }
                let reactors = reactionItems
                    .filter { $0.reactionKind == kind }
                    .compactMap { profileMap[$0.user_id] }
                return ReactionSummary(kind: kind, count: exactCount, reactors: reactors)
            }

            let viewerReactionKinds = engagement?.viewerReactionKinds ?? Set(
                reactionItems.compactMap { reaction in
                    guard reaction.user_id == viewerID else { return nil }
                    return reaction.reactionKind
                }
            )

            let fullyLoadedReactionKinds = Set(
                reactionSummaries.compactMap { summary -> ReactionKind? in
                    summary.reactors.count >= summary.count ? summary.kind : nil
                }
            )

            let exactCommentCount = engagement?.comment_count ?? comments.count

            return makeMomentPost(
                from: record,
                author: author,
                taggedFriends: record.tagged_user_ids.compactMap { profileMap[$0] },
                comments: comments,
                commentCount: exactCommentCount,
                hasLoadedFullCommentThread: comments.count >= exactCommentCount,
                reactions: reactionSummaries,
                viewerReactionKinds: viewerReactionKinds,
                fullyLoadedReactionKinds: fullyLoadedReactionKinds
            )
        }
    }

    private func makeDrinkCatalogPreferences(from profile: SupabaseProfileRecord) -> DrinkCatalogPreferences {
        normalizeDrinkCatalogPreferences(
            DrinkCatalogPreferences(
                customDrinks: profile.custom_drinks ?? [],
                deletedDrinkNames: profile.deleted_drink_names ?? [],
                orderedDrinkNames: profile.drink_order_names ?? []
            )
        )
    }

    private func normalizeDrinkCatalogPreferences(_ preferences: DrinkCatalogPreferences) -> DrinkCatalogPreferences {
        let customs = AppStore.deduplicatedDrinks(preferences.customDrinks)
        let customNames = Set(customs.map { AppStore.normalizedDrinkName($0.name) })
        let deleted = Array(Set(preferences.deletedDrinkNames.map(AppStore.normalizedDrinkName))).sorted()
        let ordered = preferences.orderedDrinkNames
            .map(AppStore.normalizedDrinkName)
            .reduce(into: [String]()) { result, name in
                guard !name.isEmpty, !result.contains(name) else { return }
                result.append(name)
            }
            .filter { name in
                customNames.contains(name) || SeedCatalog.drinks.contains(where: {
                    AppStore.normalizedDrinkName($0.name) == name
                })
            }

        return DrinkCatalogPreferences(
            customDrinks: customs,
            deletedDrinkNames: deleted,
            orderedDrinkNames: ordered
        )
    }
}
