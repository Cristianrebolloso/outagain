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
            await self?.refreshAppData(promoteLiveSession: true, silenceErrors: true)
            // Kick off polling once the first bootstrap has resolved so
            // in-app state stays fresh without waiting for a background /
            // foreground cycle.
            await MainActor.run { self?.startForegroundPollingIfNeeded() }
        }
    }

    func refreshAppData(promoteLiveSession: Bool = false, silenceErrors: Bool = false) async {
        BootstrapTrace.mark("refreshAppData task started")
        defer {
            // The first bootstrap always flips us into `.ready` even if it
            // failed — otherwise a transient network failure traps us on the
            // loading splash forever. Subsequent refreshes leave it `.ready`.
            bootstrapPhase = .ready
            BootstrapTrace.mark("bootstrapPhase = .ready (UI unblocked)")
        }

        do {
            await syncPendingDeletedNotifications()
            BootstrapTrace.mark("backend.loadAppData() awaiting")
            let bootstrap = try await backend.loadAppData()
            BootstrapTrace.mark("backend.loadAppData() returned")
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
                    incomingFriendRequests = []
                    outgoingFriendRequests = []
                    blockedUserIDs = []
                    blockedUsers = []
                    posts = []
                    notifications = []
                    ensureSelectedPresenceCluster()
                }
                // If we still have a session but got no profile, leave the
                // existing UI state intact — the next refresh will recover.
                return
            }

            applyBootstrap(bootstrap)
            lastFullRefreshAt = .now
            authState = .signedIn

            if backendViewer.username.isEmpty {
                onboardingStep = .profile
            } else if promoteLiveSession {
                promoteToLiveSession()
            }

            if onboardingDraft.inviteLink.isEmpty {
                onboardingDraft.inviteLink = backend.createInviteLink(for: backendViewer.username).absoluteString
            }

            ensureSelectedPresenceCluster()

            // Sync tonight's groups for this user — fires concurrently after
            // the main bootstrap so it never delays the feed rendering.
            // All members of a group fetch the same rows via RLS, so everyone
            // sees groups they were added to without any client-side broadcast.
            Task { await syncGroupsFromBackend() }
        } catch SupabaseBackendError.notAuthenticated {
            // Only sign out when the backend has confirmed there is genuinely
            // no valid session — i.e. the stored session was already cleared
            // by ensureAuthenticatedSession() because the server explicitly
            // rejected the refresh token with invalid_grant. If a session is
            // still persisted (hasStoredSession == true), the notAuthenticated
            // throw came from a transient race or a momentarily nil authSession
            // during a background refresh; signing out in that case would be
            // incorrect and is exactly what was causing random logouts.
            guard !backend.hasStoredSession else { return }
            viewer = nil
            authState = .signedOut
            onboardingStep = .welcome
            friends = []
            suggestedFriends = []
            friendOfFriendIDsStore = []
            incomingFriendRequests = []
            outgoingFriendRequests = []
            blockedUserIDs = []
            blockedUsers = []
            posts = []
            notifications = []
            ensureSelectedPresenceCluster()
        } catch {
            if !silenceErrors {
                socialErrorMessage = "Couldn't refresh the app from the backend yet."
            }
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
        guard bootstrapPhase == .ready, authState == .signedIn else { return }
        let needsFullRefresh = lastFullRefreshAt.map { Date().timeIntervalSince($0) > 10 * 60 } ?? true
        if needsFullRefresh {
            refreshAppDataInBackground()
        } else {
            Task {
                await pollNewNotifications()
                await pollNewFeedPosts()
            }
        }
        startForegroundPollingIfNeeded()
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
                if tickCount % 20 == 0 {
                    // Full refresh every 20 minutes.
                    await self?.refreshAppData(silenceErrors: true)
                } else {
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

    /// Lightweight delta poll — fetches only notification rows created after
    /// the last known notification timestamp. Merges new rows into the existing
    /// in-memory list without touching friends, posts, or reactions. A single
    /// indexed RPC call on the server; typically returns an empty array.
    func pollNewNotifications() async {
        guard authState == .signedIn else { return }
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
                let structuralKinds: Set<NotificationKind> = [.friendRequest, .friendAccepted, .groupAdded]
                shouldTriggerFullRefresh = fresh.contains { structuralKinds.contains($0.kind) }
                notifications = (fresh + notifications).sorted { $0.createdAt > $1.createdAt }
            }
            if shouldTriggerFullRefresh {
                await refreshAppData(silenceErrors: true)
            }
        } catch {
            // Delta poll failures are silent — the next full refresh recovers.
        }
    }

    /// Lightweight feed delta — returns only posts newer than the newest post
    /// already visible in the home feed graph, then merges them into `store.posts`.
    func pollNewFeedPosts() async {
        guard authState == .signedIn, let viewer else { return }

        let visibleAuthorIDs = directFriendIDs
            .union(friendOfFriendIDs)
            .union([viewer.id])
        let since = posts
            .filter { visibleAuthorIDs.contains($0.author.id) }
            .map(\.createdAt)
            .max() ?? Date(timeIntervalSinceNow: -3600)

        do {
            let newPosts = visiblePosts(
                try await backend.fetchNewFeedPosts(since: since, viewer: viewer)
            )
            guard !newPosts.isEmpty else { return }

            let existingIDs = Set(posts.map(\.id))
            let fresh = newPosts.filter { !existingIDs.contains($0.id) }
            guard !fresh.isEmpty else { return }

            posts = sortPostsByRecency(fresh + posts)
            refreshCatalogs()
            ensureSelectedPresenceCluster()
            persistFeedCache()
        } catch {
            // Feed delta failures are silent — the next full refresh recovers.
        }
    }

    func applyBootstrap(_ bootstrap: SocialBootstrap) {
        if let backendViewer = bootstrap.viewer {
            viewer = backendViewer
            onboardingDraft.displayName = backendViewer.displayName
            onboardingDraft.username = backendViewer.username
        }

        applyDrinkCatalogBootstrapPreferences(bootstrap.drinkCatalogPreferences)

        friends = bootstrap.friends
        suggestedFriends = bootstrap.suggestedFriends
        friendOfFriendIDsStore = bootstrap.friendOfFriendIDs
        incomingFriendRequests = bootstrap.incomingRequests.sorted { $0.createdAt > $1.createdAt }
        outgoingFriendRequests = bootstrap.outgoingRequests.sorted { $0.createdAt > $1.createdAt }
        blockedUserIDs = bootstrap.blockedUserIDs
        blockedUsers = sortProfilesByDisplayName(bootstrap.blockedUsers)
        posts = sortPostsByRecency(visiblePosts(bootstrap.posts))
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
        refreshCatalogs()

        // If a token was captured before the viewer existed, register it now.
        Task { await flushPendingAPNsTokenIfPossible() }

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

    func signOut() async {
        await unregisterAPNsTokenIfNeeded()
        try? await backend.signOut()
        finishSessionEndedLocally()
    }

    func finishSessionEndedLocally() {
        // Wipe the feed cache so the next user on this device starts clean.
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
        selectedTab = .home
        authDraft = EmailPasswordAuthDraft()
        onboardingDraft = OnboardingDraft()
        friends = []
        suggestedFriends = []
        friendOfFriendIDsStore = []
        incomingFriendRequests = []
        outgoingFriendRequests = []
        blockedUserIDs = []
        blockedUsers = []
        drinkCatalogPreferences = DrinkCatalogPreferences()
        lastSyncedDrinkCatalogPreferences = DrinkCatalogPreferences()
        drinks = SeedCatalog.drinks
        venues = SeedCatalog.venues
        posts = []
        notifications = []
        pendingDeletedNotificationIDs = []
        resetDraft()
    }

    func refreshCatalogs() {
        let preferences = drinkCatalogPreferences
        let hiddenNames = Set(preferences.deletedDrinkNames.map(AppStore.normalizedDrinkName))
        let seedByName: [String: DrinkTag] = Dictionary(
            uniqueKeysWithValues: SeedCatalog.drinks.map {
                (AppStore.normalizedDrinkName($0.name), $0)
            }
        )

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

        let viewerID = viewer?.id
        for postedDrink in posts.filter({ $0.author.id == viewerID }).map(\.drink) {
            let key = AppStore.normalizedDrinkName(postedDrink.name)
            guard !hiddenNames.contains(key) else { continue }
            if let seedDrink = seedByName[key] {
                mergedDrinks[key] = seedDrink
            } else if mergedDrinks[key] == nil {
                mergedDrinks[key] = AppStore.canonicalDrinkTag(postedDrink)
            }
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
        onboardingStep = .done
        selectedTab = .home
        feedScope = .friends
        ensureSelectedPresenceCluster()
    }

    func refreshAppDataInBackground(promoteLiveSession: Bool = false, silenceErrors: Bool = true) {
        Task {
            await refreshAppData(promoteLiveSession: promoteLiveSession, silenceErrors: silenceErrors)
        }
    }
}
