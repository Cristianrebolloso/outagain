import Foundation

/// A display-only bundle. Every original notification stays available so its
/// read state, dismissal and exact post/comment destination remain independent.
struct ActivityNotificationBundle: Identifiable {
    let id: String
    let notifications: [AppNotification]

    var latest: AppNotification { notifications[0] }
    var hasUnread: Bool { notifications.contains { !$0.isRead } }

    static func make(from notifications: [AppNotification], calendar: Calendar = .current) -> [Self] {
        let sorted = notifications.sorted {
            $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
        }
        var orderedKeys: [String] = []
        var buckets: [String: [AppNotification]] = [:]
        for notification in sorted {
            let key: String
            switch notification.kind {
            case .reaction, .comment, .photoReply, .commentLike, .commentTagged, .tagged, .sharedMoment:
                if let postID = notification.postID {
                    let day = calendar.startOfDay(for: notification.createdAt).timeIntervalSince1970
                    key = "post:\(postID.uuidString):\(day)"
                } else {
                    key = notification.id.uuidString
                }
            default:
                key = notification.id.uuidString
            }
            if buckets[key] == nil { orderedKeys.append(key) }
            buckets[key, default: []].append(notification)
        }
        return orderedKeys.map { Self(id: $0, notifications: buckets[$0] ?? []) }
    }
}
