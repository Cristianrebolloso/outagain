import Foundation
import CoreLocation

struct NightRecapRoute: Hashable {
    var start: Date
    var end: Date
    var groupID: UUID?

    func title(at date: Date = .now) -> String {
        NotificationDates.recapTitle(start: start, end: end, now: date)
    }
}

enum NotificationDestination: Identifiable, Hashable {
    case post(UUID, commentID: UUID?)
    case recap(NightRecapRoute)

    var id: String {
        switch self {
        case .post(let id, let commentID): "post-\(id)-\(commentID?.uuidString ?? "")"
        case .recap(let route): "recap-\(route.start.timeIntervalSince1970)-\(route.groupID?.uuidString ?? "friends")"
        }
    }
}

struct PendingPushTarget {
    var notificationID: UUID?
    var postID: UUID?
    var commentID: UUID?
    var recap: NightRecapRoute?
}

extension AppStore {
    /// Membership comes from the radius-checked RPC, including nearby friends.
    /// A cached friend post alone must never enable Local.
    var localFeedPosts: [MomentPost] {
        let now = Date()
        let cutoff = now.addingTimeInterval(-48 * 3600)
        return localFeedIDs.compactMap { livePost(matching: $0) }.filter {
            $0.isSharedLocally == true
                && !locallyDeletedPostIDs.contains($0.id)
                && !blockedUserIDs.contains($0.author.id)
                && $0.createdAt >= cutoff && $0.createdAt <= now
        }
    }

    var hasLocalFeedPosts: Bool { !localFeedPosts.isEmpty }

    func reconcileLocalFeedAvailability() {
        let visibleIDs = localFeedPosts.map(\.id)
        if localFeedIDs != visibleIDs { localFeedIDs = visibleIDs }
        if visibleIDs.isEmpty && feedScope == .local { feedScope = .friends }
    }

    func clearLocalFeed() {
        localFeedRequestID = UUID()
        localFeedIDs = []
        localFeedLocation = nil
        localFeedLoadedAt = nil
        isLoadingLocalFeed = false
        hasOlderLocalPosts = false
        localFeedError = nil
        feedScope = .friends
    }

    func resetLocalDiscovery() {
        clearLocalFeed()
        notificationDestination = nil
    }

    func refreshLocalFeed(at location: LocationSnapshot?, force: Bool = false, loadMore: Bool = false) async {
        reconcileLocalFeedAvailability()
        guard !isLayoutPreview, let viewer, let location else { return }
        guard abs(location.capturedAt.timeIntervalSinceNow) < 300 else {
            localFeedError = "Waiting for a fresh location. Try again in a moment."
            return
        }
        let previous = localFeedLocation.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let moved = previous.map { $0.distance(from: CLLocation(latitude: location.latitude, longitude: location.longitude)) > 250 } ?? true
        if !force && !loadMore && !moved, let loaded = localFeedLoadedAt, Date().timeIntervalSince(loaded) < 60 { return }
        if isLoadingLocalFeed && !moved { return }
        if moved {
            localFeedIDs = []
            hasOlderLocalPosts = false
            reconcileLocalFeedAvailability()
        }
        let requestID = UUID()
        localFeedRequestID = requestID
        localFeedLocation = location
        isLoadingLocalFeed = true
        localFeedError = nil
        defer { if localFeedRequestID == requestID { isLoadingLocalFeed = false } }
        do {
            try await backend.updateDiscoveryContext(location: location)
            let cursor = loadMore ? localFeedIDs.last.flatMap { livePost(matching: $0) } : nil
            let page = try await backend.loadLocalFeedPosts(viewer: viewer, before: cursor, limit: Self.homeFeedPageSize)
            guard self.viewer?.id == viewer.id, localFeedRequestID == requestID else { return }
            let visible = visiblePosts(Array(page.prefix(Self.homeFeedPageSize)))
            cacheProfilePosts(visible)
            let ids = visible.map(\.id)
            localFeedIDs = loadMore ? localFeedIDs + ids.filter { !localFeedIDs.contains($0) } : ids
            hasOlderLocalPosts = page.count > Self.homeFeedPageSize
            localFeedLoadedAt = .now
            reconcileLocalFeedAvailability()
        } catch {
            guard self.viewer?.id == viewer.id, localFeedRequestID == requestID else { return }
            localFeedError = "Couldn't load Local. Pull down or tap Try Again."
        }
    }

    func loadOlderHomeSelection(at location: LocationSnapshot?) async {
        if feedScope == .local {
            guard hasOlderLocalPosts else { return }
            await refreshLocalFeed(at: location, loadMore: true)
        } else {
            await loadOlderHomeFeedPostsIfNeeded()
        }
    }

    var hasOlderSelectedFeedPosts: Bool { feedScope == .local ? hasOlderLocalPosts : hasOlderHomeFeedPosts }
    var isLoadingSelectedFeedPosts: Bool { feedScope == .local ? isLoadingLocalFeed : isLoadingOlderHomeFeedPosts }

    var latestNightRecapRoute: NightRecapRoute? {
        if let summary = lastNightGroupActivitySummaryContext {
            return NightRecapRoute(start: summary.window.start, end: summary.window.end,
                                  groupID: summary.group.id)
        }
        if let summary = lastNightActivitySummary {
            return NightRecapRoute(start: summary.window.start, end: summary.window.end)
        }
        return nil
    }

    func openNightRecap(_ notification: AppNotification) {
        guard let start = notification.nightStart, let end = notification.nightEnd else { return }
        markNotificationRead(notification.id)
        notificationDestination = .recap(NightRecapRoute(start: start, end: end,
            groupID: notification.nightGroupID))
    }

    func openPendingPushIfReady() async {
        guard isLive, let target = pendingPushTarget else { return }
        pendingPushTarget = nil
        if let recap = target.recap {
            notificationDestination = .recap(recap)
        } else if let postID = target.postID {
            notificationDestination = .post(postID, commentID: target.commentID)
        } else {
            openNotifications()
        }
        if let id = target.notificationID {
            try? await backend.markNotificationsRead([id])
            markNotificationRead(id)
        }
    }
}
