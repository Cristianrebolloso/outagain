import Foundation

@main
struct CheckNotificationPreferences {
    static func main() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let defaults = NotificationPreferences()
        precondition(PushNotificationCategory.allCases.allSatisfy { defaults[$0] })
        let partial = try decoder.decode(NotificationPreferences.self, from: Data(#"{"commentsAndReplies":false}"#.utf8))
        precondition(!partial.commentsAndReplies && partial.announcements && partial.friendRequests)

        for category in PushNotificationCategory.allCases {
            var changed = defaults
            changed[category] = false
            let roundTrip = try decoder.decode(NotificationPreferences.self, from: encoder.encode(changed))
            precondition(!roundTrip[category])
            precondition(PushNotificationCategory.allCases.filter { $0 != category }.allSatisfy { roundTrip[$0] })
            let request = SupabaseNotificationPreferenceUpdate(userID: UUID(), category: category, enabled: false)
            let object = try JSONSerialization.jsonObject(with: encoder.encode(request)) as! [String: Any]
            precondition(Set(object.keys) == ["user_id", category.rawValue], "A save must touch exactly one preference")
            precondition(object[category.rawValue] as? Bool == false)
        }

        precondition(LiveActivityPreferences().isEnabled)
        for legacy in [#"{}"#, #"{"isEnabled":false}"#,
                       #"{"isEnabled":false,"hasAcceptedPrompt":true}"#,
                       #"{"isEnabled":false,"lastDeclinedDayKey":"2026-10-26"}"#] {
            let decoded = try decoder.decode(LiveActivityPreferences.self, from: Data(legacy.utf8))
            precondition(decoded.isEnabled, "An old default or temporary prompt dismissal is not a permanent opt-out")
        }
        let manualOff = try decoder.decode(LiveActivityPreferences.self, from: Data(#"{"isEnabled":false,"hasAcceptedPrompt":true,"hasManuallyDisabled":true}"#.utf8))
        precondition(!manualOff.isEnabled)
        var live = LiveActivityPreferences()
        live.setEnabled(false)
        let restored = try decoder.decode(LiveActivityPreferences.self, from: encoder.encode(live))
        precondition(!restored.isEnabled && restored.hasManuallyDisabled)
        live.setEnabled(true)
        precondition(live.isEnabled && !live.hasManuallyDisabled)

        let suite = "OutAgain.preferences-test.\(UUID())"
        let storage = UserDefaults(suiteName: suite)!
        defer { storage.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        storage.set(try encoder.encode(partial), forKey: "OutAgain.notificationPreferences")
        storage.set(try encoder.encode(manualOff), forKey: "OutAgain.liveActivityPreferences")
        storage.set(false, forKey: "OutAgain.announcementPush.\(first.uuidString)")
        let migrated = NotificationPreferenceStorage.loadPush(for: first, defaults: storage)
        precondition(!migrated.commentsAndReplies && !migrated.announcements)
        precondition(!NotificationPreferenceStorage.loadLiveActivity(for: first, defaults: storage).isEnabled)
        precondition(storage.data(forKey: "OutAgain.notificationPreferences") == nil)
        precondition(storage.data(forKey: "OutAgain.liveActivityPreferences") == nil)
        precondition(NotificationPreferenceStorage.loadPush(for: second, defaults: storage) == defaults)
        precondition(NotificationPreferenceStorage.loadLiveActivity(for: second, defaults: storage).isEnabled)
        precondition(NotificationPreferenceStorage.loadPush(for: first, defaults: storage) == migrated)
        precondition(!NotificationPreferenceStorage.loadLiveActivity(for: first, defaults: storage).isEnabled)
        precondition(!NotificationPreferenceStorage.hasSyncedPush(for: first, defaults: storage))
        NotificationPreferenceStorage.markPushSynced(for: first, defaults: storage)
        precondition(NotificationPreferenceStorage.hasSyncedPush(for: first, defaults: storage))
        precondition(!NotificationPreferenceStorage.hasSyncedPush(for: second, defaults: storage))
        print("PASS: default-on categories and Live Activities, legacy opt-out migration, partial saves, account isolation, and persistence")
    }
}
