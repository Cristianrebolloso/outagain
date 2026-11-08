import SwiftUI

struct PhoneHomeFeedView: View {
    @Environment(AppStore.self) private var store
    @Environment(FeedAdStore.self) private var feedAds
    @Environment(PermissionCenter.self) private var permissions
    @State private var activeSheet: ActiveHomeSheet?
    @State private var tonightAuthorTarget: UUID?   // author ID whose tonight posts to show
    @State private var homeTabRefreshTask: Task<Void, Never>?
    /// Tracks scroll offset to detect a manual pull-to-refresh gesture.
    @State private var scrollOffset: CGFloat = 0
    /// Prevents rapid consecutive pull-to-refresh triggers.
    @State private var didTriggerPullRefresh = false
    private let feedPostHorizontalInset: CGFloat = 0

    private enum ActiveHomeSheet: Identifiable {
        case comments(MomentPost)
        case groupFeed(NightGroup)
        case groupCreation

        var id: String {
            switch self {
            case .comments(let post):
                return "comments-\(post.id.uuidString)"
            case .groupFeed(let group):
                return "group-\(group.id.uuidString)"
            case .groupCreation:
                return "group-creation"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    // Invisible anchor used to read scroll offset via preference key.
                    GeometryReader { geo in
                        Color.clear
                            .preference(
                                key: ScrollOffsetKey.self,
                                value: geo.frame(in: .named("homeFeedScroll")).minY
                            )
                    }
                    .frame(height: 0)

                    VStack(alignment: .leading, spacing: 14) {
                        Color.clear
                            .frame(height: 0)
                            .id("home-feed-top")

                        // Offline banner — shown when the last refresh was a
                        // transport failure. Non-blocking: cached content is still
                        // visible below. Disappears automatically once connectivity
                        // is restored and a background refresh succeeds.
                        if store.isOffline {
                            HStack(spacing: 8) {
                                Image(systemName: "wifi.slash")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("You're offline — showing cached content")
                                    .font(AppTypography.captionMedium)
                            }
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .padding(.horizontal, 16)
                            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                            )
                            .padding(.horizontal, AppLayout.screenPadding)
                            .transition(.opacity.animation(.easeInOut(duration: 0.22)))
                        }

                        if store.hasLocalFeedPosts || store.latestNightRecapRoute != nil {
                            HomeFeedScopeControl()
                                .padding(.horizontal, AppLayout.screenPadding)
                        }
                        if store.feedScope == .friends {
                        TonightActivityStrip(
                            onFriendPostTap: { authorID in
                                store.cacheProfilePosts(store.tonightPosts(for: authorID))
                                tonightAuthorTarget = authorID
                            },
                            onFriendProfileTap: { profile in
                                openProfile(profile)
                            },
                            onCreateGroupTap: {
                                activeSheet = .groupCreation
                            },
                            onGroupTap: { group in
                                store.cacheProfilePosts(store.groupPosts(for: group))
                                activeSheet = .groupFeed(group)
                            }
                        )
                        }
                        // Strip sits outside the horizontal padding so its ScrollView
                        // bleeds to the screen edge and the last avatar isn't clipped.
                        // feedPosts carries its own padding below.
                        feedPosts
                            .padding(.horizontal, feedPostHorizontalInset)
                    }
                    .padding(.top, -10)
                    .padding(.bottom, AppLayout.tabBarClearance)
                }
                .coordinateSpace(name: "homeFeedScroll")
                .onPreferenceChange(ScrollOffsetKey.self) { offset in
                    scrollOffset = offset
                    // Trigger refresh when pulled down past 60pt and not already refreshing.
                    if offset > 60 && !didTriggerPullRefresh {
                        didTriggerPullRefresh = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        homeTabRefreshTask?.cancel()
                        homeTabRefreshTask = Task {
                            await runManualRefresh()
                        }
                    }
                    // Reset trigger guard once scroll returns to top
                    if offset <= 0 {
                        didTriggerPullRefresh = false
                    }
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollContentBackground(.hidden)
                .background {
                    AmbientBackground()
                        .ignoresSafeArea()
                }
                .modifier(HomeLocalDiscoveryRefresh())
                .onChange(of: store.homeTabSelectionTrigger) { _, _ in
                    proxy.scrollTo("home-feed-top", anchor: .top)

                    homeTabRefreshTask?.cancel()
                    homeTabRefreshTask = Task {
                        await runManualRefresh()
                    }
                }
                .onChange(of: store.activeGroupID) { _, groupID in
                    guard let groupID,
                          let group = store.nightGroups.first(where: { $0.id == groupID })
                    else { return }
                    activeSheet = .groupFeed(group)
                    store.activeGroupID = nil
                }
                // ── Polling removed ──────────────────────────────────────────────
                // The previous 20-second loop was generating ~43k DB requests/day
                // even with a tiny user base. Foreground refresh is now handled
                // entirely by AppStore.startForegroundPollingIfNeeded() which runs:
                //   • Delta notification poll every 60s
                //   • Delta feed-post poll every 120s
                //   • Full bootstrap every 20 minutes
                // Pull-to-refresh and post-mutation refreshes cover everything else.
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .comments(let post):
                        CommentThreadSheet(postID: post.id, initialPost: post)
                            .presentationDetents([.large])
                            .appSheetDragHandle()
                    case .groupFeed(let group):
                        GroupFeedView(group: group)
                            .environment(\.appAccent, store.accentColorChoice.color)
                            .presentationDetents([.large])
                            .appSheetDragHandle()
                    case .groupCreation:
                        GroupCreationSheet()
                            .environment(\.appAccent, store.accentColorChoice.color)
                            .presentationDetents([.large])
                            .appSheetDragHandle()
                    }
                }
                .sheet(item: $tonightAuthorTarget) { authorID in
                    // All tonight posts for this author — count matches the pill.
                    TonightAuthorSheet(
                        authorID: authorID,
                        onCommentTap: { post in
                            tonightAuthorTarget = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                activeSheet = .comments(post)
                            }
                        },
                        onAuthorTap: { profile in
                            tonightAuthorTarget = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                openProfile(profile)
                            }
                        }
                    )
                    .presentationDetents([.large])
                    .appSheetDragHandle()
                }
            }
        }
    }

    private func openProfile(_ profile: UserProfile) {
        if profile.id == store.viewer?.id {
            store.selectedTab = .profile
        } else {
            store.profileOverlayRoute = .userProfile(profile)
        }
    }

    @ViewBuilder
    private var feedPosts: some View {
        let posts = store.homeFeedPosts
        let postIDs = posts.map(\.id)
        let adAnchors = Set(FeedAdPlacement.anchors(in: postIDs))

        LazyVStack(spacing: 22) {
            ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                MomentPostCard(
                    post: post,
                    isFocused: false,
                    onCommentTap: {
                        activeSheet = .comments(post)
                    },
                    onAuthorTap: { profile in
                        openProfile(profile)
                    }
                )
                .onAppear { feedAds.postAppeared(at: index, postIDs: postIDs) }
                if store.areFeedAdsEnabled && adAnchors.contains(post.id) {
                    FeedNativeAdCard(anchorID: post.id)
                }
            }

            if posts.isEmpty {
                if store.feedScope == .local {
                    LocalFeedEmptyState()
                } else {
                    emptyFeedState.padding(.top, 8)
                }
            } else if store.hasOlderSelectedFeedPosts {
                if store.isLoadingSelectedFeedPosts {
                    ProgressView()
                        .tint(store.accentColorChoice.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                } else {
                    Color.clear
                        .frame(height: 1)
                        .onAppear {
                            Task {
                                await store.loadOlderHomeSelection(at: permissions.currentLocationSnapshot)
                            }
                        }
                }
            }
        }
        .task(id: FeedAdRequestState(postIDs: postIDs, enabled: store.areFeedAdsEnabled)) {
            await feedAds.prepare(postIDs: postIDs, isLayoutPreview: store.isLayoutPreview, enabled: store.areFeedAdsEnabled)
        }
    }

    private var emptyFeedState: some View {
        NightPanel(cornerRadius: 28, padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "moon.stars.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(store.accentColorChoice.color.opacity(0.85))
                Text("No posts yet")
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(.white)
            }
        }
    }

    private func runManualRefresh() async {
        if !store.isLayoutPreview { permissions.requestLocation() }
        if store.feedScope == .local {
            await store.refreshLocalFeed(at: permissions.currentLocationSnapshot, force: true)
        } else {
            await store.refreshAppData(silenceErrors: true)
            await store.refreshLocalFeed(at: permissions.currentLocationSnapshot, force: true)
        }
    }
}

// MARK: - Scroll Offset Preference Key

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Tonight Author Sheet

/// Shows all of a given author's tonight posts in a scrollable feed.
/// The count on the strip pill and the number of cards here are always
/// in sync because both derive from the same 7am-to-7am activity source.
private struct TonightAuthorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    private let contentHorizontalPadding: CGFloat = 16
    let authorID: UUID
    let onCommentTap: (MomentPost) -> Void
    let onAuthorTap: (UserProfile) -> Void

    /// All posts by this author within tonight's window, newest first.
    private var tonightPosts: [MomentPost] {
        store.tonightPosts(for: authorID)
    }

    private var authorName: String {
        tonightPosts.first?.author.displayName
            ?? store.friends.first(where: { $0.id == authorID })?.displayName
            ?? "Tonight"
    }

    private var drinkSummaries: [AuthorDrinkSummary] {
        var summaries: [String: AuthorDrinkSummary] = [:]
        var order: [String] = []

        for post in tonightPosts {
            guard let drink = post.drink else { continue }
            let key = AppStore.normalizedDrinkName(drink.name)

            if var summary = summaries[key] {
                summary.count += 1
                summaries[key] = summary
            } else {
                summaries[key] = AuthorDrinkSummary(
                    id: key,
                    drink: drink,
                    count: 1,
                    latestPostDate: post.createdAt
                )
                order.append(key)
            }
        }

        return order.compactMap { summaries[$0] }
    }

    private var latestPostDate: Date? {
        tonightPosts.first?.createdAt
    }

    private var uniqueTaggedFriends: [UserProfile] {
        var seen = Set<UUID>()
        var friends: [UserProfile] = []

        for post in tonightPosts {
            for friend in post.taggedFriends where friend.id != authorID {
                if seen.insert(friend.id).inserted {
                    friends.append(friend)
                }
            }
        }

        return friends
    }

    private var nightSummaryTitle: String {
        "\(possessiveName(authorName)) night"
    }

    private var drinkListItems: [ActivityDrinkListItem] {
        drinkSummaries.map {
            ActivityDrinkListItem(
                id: $0.id,
                drink: $0.drink,
                count: $0.count,
                detail: nil
            )
        }
    }

    private var companionSummary: String? {
        guard !uniqueTaggedFriends.isEmpty else { return nil }

        let visibleNames = uniqueTaggedFriends.prefix(2).map(\.displayName)
        let hiddenCount = max(0, uniqueTaggedFriends.count - visibleNames.count)

        switch visibleNames.count {
        case 0:
            return nil
        case 1:
            return "With \(visibleNames[0]) tonight"
        default:
            if hiddenCount > 0 {
                return "With \(visibleNames[0]), \(visibleNames[1]) +\(hiddenCount) more tonight"
            }

            return "With \(visibleNames[0]) and \(visibleNames[1]) tonight"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !tonightPosts.isEmpty {
                        nightRecap
                    }

                    if tonightPosts.isEmpty {
                        // Defensive fallback — shouldn't normally show
                        // because the strip only routes here when count > 0.
                        EmptyStateCard(
                            title: "No posts yet tonight",
                            symbol: "moon.stars.fill"
                        )
                        .padding(.top, 32)
                    } else {
                        ForEach(tonightPosts) { post in
                            MomentPostCard(
                                post: post,
                                isFocused: true,
                                onCommentTap: { onCommentTap(post) },
                                onAuthorTap: onAuthorTap
                            )
                            .padding(.horizontal, -contentHorizontalPadding)
                        }
                    }
                }
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.top, 36)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground())
        }
    }

    /// A compact stats-style recap for the author tile. The posts below still
    /// carry the full post context, so this section avoids repeating totals and
    /// focuses on timeline plus drink list.
    private var nightRecap: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActivityNightOverviewCard(
                title: nightSummaryTitle,
                subtitle: nil,
                value: "\(tonightPosts.count)",
                unit: tonightPosts.count == 1 ? "post" : "posts",
                stats: [
                    ActivityNightOverviewStat(
                        symbol: "play.fill",
                        title: "Started",
                        value: ActivityNightText.startedTimeLabel(for: tonightPosts),
                        tint: AppTheme.barLightGreen
                    ),
                    ActivityNightOverviewStat(
                        symbol: "clock.fill",
                        title: "Latest",
                        value: ActivityNightText.latestTimeLabel(latestPostDate),
                        tint: AppTheme.barLightBlue
                    )
                ],
                tint: accent
            )

            ActivityDrinkListCard(
                title: "Drinks tonight",
                items: drinkListItems,
                tint: AppTheme.barLightGreen
            )

            if let companionSummary {
                ActivityContextPill(symbol: "person.2.fill", text: companionSummary)
            }
        }
    }

    private func possessiveName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Tonight's" }

        if trimmed.lowercased().hasSuffix("s") {
            return "\(trimmed)'"
        }

        return "\(trimmed)'s"
    }

    private struct AuthorDrinkSummary: Identifiable {
        let id: String
        let drink: DrinkTag
        var count: Int
        let latestPostDate: Date
    }
}

