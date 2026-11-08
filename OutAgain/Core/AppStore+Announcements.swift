import Foundation

extension AppStore {
    static func pendingSeenAppAnnouncementIDsKey(for userID: UUID) -> String {
        "OutAgain.pendingSeenAppAnnouncementIDs.\(userID.uuidString)"
    }

    static func loadPendingSeenAppAnnouncementIDs(for userID: UUID) -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: pendingSeenAppAnnouncementIDsKey(for: userID)) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    func loadPendingSeenAppAnnouncementIDsIfNeeded(for userID: UUID, previousViewerID: UUID?) {
        let persistedIDs = Self.loadPendingSeenAppAnnouncementIDs(for: userID)
        if previousViewerID == userID {
            pendingSeenAppAnnouncementIDs.formUnion(persistedIDs)
        } else {
            pendingSeenAppAnnouncementIDs = persistedIDs
            syncingSeenAppAnnouncementIDs = []
        }
    }

    func markAppAnnouncementsPendingSeen(_ ids: [UUID], for userID: UUID) {
        guard !ids.isEmpty else { return }
        pendingSeenAppAnnouncementIDs.formUnion(ids)
        persistPendingSeenAppAnnouncementIDs(for: userID)
    }

    func clearPendingSeenAppAnnouncementIDs(_ ids: [UUID], for userID: UUID) {
        guard !ids.isEmpty else { return }
        pendingSeenAppAnnouncementIDs.subtract(ids)
        persistPendingSeenAppAnnouncementIDs(for: userID)
    }

    func persistPendingSeenAppAnnouncementIDs(for userID: UUID) {
        let key = Self.pendingSeenAppAnnouncementIDsKey(for: userID)
        if pendingSeenAppAnnouncementIDs.isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            let raw = pendingSeenAppAnnouncementIDs.map(\.uuidString)
            UserDefaults.standard.set(raw, forKey: key)
        }
    }

    func visibleAppAnnouncements(_ announcements: [AppAnnouncement]) -> [AppAnnouncement] {
        announcements.filter { !pendingSeenAppAnnouncementIDs.contains($0.id) }
    }

    func saveFeedAdsEnabled(_ enabled: Bool) async throws {
        guard isViewerAdmin else {
            throw SupabaseBackendError.requestFailed("Only @admin can manage feed ads.", statusCode: 403)
        }
        let updated = try await backend.setFeedAdsEnabled(enabled)
        guard updated["feed_ads_enabled"] == (enabled ? "true" : "false") else {
            throw SupabaseBackendError.requestFailed("The ad setting was not saved. Please try again.", statusCode: 500)
        }
        appConfig.merge(updated) { _, new in new }
    }

    func saveMaintenanceMode(enabled: Bool, title: String, message: String) async throws {
        guard isViewerAdmin else {
            throw SupabaseBackendError.requestFailed("Only @admin can manage maintenance mode.", statusCode: 403)
        }

        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let updatedConfig = try await backend.setMaintenanceMode(
            enabled: enabled,
            title: cleanedTitle,
            message: cleanedMessage
        )
        appConfig.merge(updatedConfig) { _, new in new }
    }

    func sendAppWideAnnouncement(
        requestID: UUID,
        title: String,
        message: String,
        audience: AppAnnouncementAudience,
        targetUsernames: [String] = [],
        delivery: AppAnnouncementDelivery
    ) async throws {
        guard isViewerAdmin else {
            throw SupabaseBackendError.requestFailed("Only @admin can send app-wide notifications.", statusCode: 403)
        }

        try await backend.publishAppAnnouncement(
            requestID: requestID,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            message: message.trimmingCharacters(in: .whitespacesAndNewlines),
            audience: audience,
            targetUsernames: targetUsernames.map(Self.normalizedAdminTargetUsername).filter { !$0.isEmpty },
            delivery: delivery
        )

        await loadAdminAppAnnouncements()
    }

    func loadAdminAppAnnouncements() async {
        guard isViewerAdmin, !isLoadingAdminAppAnnouncements else { return }

        isLoadingAdminAppAnnouncements = true
        defer { isLoadingAdminAppAnnouncements = false }

        do {
            adminAppAnnouncements = try await backend.fetchAdminAppAnnouncements(limit: 5)
        } catch {
            adminReportsMessage = error.localizedDescription
        }
    }

    func deactivateAdminAppAnnouncement(_ announcement: AdminAppAnnouncement) async throws {
        guard isViewerAdmin else {
            throw SupabaseBackendError.requestFailed("Only @admin can remove app-wide notifications.", statusCode: 403)
        }

        try await backend.deactivateAppAnnouncement(id: announcement.id)
        adminAppAnnouncements = adminAppAnnouncements.map { existing in
            guard existing.id == announcement.id else { return existing }
            var updated = existing
            updated.isActive = false
            return updated
        }
    }

    func pollAppAnnouncements() async {
        guard authState == .signedIn, !shouldPresentMaintenanceScreen else { return }

        await syncPendingSeenAppAnnouncementReceipts()

        do {
            let unseenAnnouncements = try await backend.loadUnseenAppAnnouncements(limit: 1)
            guard !unseenAnnouncements.isEmpty else { return }

            var seenIDs = Set(appAnnouncements.map(\.id))
            let newAnnouncements = visibleAppAnnouncements(unseenAnnouncements)
                .filter { seenIDs.insert($0.id).inserted }
            appAnnouncements.append(contentsOf: newAnnouncements)
            appAnnouncements.sort { $0.createdAt > $1.createdAt }
        } catch {
            // App announcements are best-effort foreground polish. A failed
            // poll should not interrupt the feed or show a stale error.
        }
    }

    func markAppAnnouncementPresented(_ announcement: AppAnnouncement) {
        guard let viewer else { return }

        markAppAnnouncementsPendingSeen([announcement.id], for: viewer.id)
        Task { await syncPendingSeenAppAnnouncementReceipts() }
    }

    func dismissAppAnnouncement(_ announcement: AppAnnouncement) {
        appAnnouncements.removeAll { $0.id == announcement.id }
        markAppAnnouncementPresented(announcement)
    }

    func syncPendingSeenAppAnnouncementReceipts() async {
        guard let viewer else { return }
        let viewerID = viewer.id

        let ids = pendingSeenAppAnnouncementIDs
            .filter { !syncingSeenAppAnnouncementIDs.contains($0) }
        guard !ids.isEmpty else { return }

        for id in ids {
            syncingSeenAppAnnouncementIDs.insert(id)
            do {
                try await backend.markAppAnnouncementSeen(id: id, for: viewer)
                if self.viewer?.id == viewerID {
                    clearPendingSeenAppAnnouncementIDs([id], for: viewerID)
                }
            } catch {
                // Keep the local receipt persisted; bootstrap and foreground
                // polling will hide it locally and retry the server write.
            }
            if self.viewer?.id == viewerID {
                syncingSeenAppAnnouncementIDs.remove(id)
            }
        }
    }

    private static func normalizedAdminTargetUsername(_ username: String) -> String {
        username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
            .lowercased()
    }
}
