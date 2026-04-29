import Foundation

final class SupabaseSocialBackendClient: SocialBackendClient {
    enum SessionStorage {
        static let key = "OutAgain.supabase.session"
    }

    let environment: SupabaseEnvironment
    let urlSession: URLSession
    var authSession: SupabaseAuthSession?

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

    func signIn(email: String, password: String) async throws {
        guard let normalizedEmail = EmailAddressRules.normalized(email) else {
            throw SupabaseBackendError.invalidEmailAddress
        }
        guard !password.isEmpty else {
            throw SupabaseBackendError.invalidPassword
        }

        let session: SupabaseAuthSession = try await sendAuth(
            path: "token",
            queryItems: [URLQueryItem(name: "grant_type", value: "password")],
            body: SupabaseEmailPasswordAuthRequest(
                email: normalizedEmail,
                password: password
            )
        )

        authSession = session
        persistSession(session)
    }

    func loadAppData() async throws -> SocialBootstrap {
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
                notifications: []
            )
        }
        BootstrapTrace.mark("loadAppData: fetchCurrentProfile done")

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
                notifications: []
            )
        }

        // Single concurrent wave: all independent fetches fire at once.
        // Previously this was 4 sequential phases; collapsing them into one
        // async-let fan-out cuts wall-clock bootstrap time by ~60% on a
        // typical cellular connection (saves 2-3 serial round-trips).
        //
        // The only true dependency is: we need friendIDs before we can pass
        // them to fetchProfilesByIDs. We resolve that by fetching friendships
        // first (fast, one small table) and then launching all remaining
        // fetches in parallel once we have the IDs.
        BootstrapTrace.mark("loadAppData: wave 1 launched (relationships, FoF, notifications, tonight)")
        async let allRelationshipsFetch = fetchAllFriendships(for: viewerRecord.id)
        async let fofIDRowsFetch = fetchFriendOfFriendIDs(for: viewerRecord.id)
        async let notificationsFetch = fetchNotifications(limit: 40)
        async let tonightFeedFetch = fetchTonightFeedOrEmpty(viewerID: viewerRecord.id, limit: 30)

        let (allRelationships, fofIDRows, notificationRecords) = try await (
            allRelationshipsFetch,
            fofIDRowsFetch,
            notificationsFetch
        )
        BootstrapTrace.mark("loadAppData: wave 1 (3-of-4) returned")
        let tonightPostRecords = await tonightFeedFetch
        BootstrapTrace.mark("loadAppData: wave 1 (tonight feed) returned")

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

        // Use the tonight_feed result if it returned posts; fall back to the
        // direct author_id query only if the RPC gave us nothing (schema gap).
        let postRecords: [SupabaseFeedPostRecord]
        if !tonightPostRecords.isEmpty {
            postRecords = tonightPostRecords
        } else {
            BootstrapTrace.mark("loadAppData: tonight feed empty, falling back to fetchFeedPosts")
            let fallbackAuthorIDs = Array(friendIDs) + [viewerRecord.id]
            postRecords = (try? await fetchFeedPosts(authorIDs: fallbackAuthorIDs, limit: 30)) ?? []
            BootstrapTrace.mark("loadAppData: fallback fetchFeedPosts returned")
        }

        // Second concurrent wave: now that we have friendIDs and postIDs,
        // fetch suggestions plus the lightweight engagement preview data in
        // parallel. Exact counts come from a cheap aggregate RPC, while the
        // preview comments/reactors stay capped so bootstrap egress remains low.
        BootstrapTrace.mark("loadAppData: wave 2 launched (suggestions, comments, reactions, engagement)")
        let postIDs = postRecords.map(\.id)
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
        BootstrapTrace.mark("loadAppData: wave 2 returned")

        let pendingCounterpartIDs = Set(
            incomingPending.map(\.user_id) + outgoingPending.map(\.friend_id)
        )

        let relatedProfileIDs = Set(
            [viewerRecord.id]
                + Array(friendIDs)
                + Array(blockedIDs)
                + suggestedProfiles.map(\.id)
                + postRecords.map(\.author_id)
                + postRecords.flatMap(\.tagged_user_ids)
                + commentRecords.map(\.author_id)
                + reactionRecords.map(\.user_id)
                + notificationRecords.compactMap(\.actor_id)
                + Array(pendingCounterpartIDs)
        )

        BootstrapTrace.mark("loadAppData: wave 3 fetchProfilesByIDs(\(relatedProfileIDs.count) IDs) start")
        let relatedProfiles = try await fetchProfilesByIDs(Array(relatedProfileIDs))
        BootstrapTrace.mark("loadAppData: wave 3 returned, building bootstrap")
        let profileMap = Dictionary(
            uniqueKeysWithValues: relatedProfiles.map { profile in
                (
                    profile.id,
                    makeUserProfile(
                        from: profile,
                        preferredImageData: nil,
                        isCloseFriend: friendIDs.contains(profile.id) || profile.id == viewerRecord.id
                    )
                )
            }
        )

        let viewer = profileMap[viewerRecord.id]
        let friends = Array(friendIDs)
            .compactMap { profileMap[$0] }
            .sorted { $0.displayName < $1.displayName }
        let suggestedFriends = suggestedProfiles
            .compactMap { profileMap[$0.id] }
            .filter { !friendIDs.contains($0.id) && $0.id != viewerRecord.id && !blockedIDs.contains($0.id) }
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
            reactionRecords: reactionRecords,
            engagementRecords: engagementRecords,
            viewerID: viewerRecord.id
        )

        return SocialBootstrap(
            viewer: viewer,
            drinkCatalogPreferences: makeDrinkCatalogPreferences(from: viewerRecord),
            friends: friends,
            suggestedFriends: suggestedFriends,
            friendOfFriendIDs: friendOfFriendIDs,
            incomingRequests: incomingRequests.sorted { $0.createdAt > $1.createdAt },
            outgoingRequests: outgoingRequests.sorted { $0.createdAt > $1.createdAt },
            blockedUserIDs: blockedIDs,
            blockedUsers: blockedUsers,
            posts: posts.sorted { $0.createdAt > $1.createdAt },
            notifications: notificationRecords
                .map { makeNotification(from: $0, profileMap: profileMap) }
                .sorted { $0.createdAt > $1.createdAt }
        )
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

        let existing: [SupabaseProfileRecord] = try await fetchProfiles(
            queryItems: [
                URLQueryItem(name: "select", value: SupabaseProfileRecord.selectList),
                URLQueryItem(name: "username", value: "eq.\(normalized)"),
                URLQueryItem(name: "limit", value: "1")
            ]
        )

        if let existingProfile = existing.first {
            if existingProfile.id == currentUserIDOptional {
                return .available(normalized)
            }

            let takenUsernames = Set(existing.compactMap(\.username)).union(reserved)
            return .unavailable(
                normalized,
                suggestion: UsernameRules.suggestion(for: normalized, reserved: takenUsernames)
            )
        }

        return .available(normalized)
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
            queryItems: [URLQueryItem(name: "on_conflict", value: "id")],
            prefer: "resolution=merge-duplicates,return=representation",
            body: [
                SupabaseProfileRecord(
                    id: userID,
                    username: normalized,
                    display_name: displayName,
                    avatar_path: avatarPath,
                    avatar_version: nil,
                    custom_drinks: [],
                    deleted_drink_names: [],
                    drink_order_names: [],
                    apple_user_identifier: nil,
                    normalized_email_hash: PrivacyHash.normalizedEmailHash(for: request.email)
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
        let avatarPath = try await resolveAvatarPath(
            preferredImageData: request.profileImageData,
            userID: userID,
            knownCurrentPath: request.currentAvatarPath
        )

        let records: [SupabaseProfileRecord] = try await sendRest(
            path: "profiles",
            method: "PATCH",
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(userID.uuidString.lowercased())"),
                URLQueryItem(name: "select", value: SupabaseProfileRecord.selectList)
            ],
            prefer: "return=representation",
            body: SupabaseProfileUpdateRecord(
                username: normalized,
                display_name: displayName,
                avatar_path: avatarPath
            )
        )

        guard let updatedProfile = records.first else {
            throw SupabaseBackendError.invalidResponse
        }

        return makeUserProfile(
            from: updatedProfile,
            preferredImageData: request.profileImageData,
            isCloseFriend: viewer.isCloseFriend
        )
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
        let usernameFragment = UsernameRules.searchFragment(query)
        guard usernameFragment.count >= 2 else { return [] }

        let sanitizedQuery = usernameFragment.replacingOccurrences(of: ",", with: "")
        var queryItems = [
            URLQueryItem(name: "select", value: SupabaseProfileRecord.selectList),
            URLQueryItem(name: "username", value: "ilike.*\(sanitizedQuery)*"),
            URLQueryItem(name: "limit", value: "12")
        ]

        if let viewer {
            queryItems.append(URLQueryItem(name: "id", value: "neq.\(viewer.id.uuidString.lowercased())"))
        }

        let profiles: [SupabaseProfileRecord] = try await fetchProfiles(queryItems: queryItems)
        return profiles.map { makeUserProfile(from: $0, preferredImageData: nil, isCloseFriend: false) }
    }

    func searchContacts(matching contacts: [ContactLookupSeed], excluding viewer: UserProfile?) async throws -> [UserProfile] {
        let hashes = Array(Set(contacts.flatMap(\.emailHashes))).sorted()
        guard !hashes.isEmpty else { return [] }

        let profiles: [SupabaseProfileRecord] = try await sendRest(
            path: "rpc/match_profiles_by_email_hashes",
            method: "POST",
            body: SupabaseEmailHashesRequest(email_hashes: hashes)
        )
        return profiles.map { makeUserProfile(from: $0, preferredImageData: nil, isCloseFriend: false) }
            .filter { profile in
                guard let viewer else { return true }
                return profile.id != viewer.id
            }
    }

    func loadFriendCount(of profile: UserProfile, for viewer: UserProfile) async throws -> Int {
        let rows: [SupabaseProfileFriendCountResponse] = try await sendRest(
            path: "rpc/friend_count_for_profile",
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

    func loadUserPosts(for profile: UserProfile, viewer: UserProfile) async throws -> [MomentPost] {
        let postRecords = try await fetchFeedPosts(authorIDs: [profile.id], limit: 60)
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

        // Collect all profile IDs referenced by these posts so we can hydrate
        // author/tagger/commenter/reactor names and avatars in a single batch.
        let relatedIDs = Array(Set(
            [profile.id, viewer.id]
                + postRecords.flatMap(\.tagged_user_ids)
                + commentRecords.map(\.author_id)
                + reactionRecords.map(\.user_id)
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

        let posts = buildMomentPosts(
            from: postRecords,
            profileMap: profileMap,
            commentRecords: commentRecords,
            reactionRecords: reactionRecords,
            engagementRecords: engagementRecords,
            viewerID: viewer.id,
            fallbackAuthors: [profile.id: profile]
        )

        return posts.sorted { $0.createdAt > $1.createdAt }
    }

    func fetchNewFeedPosts(since: Date, viewer: UserProfile) async throws -> [MomentPost] {
        let postRecords = try await fetchNewFeedPostRecords(since: since, limit: 20)
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

        let relatedIDs = Array(Set(
            [viewer.id]
                + postRecords.map(\.author_id)
                + postRecords.flatMap(\.tagged_user_ids)
                + commentRecords.map(\.author_id)
                + reactionRecords.map(\.user_id)
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

        return buildMomentPosts(
            from: postRecords,
            profileMap: profileMap,
            commentRecords: commentRecords,
            reactionRecords: reactionRecords,
            engagementRecords: engagementRecords,
            viewerID: viewer.id
        ).sorted { $0.createdAt > $1.createdAt }
    }

    func loadFullComments(for post: MomentPost, viewer: UserProfile) async throws -> [Comment] {
        let commentRecords = try await fetchAllComments(for: post.id)
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

        return commentsByPostID(from: commentRecords, profileMap: profileMap)[post.id] ?? []
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
        // Best-effort: tell Supabase to invalidate the refresh token, then
        // clear local storage regardless of the server's response. We don't
        // want a network failure to strand the user in a signed-in state.
        if let refreshToken = authSession?.refresh_token, !refreshToken.isEmpty {
            _ = try? await postAuth(path: "logout")
        }
        clearSession()
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
        try? await deleteRest(
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

    func unfriend(_ friend: UserProfile, for viewer: UserProfile) async throws {
        // A friendship may be represented by either ordering of (user_id,
        // friend_id). Delete any row between the pair that the viewer is
        // allowed to delete under RLS. We issue two deletes because the
        // OR-composite filter on PostgREST is tricky and we prefer
        // correctness over a single round-trip.
        try? await deleteRest(
            path: "friendships",
            queryItems: [
                URLQueryItem(name: "user_id", value: "eq.\(viewer.id.uuidString.lowercased())"),
                URLQueryItem(name: "friend_id", value: "eq.\(friend.id.uuidString.lowercased())")
            ]
        )
        try? await deleteRest(
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
}

private extension SupabaseSocialBackendClient {
    func commentsByPostID(
        from records: [SupabaseFeedCommentRecord],
        profileMap: [UUID: UserProfile]
    ) -> [UUID: [Comment]] {
        let commentsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        return Dictionary(grouping: records, by: \.post_id).mapValues { postRecords in
            postRecords.compactMap { commentRecord -> Comment? in
                guard let author = profileMap[commentRecord.author_id] else { return nil }
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
        reactionRecords: [SupabaseFeedReactionRecord],
        engagementRecords: [SupabasePostEngagementRecord],
        viewerID: UUID,
        fallbackAuthors: [UUID: UserProfile] = [:]
    ) -> [MomentPost] {
        let commentsByPostID = commentsByPostID(from: commentRecords, profileMap: profileMap)
        let reactionsByPostID = Dictionary(grouping: reactionRecords, by: \.post_id)
        let engagementByPostID = Dictionary(uniqueKeysWithValues: engagementRecords.map { ($0.post_id, $0) })

        return postRecords.compactMap { record -> MomentPost? in
            guard let author = profileMap[record.author_id] ?? fallbackAuthors[record.author_id] else { return nil }

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
