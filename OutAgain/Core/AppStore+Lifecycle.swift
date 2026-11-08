import Foundation

extension AppStore {
    static func loadPendingDeletedNotificationIDs() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: pendingDeletedNotificationIDsKey) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    func markNotificationsPendingDeletion(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        pendingDeletedNotificationIDs.formUnion(ids)
        persistPendingDeletedNotificationIDs()
    }

    func clearPendingDeletedNotificationIDs(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        pendingDeletedNotificationIDs.subtract(ids)
        persistPendingDeletedNotificationIDs()
    }

    func persistPendingDeletedNotificationIDs() {
        let raw = pendingDeletedNotificationIDs.map(\.uuidString)
        UserDefaults.standard.set(raw, forKey: AppStore.pendingDeletedNotificationIDsKey)
    }

    func syncPendingDeletedNotifications() async {
        let ids = Array(pendingDeletedNotificationIDs)
        guard !ids.isEmpty else { return }

        do {
            try await backend.deleteNotifications(ids: ids)
            clearPendingDeletedNotificationIDs(ids)
        } catch {
            // Keep the tombstones persisted; the next refresh/foreground cycle retries.
        }
    }

    func selectFeedScope(_ scope: FeedScope) {
        feedScope = scope
        ensureSelectedPresenceCluster()
    }

    func selectPresenceCluster(_ cluster: PresenceCluster?) {
        selectedPresenceClusterID = cluster?.id
    }

    func bootstrapFromBackendIfNeeded() {
        guard !didAttemptBootstrap else { return }
        didAttemptBootstrap = true
        BootstrapTrace.reset()
        BootstrapTrace.mark("bootstrapFromBackendIfNeeded called")
        #if DEBUG
        PerformanceTracker.shared.beginSession(label: "cold-launch")
        #endif
        // Pre-populate the feed from disk so the home screen renders
        // immediately on cold launch, before the first network round-trip.
        hydrateFeedFromCacheIfAvailable()
        Task { [weak self] in
            await QuickPostLiveActivityManager.endExpiredActivities()
            await self?.refreshAppData(promoteLiveSession: true, silenceErrors: true)
            // Kick off polling once the first bootstrap has resolved so
            // in-app state stays fresh without waiting for a background /
            // foreground cycle.
            await MainActor.run {
                self?.startForegroundPollingIfNeeded()
                self?.startMaintenanceConfigPollingIfNeeded()
            }
        }
    }

    func refreshAppData(promoteLiveSession: Bool = false, silenceErrors: Bool = false) async {
        BootstrapTrace.mark("refreshAppData task started")

        // Helper that unblocks the splash screen. Called explicitly at every
        // exit path so the UI is never left on the loading screen indefinitely,
        // but — crucially — only AFTER data has been applied to the store on the
        // happy path. This means the home feed, friends, and profile are all
        // populated before the splash fades out.
        func markReady() {
            bootstrapPhase = .ready
            BootstrapTrace.mark("bootstrapPhase = .ready (UI unblocked)")
        }

        func restoreCachedLiveSessionIfPossible() -> Bool {
            guard backend.hasStoredSession, viewer != nil else { return false }
            authState = .signedIn
            promoteToLiveSession()
            if posts.isEmpty {
                resetHomeFeedPagination(hasOlderPosts: false, cursorDate: nil)
            }
            markReady()
            return true
        }

        do {
            await syncPendingDeletedNotifications()
            BootstrapTrace.mark("backend.loadAppData() awaiting")
            let bootstrap = try await backend.loadAppData()
            BootstrapTrace.mark("backend.loadAppData() returned")
            appConfig = bootstrap.appConfig
            guard let backendViewer = bootstrap.viewer else {
                // viewer == nil means the backend returned no profile row.
                // This can happen legitimately (not yet onboarded) OR
                // spuriously (empty response from a transient server issue).
                // Only sign the user out if we truly have no stored auth
                // session — if a session exists, the absence of a profile
                // row is more likely a race or network blip than a real
                // de-auth. Signing out on every transient failure is what
                // was causing random logouts in the field.
                if !backend.hasStoredSession {
                    viewer = nil
                    authState = .signedOut
                    onboardingStep = .welcome
                    friends = []
                    suggestedFriends = []
                    friendOfFriendIDsStore = []
                    mutualCounts = [:]
                    incomingFriendRequests = []
                    outgoingFriendRequests = []
                    blockedUserIDs = []
                    blockedUsers = []
                    posts = []
                    resetLocalDiscovery()
                    tonightActivityPosts = []
                    nightSummaryPosts = []
                    nightGroups = []
                    nightSummaryGroups = []
                    notifications = []
                    appAnnouncements = []
                    ensureSelectedPresenceCluster()
                }
                // If we still have a session but got no profile, surface any
                // cached signed-in shell instead of routing to the empty
                // onboarding `.done` state. The next refresh will recover.
                if restoreCachedLiveSessionIfPossible() {
                    return
                }
                markReady()
                return
            }

            // Apply all data to the store BEFORE marking ready so the home
            // feed, friend list, and profile are fully populated the moment
            // the splash screen fades out.
            applyBootstrap(bootstrap)
            lastFullRefreshAt = .now
            authState = .signedIn
            isOffline = false

            if backendViewer.username.isEmpty {
                onboardingStep = .profile
            } else if promoteLiveSession {
                promoteToLiveSession()
            }

            if onboardingDraft.inviteLink.isEmpty {
                onboardingDraft.inviteLink = backend.createInviteLink(for: backendViewer.username).absoluteString
            }

            ensureSelectedPresenceCluster()

            // Prefetch first-paint images while the splash is still visible so
            // Home does not reveal placeholder avatars or media after routing.
            // This runs on the initial cold launch only (when bootstrapPhase is
            // still .pending); subsequent background refreshes skip it to avoid
            // unnecessary network work.
            if bootstrapPhase == .pending {
                await prefetchInitialImages(bootstrap: bootstrap)
            }

            markReady()

            // Sync tonight's groups concurrently after the splash has cleared —
            // groups are supplementary and should never delay the initial render.
            Task { await syncGroupsFromBackend() }
        } catch SupabaseBackendError.accountBanned {
            finishSessionEndedLocally()
            socialErrorMessage = SupabaseBackendError.accountBanned.errorDescription
            markReady()
        } catch SupabaseBackendError.notAuthenticated {
            // Only sign out when the backend has confirmed there is genuinely
            // no valid session — i.e. the stored session was already cleared
            // by ensureAuthenticatedSession() because the server explicitly
            // rejected the refresh token with invalid_grant. If a session is
            // still persisted (hasStoredSession == true), the notAuthenticated
            // throw came from a transient race or a momentarily nil authSession
            // during a background refresh; signing out in that case would be
            // incorrect and is exactly what was causing random logouts.
            if !backend.hasStoredSession {
                viewer = nil
                authState = .signedOut
                onboardingStep = .welcome
                friends = []
                suggestedFriends = []
                friendOfFriendIDsStore = []
                mutualCounts = [:]
                incomingFriendRequests = []
                outgoingFriendRequests = []
                blockedUserIDs = []
                blockedUsers = []
                posts = []
                resetLocalDiscovery()
                tonightActivityPosts = []
                nightSummaryPosts = []
                nightGroups = []
                nightSummaryGroups = []
                notifications = []
                appAnnouncements = []
                ensureSelectedPresenceCluster()
            }
            markReady()
        } catch SupabaseBackendError.transport {
            // Network unavailable (no connectivity, DNS failure, timeout).
            // If we have a cached feed, promote to .ready immediately so the
            // user lands on real cached content rather than an infinite spinner.
            // If no cache exists (first-ever launch with no internet), stay
            // on the splash and show a clear message so the user knows to
            // connect — they have no session yet and nothing to show.
            isOffline = true
            if !posts.isEmpty {
                // Cache was pre-loaded by hydrateFeedFromCacheIfAvailable()
                // and the viewer shell was also restored. Surface them now.
                if viewer != nil {
                    authState = .signedIn
                    promoteToLiveSession()
                }
                markReady()
            } else if backend.hasStoredSession {
                // Has a session but no cache (rare: first launch after install
                // with no connectivity). Show a clear offline prompt rather
                // than an infinite spinner.
                if !silenceErrors {
                    socialErrorMessage = "You're offline. Connect to load your feed."
                }
                markReady()
            } else {
                // No session, no cache — nothing to show. Stay on splash;
                // there's no state to restore and sign-in needs connectivity.
                if !silenceErrors {
                    socialErrorMessage = "No internet connection. Please connect and try again."
                }
                markReady()
            }
        } catch {
            isOffline = false
            if !silenceErrors {
                socialErrorMessage = "Couldn't refresh the app from the backend yet."
            }
            if restoreCachedLiveSessionIfPossible() {
                return
            }
            // Always unblock the splash even on unexpected errors — a failed
            // refresh shouldn't trap the user on the loading screen.
            markReady()
        }
    }

    /// Called when the app returns to the foreground. Pulls fresh server
    /// state so notifications and friend-requests inserted while the app was
    /// backgrounded show up without a cold relaunch.
    ///
    /// Guarded on `authState == .signedIn` because there's nothing to refresh
    /// when there's no session, and on the initial bootstrap having finished
    /// so we don't race with it.
    func refreshOnForeground() {
        guard !isLayoutPreview else { return }
        guard bootstrapPhase == .ready else { return }

        refreshAppConfigInBackground()
        startForegroundPollingIfNeeded()
        startMaintenanceConfigPollingIfNeeded()
        Task {
            await QuickPostLiveActivityManager.endExpiredActivities()
        }

        // If we were offline, always attempt a full refresh — don't run the
        // lightweight delta polls, which are likely to fail the same way and
        // won't clear the isOffline flag even if connectivity has returned.
        if isOffline {
            refreshAppDataInBackground(promoteLiveSession: authState != .signedIn, silenceErrors: true)
            return
        }

        guard authState == .signedIn else { return }
        Task { try? await backend.updateDiscoveryContext(location: nil) }
        let needsFullRefresh = lastFullRefreshAt.map { Date().timeIntervalSince($0) > 10 * 60 } ?? true
        if needsFullRefresh {
            refreshAppDataInBackground()
        } else {
            Task {
                await refreshAppConfigOnly()
                guard !shouldPresentMaintenanceScreen else { return }
                await pollAppAnnouncements()
                await pollNewNotifications()
                await pollNewFeedPosts()
            }
        }
    }

    /// Starts a three-tier polling loop while the app is foregrounded:
    ///
    ///   - Every 60s: lightweight delta poll — fetches only new notification
    ///     rows since the last known timestamp via the `new_notifications` RPC.
    ///     This is ~200 bytes vs. a full bootstrap and keeps the server load
    ///     trivial at 300 concurrent users (~5 req/s total vs. ~15 req/s at 20s).
    ///
    ///   - Every 120s: lightweight feed delta — fetches only new posts newer
    ///     than the newest currently-visible feed post, then hydrates just those
    ///     rows plus their small preview engagement data.
    ///
    ///   - Every 20 minutes: full bootstrap refresh to catch friend graph
    ///     changes, post deletions, and anything the delta polls might have
    ///     missed. Most foreground returns skip this and use deltas only.
    ///
    /// Cancelled when the app backgrounds via `stopForegroundPolling()`.
    func startForegroundPollingIfNeeded() {
        foregroundPollTask?.cancel()
        foregroundPollTask = Task { [weak self] in
            var tickCount = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
                guard !Task.isCancelled else { return }
                tickCount += 1
                await self?.refreshAppConfigOnly()
                if self?.shouldPresentMaintenanceScreen == true {
                    continue
                } else if self?.isOffline == true {
                    // While offline, every tick attempts a full refresh rather
                    // than the lightweight delta polls — deltas would fail the
                    // same way and won't clear the isOffline flag. As soon as
                    // connectivity returns the full refresh succeeds, clears
                    // isOffline, and the banner disappears automatically.
                    await self?.refreshAppData(silenceErrors: true)
                } else if tickCount % 20 == 0 {
                    // Full refresh every 20 minutes.
                    await self?.refreshAppData(silenceErrors: true)
                } else {
                    await self?.pollAppAnnouncements()
                    await self?.pollNewNotifications()
                    if tickCount.isMultiple(of: 2) {
                        await self?.pollNewFeedPosts()
                    }
                }
            }
        }
    }

    func stopForegroundPolling() {
        foregroundPollTask?.cancel()
        foregroundPollTask = nil
    }

    func startMaintenanceConfigPollingIfNeeded() {
        maintenanceConfigPollTask?.cancel()
        maintenanceConfigPollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10 * NSEC_PER_SEC)
                guard !Task.isCancelled else { return }
                guard self?.authState == .signedIn
                else { continue }
                await self?.refreshAppConfigOnly()
            }
        }
    }

    func stopMaintenanceConfigPolling() {
        maintenanceConfigPollTask?.cancel()
        maintenanceConfigPollTask = nil
    }

    /// Lightweight delta poll — fetches only notification rows created after
    /// the last known notification timestamp. Merges new rows into the existing
    /// in-memory list without touching friends, posts, or reactions. A single
    /// indexed RPC call on the server; typically returns an empty array.
    func pollNewNotifications() async {
        guard authState == .signedIn, !shouldPresentMaintenanceScreen else { return }
        let since = notifications.first?.createdAt ?? Date(timeIntervalSinceNow: -3600)
        do {
            let newItems = try await backend.fetchNewNotifications(since: since)
            guard !newItems.isEmpty else { return }
            var shouldTriggerFullRefresh = false
            await MainActor.run {
                // Prepend new items, deduplicate by ID, and filter self-actor
                // rows. Keep sorted newest-first.
                //
                // Note: we intentionally do NOT filter by knownPostIDs here.
                // The delta poll only fetches *new* notifications from the
                // server, so the referenced post may simply not be loaded in
                // the current in-memory snapshot (e.g. posted in a prior
                // session). Filtering by local post presence would silently
                // drop valid notifications — e.g. a friend liking a post you
                // made earlier in the evening. Post-deletion cleanup is handled
                // correctly at bootstrap time where posts and notifications are
                // fetched together, making the postID cross-check reliable.
                let existingIDs = Set(notifications.map(\.id))
                let fresh = visibleNotifications(newItems).filter { notification in
                    guard !existingIDs.contains(notification.id) else { return false }
                    guard notification.actor?.id != viewer?.id else { return false }
                    guard !isNotificationPendingDeletion(notification.id) else { return false }
                    return true
                }
                guard !fresh.isEmpty else { return }
                let structuralKinds: Set<NotificationKind> = [
                    .friendRequest,
                    .friendAccepted,
                    .profileVerified,
                    .groupAdded,
                ]
                shouldTriggerFullRefresh = fresh.contains { structuralKinds.contains($0.kind) }
                notifications = (fresh + notifications).sorted { $0.createdAt > $1.createdAt }
            }
            if shouldTriggerFullRefresh {
                // Structural notifications (friend request, friend accepted,
                // group added) require a full bootstrap to update the friends
                // list and graph. Guard against a cascade: if a full refresh
                // already ran within the last 30 seconds, skip this one.
                // The next 60-second poll tick will catch any remaining delta.
                let timeSinceLastRefresh = lastFullRefreshAt.map { Date().timeIntervalSince($0) } ?? .infinity
                if timeSinceLastRefresh > 30 {
                    await refreshAppData(silenceErrors: true)
                }
            }
        } catch {
            // Delta poll failures are silent — the next full refresh recovers.
        }
    }

    /// Lightweight feed delta — reconciles locally cached IDs, then returns only
    /// posts newer than the newest post already visible in the home feed graph
    /// and merges them into `store.posts`.
    func pollNewFeedPosts() async {
        guard authState == .signedIn, !shouldPresentMaintenanceScreen, let viewer else { return }

        await reconcileVisibleHomeFeedPostIDs()

        let visibleAuthorIDs = homeFeedAuthorIDs
        let newestVisiblePostAt = posts
            .filter { visibleAuthorIDs.contains($0.author.id) }
            .map(\.createdAt)
            .max()
        let since = newestVisiblePostAt?
            .addingTimeInterval(-Self.feedDeltaOverlapDuration)
            ?? Date(timeIntervalSinceNow: -(20 * 60 * 60))

        do {
            let newPosts = visiblePosts(
                try await backend.fetchNewFeedPosts(since: since, viewer: viewer)
            )
            .map { applyingPendingEngagement(to: $0) }
            .filter { isViewerAdmin || visibleAuthorIDs.contains($0.author.id) }
            guard !newPosts.isEmpty else { return }

            let existingIDs = Set(posts.map(\.id))
            // Drop anything the viewer just deleted locally. The server can
            // still return a recently-deleted row if the delete RPC silently
            // failed or the cascade is still propagating; without this filter
            // the delta poll resurrects the post within 2 minutes and the user
            // sees it "come back."
            let fresh = newPosts.filter {
                !existingIDs.contains($0.id) && !locallyDeletedPostIDs.contains($0.id)
            }
            guard !fresh.isEmpty else { return }

            posts = sortPostsByRecency(fresh + posts)
            refreshCatalogs()
            ensureSelectedPresenceCluster()
            persistFeedCache()
        } catch {
            // Feed delta failures are silent — the next full refresh recovers.
        }
    }

    /// The delta endpoint only reports new rows; it cannot report hard-deleted
    /// posts. Confirm the local visible set against Supabase's current RLS view
    /// so a friend's deleted post does not linger from the device cache until
    /// the next full bootstrap.
    private func reconcileVisibleHomeFeedPostIDs() async {
        let visibleAuthorIDs = homeFeedAuthorIDs
        let reconciliationCutoff = Date(timeIntervalSinceNow: -(20 * 60 * 60))
        let candidateIDs = Set(
            (posts + tonightActivityPosts + nightSummaryPosts)
                .filter { post in
                    guard !locallyDeletedPostIDs.contains(post.id) else { return false }
                    guard pendingPostCreates[post.id] == nil else { return false }
                    guard isViewerAdmin || visibleAuthorIDs.contains(post.author.id) else { return false }
                    return post.createdAt >= reconciliationCutoff
                }
                .map(\.id)
        )

        guard !candidateIDs.isEmpty else { return }

        do {
            let visibleIDs = try await backend.loadVisiblePostIDs(Array(candidateIDs))
            let removedIDs = candidateIDs.subtracting(visibleIDs)
            guard !removedIDs.isEmpty else { return }
            removePostsEverywhere(removedIDs)
        } catch {
            // A failed reconciliation should never hide posts pessimistically.
            // The next delta or full bootstrap will try again.
        }
    }

    func loadOlderHomeFeedPostsIfNeeded() async {
        guard authState == .signedIn, let viewer else { return }
        guard hasOlderHomeFeedPosts, !isLoadingOlderHomeFeedPosts else { return }
        guard !homeFeedPosts.isEmpty else {
            hasOlderHomeFeedPosts = false
            return
        }

        // Cursor: oldest post currently loaded, or nil for first page.
        let cursor = homeFeedCursorDate
            ?? homeFeedPosts.map(\.createdAt).min()
        let authorIDs = isViewerAdmin ? [] : Array(homeFeedAuthorIDs)

        isLoadingOlderHomeFeedPosts = true
        defer { isLoadingOlderHomeFeedPosts = false }

        do {
            let page = visiblePosts(
                try await backend.loadFeedPosts(
                    authorIDs: authorIDs,
                    viewer: viewer,
                    before: cursor,
                    limit: Self.homeFeedPageSize
                )
            )
            .map { applyingPendingEngagement(to: $0) }

            guard !page.isEmpty else {
                hasOlderHomeFeedPosts = false
                return
            }

            // If we got fewer than a full page, there's nothing left.
            if page.count < Self.homeFeedPageSize {
                hasOlderHomeFeedPosts = false
            }

            // Advance cursor to the oldest post in this page.
            if let oldest = page.map(\.createdAt).min() {
                homeFeedCursorDate = oldest
            }

            let existingIDs = Set(posts.map(\.id))
            // Same guard as pollNewFeedPosts: don't let a locally-deleted post
            // resurrect through a paginated backfill.
            let fresh = page.filter {
                !existingIDs.contains($0.id) && !locallyDeletedPostIDs.contains($0.id)
            }
            guard !fresh.isEmpty else { return }

            posts = sortPostsByRecency(posts + fresh)
            refreshCatalogs()
            ensureSelectedPresenceCluster()
            persistFeedCache()
        } catch {
            hasOlderHomeFeedPosts = false
            socialErrorMessage = "Couldn't load older posts right now."
        }
    }

    /// Merges incoming bootstrap posts into the existing array without ever
    /// clearing it. This prevents the feed from going blank during a refresh.
    ///
    /// Strategy:
    ///  - Posts that exist in both old and new are updated in-place (same index,
    ///    same SwiftUI identity → no disappear/reappear).
    ///  - Posts only in the new set are prepended in recency order.
    ///  - Posts missing from a confirmed full server tonight/summary snapshot
    ///    are removed everywhere, including cache and delivered pushes.
    ///  - Posts only in the existing top-page set are dropped UNLESS they
    ///    carry local photoData or are recent direct-friend posts outside the
    ///    authoritative windows.
    ///
    ///    Rule (b) keeps already-visible direct-friend cards steady during a
    ///    top-page refresh. Older pages can still be reloaded by the cursor
    ///    pagination path when the viewer scrolls down.
    private func mergePosts(from bootstrap: SocialBootstrap) {
        let incoming = sortPostsByRecency(
            visiblePosts(bootstrap.posts)
                .filter { !locallyDeletedPostIDs.contains($0.id) }
                .map { applyingPendingEngagement(to: $0) }
        )

        let incomingByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let existingByID = Dictionary(uniqueKeysWithValues: posts.map { ($0.id, $0) })
        let feedWindowCutoff = Date(timeIntervalSinceNow: -(20 * 60 * 60))
        let authoritativeTonightPostIDs = bootstrap.tonightActivitySnapshotIsAuthoritative
            ? Set(visiblePosts(bootstrap.tonightActivityPosts).map(\.id))
            : nil
        let authoritativeSummaryPostIDs = bootstrap.nightSummarySnapshotIsAuthoritative
            ? Set(visiblePosts(bootstrap.nightSummaryPosts).map(\.id))
            : nil
        let tonightWindow = Self.tonightWindow(reference: .now)
        let completedNightWindow = Self.lastCompletedNightWindow(reference: .now)
        var authoritativelyRemovedPostIDs = Set<UUID>()

        func isMissingFromAuthoritativeWindow(_ post: MomentPost) -> Bool {
            if tonightWindow.contains(post.createdAt) {
                guard let authoritativeTonightPostIDs else { return false }
                return !authoritativeTonightPostIDs.contains(post.id)
            }

            if let completedNightWindow,
               post.createdAt >= completedNightWindow.start,
               post.createdAt < completedNightWindow.end {
                guard let authoritativeSummaryPostIDs else { return false }
                return !authoritativeSummaryPostIDs.contains(post.id)
            }

            return false
        }

        // Update existing posts in-place; preserve local photoData the server
        // doesn't carry so optimistic cards never collapse to placeholders.
        var merged: [MomentPost] = posts.compactMap { existing in
            guard let fresh = incomingByID[existing.id] else {
                if pendingPostCreates[existing.id] != nil {
                    return applyingPendingEngagement(to: existing)
                }
                // Keep locally-published content not yet indexed by the server.
                if existing.media.photoData != nil,
                   Date().timeIntervalSince(existing.createdAt) < 2 * 60 {
                    return existing
                }
                if (isViewerAdmin || homeFeedAuthorIDs.contains(existing.author.id)),
                   isMissingFromAuthoritativeWindow(existing) {
                    authoritativelyRemovedPostIDs.insert(existing.id)
                    return nil
                }
                if localFeedIDs.contains(existing.id), existing.createdAt > Date().addingTimeInterval(-48 * 3600) { return existing }
                // Keep recent direct-friend posts steady even when a top-page
                // bootstrap returns only the newest slice.
                if (isViewerAdmin || directFriendIDs.contains(existing.author.id)),
                   existing.createdAt > feedWindowCutoff { return existing }
                return nil
            }
            // Carry forward any local photoData not present on the server record.
            var updated = applyingPendingEngagement(to: fresh)
            if updated.media.photoData == nil, let localData = existing.media.photoData {
                updated.media.photoData = localData
            }
            if updated.media.photoAspectRatio == nil, let localRatio = existing.media.photoAspectRatio {
                updated.media.photoAspectRatio = localRatio
            }
            return updated
        }

        // Prepend truly new posts (not already in the existing array).
        let newPosts = incoming.filter { existingByID[$0.id] == nil }
        merged = newPosts + merged

        let mergedIDs = Set(merged.map(\.id))
        let pendingPosts = pendingPostCreates.values
            .filter { !mergedIDs.contains($0.id) }
            .map { applyingPendingEngagement(to: $0) }
        merged = pendingPosts + merged

        // Final recency sort to keep ordering stable after the merge.
        posts = sortPostsByRecency(merged)

        if !authoritativelyRemovedPostIDs.isEmpty {
            removePostsEverywhere(authoritativelyRemovedPostIDs, persist: false)
        }
    }

    func applyBootstrap(_ bootstrap: SocialBootstrap) {
        let previousViewerID = viewer?.id
        if let backendViewer = bootstrap.viewer {
            loadPendingSeenAppAnnouncementIDsIfNeeded(for: backendViewer.id, previousViewerID: previousViewerID)
            viewer = backendViewer
            accentColorChoice = AppStore.loadAccentColorChoice(for: backendViewer.id)
            if let syncedTheme = backendViewer.backgroundTheme {
                let availableTheme = syncedTheme.availableTheme
                if availableTheme != backgroundTheme {
                    backgroundTheme = availableTheme
                }
                if availableTheme != syncedTheme {
                    handleBackgroundThemeChanged(availableTheme)
                }
            } else if backendViewer.backgroundTheme == nil {
                handleBackgroundThemeChanged(backgroundTheme)
            }
            onboardingDraft.displayName = backendViewer.displayName
            onboardingDraft.username = backendViewer.username
        }

        applyDrinkCatalogBootstrapPreferences(bootstrap.drinkCatalogPreferences)

        friends = bootstrap.friends
        suggestedFriends = bootstrap.suggestedFriends
        friendOfFriendIDsStore = bootstrap.friendOfFriendIDs
        mutualCounts = bootstrap.mutualCounts
        incomingFriendRequests = bootstrap.incomingRequests.sorted { $0.createdAt > $1.createdAt }
        outgoingFriendRequests = bootstrap.outgoingRequests.sorted { $0.createdAt > $1.createdAt }
        blockedUserIDs = bootstrap.blockedUserIDs
        blockedUsers = sortProfilesByDisplayName(bootstrap.blockedUsers)
        tonightActivityPosts = sortPostsByRecency(
            visiblePosts(bootstrap.tonightActivityPosts)
                .filter { !locallyDeletedPostIDs.contains($0.id) }
                .map { applyingPendingEngagement(to: $0) }
        )
        nightSummaryPosts = sortPostsByRecency(
            visiblePosts(bootstrap.nightSummaryPosts)
                .filter { !locallyDeletedPostIDs.contains($0.id) }
                .map { applyingPendingEngagement(to: $0) }
        )
        nightSummaryGroups = bootstrap.nightSummaryGroups
        mergePosts(from: bootstrap)
        resetHomeFeedPagination(
            hasOlderPosts: bootstrap.homeFeedHasMore,
            cursorDate: bootstrap.posts.map(\.createdAt).min()
        )
        // Filter out any notification where the actor is the viewer themselves —
        // the backend trigger occasionally fires with the wrong user_id (liker
        // instead of post author), which causes the viewer to receive their own
        // like notifications. Drop them client-side as a defensive measure.
        //
        // We do NOT filter by whether the post appears in bootstrapPostIDs:
        // the bootstrap only fetches the most recent N posts, so a notification
        // referencing an older post (e.g. a friend liking a post from earlier
        // tonight) would be incorrectly dropped. Post deletion is handled
        // server-side via ON DELETE CASCADE on the notifications table, so
        // deleted-post notifications never arrive in bootstrap.notifications.
        let viewerID = bootstrap.viewer?.id
        notifications = visibleNotifications(bootstrap.notifications)
            .filter { $0.actor?.id != viewerID && !isNotificationPendingDeletion($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        appAnnouncements = visibleAppAnnouncements(bootstrap.appAnnouncements)
            .sorted { $0.createdAt > $1.createdAt }
        appConfig = bootstrap.appConfig
        let livePostIDs = Set(posts.map(\.id))
        locallyDeletedPostIDs = locallyDeletedPostIDs.filter { !livePostIDs.contains($0) }
        refreshCatalogs()

        // If a token was captured before the viewer existed, register it now.
        Task { await flushPendingAPNsTokenIfPossible() }
        if let viewer { prepareNotificationPreferences(for: viewer.id) }
        Task {
            await refreshNotificationPreferences()
            try? await backend.updateDiscoveryContext(location: nil)
            await openPendingPushIfReady()
        }
        Task { await syncPendingSeenAppAnnouncementReceipts() }

        // Write the fresh feed to disk so the next cold launch can render
        // immediately without waiting for the network bootstrap.
        persistFeedCache()

        #if DEBUG
        // Track that live data is now on screen, and print the session report
        // after the first bootstrap completes. Filter Xcode console by "PERF"
        // or "SUPA" to read the output.
        trackLiveFeedApplied(postCount: bootstrap.posts.count)
        Task {
            // Slight delay so all async call completions have been recorded
            // before we tally them in the summary.
            try? await Task.sleep(for: .milliseconds(100))
            PerformanceTracker.shared.printReport()
        }
        #endif
    }

    func signOut() {
        // Clear local state immediately so the UI jumps to the sign-in screen
        // on the same run loop tick. Network cleanup (APNs token removal and
        // Supabase session invalidation) runs in the background — a failure
        // there is inconsequential because the local session is already gone.
        let registeredAPNsToken = lastRegisteredAPNsToken
        let registeredViewer = viewer
        let backendSignOutTask = backend.beginSignOut()
        finishSessionEndedLocally()
        lastRegisteredAPNsToken = nil
        pendingAPNsToken = registeredAPNsToken
        Task {
            if let registeredAPNsToken, let registeredViewer {
                try? await backend.unregisterDeviceToken(registeredAPNsToken, for: registeredViewer)
            }
            await backendSignOutTask.value
        }
    }

    func finishSessionEndedLocally() {
        notificationPreferenceUserID = nil
        notificationPreferenceRevision = UUID()
        notificationPreferences = NotificationPreferences()
        isLoadingNotificationPreferences = false
        isSavingNotificationPreferences = false
        notificationPreferenceError = nil
        stopForegroundPolling()
        stopMaintenanceConfigPolling()

        // Clear session data; account-scoped notification opt-outs remain saved.
        UserDefaults.standard.removeObject(forKey: "OutAgain.feedCache.v2")
        UserDefaults.standard.removeObject(forKey: "OutAgain.viewerCache.v1")
        UserDefaults.standard.removeObject(forKey: AppStore.pendingDeletedNotificationIDsKey)
        Task {
            await QuickPostLiveActivityManager.endAll()
        }

        viewer = nil
        didAttemptBootstrap = false
        lastFullRefreshAt = nil
        bootstrapPhase = .ready
        authState = .signedOut
        onboardingStep = .welcome
        socialErrorMessage = nil
        selectedTab = .home
        authDraft = EmailPasswordAuthDraft()
        onboardingDraft = OnboardingDraft()
        friends = []
        suggestedFriends = []
        friendOfFriendIDsStore = []
        mutualCounts = [:]
        incomingFriendRequests = []
        outgoingFriendRequests = []
        blockedUserIDs = []
        blockedUsers = []
        adminAllUsers = []
        adminBusyUserIDs = []
        adminStatusMessage = nil
        hasMoreAdminUsers = true
        isLoadingAdminUsers = false
        adminAppAnnouncements = []
        isLoadingAdminAppAnnouncements = false
        drinkCatalogPreferences = DrinkCatalogPreferences()
        lastSyncedDrinkCatalogPreferences = DrinkCatalogPreferences()
        drinks = SeedCatalog.drinks
        venues = SeedCatalog.venues
        posts = []
        resetLocalDiscovery()
        tonightActivityPosts = []
        nightSummaryPosts = []
        nightGroups = []
        nightSummaryGroups = []
        notifications = []
        appAnnouncements = []
        isLoadingOlderHomeFeedPosts = false
        hasOlderHomeFeedPosts = true
        locallyDeletedPostIDs = []
        homeFeedCursorDate = nil
        pendingPostCreates = [:]
        pendingCommentCreates = [:]
        pendingReactionStates = [:]
        pendingCommentLikeStates = [:]
        pendingSeenAppAnnouncementIDs = []
        syncingSeenAppAnnouncementIDs = []
        liveActivityPreferences = LiveActivityPreferences()
        pendingDeletedNotificationIDs = []
        accentColorChoice = .purple
        backgroundTheme = .standard
        resetDraft()
    }

    func refreshCatalogs() {
        let preferences = drinkCatalogPreferences
        let hiddenNames = Set(preferences.deletedDrinkNames.map(AppStore.normalizedDrinkName))

        var mergedDrinks: [String: DrinkTag] = [:]

        for drink in SeedCatalog.drinks {
            let key = AppStore.normalizedDrinkName(drink.name)
            guard !hiddenNames.contains(key) else { continue }
            mergedDrinks[key] = drink
        }

        for custom in preferences.customDrinks {
            let canonical = AppStore.canonicalDrinkTag(custom)
            let key = AppStore.normalizedDrinkName(canonical.name)
            guard !hiddenNames.contains(key) else { continue }
            mergedDrinks[key] = canonical
        }

        var orderedCatalog: [DrinkTag] = []
        var usedNames: Set<String> = []

        for name in preferences.orderedDrinkNames {
            guard let drink = mergedDrinks[name], usedNames.insert(name).inserted else { continue }
            orderedCatalog.append(drink)
        }

        for seed in SeedCatalog.drinks {
            let key = AppStore.normalizedDrinkName(seed.name)
            guard let drink = mergedDrinks[key], usedNames.insert(key).inserted else { continue }
            orderedCatalog.append(drink)
        }

        let remainingCustoms = mergedDrinks
            .filter { !usedNames.contains($0.key) }
            .values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        orderedCatalog.append(contentsOf: remainingCustoms)

        drinks = AppStore.deduplicatedDrinks(orderedCatalog)

        var mergedVenues = Dictionary(uniqueKeysWithValues: SeedCatalog.venues.map { ($0.id, $0) })
        for venue in posts.compactMap(\.venue) {
            mergedVenues[venue.id] = venue
        }
        venues = Array(mergedVenues.values).sorted { $0.name < $1.name }
    }

    func ensureSelectedPresenceCluster() {
        if !presenceClusters.contains(where: { $0.id == selectedPresenceClusterID }) {
            selectedPresenceClusterID = nil
        }
    }

    func promoteToLiveSession() {
        let shouldSelectHome = !isLive || selectedTab == .post
        onboardingStep = .done
        if shouldSelectHome {
            selectedTab = .home
            feedScope = .friends
        }
        ensureSelectedPresenceCluster()
    }

    func refreshAppDataInBackground(promoteLiveSession: Bool = false, silenceErrors: Bool = true) {
        Task {
            await refreshAppData(promoteLiveSession: promoteLiveSession, silenceErrors: silenceErrors)
        }
    }

    func refreshAppConfigOnly() async {
        do {
            let wasInMaintenanceMode = isMaintenanceModeActive
            let newConfig = try await backend.fetchAppConfig()

            // Skip the assignment when the config is unchanged. @Observable
            // doesn't equality-check on write, so without this guard every
            // 60-second poll would invalidate the entire view tree observing
            // appConfig and cause a periodic feed redraw.
            if newConfig != appConfig {
                appConfig = newConfig
            }

            if wasInMaintenanceMode && !isMaintenanceModeActive {
                await refreshAppData(promoteLiveSession: authState != .signedIn, silenceErrors: true)
            }
        } catch {
            // Keep the last-known config. A failed maintenance-config poll
            // should not accidentally dismiss an active maintenance screen.
        }
    }

    func refreshAppConfigInBackground() {
        Task {
            await refreshAppConfigOnly()
        }
    }

    func resetHomeFeedPagination(hasOlderPosts: Bool = true, cursorDate: Date? = nil) {
        isLoadingOlderHomeFeedPosts = false
        hasOlderHomeFeedPosts = hasOlderPosts
        homeFeedCursorDate = cursorDate
    }
}
