import Foundation

extension SupabaseSocialBackendClient {
    func updateDiscoveryContext(location: LocationSnapshot?) async throws {
        struct Context: Encodable {
            var viewer_time_zone: String
            var viewer_latitude: Double?
            var viewer_longitude: Double?
        }
        try await sendRestWithoutResponse(path: "rpc/update_discovery_context", method: "POST", queryItems: [],
            body: Context(viewer_time_zone: TimeZone.current.identifier,
                          viewer_latitude: location?.latitude, viewer_longitude: location?.longitude))
    }

    func loadLocalFeedPosts(viewer: UserProfile, before: MomentPost?, limit: Int) async throws -> [MomentPost] {
        struct Page: Encodable { var before_date: Date?; var before_id: UUID?; var page_limit: Int }
        let rows: [SupabaseFeedPostRecord] = try await sendRest(
            path: "rpc/local_feed_posts", method: "POST", queryItems: [],
            body: Page(before_date: before?.createdAt, before_id: before?.id, page_limit: limit + 1))
        return try await hydrateFeedPosts(from: rows, viewer: viewer)
    }

    func loadNightRecapPosts(viewer: UserProfile, start: Date, end: Date, groupID: UUID?) async throws -> [MomentPost] {
        struct Window: Encodable { var window_start: Date; var window_end: Date; var group_id: UUID? }
        let rows: [SupabaseFeedPostRecord] = try await sendRest(
            path: "rpc/night_recap_posts", method: "POST", queryItems: [],
            body: Window(window_start: start, window_end: end, group_id: groupID))
        return try await hydrateFeedPosts(from: rows, viewer: viewer)
    }

    func markNightRecapSeen(through end: Date) async throws {
        struct Seen: Encodable { var window_end: Date }
        try await sendRestWithoutResponse(path: "rpc/mark_night_recap_seen", method: "POST", queryItems: [],
                                         body: Seen(window_end: end))
    }
}
