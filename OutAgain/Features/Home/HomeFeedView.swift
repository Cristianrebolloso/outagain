import SwiftUI

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

struct HomeFeedView: View {
    @Environment(AppStore.self) private var store
    @Environment(FeedAdStore.self) private var feedAds
    @Environment(PermissionCenter.self) private var permissions
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.duoLayoutContinuity) private var layoutContinuity
    @State private var activeSheet: ActiveHomeSheet?
    @State private var tonightAuthorTarget: UUID?   // author ID whose tonight posts to show
    @State private var homeTabRefreshTask: Task<Void, Never>?
    @State private var isTabRefreshing = false
    /// Tracks scroll offset to detect a manual pull-to-refresh gesture.
    @State private var scrollOffset: CGFloat = 0
    /// Prevents rapid consecutive pull-to-refresh triggers.
    @State private var isInlineComments = false
    @State private var feedViewportHeight: CGFloat = 0
    @State private var feedItemFrames: [FeedVisibleItem: CGRect] = [:]
    // Retain the outgoing profile until its slide has finished.
    @State private var presentedProfile: UserProfile?
    @State private var profilePresentationID = UUID()
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
        Group {
            GeometryReader { safeArea in
                GeometryReader { geometry in
                    // Only a wide window has room for a discussion beside the
                    // feed. An open portrait window keeps one centered feed.
                    let isWide = geometry.size.width > safeArea.size.height
                        + safeArea.safeAreaInsets.top + safeArea.safeAreaInsets.bottom
                    let expanded =
                        isWide && horizontalSizeClass == .regular
                        && geometry.size.width >= AppLayout.inlineCommentsMinimumWidth
                        && (!dynamicTypeSize.isAccessibilitySize || geometry.size.width >= 1_000)
                    let pageWidth = expanded
                        ? (layoutContinuity?.pageWidth(in: geometry.size.width) ?? geometry.size.width / 2)
                        : geometry.size.width
                    let companionWidth = expanded ? geometry.size.width - pageWidth : 0
                    let leadingInset = safeArea.safeAreaInsets.leading
                    let trailingInset = safeArea.safeAreaInsets.trailing
                    // Continue the compact window on the right. Subtract its
                    // native bar once; the companion never inherits that bar.
                    let naturalFeedWidth = max(
                        1,
                        pageWidth
                            - (expanded ? 0 : leadingInset) - trailingInset)
                    let pageContentWidth = expanded
                        ? min(naturalFeedWidth, AppLayout.phoneColumnMaximumWidth)
                        : naturalFeedWidth
                    let feedWidth = expanded ? pageContentWidth
                        : min(naturalFeedWidth, AppLayout.phoneColumnMaximumWidth)
                    let showsProfile = store.homeProfile != nil
                    ZStack(alignment: .topLeading) {
                        Group {
                            if expanded {
                                inlineDiscussion.padding(.top, safeArea.safeAreaInsets.top)
                                    .opacity(store.feedDiscussion.isShowingAd ? 0 : 1)
                                    .allowsHitTesting(!store.feedDiscussion.isShowingAd)
                                    .accessibilityHidden(store.feedDiscussion.isShowingAd)
                                    .animation(reduceMotion ? nil : .easeOut(duration: 0.12),
                                               value: store.feedDiscussion.isShowingAd)
                            }
                        }
                        .environment(\.duoPresentationPane, expanded ? .leading : nil)
                        .environment(\.duoPresentationWidth, expanded ? pageWidth : nil)
                        .padding(.bottom, expanded ? safeArea.safeAreaInsets.bottom : 0)
                        .frame(width: expanded ? max(0, companionWidth - leadingInset) : 0)
                        .padding(.leading, expanded ? leadingInset : 0)
                        .frame(width: companionWidth)
                        .clipped()
                        .offset(x: showsProfile ? -companionWidth : 0)
                        .allowsHitTesting(expanded && !showsProfile)
                        .accessibilityHidden(!expanded || showsProfile)

                        // One scroll view moves between slots; its identity,
                        // image framing and scroll offset survive navigation.
                        homeFeedContent(
                            width: feedWidth,
                            alignment: .center,
                            topInset: safeArea.safeAreaInsets.top
                        )
                            // Home's stories and groups open over the right
                            // pane even while a profile moves the feed left.
                            .environment(\.duoPresentationPane, expanded ? .trailing : nil)
                            .environment(\.duoPresentationWidth, expanded ? pageWidth : nil)
                            .frame(width: expanded && showsProfile ? companionWidth : naturalFeedWidth, alignment: .center)
                            .padding(.leading, expanded ? 0 : leadingInset)
                            .padding(.trailing, expanded && showsProfile ? 0 : trailingInset)
                            .frame(width: expanded && showsProfile ? companionWidth : pageWidth, alignment: .leading)
                            .clipped()
                            .geometryGroup()
                            .offset(x: expanded ? (showsProfile ? 0 : companionWidth) : (showsProfile ? -pageWidth : 0))
                            .allowsHitTesting(expanded || !showsProfile)
                            .accessibilityHidden(!expanded && showsProfile)

                        homeProfilePage(width: pageContentWidth)
                            .environment(\.duoPresentationPane, expanded ? .trailing : nil)
                            .environment(\.duoPresentationWidth, expanded ? pageWidth : nil)
                            .frame(width: pageWidth)
                            .geometryGroup()
                            .offset(x: companionWidth + (showsProfile ? 0 : pageWidth))
                            .allowsHitTesting(showsProfile)
                            .accessibilityHidden(!showsProfile)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                    .clipped()
                    .onChange(of: expanded, initial: true) { oldValue, value in
                        if oldValue && !value {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        }
                        isInlineComments = value
                        moveDiscussionPresentation(expanded: value)
                    }
                }
                // Let scrolled photos reach the display edge. Initial content
                // receives the top inset inside the scroll view instead.
                .ignoresSafeArea(.container, edges: [.top, .horizontal, .bottom])
                // The companion already reserves the outer reader's bottom
                // inset. Keep keyboard avoidance from reserving it twice.
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
        }
        .background(AmbientBackground())
        .onChange(of: store.homeProfile, initial: true) { _, profile in
            if let profile { presentedProfile = profile }
        }
        .onChange(of: store.homeFeedPosts.map(\.id), initial: true) { _, ids in
            store.feedDiscussion.reconcile(postIDs: ids)
        }
        .onChange(of: store.feedDiscussion.isShowingAd) { _, isShowingAd in
            if isShowingAd && isInlineComments {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        }
    }

    private func homeProfilePage(width: CGFloat) -> some View {
        // The profile owns its navigation safe area. Its toolbar must never
        // resize the neighboring feed or change the feed's content insets.
        NavigationStack {
            Group {
                if let profile = presentedProfile {
                    FriendProfileView(
                        profile: profile,
                        presentationStyle: .embedded,
                        showsBackButton: false,
                        onBack: closeHomeProfile
                    )
                    .id(profile.id)
                    // The outgoing view stays alive for its slide. Restore
                    // the viewer's backdrop as soon as Back is pressed.
                    .environment(\.isProfileSceneThemeActive, store.homeProfile != nil)
                    .modifier(DuoPageViewport())
                } else {
                    Color.clear
                }
            }
            .environment(\.duoPageContentWidth, width)
            .containerBackground(.clear, for: .navigation)
            .toolbar(store.homeProfile == nil ? .hidden : .visible, for: .navigationBar)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if store.homeProfile != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back to feed", systemImage: "chevron.left", action: closeHomeProfile)
                            .accessibilityIdentifier("home.profile.back")
                    }
                }
            }
        }
        .accessibilityIdentifier("home.profile")
        .accessibilityAction(.escape, closeHomeProfile)
    }

    private var profileSlideAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.24)
    }

    private func closeHomeProfile() {
        guard store.homeProfile != nil else { return }
        let closingPresentationID = profilePresentationID
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(profileSlideAnimation, completionCriteria: .logicallyComplete) {
            store.homeProfile = nil
        } completion: {
            if store.homeProfile == nil, profilePresentationID == closingPresentationID {
                presentedProfile = nil
            }
        }
    }

    private func homeFeedContent(width: CGFloat, alignment: Alignment, topInset: CGFloat) -> some View {
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
                        // Offline banner — shown when the last refresh was a
                        // transport failure. Non-blocking: cached content is still
                        // visible below. Disappears automatically once connectivity
                        // is restored and a background refresh succeeds.
                        if store.offlineNotice.isVisible {
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
                        if store.feedScope == .friends && (!store.homeFeedPosts.isEmpty || !store.nightGroups.isEmpty) {
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
                            .frame(maxWidth: AppLayout.feedMaximumWidth)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, feedPostHorizontalInset)
                    }
                    .frame(width: width)
                    // Keep the post column narrow while making both empty
                    // margins part of the same native scrolling surface.
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .contentShape(Rectangle())
                    .padding(.top, max(0, topInset) + 8)
                    .padding(.bottom, AppLayout.tabBarClearance)
                    .id("home-feed-top")
                }
                .coordinateSpace(name: "homeFeedScroll")
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                // Preserve the top content coordinate as the display resizes.
                // Re-anchoring to a post ID would move a partially visible
                // image when the outer and inner viewport heights differ.
                .defaultScrollAnchor(.top, for: .sizeChanges)
                .accessibilityIdentifier("home.feed")
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    feedViewportHeight = height
                    followVisibleItem(in: feedItemFrames)
                }
                .onPreferenceChange(FeedItemFramesKey.self) { frames in
                    feedItemFrames = frames
                    followVisibleItem(in: frames)
                }
                .onPreferenceChange(ScrollOffsetKey.self) { offset in
                    scrollOffset = offset
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.always, axes: .vertical)
                .glassPullToRefresh(isRefreshing: isTabRefreshing) { await runManualRefresh() }
                .scrollContentBackground(.hidden)
                .modifier(HomeLocalDiscoveryRefresh())
                .task {
                    #if DEBUG
                    if store.isLayoutPreview, let postID = DuoLayoutFixtures.initialContinuityPostID {
                        proxy.scrollTo(postID, anchor: .center)
                    }
                    #endif
                }
                .onChange(of: store.homeTabSelectionTrigger) { _, _ in
                    closeHomeProfile()
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
                            .appSheetDragHandle(contentWidth: PostDetailPresentation.sheetWidth)
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
                                openComments(for: post)
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
                    .appSheetDragHandle(contentWidth: PostDetailPresentation.sheetWidth)
                }
            }
    }

    @ViewBuilder
    private var inlineDiscussion: some View {
        if let postID = store.feedDiscussion.selectedPostID,
           let post = store.livePost(matching: postID) {
            InlineFeedDiscussion(post: post)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(AppTypography.sectionTitle)
                Text("Comments appear beside your feed")
                    .font(AppTypography.rowSubtitle)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(AppTheme.softText)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func openComments(for post: MomentPost) {
        store.feedDiscussion.select(post.id, focusComposer: isInlineComments)
        if !isInlineComments { activeSheet = .comments(post) }
    }

    private func moveDiscussionPresentation(expanded: Bool) {
        if expanded, case .comments(let post) = activeSheet {
            store.feedDiscussion.select(post.id)
            activeSheet = nil
        }
        // Closing continues the feed on the outer display. Per-post drafts
        // remain in AppStore and can be resumed by reopening or tapping comments.
    }

    private func followVisibleItem(in frames: [FeedVisibleItem: CGRect]) {
        guard feedViewportHeight > 0 else { return }
        guard let candidate = FeedVisibleItemSelection.dominantItem(
            frames: frames, viewportHeight: feedViewportHeight,
            current: store.feedDiscussion.visibleItem
        ) else {
            store.feedDiscussion.clearVisibleAdvertisement()
            return
        }
        // Geometry arrives throughout the gesture. A small spatial margin
        // prevents boundary flicker without waiting for the scroll to stop.
        switch candidate {
        case .post(let postID):
            guard store.homeFeedPosts.contains(where: { $0.id == postID }) else { return }
            store.feedDiscussion.follow(postID)
        case .advertisement(let anchorID):
            guard store.homeFeedPosts.contains(where: { $0.id == anchorID }) else { return }
            store.feedDiscussion.followAdvertisement(after: anchorID)
        }
    }

    private func openProfile(_ profile: UserProfile) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        profilePresentationID = UUID()
        presentedProfile = profile
        withAnimation(profileSlideAnimation) {
            store.homeProfile = profile
        }
    }

    @ViewBuilder
    private var feedPosts: some View {
        let posts = store.homeFeedPosts
        let postIDs = posts.map(\.id)
        let adAnchors = Set(FeedAdPlacement.anchors(in: postIDs))

        LazyVStack(spacing: 22) {
            ForEach(Array(posts.enumerated()), id: \.element.id) { index, post in
                if store.feedScope == .friends {
                    HomeFeedPeriodHeading(
                        date: post.createdAt,
                        previousDate: index > 0 ? posts[index - 1].createdAt : nil
                    )
                }
                MomentPostCard(
                    post: post,
                    isFocused: false,
                    onCommentTap: {
                        openComments(for: post)
                    },
                    onAuthorTap: { profile in
                        openProfile(profile)
                    }
                )
                .id(post.id)
                .onAppear { feedAds.postAppeared(at: index, postIDs: postIDs) }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: FeedItemFramesKey.self,
                            value: [.post(post.id): geometry.frame(in: .named("homeFeedScroll"))]
                        )
                    }
                }
                if store.areFeedAdsEnabled && adAnchors.contains(post.id) {
                    FeedNativeAdCard(anchorID: post.id)
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: FeedItemFramesKey.self,
                                    value: [.advertisement(post.id): geometry.frame(in: .named("homeFeedScroll"))]
                                )
                            }
                        }
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
        FriendsFeedEmptyState()
            .padding(.horizontal, AppLayout.screenPadding)
    }

    private func runManualRefresh() async {
        guard !isTabRefreshing else { return }
        let startedAt = Date()
        withAnimation(.easeOut(duration: 0.18)) { isTabRefreshing = true }
        defer { withAnimation(.easeOut(duration: 0.18)) { isTabRefreshing = false } }
        if !store.isLayoutPreview { permissions.requestLocation() }
        if store.feedScope == .local {
            await store.refreshLocalFeed(at: permissions.currentLocationSnapshot, force: true)
        } else {
            await store.refreshAppData(silenceErrors: true)
            await store.refreshLocalFeed(at: permissions.currentLocationSnapshot, force: true)
        }
        await MainTabRefreshFeedback.waitForMinimumVisibleDuration(since: startedAt)
    }
}

// MARK: - Scroll Offset Preference Key

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct FeedItemFramesKey: PreferenceKey {
    static let defaultValue: [FeedVisibleItem: CGRect] = [:]
    static func reduce(value: inout [FeedVisibleItem: CGRect], nextValue: () -> [FeedVisibleItem: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct InlineFeedDiscussion: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    let post: MomentPost

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                DuoPageHeading(title: "Comments")
                if let visibleID = store.feedDiscussion.visiblePostID, visibleID != post.id {
                    Button("Follow feed") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                        store.feedDiscussion.resumeFollowing()
                    }
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(accent)
                    .padding(.horizontal, AppLayout.screenPadding)
                    .accessibilityIdentifier("comments.followFeed")
                }
            }
            CommentThreadSheet(
                postID: post.id,
                initialPost: post,
                isEmbedded: true,
                externalFocusRequestID: store.feedDiscussion.focusPostID == post.id ? store.feedDiscussion.focusRequestID : 0,
                onInteractionChanged: { engaged in
                    if store.feedDiscussion.selectedPostID == post.id {
                        store.feedDiscussion.isInteracting = engaged
                    }
                },
                onDraftChanged: { store.feedDiscussion.setDraftPresent($0, for: post.id) },
                onSubmitted: { store.feedDiscussion.didSubmit(to: post.id) }
            )
            .id(post.id)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("comments.inline")
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
                .padding(.top, store.isDuoDevice ? 12 : 36)
                .padding(.bottom, 32)
                .modifier(PostDetailColumn())
            }
            .scrollIndicators(.hidden)
            .modifier(MainPageSurface())
            .modifier(DuoModalNavigation(title: authorName))
        }
        .modifier(DuoSheetSurface())
        .modifier(PostDetailPresentation())
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

enum ActivityNightText {
    static func postCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "post" : "posts")"
    }

    static func memberCountLabel(_ count: Int) -> String {
        "\(count) \(count == 1 ? "member" : "members")"
    }

    static func latestTimeLabel(_ date: Date?) -> String {
        date?.postClockTimeLabel ?? "Tonight"
    }

    static func startedTimeLabel(for posts: [MomentPost]) -> String {
        guard let firstPostDate = posts.map(\.createdAt).min() else {
            return "Not started"
        }

        return firstPostDate.postClockTimeLabel
    }
}

struct ActivityNightOverviewStat: Identifiable {
    let id: String
    let symbol: String
    let title: String
    let value: String
    let tint: Color

    init(symbol: String, title: String, value: String, tint: Color) {
        self.id = title
        self.symbol = symbol
        self.title = title
        self.value = value
        self.tint = tint
    }
}

struct ActivityDrinkListItem: Identifiable {
    let id: String
    let drink: DrinkTag
    let count: Int
    let detail: String?
}

struct ActivityNightOverviewCard: View {
    let title: String
    let subtitle: String?
    let value: String
    let unit: String
    let stats: [ActivityNightOverviewStat]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                ActivityMetricIcon(symbol: "moon.stars.fill", tint: tint, size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppTypography.metadataEmphasis)
                        .foregroundStyle(.white.opacity(0.72))
                        .textCase(.uppercase)
                        .tracking(1.3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    if let subtitle {
                        Text(subtitle)
                            .font(AppTypography.captionMedium)
                            .foregroundStyle(AppTheme.softText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                }

                Spacer(minLength: 8)
            }

            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(value)
                    .font(AppTypography.statFeature)
                    .foregroundStyle(.white)
                    .shadow(color: tint.opacity(0.62), radius: 16)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Text(unit)
                    .font(AppTypography.heroSubtitle)
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.bottom, 6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            HStack(spacing: 10) {
                ForEach(stats) { stat in
                    ActivityNightOverviewStatPill(stat: stat)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    tint.opacity(0.20),
                    Color.white.opacity(0.07),
                    Color.black.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: tint.opacity(0.18), radius: 24, y: 10)
        .glassEffect(.regular.tint(tint.opacity(0.12)), in: .rect(cornerRadius: 30))
    }
}

private struct ActivityNightOverviewStatPill: View {
    let stat: ActivityNightOverviewStat

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: stat.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.88))

                Text(stat.title)
                    .font(AppTypography.caption2Emphasis)
                    .foregroundStyle(.white.opacity(0.62))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            Text(stat.value)
                .font(AppTypography.controlLabel)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stat.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
    }
}

struct ActivityDrinkListCard: View {
    let title: String
    let items: [ActivityDrinkListItem]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActivityMetricHeader(symbol: "wineglass.fill", title: title, tint: tint)

            if items.isEmpty {
                Text("No drink tags yet")
                    .font(AppTypography.rowSubtitle)
                    .foregroundStyle(AppTheme.softText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ActivityDrinkListRow(item: item)

                        if index < items.count - 1 {
                            Divider()
                                .overlay(.white.opacity(0.08))
                                .padding(.leading, 56)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    tint.opacity(0.13),
                    Color.white.opacity(0.055)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .glassEffect(.regular.tint(tint.opacity(0.08)), in: .rect(cornerRadius: 24))
    }
}

private struct ActivityDrinkListRow: View {
    let item: ActivityDrinkListItem

    var body: some View {
        HStack(spacing: 12) {
            DrinkIconView(drink: item.drink, size: 32)
                .frame(width: 44, height: 44)
                .background(Color(hex: item.drink.primaryHex).opacity(0.16), in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(item.drink.name)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)

                if let detail = item.detail {
                    Text(detail)
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(AppTheme.softText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
            }

            Spacer(minLength: 8)

            Text("\(item.count)")
                .font(AppTypography.controlLabel)
                .foregroundStyle(.white)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(minWidth: 20, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }
}

struct ActivityContextPill: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))

            Text(text)
                .font(AppTypography.metadataEmphasis)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white.opacity(0.88))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .primaryGlass(in: .capsule)
    }
}

private struct ActivityMetricHeader: View {
    let symbol: String
    let title: String
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            ActivityMetricIcon(symbol: symbol, tint: tint, size: 30)

            Text(title)
                .font(AppTypography.metadataEmphasis)
                .foregroundStyle(.white.opacity(0.70))
                .textCase(.uppercase)
                .tracking(1.1)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }
}

private struct ActivityMetricIcon: View {
    let symbol: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.43, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.opacity(0.22), in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: tint.opacity(0.38), radius: 9)
    }
}
