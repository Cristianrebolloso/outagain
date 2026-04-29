import Foundation

extension SupabaseSocialBackendClient {
    func publishMoment(_ request: MomentCreateRequest) async throws -> MomentPost {
        let imagePath = try await uploadMomentImageIfNeeded(
            data: request.media.photoData,
            authorID: request.author.id
        )

        let payload = [
            SupabasePostRecord(
                author_id: request.author.id,
                drink_name: request.drink.name,
                drink_subtitle: request.drink.subtitle,
                drink_symbol: request.drink.symbol,
                drink_primary_hex: request.drink.primaryHex,
                drink_secondary_hex: request.drink.secondaryHex,
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

        let insertedPosts: [SupabaseInsertedRecord] = try await sendRest(
            path: "posts",
            method: "POST",
            prefer: "return=representation",
            body: payload
        )

        let postID = insertedPosts.first?.id ?? UUID()
        return MomentPost(
            id: postID,
            author: request.author,
            drink: request.drink,
            venue: request.venue,
            location: request.location,
            caption: request.caption,
            createdAt: .now,
            taggedFriends: request.taggedFriends,
            isSharedMoment: request.isSharedMoment,
            media: MomentMedia(
                photoData: request.media.photoData,
                remotePhotoURL: imagePath.map {
                    environment.storageObjectURL(
                        bucket: environment.storageBucket,
                        objectPath: $0,
                        isPublic: true
                    )
                },
                primaryHex: request.media.primaryHex,
                secondaryHex: request.media.secondaryHex,
                symbol: request.media.symbol
            ),
            reactions: [],
            comments: [],
            commentCount: 0,
            hasLoadedFullCommentThread: true,
            presenceNote: request.taggedFriends.isEmpty ? nil : "\(request.taggedFriends.first?.displayName ?? "Friends") is in the post",
            connectionPath: nil,
            contextReason: request.venue == nil ? "Live right now" : "Just checked in"
        )
    }

    func deletePost(_ post: MomentPost, by viewer: UserProfile) async throws {
        try await deleteRest(
            path: "posts",
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(post.id.uuidString.lowercased())"),
                URLQueryItem(name: "author_id", value: "eq.\(viewer.id.uuidString.lowercased())")
            ]
        )
    }

    func recordReaction(_ kind: ReactionKind, to post: MomentPost, by viewer: UserProfile) async throws -> OutboundNotificationDelivery? {
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

        return OutboundNotificationDelivery(
            id: UUID(),
            recipient: post.author,
            kind: .reaction,
            title: "\(viewer.displayName) liked your post",
            detail: "\(viewer.displayName) liked your \(post.drink.name) post.",
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
                reply_to_comment_id: comment.replyToCommentID
            )
        ]

        try await sendRestWithoutResponse(
            path: "comments",
            method: "POST",
            prefer: "return=minimal",
            body: payload
        )

        guard post.author.id != viewer.id else { return nil }

        return OutboundNotificationDelivery(
            id: UUID(),
            recipient: post.author,
            kind: comment.kind == .photo ? .photoReply : .comment,
            title: "\(viewer.displayName) commented on your post",
            detail: comment.text,
            createdAt: .now
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
        let reporterID = try currentUserID()
        let reporterUsername = try await fetchCurrentProfile()?.username ?? "unknown"

        let payload = [
            SupabaseContentReportInsert(
                reporter_id: reporterID,
                reporter_username: normalizedReportField(reporterUsername, fallback: "unknown", maxLength: 64),
                target_type: request.target.rawValue,
                target_post_id: request.postID,
                target_comment_id: request.commentID,
                target_author_id: request.targetAuthorID,
                target_author_username: normalizedReportField(request.targetAuthorUsername, fallback: "unknown", maxLength: 64),
                target_excerpt: normalizedReportField(request.targetExcerpt, fallback: "(no preview)", maxLength: 240),
                reason: "community_report",
                detail: normalizedReportField(request.detail, fallback: "", maxLength: 500)
            )
        ]

        do {
            try await sendRestWithoutResponse(
                path: "content_reports",
                method: "POST",
                prefer: "return=minimal",
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
        let payload = SupabaseNightGroupUpdate(
            name: group.name,
            member_ids: group.memberIDs
        )
        try await sendRestWithoutResponse(
            path: "night_groups",
            method: "PATCH",
            queryItems: [
                URLQueryItem(name: "id", value: "eq.\(group.id.uuidString.lowercased())")
            ],
            prefer: "return=minimal",
            body: payload
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
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let windowStr = iso.string(from: windowStart)

        let records: [SupabaseNightGroupRecord] = try await sendRest(
            path: "night_groups",
            method: "GET",
            queryItems: [
                URLQueryItem(name: "select", value: SupabaseNightGroupRecord.selectList),
                URLQueryItem(name: "created_at", value: "gte.\(windowStr)"),
                URLQueryItem(name: "order", value: "created_at.asc")
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
