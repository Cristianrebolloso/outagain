import Foundation
@preconcurrency import UserNotifications

extension AppStore {
    func prepareNotificationPreferences(for userID: UUID) {
        guard notificationPreferenceUserID != userID else { return }
        notificationPreferenceUserID = userID
        notificationPreferenceRevision = UUID()
        notificationPreferences = NotificationPreferenceStorage.loadPush(for: userID)
        liveActivityPreferences = NotificationPreferenceStorage.loadLiveActivity(for: userID)
        notificationPreferenceError = nil
        isLoadingNotificationPreferences = false
        isSavingNotificationPreferences = false
    }

    func refreshNotificationPreferences() async {
        guard let userID = viewer?.id else { return }
        prepareNotificationPreferences(for: userID)
        guard !isLoadingNotificationPreferences, !isSavingNotificationPreferences else { return }
        let revision = UUID()
        notificationPreferenceRevision = revision
        isLoadingNotificationPreferences = true
        defer {
            if notificationPreferenceRevision == revision { isLoadingNotificationPreferences = false }
        }
        do {
            // The old social toggles were local-only. Migrate existing opt-outs
            // once, without enabling anything already disabled on the server.
            if !NotificationPreferenceStorage.hasSyncedPush(for: userID) {
                for category in PushNotificationCategory.allCases where !notificationPreferences[category] {
                    guard viewer?.id == userID, notificationPreferenceRevision == revision else { return }
                    try await backend.setNotificationPreference(category, enabled: false, for: userID)
                }
            }
            let preferences = try await backend.fetchNotificationPreferences(for: userID)
            guard viewer?.id == userID, notificationPreferenceRevision == revision else { return }
            notificationPreferences = preferences
            NotificationPreferenceStorage.markPushSynced(for: userID)
            notificationPreferenceError = nil
        } catch {
            guard viewer?.id == userID, notificationPreferenceRevision == revision else { return }
            notificationPreferenceError = "Couldn't sync your notification settings. Try again."
        }
    }

    func setNotificationPreference(_ category: PushNotificationCategory, enabled: Bool) {
        guard let userID = viewer?.id, !isSavingNotificationPreferences, !isLoadingNotificationPreferences else { return }
        prepareNotificationPreferences(for: userID)
        let previous = notificationPreferences[category]
        let revision = UUID()
        notificationPreferenceRevision = revision
        notificationPreferences[category] = enabled
        isSavingNotificationPreferences = true
        notificationPreferenceError = nil
        Task {
            defer {
                if notificationPreferenceRevision == revision { isSavingNotificationPreferences = false }
            }
            do {
                try await backend.setNotificationPreference(category, enabled: enabled, for: userID)
                guard viewer?.id == userID, notificationPreferenceRevision == revision else { return }
            } catch {
                guard viewer?.id == userID, notificationPreferenceRevision == revision else { return }
                notificationPreferences[category] = previous
                notificationPreferenceError = "Couldn't save your \(category.title) setting. Try again."
            }
        }
    }

    /// Forwards an APNs device token into the backend for the signed-in viewer.
    ///
    /// Called by `OutAgainAppDelegate` when UIKit hands us the token after
    /// `UIApplication.registerForRemoteNotifications()` succeeds. If the viewer isn't
    /// populated yet (cold launch before bootstrap completes), we stash the token locally
    /// and retry once the viewer lands.
    func registerAPNsToken(_ token: Data) async {
        pendingAPNsToken = token
        await flushPendingAPNsTokenIfPossible()
    }

    /// Called from `applyBootstrap` once the viewer is known so buffered tokens get
    /// registered on the first launch where the user just signed in.
    func flushPendingAPNsTokenIfPossible() async {
        guard let token = pendingAPNsToken, let viewer else {
            #if DEBUG
            if pendingAPNsToken == nil {
                print("[APNs] No pending token to flush.")
            } else if viewer == nil {
                print("[APNs] Pending token held — waiting for viewer bootstrap.")
            }
            #endif
            return
        }

        // APNs environment must match the entitlement that produced this
        // token. Debug builds use the development entitlement even on a real
        // iPhone connected through Xcode; distributed Release builds use
        // production. Mismatching these is a silent push killer.
        let deviceEnvironment: DeviceEnvironment
        #if DEBUG
        deviceEnvironment = .development
        #else
        deviceEnvironment = .production
        #endif

        do {
            try await backend.registerDeviceToken(token, environment: deviceEnvironment, for: viewer)
            pendingAPNsToken = nil
            lastRegisteredAPNsToken = token
            #if DEBUG
            let tokenPreview = token.map { String(format: "%02x", $0) }.joined().prefix(12)
            print("[APNs] Registered device token \(tokenPreview)… for \(viewer.username) (\(deviceEnvironment)).")
            #endif
        } catch {
            #if DEBUG
            print("[APNs] Register failed: \(error.localizedDescription). Will retry on next bootstrap.")
            #endif
            // Keep the token buffered — the next app foreground / bootstrap will retry.
        }
    }

    /// Unregister on sign-out so the backend stops targeting this device.
    func unregisterAPNsTokenIfNeeded() async {
        guard let token = lastRegisteredAPNsToken, let viewer else { return }
        try? await backend.unregisterDeviceToken(token, for: viewer)
        lastRegisteredAPNsToken = nil
    }

    /// Debug-only self-test: asks the backend to insert a notification row
    /// addressed to the signed-in viewer so the push-dispatch chain
    /// (trigger -> pg_net -> edge function -> APNs) is exercised end-to-end.
    /// The outcome is recorded server-side in `public.push_attempts`. Any
    /// error surfaces through `socialErrorMessage` so the Profile diagnostics
    /// button reflects failures without the user needing to tail logs.
    func sendSelfTestNotification() async {
        do {
            try await backend.sendSelfTestNotification()
            #if DEBUG
            print("[APNs] Self-test notification inserted. Inspect public.push_attempts for dispatch status.")
            #endif
            // Pull fresh data so the in-app notifications list reflects the
            // row that was just inserted on the server.
            await refreshAppData(silenceErrors: true)
        } catch {
            socialErrorMessage = "Self-test push failed: \(error.localizedDescription)"
            #if DEBUG
            print("[APNs] Self-test failed: \(error.localizedDescription)")
            #endif
        }
    }

    func removeDeliveredNotifications(forPostIDs postIDs: Set<UUID>) {
        let postIDStrings = Set(postIDs.map { $0.uuidString.lowercased() })
        guard !postIDStrings.isEmpty else { return }

        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let matchingIdentifiers = delivered.compactMap { notification -> String? in
                let content = notification.request.content
                if postIDStrings.contains(content.threadIdentifier.lowercased()) {
                    return notification.request.identifier
                }

                guard Self.notificationUserInfo(content.userInfo, referencesAny: postIDStrings) else {
                    return nil
                }

                return notification.request.identifier
            }

            guard !matchingIdentifiers.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: matchingIdentifiers)
        }
    }

    func removeDeliveredNotifications(forPostID postID: UUID) {
        removeDeliveredNotifications(forPostIDs: [postID])
    }

    nonisolated private static func notificationUserInfo(
        _ userInfo: [AnyHashable: Any],
        referencesAny postIDStrings: Set<String>
    ) -> Bool {
        if let nested = userInfo["outagain"] as? [String: Any],
           let postID = nested["postId"] as? String {
            return postIDStrings.contains(postID.lowercased())
        }

        if let nested = userInfo["outagain"] as? [AnyHashable: Any],
           let postID = nested["postId"] as? String {
            return postIDStrings.contains(postID.lowercased())
        }

        if let postID = userInfo["postId"] as? String {
            return postIDStrings.contains(postID.lowercased())
        }

        return false
    }
}
