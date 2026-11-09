import Foundation

extension SupabaseSocialBackendClient {
    private static let commentMentionRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])@([A-Za-z0-9_]{3,20})"#,
        options: []
    )

    private static func mentionedUsernames(in text: String) -> [String] {
        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = commentMentionRegex.matches(in: text, options: [], range: nsRange)

        var usernames: [String] = []
        var seen = Set<String>()

        for match in matches {
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else { continue }

            let normalized = UsernameRules.normalized(String(text[range]))
            guard UsernameRules.isValid(normalized), seen.insert(normalized).inserted else { continue }
            usernames.append(normalized)
        }

        return usernames
    }

    private func resolveMentionedUserIDs(in text: String, excluding actorID: UUID) async -> [UUID] {
        let usernames = Self.mentionedUsernames(in: text)
        guard !usernames.isEmpty else { return [] }

        let records = (try? await fetchProfilesByUsernames(usernames)) ?? []
        let idsByUsername: [String: UUID] = Dictionary(
            uniqueKeysWithValues: records.compactMap { record in
                guard let username = record.username else { return nil }
                return (UsernameRules.normalized(username), record.id)
            }
        )

        var resolvedIDs: [UUID] = []
        var seen = Set<UUID>()

        for username in usernames {
            guard let id = idsByUsername[username],
                  id != actorID,
                  seen.insert(id).inserted
            else { continue }
            resolvedIDs.append(id)
        }

        return resolvedIDs
    }

    func publishMoment(_ request: MomentCreateRequest) async throws -> MomentPost {
        guard try currentUserID() == request.author.id else {
            throw SupabaseBackendError.notAuthenticated
        }
        // An earlier attempt may have committed even if its response was lost.
        // Check the stable draft ID before uploading or inserting again.
        if let existing = try await fetchFeedPost(id: request.id) {
            return try confirmedDraftPost(existing, request: request)
        }
        let imagePath = try await uploadMomentImageIfNeeded(
            data: request.media.photoData,
            authorID: request.author.id,
            postID: request.id
        )

        let payload = [
            SupabasePostRecord(
                id: request.id,
                is_shared_locally: request.shareLocally,
                author_id: request.author.id,
                drink_name: request.drink?.name ?? "",
                drink_subtitle: request.drink?.subtitle ?? "",
                drink_symbol: request.drink?.symbol ?? "",
                drink_primary_hex: request.drink?.primaryHex ?? "#2A1815",
                drink_secondary_hex: request.drink?.secondaryHex ?? "#B86831",
                venue_name: request.venue?.name,
                venue_neighborhood: request.venue?.neighborhood,
                venue_city: request.venue?.city,
                venue_latitude: request.venue?.latitude,
                venue_longitude: request.venue?.longitude,
                latitude: request.location?.latitude,
                longitude: request.location?.longitude,
                horizontal_accuracy: request.location?.horizontalAccuracy,
                caption: request.caption,
                image_path: imagePath,
                tagged_user_ids: request.taggedFriends.map(\.id),
                is_shared_moment: request.isSharedMoment
            )
        ]

        do {
            let inserted: [SupabaseFeedPostRecord] = try await sendRest(
                path: "posts", method: "POST",
                queryItems: [URLQueryItem(name: "on_conflict", value: "id")],
                prefer: "resolution=ignore-duplicates,return=representation", body: payload
            )
            if let record = inserted.first {
                return try confirmedDraftPost(record, request: request)
            }
            // A concurrent attempt won the insert. Return the actual saved row.
            guard let existing = try await fetchFeedPost(id: request.id) else {
                throw SupabaseBackendError.invalidResponse
            }
            return try confirmedDraftPost(existing, request: request)
        } catch {
            // Resolve an ambiguous timeout from authoritative server state.
            if let existing = try? await fetchFeedPost(id: request.id) {
                return try confirmedDraftPost(existing, request: request)
            }
            throw error
        }
    }

    private func confirmedDraftPost(_ record: SupabaseFeedPostRecord, request: MomentCreateRequest) throws -> MomentPost {
        guard record.id == request.id, record.author_id == request.author.id else {
            throw SupabaseBackendError.invalidResponse
        }
        var post = makeMomentPost(
            from: record, author: request.author,
            taggedFriends: request.taggedFriends.filter { record.tagged_user_ids.contains($0.id) },
            comments: [], commentCount: 0, hasLoadedFullCommentThread: false,
            reactions: [], viewerReactionKinds: [], fullyLoadedReactionKinds: []
        )
        post.media.photoData = request.media.photoData
        post.media.photoAspectRatio = request.media.photoAspectRatio
        return post
    }

    func deletePost(_ post: MomentPost, by _: UserProfile) async throws {
        try await sendRestWithoutResponse(
            path: "rpc/delete_own_post",
            method: "POST",
            body: SupabaseDeletePostRequest(target_post_id: post.id)
        )
    }

    func deletePostMedia(_ post: MomentPost) async {
        let imagePaths = [post.media.remotePhotoURL]
            .compactMap { $0.flatMap(extractStoragePath(from:)) }
        let commentImagePaths = post.comments
            .compactMap { $0.remotePhotoURL.flatMap(extractStoragePath(from:)) }

        for imagePath in Set(imagePaths + commentImagePaths) {
            await deleteObject(bucket: environment.storageBucket, objectPath: imagePath)
        }
    }

    func deleteCommentMedia(_ comment: Comment) async {
        if let imagePath = comment.remotePhotoURL.flatMap({ extractStoragePath(from: $0) }) {
            await deleteObject(bucket: environment.storageBucket, objectPath: imagePath)
        }
    }

    func recordReaction(_ kind: ReactionKind, to post: MomentPost, by viewer: UserProfile) async throws -> OutboundNotificationDelivery? {
        guard ReactionKind.allCases.contains(kind) else { return nil }
        let payload = [
            SupabaseReactionRecord(
                post_id: post.id,
                user_id: viewer.id,
                kind: kind.rawValue
            )
        ]

        try await sendRestWithoutResponse(
            path: "reactions",
            method: "POST",
            queryItems: [URLQueryItem(name: "on_conflict", value: "post_id,user_id,kind")],
            prefer: "resolution=merge-duplicates,return=minimal",
            body: payload
        )

        guard post.author.id != viewer.id else { return nil }

        let notificationTitle = "\(viewer.displayName) liked your post"
        let notificationDetail = "\(viewer.displayName) liked your \(post.drink.map { "\($0.name) " } ?? "")post."

        return OutboundNotificationDelivery(
            id: UUID(),
            recipient: post.author,
            kind: .reaction,
            title: notificationTitle,
            detail: notificationDetail,
            createdAt: .now
        )
    }

    func removeReaction(_ kind: ReactionKind, from post: MomentPost, by viewer: UserProfile) async throws {
        try await deleteRest(
            path: "reactions",
            queryItems: [
                URLQueryItem(name: "post_id", value: "eq.\(post.id.uuidString.lowercased())"),
                URLQueryItem(name: "user_id", value: "eq.\(viewer.id.uuidString.lowercased())"),
                URLQueryItem(name: "kind", value: "eq.\(kind.rawValue)")
            ]
        )
    }

    func deleteReactionNotification(_ kind: ReactionKind, on post: MomentPost, by actor: UserProfile) async throws {
        // Deletes the notification row sent to the post author when this actor
        // reacted. Matched on actor_id + post_id + kind so we only remove the
        // exact notification that the unlike is reversing — nothing else.
        // NotificationKind.reaction.rawValue == "reaction" matches what
        // the edge function inserts when recordReaction fires.
        try await deleteRest(
            path: "notifications",
            queryItems: [
                URLQueryItem(name: "actor_id", value: "eq.\(actor.id.uuidString.lowercased())"),
                URLQueryItem(name: "post_id", value: "eq.\(post.id.uuidString.lowercased())"),
                URLQueryItem(name: "kind", value: "eq.\(NotificationKind.reaction.rawValue)")
            ]
        )
    }

    func recordComment(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws -> OutboundNotificationDelivery? {
        let mentionedUserIDs = await resolveMentionedUserIDs(in: comment.text, excluding: viewer.id)
        let imagePath = try await uploadCommentImageIfNeeded(
            data: comment.photoData,
            authorID: viewer.id
        )

        let payload = [
            SupabaseCommentRecord(
                id: comment.id,
                post_id: post.id,
                author_id: viewer.id,
                body: comment.text,
                kind: comment.kind.databaseValue,
                image_path: imagePath,
                reply_to_comment_id: comment.replyToCommentID,
                mentioned_user_ids: mentionedUserIDs
            )
        ]

        try await sendRestWithoutResponse(
            path: "comments",
            method: "POST",
            prefer: "return=minimal",
            body: payload
        )

        guard post.author.id != viewer.id else { return nil }

        // Insert a notification row directly so the post author sees it on
        // their next poll cycle (and gets a push via the server-side trigger).
        // We use on_conflict=ignore so duplicate taps don't create extra rows.
        let notifKind: NotificationKind = comment.kind == .photo ? .photoReply : .comment
        let notifDetail = comment.text.isEmpty ? "Sent a photo." : comment.text
        let notifPayload = [
            SupabaseCommentNotificationInsert(
                user_id: post.author.id,
                kind: notifKind.rawValue,
                title: "\(viewer.displayName) commented on your post",
                detail: notifDetail,
                actor_id: viewer.id,
                post_id: post.id,
                comment_id: comment.id
            )
        ]
        try? await sendRestWithoutResponse(
            path: "notifications",
            method: "POST",
            queryItems: [URLQueryItem(name: "on_conflict", value: "actor_id,post_id,comment_id,kind")],
            prefer: "resolution=ignore-duplicates,return=minimal",
            body: notifPayload
        )

        return OutboundNotificationDelivery(
            id: UUID(),
            recipient: post.author,
            kind: notifKind,
            title: "\(viewer.displayName) commented on your post",
            detail: notifDetail,
            createdAt: .now
        )
    }

    func recordCommentLike(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws -> OutboundNotificationDelivery? {
        let payload = [
            SupabaseCommentLikeRecord(
                comment_id: comment.id,
                user_id: viewer.id,
                created_at: nil
            )
        ]

        try await sendRestWithoutResponse(
            path: "comment_likes",
            method: "POST",
            queryItems: [URLQueryItem(name: "on_conflict", value: "comment_id,user_id")],
            prefer: "resolution=merge-duplicates,return=minimal",
            body: payload
        )

        guard comment.author.id != viewer.id else { return nil }

        return OutboundNotificationDelivery(
            id: UUID(),
            recipient: comment.author,
            kind: .commentLike,
            title: "\(viewer.displayName) liked your comment",
            detail: comment.text,
            createdAt: .now
        )
    }

    func removeCommentLike(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws {
        try await deleteRest(
            path: "comment_likes",
            queryItems: [
                URLQueryItem(name: "comment_id", value: "eq.\(comment.id.uuidString.lowercased())"),
                URLQueryItem(name: "user_id", value: "eq.\(viewer.id.uuidString.lowercased())")
            ]
        )
    }

    func deleteCommentLikeNotification(_ comment: Comment, by actor: UserProfile) async throws {
        try await deleteRest(
            path: "notifications",
            queryItems: [
                URLQueryItem(name: "actor_id", value: "eq.\(actor.id.uuidString.lowercased())"),
                URLQueryItem(name: "comment_id", value: "eq.\(comment.id.uuidString.lowercased())"),
                URLQueryItem(name: "kind", value: "eq.\(NotificationKind.commentLike.rawValue)")
            ]
        )
    }

    func deleteComment(_ comment: Comment, on post: MomentPost, by viewer: UserProfile) async throws {
        try await deleteRest(
            path: "comments",
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(comment.id.uuidString.lowercased())"),
                URLQueryItem(name: "post_id", value: "eq.\(post.id.uuidString.lowercased())")
            ]
        )
    }

    func submitContentReport(_ request: ContentReportRequest) async throws {
        let payload = SupabaseContentReportSubmitRequest(
            target_type: request.target.rawValue,
            target_post_id: request.postID,
            target_comment_id: request.commentID,
            target_user_id: request.target == .user ? request.targetUserID : nil,
            detail: normalizedReportField(request.detail, fallback: "", maxLength: 500)
        )

        do {
            try await sendRestWithoutResponse(
                path: "rpc/submit_content_report",
                method: "POST",
                body: payload
            )
        } catch SupabaseBackendError.requestFailed(_, let statusCode) where statusCode == 409 {
            throw SupabaseBackendError.requestFailed(
                "You've already reported this. We'll keep the original report in the queue.",
                statusCode: statusCode
            )
        }
    }

    func markNotificationsRead(_ notificationIDs: [UUID]) async throws {
        guard !notificationIDs.isEmpty else { return }

        try await sendRestWithoutResponse(
            path: "notifications",
            method: "PATCH",
            queryItems: [
                URLQueryItem(name: "id", value: "in.\(SupabaseQueryList.uuidValues(notificationIDs))"),
                URLQueryItem(name: "user_id", value: "eq.\(try currentUserID().uuidString.lowercased())")
            ],
            prefer: "return=minimal",
            body: SupabaseNotificationReadPatch(read_at: Date())
        )
    }

    func deleteNotification(id: UUID) async throws {
        let deleted: [SupabaseInsertedRecord] = try await deleteRest(
            path: "notifications",
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())"),
                URLQueryItem(name: "user_id", value: "eq.\(try currentUserID().uuidString.lowercased())")
            ],
            responseType: [SupabaseInsertedRecord].self
        )
        guard deleted.contains(where: { $0.id == id }) else {
            throw SupabaseBackendError.requestFailed(
                "Couldn't permanently clear that notification.",
                statusCode: 409
            )
        }
    }

    func deleteNotifications(ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }

        let deleted: [SupabaseInsertedRecord] = try await deleteRest(
            path: "notifications",
            queryItems: [
                URLQueryItem(name: "id", value: "in.\(SupabaseQueryList.uuidValues(ids))"),
                URLQueryItem(name: "user_id", value: "eq.\(try currentUserID().uuidString.lowercased())")
            ],
            responseType: [SupabaseInsertedRecord].self
        )
        let deletedIDs = Set(deleted.map(\.id))
        let requestedIDs = Set(ids)
        guard deletedIDs == requestedIDs else {
            throw SupabaseBackendError.requestFailed(
                "Couldn't permanently clear all notifications.",
                statusCode: 409
            )
        }
    }

    // MARK: - Night groups

    func insertGroupNotifications(group: NightGroup, recipientIDs: [UUID], creator: UserProfile) async throws {
        guard !recipientIDs.isEmpty else { return }

        let groupLabel = group.displayName
        let payload = recipientIDs.map { recipientID in
            SupabaseGroupNotificationInsert(
                user_id: recipientID,
                kind: NotificationKind.groupAdded.rawValue,
                title: "\(creator.displayName) added you to a group",
                detail: "You've been added to \"\(groupLabel)\". See who else is out tonight.",
                actor_id: creator.id
            )
        }

        try await sendRestWithoutResponse(
            path: "notifications",
            method: "POST",
            prefer: "return=minimal",
            body: payload
        )
    }

    func createNightGroup(_ group: NightGroup) async throws {
        let payload = SupabaseNightGroupInsert(
            id: group.id,
            name: group.name,
            creator_id: group.creatorID,
            member_ids: group.memberIDs
        )
        try await sendRestWithoutResponse(
            path: "night_groups",
            method: "POST",
            prefer: "return=minimal",
            body: payload
        )
    }

    func renameNightGroup(id: UUID, name: String) async throws {
        do {
            try await sendRestWithoutResponse(
                path: "rpc/rename_night_group",
                method: "POST",
                prefer: "return=minimal",
                body: SupabaseNightGroupRenameRequest(
                    group_id: id,
                    new_name: name
                )
            )
        } catch SupabaseBackendError.requestFailed(let message, let statusCode)
            where statusCode == 404
                || message.localizedCaseInsensitiveContains("rename_night_group")
                || message.localizedCaseInsensitiveContains("function")
        {
            // Backward-compatible fallback for environments that haven't had
            // the rename RPC migration applied yet. If the older row-level
            // update policy is present, this still lets members rename groups.
            let updated: [SupabaseNightGroupRecord] = try await sendRest(
                path: "night_groups",
                method: "PATCH",
                queryItems: [
                    URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")
                ],
                prefer: "return=representation",
                body: SupabaseNightGroupRename(name: name)
            )
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard updated.contains(where: { $0.id == id && $0.name == normalized }) else {
                throw SupabaseBackendError.requestFailed(
                    "Couldn't save group changes. Please try again.",
                    statusCode: 409
                )
            }
        }
    }

    func updateNightGroup(_ group: NightGroup) async throws {
        try await sendRestWithoutResponse(
            path: "rpc/update_night_group",
            method: "POST",
            prefer: "return=minimal",
            body: SupabaseNightGroupUpdateRequest(
                group_id: group.id,
                new_name: group.name,
                new_member_ids: group.memberIDs
            )
        )
    }

    func deleteNightGroup(id: UUID) async throws {
        try await deleteRest(
            path: "night_groups",
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(id.uuidString.lowercased())")
            ]
        )
    }

    func fetchNightGroups(createdAfter windowStart: Date) async throws -> [NightGroup] {
        let windowStr = SupabaseDateCoder.iso8601Formatter.string(from: windowStart)

        let records: [SupabaseNightGroupRecord] = try await sendRest(
            path: "night_groups",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "select", value: SupabaseNightGroupRecord.selectList),
                URLQueryItem(name: "created_at", value: "gte.\(windowStr)"),
                URLQueryItem(name: "order", value: "created_at.asc"),
                // Hard cap: no realistic user creates more than 50 groups in a
                // single night window. Without this PostgREST returns every row
                // that matches the RLS policy, which scales with the user's age.
                URLQueryItem(name: "limit", value: "50")
            ],
            responseType: [SupabaseNightGroupRecord].self
        )
        return records.map { $0.toNightGroup() }
    }
}

private func normalizedReportField(_ value: String, fallback: String, maxLength: Int) -> String {
    let trimmed = value
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\n", with: " ")

    guard !trimmed.isEmpty else { return fallback }
    if trimmed.count <= maxLength { return trimmed }
    return String(trimmed.prefix(maxLength))
}
