import Foundation

struct SupabaseNotificationPreferences: Decodable {
    var announcements_enabled: Bool
    var friend_requests_enabled: Bool
    var reactions_enabled: Bool
    var comments_enabled: Bool
    var recaps_enabled: Bool? = nil
    var activity_enabled: Bool

    var preferences: NotificationPreferences {
        var result = NotificationPreferences()
        result.announcements = announcements_enabled
        result.friendRequests = friend_requests_enabled
        result.likesAndReactions = reactions_enabled
        result.commentsAndReplies = comments_enabled
        result.otherActivity = activity_enabled
        result.nightRecaps = recaps_enabled ?? true
        return result
    }
}

struct SupabaseNotificationPreferenceUpdate: Encodable {
    var userID: UUID
    var category: PushNotificationCategory
    var enabled: Bool

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: Key.self)
        try values.encode(userID, forKey: Key("user_id"))
        try values.encode(enabled, forKey: Key(category.rawValue))
    }
}

