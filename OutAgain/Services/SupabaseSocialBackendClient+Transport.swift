import CryptoKit
import Foundation

extension SupabaseSocialBackendClient {
    var hasStoredSession: Bool {
        authSession != nil
    }

    var currentUserIDOptional: UUID? {
        authSession?.user?.id
    }

    func currentUserID() throws -> UUID {
        guard let id = currentUserIDOptional else {
            throw SupabaseBackendError.notAuthenticated
        }
        return id
    }

    func ensureAuthenticatedSession() async throws {
        guard let session = authSession else {
            throw SupabaseBackendError.notAuthenticated
        }

        let expiresSoon: Bool
        if let expiresAt = session.expires_at {
            expiresSoon = expiresAt <= Date().addingTimeInterval(60).timeIntervalSince1970
        } else {
            expiresSoon = false
        }

        guard expiresSoon, let refreshToken = session.refresh_token else { return }

        do {
            let refreshed: SupabaseAuthSession = try await sendAuth(
                path: "token",
                queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")],
                body: SupabaseRefreshTokenGrantRequest(refresh_token: refreshToken)
            )
            authSession = refreshed
            persistSession(refreshed)
        } catch {
            // Only invalidate the stored session when the server has explicitly
            // and definitively rejected the refresh token. The criteria are tight
            // on purpose: a single transient failure — DNS blip, timeout, airplane
            // mode, CDN hiccup, 429 rate-limit, 500 server error — must never
            // sign the user out. We clear only on:
            //   • 400 with an auth error body (invalid_grant / bad refresh token)
            //   • 401 Unauthorized (token genuinely revoked server-side)
            // Everything else — transport errors, 5xx, 429, decoding failures —
            // leaves the session intact so the next foreground cycle retries.
            let shouldClearSession: Bool
            switch error {
            case SupabaseBackendError.requestFailed(let message, let statusCode):
                let isHardAuthReject = statusCode == 400 || statusCode == 401
                let isInvalidGrant = message.localizedCaseInsensitiveContains("invalid_grant")
                    || message.localizedCaseInsensitiveContains("refresh_token_not_found")
                    || message.localizedCaseInsensitiveContains("Token has expired")
                shouldClearSession = isHardAuthReject && isInvalidGrant
            default:
                // notAuthenticated, transport errors, decoding errors — retain session.
                shouldClearSession = false
            }

            if shouldClearSession {
                clearSession()
            }
            throw error
        }
    }

    func fetchCurrentProfile() async throws -> SupabaseProfileRecord? {
        let userID = try currentUserID()
        return try await fetchProfiles(
            queryItems: [
                URLQueryItem(name: "select", value: SupabaseProfileRecord.selectList),
                URLQueryItem(name: "id", value: "eq.\(userID.uuidString.lowercased())"),
                URLQueryItem(name: "limit", value: "1")
            ]
        ).first
    }

    func fetchProfiles(queryItems: [URLQueryItem]) async throws -> [SupabaseProfileRecord] {
        try await sendRest(
            path: "profiles",
            method: "GET",
            queryItems: queryItems,
            responseType: [SupabaseProfileRecord].self
        )
    }

    func fetchProfilesByIDs(_ ids: [UUID]) async throws -> [SupabaseProfileRecord] {
        guard !ids.isEmpty else { return [] }
        return try await fetchProfiles(
            queryItems: [
                URLQueryItem(name: "select", value: SupabaseProfileRecord.selectList),
                URLQueryItem(name: "id", value: "in.\(SupabaseQueryList.uuidValues(ids))"),
                URLQueryItem(name: "limit", value: "\(max(ids.count, 1))")
            ]
        )
    }

    func fetchSuggestedProfiles(excluding ids: [UUID]) async throws -> [SupabaseProfileRecord] {
        guard !ids.isEmpty else {
            return try await fetchProfiles(
                queryItems: [
                    URLQueryItem(name: "select", value: SupabaseProfileRecord.selectList),
                    URLQueryItem(name: "order", value: "created_at.desc"),
                    URLQueryItem(name: "limit", value: "12")
                ]
            )
        }

        return try await fetchProfiles(
            queryItems: [
                URLQueryItem(name: "select", value: SupabaseProfileRecord.selectList),
                URLQueryItem(name: "id", value: "not.in.\(SupabaseQueryList.uuidValues(ids))"),
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "12")
            ]
        )
    }

    /// Fetch every friendship row (accepted, pending, blocked, etc.) that
    /// involves the given user. The bootstrap uses this to build the friend
    /// list, the incoming/outgoing request inboxes, and the blocked set from
    /// a single round trip.
    func fetchAllFriendships(for userID: UUID) async throws -> [SupabaseStoredFriendshipRecord] {
        try await sendRest(
            path: "friendships",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "select", value: SupabaseStoredFriendshipRecord.selectList),
                URLQueryItem(
                    name: "or",
                    value: "(user_id.eq.\(userID.uuidString.lowercased()),friend_id.eq.\(userID.uuidString.lowercased()))"
                ),
                URLQueryItem(name: "limit", value: "500")
            ],
            responseType: [SupabaseStoredFriendshipRecord].self
        )
    }

    func fetchFriendship(from userID: UUID, to friendID: UUID) async throws -> SupabaseStoredFriendshipRecord? {
        let rows: [SupabaseStoredFriendshipRecord] = try await sendRest(
            path: "friendships",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "select", value: SupabaseStoredFriendshipRecord.selectList),
                URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString.lowercased())"),
                URLQueryItem(name: "friend_id", value: "eq.\(friendID.uuidString.lowercased())"),
                URLQueryItem(name: "limit", value: "1")
            ],
            responseType: [SupabaseStoredFriendshipRecord].self
        )
        return rows.first
    }

    func updateFriendshipStatus(_ id: UUID, to status: String) async throws {
        try await sendRestWithoutResponse(
            path: "friendships",
            method: "PATCH",
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")
            ],
            prefer: "return=minimal",
            body: SupabaseFriendshipStatusPatch(status: status)
        )
    }

    /// Cached set of reserved usernames. Reservations rarely change, so we
    /// fetch once per session and fall back to a compiled-in set if the DB
    /// isn't reachable (e.g. during the initial network blip after launch).
    private static var reservedUsernameCache: Set<String>?
    private static let reservedUsernameFallback: Set<String> = [
        "admin", "support", "help", "moderator", "outagain", "out_again",
        "team", "staff", "owner", "root", "api", "null", "undefined"
    ]

    func fetchReservedUsernames() async throws -> Set<String> {
        if let cached = Self.reservedUsernameCache { return cached }

        struct Row: Decodable { var username: String }
        do {
            let rows: [Row] = try await sendRest(
                path: "reserved_usernames",
                method: "GET",
                queryItems: [URLQueryItem(name: "select", value: "username")],
                responseType: [Row].self
            )
            let set = Set(rows.map { $0.username.lowercased() })
            Self.reservedUsernameCache = set
            return set
        } catch {
            return Self.reservedUsernameFallback
        }
    }

    /// Hit a Supabase auth endpoint that doesn't need a body (logout).
    func postAuth(path: String) async throws {
        try await ensureAuthenticatedSession()
        var request = try makeRequest(
            url: environment.authURL(path: path),
            method: "POST",
            authenticated: true
        )
        request.httpBody = Data("{}".utf8)
        _ = try await perform(request)
    }

    /// Feed query. After the RLS tightening in migration 0004, the database
    /// will only return rows the viewer is allowed to see — but passing an
    /// explicit author_id IN (...) filter avoids a full table scan and keeps
    /// the query plan cheap as the dataset grows. If no author IDs are
    /// provided (e.g. a new user with zero friends) we fall back to a
    /// self-only filter so we still return the user's own posts.
    func fetchFeedPosts(authorIDs: [UUID], limit: Int) async throws -> [SupabaseFeedPostRecord] {
        let sanitized = Array(Set(authorIDs))
        guard !sanitized.isEmpty else { return [] }

        return try await sendRest(
            path: "posts",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "select", value: SupabaseFeedPostRecord.selectList),
                URLQueryItem(name: "author_id", value: "in.\(SupabaseQueryList.uuidValues(sanitized))"),
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ],
            responseType: [SupabaseFeedPostRecord].self
        )
    }

    /// Non-throwing wrapper around `fetchTonightFeed` — returns an empty array
    /// on failure so it can be used inside an `async let` fan-out without
    /// requiring a try/catch at the call site.
    func fetchTonightFeedOrEmpty(viewerID: UUID, limit: Int) async -> [SupabaseFeedPostRecord] {
        (try? await fetchTonightFeed(viewerID: viewerID, limit: limit)) ?? []
    }

    /// Calls the `tonight_feed` RPC — returns posts within a 20-hour window
    /// for the viewer's friend + FoF graph. One server-side query instead of
    /// the client assembling and sending a large `author_id IN (...)` list.
    ///
    /// Throws on failure so `loadAppData` can fall back to the direct
    /// `fetchFeedPosts` query rather than silently returning an empty feed.
    func fetchTonightFeed(viewerID: UUID, limit: Int) async throws -> [SupabaseFeedPostRecord] {
        try await sendRest(
            path: "rpc/tonight_feed",
            method: "POST",
            body: SupabaseTonightFeedRequest(viewer_id: viewerID, lim: limit)
        )
    }

    func fetchComments(for postIDs: [UUID]) async throws -> [SupabaseFeedCommentRecord] {
        guard !postIDs.isEmpty else { return [] }
        // Cap at 5 comments per post on bootstrap (covers the visible preview)
        // with a hard ceiling of 150. Full comment threads load lazily when the
        // user opens a post detail view — no need to pull hundreds of rows on
        // every bootstrap just to show a count.
        let limit = min(postIDs.count * 5, 150)
        return try await sendRest(
            path: "comments",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "select", value: SupabaseFeedCommentRecord.selectList),
                URLQueryItem(name: "post_id", value: "in.\(SupabaseQueryList.uuidValues(postIDs))"),
                URLQueryItem(name: "order", value: "created_at.asc"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ],
            responseType: [SupabaseFeedCommentRecord].self
        )
    }

    func fetchAllComments(for postID: UUID) async throws -> [SupabaseFeedCommentRecord] {
        try await sendRest(
            path: "comments",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "select", value: SupabaseFeedCommentRecord.selectList),
                URLQueryItem(name: "post_id", value: "eq.\(postID.uuidString.lowercased())"),
                URLQueryItem(name: "order", value: "created_at.asc"),
                URLQueryItem(name: "limit", value: "500")
            ],
            responseType: [SupabaseFeedCommentRecord].self
        )
    }

    func fetchReactions(for postIDs: [UUID]) async throws -> [SupabaseFeedReactionRecord] {
        guard !postIDs.isEmpty else { return [] }
        // Reactions are shown as summary counts + a short reactor list in the
        // sheet view. 10 reactors per post covers the display comfortably;
        // capped at 200 so a single viral post can't balloon egress.
        let limit = min(postIDs.count * 10, 200)
        return try await sendRest(
            path: "reactions",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "select", value: SupabaseFeedReactionRecord.selectList),
                URLQueryItem(name: "post_id", value: "in.\(SupabaseQueryList.uuidValues(postIDs))"),
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ],
            responseType: [SupabaseFeedReactionRecord].self
        )
    }

    func fetchAllReactions(for postID: UUID, kind: ReactionKind? = nil) async throws -> [SupabaseFeedReactionRecord] {
        var queryItems = [
            URLQueryItem(name: "select", value: SupabaseFeedReactionRecord.selectList),
            URLQueryItem(name: "post_id", value: "eq.\(postID.uuidString.lowercased())"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "500")
        ]
        if let kind {
            queryItems.append(URLQueryItem(name: "kind", value: "eq.\(kind.rawValue)"))
        }
        return try await sendRest(
            path: "reactions",
            method: "GET",
            queryItems: queryItems,
            responseType: [SupabaseFeedReactionRecord].self
        )
    }

    func fetchPostEngagement(for postIDs: [UUID]) async throws -> [SupabasePostEngagementRecord] {
        guard !postIDs.isEmpty else { return [] }
        return try await sendRest(
            path: "rpc/post_engagement_counts",
            method: "POST",
            body: SupabasePostIDsRequest(post_ids: postIDs)
        )
    }

    /// Non-throwing: returns an empty array on failure so the FoF tab being
    /// unavailable never breaks the whole bootstrap.
    func fetchFriendOfFriendIDs(for userID: UUID) async throws -> [SupabaseFriendOfFriendIDResponse] {
        (try? await sendRest(
            path: "rpc/friends_of_friends_ids",
            method: "POST",
            body: SupabaseViewerIDRequest(viewer_id: userID)
        )) ?? []
    }

    func fetchNotifications(limit: Int) async throws -> [SupabaseNotificationRecord] {
        let userID = try currentUserID()
        return try await sendRest(
            path: "notifications",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "select", value: SupabaseNotificationRecord.selectList),
                URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString.lowercased())"),
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ],
            responseType: [SupabaseNotificationRecord].self
        )
    }

    /// Delta poll: fetch notifications newer than `since`, with actor profile
    /// embedded via PostgREST join so no second round-trip is needed.
    func fetchNewNotifications(since: Date) async throws -> [AppNotification] {
        let userID = try currentUserID()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let sinceStr = iso.string(from: since)

        // Embed actor profile fields inline using PostgREST resource embedding.
        // The join is notification.actor_id -> profiles.id.
        let selectWithActor = "id,kind,title,detail,created_at,read_at,actor_id,post_id,comment_id,actor:profiles!notifications_actor_id_fkey(id,username,display_name,avatar_path,avatar_version)"

        let records: [SupabaseNotificationWithActorRecord] = try await sendRest(
            path: "notifications",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "select", value: selectWithActor),
                URLQueryItem(name: "user_id", value: "eq.\(userID.uuidString.lowercased())"),
                URLQueryItem(name: "created_at", value: "gte.\(sinceStr)"),
                URLQueryItem(name: "order", value: "created_at.desc"),
                URLQueryItem(name: "limit", value: "20")
            ],
            responseType: [SupabaseNotificationWithActorRecord].self
        )

        return records.map { record in
            let actorProfile = record.actor.map { a in
                UserProfile(
                    id: a.id,
                    displayName: a.display_name,
                    username: a.username ?? "",
                    avatar: AvatarStyle(
                        symbol: "person.fill",
                        primaryHex: "#8B5CF6",
                        secondaryHex: "#1E1B2E",
                        imageData: nil,
                        remoteURL: a.avatar_path.map {
                            environment.storageObjectURL(
                                bucket: environment.avatarBucket,
                                objectPath: $0,
                                isPublic: true
                            )
                        }
                    ),
                    isCloseFriend: false
                )
            }
            return AppNotification(
                id: record.id,
                kind: record.notificationKind,
                title: record.title,
                detail: record.detail,
                createdAt: record.created_at,
                isRead: record.read_at != nil,
                actor: actorProfile,
                postID: record.post_id,
                commentID: record.comment_id
            )
        }
    }

    func fetchNewFeedPostRecords(since: Date, limit: Int) async throws -> [SupabaseFeedPostRecord] {
        try await sendRest(
            path: "rpc/new_feed_posts",
            method: "POST",
            body: SupabaseSinceCursorRequest(since: since, lim: limit)
        )
    }

    func uploadProfileImageIfNeeded(data: Data?, userID: UUID) async throws -> String? {
        guard let data, !data.isEmpty else { return nil }
        // Compress avatar before upload: max 400 px, quality 0.82.
        // Raw iPhone avatars can be 3–8 MB; compressed output is ~30–80 KB.
        let compressed = await Task.detached(priority: .userInitiated) {
            ImageCompressor.avatar(from: data)
        }.value
        #if DEBUG
        ImageCompressor.logRatio(original: data, compressed: compressed, label: "avatar")
        #endif
        let objectPath = "users/\(userID.uuidString.lowercased())/avatar.jpg"
        return try await uploadObject(
            data: compressed,
            bucket: environment.avatarBucket,
            objectPath: objectPath,
            contentType: "image/jpeg"
        )
    }

    func resolveAvatarPath(
        preferredImageData: Data?,
        userID: UUID,
        knownCurrentPath: String? = nil
    ) async throws -> String? {
        if let preferredImageData, !preferredImageData.isEmpty {
            return try await uploadProfileImageIfNeeded(data: preferredImageData, userID: userID)
        }
        // Use the caller-supplied path when the avatar isn't changing.
        // This eliminates the fetchCurrentProfile() round-trip that was
        // previously needed to discover the existing path — saving one DB
        // call on every profile edit where the user only changes display name
        // or username without touching their avatar photo.
        if let knownCurrentPath {
            return knownCurrentPath
        }
        // Last resort: fetch from DB. Only hits this path for legacy call
        // sites that don't pass a known path.
        return try await fetchCurrentProfile()?.avatar_path
    }

    func uploadMomentImageIfNeeded(data: Data?, authorID: UUID) async throws -> String? {
        guard let data, !data.isEmpty else { return nil }
        // Compress to display quality before upload.
        // iPhone photos can be 6–12 MB; 1080 px / 0.80 JPEG ≈ 150–350 KB.
        let compressed = await Task.detached(priority: .userInitiated) {
            ImageCompressor.feedDisplay(from: data)
        }.value
        #if DEBUG
        ImageCompressor.logRatio(original: data, compressed: compressed, label: "moment")
        ImageCompressor.assertAspectRatioPreserved(original: data, compressed: compressed, label: "moment")
        #endif
        let objectPath = "posts/\(authorID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
        return try await uploadObject(
            data: compressed,
            bucket: environment.storageBucket,
            objectPath: objectPath,
            contentType: "image/jpeg"
        )
    }

    func uploadCommentImageIfNeeded(data: Data?, authorID: UUID) async throws -> String? {
        guard let data, !data.isEmpty else { return nil }
        if data.isGIF {
            let objectPath = "comments/\(authorID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).gif"
            return try await uploadObject(
                data: data,
                bucket: environment.storageBucket,
                objectPath: objectPath,
                contentType: "image/gif"
            )
        } else {
            // Comment photo replies — medium compression, small enough for inline display.
            let compressed = await Task.detached(priority: .userInitiated) {
                ImageCompressor.commentPhoto(from: data)
            }.value
            #if DEBUG
            ImageCompressor.logRatio(original: data, compressed: compressed, label: "comment")
            ImageCompressor.assertAspectRatioPreserved(original: data, compressed: compressed, label: "comment")
            #endif
            let objectPath = "comments/\(authorID.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
            return try await uploadObject(
                data: compressed,
                bucket: environment.storageBucket,
                objectPath: objectPath,
                contentType: "image/jpeg"
            )
        }
    }

    func uploadObject(
        data: Data,
        bucket: String,
        objectPath: String,
        contentType: String
    ) async throws -> String {
        var request = try makeRequest(
            url: environment.storageObjectURL(bucket: bucket, objectPath: objectPath),
            method: "POST",
            authenticated: true,
            contentType: contentType,
            timeoutInterval: 60
        )
        request.httpBody = data
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        request.setValue("public, max-age=31536000, immutable", forHTTPHeaderField: "Cache-Control")
        _ = try await perform(request)
        return objectPath
    }

    func sendAuth<Response: Decodable, Body: Encodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Body
    ) async throws -> Response {
        var request = try makeRequest(
            url: environment.authURL(path: path, queryItems: queryItems),
            method: "POST",
            authenticated: false
        )
        request.httpBody = try encode(body)
        let data = try await perform(request)
        return try decode(Response.self, from: data)
    }

    func sendRest<Response: Decodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        responseType: Response.Type
    ) async throws -> Response {
        try await ensureAuthenticatedSession()
        let request = try makeRequest(
            url: environment.restURL(path: path, queryItems: queryItems),
            method: method,
            authenticated: true
        )
        let data = try await perform(request)
        return try decode(Response.self, from: data)
    }

    func sendRest<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        prefer: String? = nil,
        body: Body
    ) async throws -> Response {
        try await ensureAuthenticatedSession()
        var request = try makeRequest(
            url: environment.restURL(path: path, queryItems: queryItems),
            method: method,
            authenticated: true
        )
        request.httpBody = try encode(body)
        if let prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }

        let data = try await perform(request)
        return try decode(Response.self, from: data)
    }

    func sendRestWithoutResponse<Body: Encodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        prefer: String? = nil,
        body: Body
    ) async throws {
        try await ensureAuthenticatedSession()
        var request = try makeRequest(
            url: environment.restURL(path: path, queryItems: queryItems),
            method: method,
            authenticated: true
        )
        request.httpBody = try encode(body)
        if let prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        _ = try await perform(request)
    }

    func sendFunctionWithoutResponse<Body: Encodable>(
        name: String,
        method: String = "POST",
        body: Body,
        timeoutInterval: TimeInterval = 30
    ) async throws {
        try await ensureAuthenticatedSession()
        var request = try makeRequest(
            url: environment.functionURL(name: name),
            method: method,
            authenticated: true,
            timeoutInterval: timeoutInterval
        )
        request.httpBody = try encode(body)
        _ = try await perform(request)
    }

    func deleteRest(
        path: String,
        queryItems: [URLQueryItem] = [],
        prefer: String? = "return=minimal"
    ) async throws {
        try await ensureAuthenticatedSession()
        var request = try makeRequest(
            url: environment.restURL(path: path, queryItems: queryItems),
            method: "DELETE",
            authenticated: true
        )
        if let prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        _ = try await perform(request)
    }

    func deleteRest<Response: Decodable>(
        path: String,
        queryItems: [URLQueryItem] = [],
        prefer: String? = "return=representation",
        responseType: Response.Type
    ) async throws -> Response {
        try await ensureAuthenticatedSession()
        var request = try makeRequest(
            url: environment.restURL(path: path, queryItems: queryItems),
            method: "DELETE",
            authenticated: true
        )
        if let prefer {
            request.setValue(prefer, forHTTPHeaderField: "Prefer")
        }
        let data = try await perform(request)
        return try decode(Response.self, from: data)
    }

    func makeRequest(
        url: URL,
        method: String,
        authenticated: Bool,
        contentType: String = "application/json",
        timeoutInterval: TimeInterval = 15
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeoutInterval
        request.setValue(environment.anonKey, forHTTPHeaderField: "apikey")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if authenticated {
            guard let accessToken = authSession?.access_token else {
                throw SupabaseBackendError.notAuthenticated
            }
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        return request
    }

    func perform(_ request: URLRequest, source: String = #function) async throws -> Data {
        let start = Date()
        let (data, response): (Data, URLResponse)

        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw SupabaseBackendError.transport(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseBackendError.invalidResponse
        }

        // ── Logging ──────────────────────────────────────────────────────
        // Records every Supabase call through this single choke point.
        // Filter Xcode console by "SUPA" to see the log. Disable in
        // release by setting SupabaseCallLogger.isEnabled = false.
        let durationMs = Date().timeIntervalSince(start) * 1000
        if let url = request.url {
            SupabaseCallLogger.shared.record(
                method: request.httpMethod ?? "GET",
                url: url,
                source: source,
                durationMs: durationMs,
                statusCode: httpResponse.statusCode
            )
        }
        // ─────────────────────────────────────────────────────────────────

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw decodeErrorResponse(from: data, statusCode: httpResponse.statusCode)
        }

        return data
    }

    func encode<Body: Encodable>(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(SupabaseDateCoder.iso8601Formatter.string(from: date))
        }

        do {
            return try encoder.encode(body)
        } catch {
            throw SupabaseBackendError.transport(error.localizedDescription)
        }
    }

    func decode<Response: Decodable>(_ type: Response.Type, from data: Data) throws -> Response {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let value = try container.decode(String.self)

                if let date = SupabaseDateCoder.iso8601Formatter.date(from: value)
                    ?? SupabaseDateCoder.iso8601FormatterWithoutFractions.date(from: value) {
                    return date
                }

                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(value)"
                )
            }
            return try decoder.decode(type, from: data)
        } catch {
            throw SupabaseBackendError.transport(error.localizedDescription)
        }
    }

    func decodeErrorResponse(from data: Data, statusCode: Int) -> SupabaseBackendError {
        if let errorEnvelope = try? JSONDecoder().decode(SupabaseErrorEnvelope.self, from: data) {
            let message = errorEnvelope.message
                ?? errorEnvelope.error_description
                ?? errorEnvelope.msg
                ?? errorEnvelope.error
                ?? "Request failed."
            return .requestFailed(message, statusCode: statusCode)
        }

        if let rawMessage = String(data: data, encoding: .utf8), !rawMessage.isEmpty {
            return .requestFailed(rawMessage, statusCode: statusCode)
        }

        return .requestFailed("Request failed.", statusCode: statusCode)
    }

    func makeUserProfile(
        from profile: SupabaseProfileRecord,
        preferredImageData: Data?,
        isCloseFriend: Bool
    ) -> UserProfile {
        // A profile row without a username is a shell created by the
        // on_auth_user_created trigger. We fall back to placeholder values so
        // the struct is well-formed while the client guides the user through
        // onboarding to finish it.
        let resolvedUsername = profile.username ?? ""
        let resolvedDisplayName = profile.display_name ?? resolvedUsername

        return UserProfile(
            id: profile.id,
            displayName: resolvedDisplayName,
            username: resolvedUsername,
            avatar: makeAvatarStyle(
                username: resolvedUsername,
                imageData: preferredImageData,
                avatarPath: profile.avatar_path,
                avatarVersion: profile.avatar_version
            ),
            isCloseFriend: isCloseFriend
        )
    }

    func makeAvatarStyle(username: String, imageData: Data?, avatarPath: String?, avatarVersion: Int?) -> AvatarStyle {
        let palettes: [(String, String)] = [
            ("#D98B3D", "#281916"),
            ("#5BB3E6", "#0F2532"),
            ("#A55AE6", "#241235"),
            ("#E56783", "#341421"),
            ("#53C38C", "#10291F")
        ]
        let symbols = [
            "moon.stars.fill",
            "sparkles",
            "camera.aperture",
            "person.2.fill",
            "location.north.fill"
        ]
        let seed = username.unicodeScalars.map(\.value).reduce(0, +)
        let palette = palettes[Int(seed % UInt32(palettes.count))]
        let symbol = symbols[Int(seed % UInt32(symbols.count))]

        let remoteURL = avatarPath.map { path -> URL in
            let baseURL = environment.storageObjectURL(
                bucket: environment.avatarBucket,
                objectPath: path,
                isPublic: true
            )
            // Append ?v=<version> so CDNs and NSURLCache fetch a fresh copy
            // whenever avatar_version bumps (i.e. whenever avatar_path changes).
            guard let version = avatarVersion,
                  var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                return baseURL
            }
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "v", value: String(version)))
            components.queryItems = items
            return components.url ?? baseURL
        }

        return AvatarStyle(
            symbol: symbol,
            primaryHex: palette.0,
            secondaryHex: palette.1,
            imageData: imageData,
            remoteURL: remoteURL
        )
    }

    func makeMomentPost(
        from record: SupabaseFeedPostRecord,
        author: UserProfile,
        taggedFriends: [UserProfile],
        comments: [Comment],
        commentCount: Int,
        hasLoadedFullCommentThread: Bool,
        reactions: [ReactionSummary],
        viewerReactionKinds: Set<ReactionKind>,
        fullyLoadedReactionKinds: Set<ReactionKind>
    ) -> MomentPost {
        let venue = record.venue_name.flatMap { venueName -> Venue? in
            guard let latitude = record.venue_latitude, let longitude = record.venue_longitude else { return nil }
            return Venue(
                id: stableUUID(seed: "venue|\(venueName)|\(latitude)|\(longitude)"),
                name: venueName,
                neighborhood: record.venue_neighborhood ?? "",
                city: record.venue_city ?? "",
                latitude: latitude,
                longitude: longitude
            )
        }

        let location: LocationSnapshot? = {
            guard let latitude = record.latitude,
                  let longitude = record.longitude,
                  let horizontalAccuracy = record.horizontal_accuracy else {
                return nil
            }

            return LocationSnapshot(
                latitude: latitude,
                longitude: longitude,
                horizontalAccuracy: horizontalAccuracy,
                capturedAt: record.created_at
            )
        }()

        let media = MomentMedia(
            photoData: nil,
            remotePhotoURL: record.image_path.map {
                environment.storageObjectURL(
                    bucket: environment.storageBucket,
                    objectPath: $0,
                    isPublic: true
                )
            },
            primaryHex: record.drink_primary_hex,
            secondaryHex: record.drink_secondary_hex,
            symbol: record.drink_symbol
        )

        return MomentPost(
            id: record.id,
            author: author,
            drink: DrinkTag(
                id: stableUUID(seed: "drink|\(record.drink_name)|\(record.drink_subtitle)|\(record.drink_symbol)"),
                name: record.drink_name,
                subtitle: record.drink_subtitle,
                symbol: record.drink_symbol,
                imageName: DrinkTag.resolvedImageName(for: record.drink_name),
                primaryHex: record.drink_primary_hex,
                secondaryHex: record.drink_secondary_hex
            ),
            venue: venue,
            location: location,
            caption: record.caption,
            createdAt: record.created_at,
            taggedFriends: taggedFriends,
            isSharedMoment: record.is_shared_moment,
            media: media,
            reactions: reactions,
            viewerReactionKinds: viewerReactionKinds,
            comments: comments,
            commentCount: commentCount,
            hasLoadedFullCommentThread: hasLoadedFullCommentThread,
            fullyLoadedReactionKinds: fullyLoadedReactionKinds,
            presenceNote: taggedFriends.isEmpty ? nil : "\(taggedFriends.first?.displayName ?? "Friends") is in the post",
            connectionPath: nil,
            contextReason: venue == nil ? "Live right now" : "Checked in"
        )
    }

    func makeNotification(
        from record: SupabaseNotificationRecord,
        profileMap: [UUID: UserProfile]
    ) -> AppNotification {
        AppNotification(
            id: record.id,
            kind: record.notificationKind,
            title: record.title,
            detail: record.detail,
            createdAt: record.created_at,
            isRead: record.read_at != nil,
            actor: record.actor_id.flatMap { profileMap[$0] },
            postID: record.post_id,
            commentID: record.comment_id
        )
    }

    func persistSession(_ session: SupabaseAuthSession) {
        var session = session
        if session.expires_at == nil, let expiresIn = session.expires_in {
            session.expires_at = Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970
        }

        authSession = session

        guard let data = try? JSONEncoder().encode(session) else { return }

        // Write on the main thread to avoid a race where the app is suspended
        // mid-write from a background Task, which can corrupt the UserDefaults
        // plist and cause loadStoredSession() to return nil on the next launch.
        // Also synchronize() immediately so the OS flushes to disk before a
        // possible force-quit — without this, in-memory changes can be lost.
        DispatchQueue.main.async {
            UserDefaults.standard.set(data, forKey: SessionStorage.key)
            UserDefaults.standard.synchronize()
        }
    }

    func clearSession() {
        authSession = nil
        DispatchQueue.main.async {
            UserDefaults.standard.removeObject(forKey: SessionStorage.key)
            UserDefaults.standard.synchronize()
        }
    }

    static func loadStoredSession() -> SupabaseAuthSession? {
        guard let data = UserDefaults.standard.data(forKey: SessionStorage.key) else { return nil }
        return try? JSONDecoder().decode(SupabaseAuthSession.self, from: data)
    }

    func stableUUID(seed: String) -> UUID {
        let digest = SHA256.hash(data: Data(seed.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let part1 = String(hex.prefix(8))
        let part2 = String(hex.dropFirst(8).prefix(4))
        let part3 = String(hex.dropFirst(12).prefix(4))
        let part4 = String(hex.dropFirst(16).prefix(4))
        let part5 = String(hex.dropFirst(20).prefix(12))
        let formatted = [part1, part2, part3, part4, part5].joined(separator: "-")
        return UUID(uuidString: formatted) ?? UUID()
    }
}

private extension Data {
    var isGIF: Bool {
        prefix(6).starts(with: [0x47, 0x49, 0x46, 0x38])
    }
}
