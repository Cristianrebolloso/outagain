import Foundation

enum PushNotificationCategory: String, CaseIterable {
    case friendRequests = "friend_requests_enabled"
    case likesAndReactions = "reactions_enabled"
    case commentsAndReplies = "comments_enabled"
    case otherActivity = "activity_enabled"
    case nightRecaps = "recaps_enabled"
    case announcements = "announcements_enabled"

    var title: String {
        switch self {
        case .friendRequests: "Friend requests"
        case .likesAndReactions: "Reactions"
        case .commentsAndReplies: "Comments"
        case .otherActivity: "Tags & other activity"
        case .nightRecaps: "Night recaps"
        case .announcements: "Announcements"
        }
    }
}

struct NotificationPreferences: Codable, Hashable {
    var friendRequests = true
    // Retained for compatibility with preferences saved by older builds.
    var friendPosts = true
    var commentsAndReplies = true
    var likesAndReactions = true
    var otherActivity = true
    var nightRecaps = true
    var announcements = true

    enum CodingKeys: String, CodingKey {
        case friendRequests
        case friendPosts = "friendMoments"
        case commentsAndReplies, likesAndReactions, otherActivity, announcements, nightRecaps
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        friendRequests = try values.decodeIfPresent(Bool.self, forKey: .friendRequests) ?? true
        friendPosts = try values.decodeIfPresent(Bool.self, forKey: .friendPosts) ?? true
        commentsAndReplies = try values.decodeIfPresent(Bool.self, forKey: .commentsAndReplies) ?? true
        likesAndReactions = try values.decodeIfPresent(Bool.self, forKey: .likesAndReactions) ?? true
        otherActivity = try values.decodeIfPresent(Bool.self, forKey: .otherActivity) ?? true
        nightRecaps = try values.decodeIfPresent(Bool.self, forKey: .nightRecaps) ?? true
        announcements = try values.decodeIfPresent(Bool.self, forKey: .announcements) ?? true
    }

    subscript(category: PushNotificationCategory) -> Bool {
        get {
            switch category {
            case .friendRequests: friendRequests
            case .likesAndReactions: likesAndReactions
            case .commentsAndReplies: commentsAndReplies
            case .otherActivity: otherActivity
            case .nightRecaps: nightRecaps
            case .announcements: announcements
            }
        }
        set {
            switch category {
            case .friendRequests: friendRequests = newValue
            case .likesAndReactions: likesAndReactions = newValue
            case .commentsAndReplies: commentsAndReplies = newValue
            case .otherActivity: otherActivity = newValue
            case .nightRecaps: nightRecaps = newValue
            case .announcements: announcements = newValue
            }
        }
    }
}

struct LiveActivityPreferences: Codable, Hashable {
    private(set) var isEnabled = true
    private(set) var hasManuallyDisabled = false

    enum CodingKeys: String, CodingKey { case isEnabled, hasManuallyDisabled }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Older builds stored false before offering the opt-in prompt. Only
        // an explicit Settings opt-out should survive the move to default-on.
        hasManuallyDisabled = try values.decodeIfPresent(Bool.self, forKey: .hasManuallyDisabled) ?? false
        isEnabled = !hasManuallyDisabled
    }

    mutating func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        hasManuallyDisabled = !enabled
    }
}

/// Account-scoped caches preserve opt-outs across sign-out and avoid applying
/// one person's choices to the next account using this phone.
enum NotificationPreferenceStorage {
    static func loadPush(for userID: UUID, defaults: UserDefaults = .standard) -> NotificationPreferences {
        let key = "OutAgain.notificationPreferences.\(userID.uuidString)"
        if let saved: NotificationPreferences = decode(key, defaults: defaults) { return saved }
        var preferences: NotificationPreferences = decode("OutAgain.notificationPreferences", defaults: defaults) ?? .init()
        if let announced = defaults.object(forKey: "OutAgain.announcementPush.\(userID.uuidString)") as? Bool {
            preferences.announcements = announced
        }
        savePush(preferences, for: userID, defaults: defaults)
        defaults.removeObject(forKey: "OutAgain.notificationPreferences")
        return preferences
    }

    static func savePush(_ preferences: NotificationPreferences, for userID: UUID, defaults: UserDefaults = .standard) {
        save(preferences, key: "OutAgain.notificationPreferences.\(userID.uuidString)", defaults: defaults)
    }

    static func loadLiveActivity(for userID: UUID, defaults: UserDefaults = .standard) -> LiveActivityPreferences {
        let key = "OutAgain.liveActivityPreferences.\(userID.uuidString)"
        if let saved: LiveActivityPreferences = decode(key, defaults: defaults) { return saved }
        let preferences: LiveActivityPreferences = decode("OutAgain.liveActivityPreferences", defaults: defaults) ?? .init()
        saveLiveActivity(preferences, for: userID, defaults: defaults)
        defaults.removeObject(forKey: "OutAgain.liveActivityPreferences")
        return preferences
    }

    static func saveLiveActivity(_ preferences: LiveActivityPreferences, for userID: UUID, defaults: UserDefaults = .standard) {
        save(preferences, key: "OutAgain.liveActivityPreferences.\(userID.uuidString)", defaults: defaults)
    }

    static func hasSyncedPush(for userID: UUID, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: "OutAgain.notificationPreferencesSynced.\(userID.uuidString)")
    }

    static func markPushSynced(for userID: UUID, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: "OutAgain.notificationPreferencesSynced.\(userID.uuidString)")
    }

    private static func decode<Value: Decodable>(_ key: String, defaults: UserDefaults) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private static func save<Value: Encodable>(_ value: Value, key: String, defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
