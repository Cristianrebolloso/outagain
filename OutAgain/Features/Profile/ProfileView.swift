import PhotosUI
import SwiftUI
import UIKit

/// Profile restructured to behave like a social profile rather than a
/// settings drawer. The header carries identity and the two counters
/// that matter (friends, moments) — "nights" was removed because it
/// correlates near-perfectly with moment count in practice and the extra
/// number dilutes rather than informs. A segmented control flips between
/// the viewer's own posts (grid, Instagram-style) and a slim Stats
/// readout. Settings were pulled out into their own destination behind
/// a gear icon so identity and administration stop competing for the
/// same scroll.
struct ProfileView: View {
    private static let paginationPrefetchThreshold = 6

    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @State private var profileGridWidth: CGFloat = 360
    @State private var isDuoExpanded = false
    @State private var pageRoute: ProfileOverlayRoute?
    @State private var selectedSection: ProfileSection = .moments
    @State private var detailPost: MomentPost?
    @State private var isShowingRefreshConfirmation = false
    @State private var isShowingProfileSavedConfirmation = false
    @State private var isTabRefreshing = false
    @State private var profileScrollOffset: CGFloat = 0
    @State private var didTriggerPullRefresh = false

    @State private var viewerProfilePosts: [MomentPost] = []
    @State private var viewerProfilePostCount: Int?
    @State private var viewerHasMorePosts = true
    @State private var viewerNextPageBefore: Date?
    @State private var isLoadingViewerPosts = false
    @State private var loadedViewerPostsForID: UUID?

    // Tagged section state
    @State private var viewerTaggedPosts: [MomentPost] = []
    @State private var viewerTaggedHasMore = true
    @State private var viewerTaggedNextPageBefore: Date?
    @State private var isLoadingViewerTagged = false
    @State private var loadedViewerTaggedForID: UUID?

    @State private var viewerProfileStats: ProfileStats?
    @State private var isLoadingViewerStats = false
    @State private var loadedViewerStatsForID: UUID?

    @State private var friendNightsOut: [Int] = []
    @State private var isLoadingFriendRankStats = false
    @State private var didLoadFriendRankStats = false

    private var visibleViewerProfilePosts: [MomentPost] {
        viewerProfilePosts.filter { !store.locallyDeletedPostIDs.contains($0.id) }
    }

    private var displayedViewerPostCount: Int {
        let deletedVisibleCount = viewerProfilePosts.reduce(into: 0) { count, post in
            if store.locallyDeletedPostIDs.contains(post.id) {
                count += 1
            }
        }
        let total = viewerProfilePostCount ?? visibleViewerProfilePosts.count
        return max(total - deletedVisibleCount, visibleViewerProfilePosts.count)
    }

    enum ProfileSection: Hashable {
        case moments
        case tagged
        case stats
    }

    private var showsStatsSection: Bool {
        !store.isDuoDevice || !isDuoExpanded
    }

    private var visibleSection: ProfileSection {
        selectedSection == .stats && !showsStatsSection ? .moments : selectedSection
    }

    private var profileConfirmationText: String? {
        if isShowingProfileSavedConfirmation { return "Profile saved" }
        if isShowingRefreshConfirmation { return "Refreshed" }
        return nil
    }

    private var friendsCounterLabel: String {
        store.viewerIdentity.normalizedUsername == "landon" ? "Body Count" : "Friends"
    }

    var body: some View {
        Group {
            if store.isDuoDevice {
                duoPage
            } else {
                profilePage
            }
        }
    }

    private var profilePage: some View {
        NavigationStack {
            ScrollView {
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: ProfileScrollOffsetKey.self,
                            value: geo.frame(in: .named("profileScroll")).minY
                        )
                }
                .frame(height: 0)

                VStack(alignment: .leading, spacing: 18) {
                    profileHeader
                    sectionToggle

                    switch visibleSection {
                    case .moments:
                        momentsContent
                    case .tagged:
                        viewerTaggedContent
                    case .stats:
                        statsContent
                    }
                }
                .padding(.horizontal, AppLayout.screenPadding)
                .padding(.top, 0)
                .padding(.bottom, AppLayout.tabBarClearance)
            }
            .coordinateSpace(name: "profileScroll")
            .onPreferenceChange(ProfileScrollOffsetKey.self) { offset in
                profileScrollOffset = offset
                if offset > 60 && !isTabRefreshing && !didTriggerPullRefresh {
                    didTriggerPullRefresh = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    Task {
                        await runManualRefresh()
                    }
                }
                if offset <= 0 { didTriggerPullRefresh = false }
            }
            .onGeometryChange(for: CGFloat.self) {
                $0.size.width
            } action: { width in
                profileGridWidth = max(0, width - 40)
            }
            .modifier(DuoPageViewport())
            .defaultScrollAnchor(store.isDuoDevice ? .top : nil, for: .sizeChanges)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollContentBackground(.hidden)
            .modifier(MainPageSurface())
            .toolbarBackground(.hidden, for: .navigationBar)
            .navigationBarTitleDisplayMode(store.isDuoDevice ? .inline : .automatic)
            // Register the action before the system chooses its toolbar axis.
            // Hiding it until a vertical bar exists prevents that bar appearing.
            .toolbar(store.isDuoDevice ? .visible : .automatic, for: .navigationBar)
            .toolbar {
                if store.isDuoDevice {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape.fill") { pageRoute = .settings }
                            .tint(.white)
                            .accessibilityIdentifier("profile.settings")
                    }
                }
            }
            .overlay(alignment: .top) {
                if isTabRefreshing {
                    MainTabRefreshIndicator()
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .top) {
                if let profileConfirmationText {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(accent)
                        Text(profileConfirmationText)
                            .font(AppTypography.button)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.black.opacity(0.72), in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(AppTheme.line, lineWidth: 1)
                    )
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .sheet(item: $detailPost) { post in
                MomentDetailSheet(post: post)
                    .modifier(PostDetailPresentation())
                    .presentationDetents([.large])
                    .appSheetDragHandle(contentWidth: PostDetailPresentation.sheetWidth)
            }
            .navigationDestination(item: $pageRoute) { route in
                ProfileOverlayDestination(route: route, onProfileSaved: { pageRoute = nil })
                    .modifier(DuoPageViewport(extendsUnderBottomBar: false))
                    .toolbar(.visible, for: .navigationBar)
            }
            .task(id: store.viewer?.id) {
                guard let viewer = store.viewer else { return }
                if store.isLayoutPreview {
                    viewerProfilePosts = store.viewerPosts
                    viewerProfileStats = ProfileStats.make(
                        from: store.viewerPosts, id: { $0.id }, date: { $0.createdAt },
                        drinkName: { $0.drink?.name }
                    )
                    friendNightsOut = Array(repeating: 1, count: store.friends.count)
                    didLoadFriendRankStats = true
                    loadedViewerPostsForID = viewer.id
                    viewerHasMorePosts = false
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--profile-post-preview") {
                        detailPost = viewerProfilePosts.first
                    }
                    #endif
                    return
                }
                if loadedViewerPostsForID != viewer.id {
                    await reloadViewerProfilePosts(for: viewer)
                }
                if loadedViewerTaggedForID != viewer.id {
                    await reloadViewerTaggedPosts(for: viewer)
                }
                if loadedViewerStatsForID != viewer.id {
                    await reloadViewerProfileStats(for: viewer)
                }
            }
            .onChange(of: store.selectedTab) { _, selectedTab in
                guard selectedTab == .profile, let viewer = store.viewer else { return }
                Task {
                    await refreshViewerProfilePostsIfNeeded(for: viewer)
                    if viewerTaggedPosts.isEmpty {
                        await reloadViewerTaggedPosts(for: viewer)
                    }
                    if viewerProfileStats == nil {
                        await reloadViewerProfileStats(for: viewer)
                    }
                }
            }
            .task(id: store.profileTabSelectionTrigger) {
                guard store.selectedTab == .profile,
                    store.profileTabSelectionTrigger > 0
                else { return }

                await refreshProfileData()
            }
            .onChange(of: store.profileSavedConfirmationTrigger) { _, _ in
                handleProfileEditorSaved()
            }
            .onChange(of: store.locallyDeletedPostIDs) { _, _ in
                syncViewerProfilePostsWithLocalDeletes()
                guard let viewer = store.viewer else { return }
                Task {
                    try? await Task.sleep(for: .seconds(2.2))
                    await reloadViewerProfileStats(for: viewer)
                }
            }
        }
    }

    private var duoPage: some View {
        DuoPageLayout(isExpanded: $isDuoExpanded) {
            profilePage
        } companion: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    statsContent
                }
                .padding(.horizontal, AppLayout.screenPadding)
                .padding(.top, AppLayout.secondaryPageTopPadding)
                .padding(.bottom, AppLayout.tabBarClearance)
            }
            .modifier(DuoPageHeader(title: "Stats"))
            .scrollIndicators(.hidden)
            .accessibilityIdentifier("profile.companion.stats")
        }
    }

    private func handleProfileEditorSaved() {
        syncVisibleProfileCopiesAfterProfileSave()

        Task {
            try? await Task.sleep(for: .milliseconds(280))
            await showProfileSavedConfirmation()
        }
    }

    private func syncVisibleProfileCopiesAfterProfileSave() {
        viewerProfilePosts = viewerProfilePosts.map { store.replacingViewerProfile(in: $0) }
        viewerTaggedPosts = viewerTaggedPosts.map { store.replacingViewerProfile(in: $0) }
        if let detailPost {
            self.detailPost = store.replacingViewerProfile(in: detailPost)
        }
    }

    private func showProfileSavedConfirmation() async {
        await MainActor.run {
            isShowingRefreshConfirmation = false
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                isShowingProfileSavedConfirmation = true
            }
        }

        try? await Task.sleep(for: .seconds(1.2))

        await MainActor.run {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                isShowingProfileSavedConfirmation = false
            }
        }
    }

    private func runManualRefresh() async {
        let refreshStartedAt = Date()
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.18)) {
                isTabRefreshing = true
            }
        }

        await refreshProfileData()
        await MainTabRefreshFeedback.waitForMinimumVisibleDuration(since: refreshStartedAt)

        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.18)) {
                isTabRefreshing = false
            }
        }

        await showRefreshConfirmation()
    }

    private func refreshProfileData() async {
        await store.refreshAppData(silenceErrors: true)
        if let viewer = store.viewer {
            await reloadViewerProfilePosts(for: viewer)
            await reloadViewerTaggedPosts(for: viewer)
            await reloadViewerProfileStats(for: viewer)
        }
        // Allow friend rank to re-fetch on the next stats view.
        didLoadFriendRankStats = false
        friendNightsOut = []
    }

    private func showRefreshConfirmation() async {
        await MainActor.run {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                isShowingRefreshConfirmation = true
            }
        }

        try? await Task.sleep(for: .seconds(1.1))

        await MainActor.run {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                isShowingRefreshConfirmation = false
            }
        }
    }

    private func reloadViewerProfilePosts(for viewer: UserProfile) async {
        // Reset pagination cursors but keep the existing posts array visible
        // until the network response arrives. This prevents the grid from
        // going blank during the load — posts are replaced atomically when
        // loadMoreViewerPosts assigns result.posts on success.
        loadedViewerPostsForID = nil
        viewerProfilePostCount = nil
        viewerHasMorePosts = true
        viewerNextPageBefore = nil
        await loadMoreViewerPosts(for: viewer, reset: true)
        loadedViewerPostsForID = viewer.id
    }

    private func refreshViewerProfilePostsIfNeeded(for viewer: UserProfile) async {
        if visibleViewerProfilePosts.isEmpty {
            await reloadViewerProfilePosts(for: viewer)
            return
        }

        if store.viewerPosts.first?.id != visibleViewerProfilePosts.first?.id {
            await reloadViewerProfilePosts(for: viewer)
        }
    }

    private func loadMoreViewerPosts(for viewer: UserProfile, reset: Bool) async {
        guard !store.isLayoutPreview else { return }
        guard !isLoadingViewerPosts else { return }
        if !reset && !viewerHasMorePosts { return }

        isLoadingViewerPosts = true
        defer { isLoadingViewerPosts = false }

        let result = await store.loadUserPostsPage(
            for: viewer,
            before: reset ? nil : viewerNextPageBefore,
            limit: AppStore.profilePostsPageSize
        )

        if reset {
            // Only replace the existing posts if the server returned something.
            // An empty result on a reset is almost always a transient backend
            // issue (RLS hiccup, network timeout recovered by the outer guard,
            // etc.) — replacing with [] would wipe a grid the user can still
            // see and interact with. If the server genuinely has no posts, the
            // next refresh will confirm that state.
            if !result.posts.isEmpty {
                viewerProfilePosts = result.posts
            }
        } else {
            let existingIDs = Set(viewerProfilePosts.map(\.id))
            viewerProfilePosts += result.posts.filter { !existingIDs.contains($0.id) }
        }

        if let totalCount = result.totalCount {
            viewerProfilePostCount = totalCount
        }
        viewerHasMorePosts = result.hasMore
        viewerNextPageBefore = viewerProfilePosts.last?.createdAt
    }

    private func syncViewerProfilePostsWithLocalDeletes() {
        let beforeCount = viewerProfilePosts.count
        viewerProfilePosts.removeAll { store.locallyDeletedPostIDs.contains($0.id) }
        let deletedCount = beforeCount - viewerProfilePosts.count
        guard deletedCount > 0, let totalCount = viewerProfilePostCount else { return }
        viewerProfilePostCount = max(totalCount - deletedCount, viewerProfilePosts.count)
    }

    private func reloadViewerProfileStats(for viewer: UserProfile) async {
        guard !isLoadingViewerStats else { return }

        if loadedViewerStatsForID != viewer.id {
            viewerProfileStats = nil
        }
        loadedViewerStatsForID = nil
        isLoadingViewerStats = true
        defer { isLoadingViewerStats = false }

        let result = await store.loadProfileStats(for: viewer)
        viewerProfileStats = result.stats
        loadedViewerStatsForID = viewer.id
    }

    // MARK: - Tagged posts loading

    private func reloadViewerTaggedPosts(for viewer: UserProfile) async {
        loadedViewerTaggedForID = nil
        viewerTaggedHasMore = true
        viewerTaggedNextPageBefore = nil
        await loadMoreViewerTaggedPosts(for: viewer, reset: true)
        loadedViewerTaggedForID = viewer.id
    }

    private func loadMoreViewerTaggedPosts(for viewer: UserProfile, reset: Bool) async {
        guard !isLoadingViewerTagged else { return }
        if !reset && !viewerTaggedHasMore { return }

        isLoadingViewerTagged = true
        defer { isLoadingViewerTagged = false }

        let result = await store.loadTaggedPostsPage(
            for: viewer,
            before: reset ? nil : viewerTaggedNextPageBefore,
            limit: AppStore.profilePostsPageSize
        )

        if reset {
            if !result.posts.isEmpty {
                viewerTaggedPosts = result.posts
            }
        } else {
            let existingIDs = Set(viewerTaggedPosts.map(\.id))
            viewerTaggedPosts += result.posts.filter { !existingIDs.contains($0.id) }
        }

        viewerTaggedHasMore = result.hasMore
        viewerTaggedNextPageBefore = viewerTaggedPosts.last?.createdAt
    }

    // MARK: - Header

    private var usesProminentProfileHeader: Bool {
        store.isDuoDevice && !isDuoExpanded && profileGridWidth >= 560
    }

    private var profileHeader: some View {
        SharedProfileHeader(
            profile: store.viewerIdentity,
            friendsValue: "\(store.friends.count)",
            friendsLabel: friendsCounterLabel,
            postsValue: "\(displayedViewerPostCount)",
            onFriendsTap: openViewerFriendsList,
            onIdentityTap: openProfileEditor,
            showsAction: false,
            topPadding: store.isDuoDevice ? 12 : 64,
            isProminent: usesProminentProfileHeader
        ) {
            EmptyView()
        }
        .overlay(alignment: .topTrailing) {
            if !store.isDuoDevice {
                settingsButton
                    .padding(.top, 8)
                    .padding(.trailing, 4)
            }
        }
    }

    private var settingsButton: some View {
        Button {
            if store.isDuoDevice { pageRoute = .settings }
            else { store.profileOverlayRoute = .settings }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .primaryGlass(in: .circle, interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityIdentifier("profile.settings")
    }

    private func openViewerFriendsList() {
        if store.isDuoDevice { pageRoute = .viewerFriends }
        else { store.profileOverlayRoute = .viewerFriends }
    }

    private func openProfileEditor() {
        store.beginProfileEditing()
        if store.isDuoDevice { pageRoute = .editProfile }
        else { store.profileOverlayRoute = .editProfile }
    }

    // MARK: - Segmented control

    private var sectionToggle: some View {
        ProfileSectionToggle(
            selectedSection: Binding(
                get: { visibleSection },
                set: { selectedSection = $0 }
            ),
            showsStats: showsStatsSection
        )
        .padding(.top, 2)
    }

    // MARK: - Moments grid

    @ViewBuilder
    private var momentsContent: some View {
        let posts = visibleViewerProfilePosts

        if isLoadingViewerPosts && posts.isEmpty {
            ProgressView()
                .tint(accent)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else if posts.isEmpty {
            Text("No posts yet")
                .font(AppTypography.rowSubtitleMedium)
                .foregroundStyle(AppTheme.softText)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 32)
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: store.isDuoDevice ? AppLayout.photoGridColumnCount(width: profileGridWidth) : 3)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(posts) { post in
                    Button {
                        store.cacheProfilePosts([post])
                        detailPost = post
                    } label: {
                        momentGridCell(post: post)
                    }
                    .buttonStyle(.plain)
                    .task(id: paginationTaskID(for: post, in: posts, isLoading: isLoadingViewerPosts, hasMore: viewerHasMorePosts)) {
                        guard let viewer = store.viewer,
                              shouldLoadMore(afterAppearing: post, in: posts, isLoading: isLoadingViewerPosts, hasMore: viewerHasMorePosts)
                        else { return }

                        Task {
                            await loadMoreViewerPosts(for: viewer, reset: false)
                        }
                    }
                }
            }
            .padding(.horizontal, -AppLayout.screenPadding)

            if isLoadingViewerPosts && !posts.isEmpty {
                ProgressView()
                    .tint(accent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
        }
    }

    private func momentGridCell(post: MomentPost) -> some View {
        MomentGridThumbnail(media: post.media)
    }

    // MARK: - Tagged

    @ViewBuilder
    private var viewerTaggedContent: some View {
        if isLoadingViewerTagged && viewerTaggedPosts.isEmpty {
            ProgressView()
                .tint(accent)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else if viewerTaggedPosts.isEmpty {
            Text("No tagged posts yet")
                .font(AppTypography.rowSubtitleMedium)
                .foregroundStyle(AppTheme.softText)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 32)
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: store.isDuoDevice ? AppLayout.photoGridColumnCount(width: profileGridWidth) : 3)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(viewerTaggedPosts) { post in
                    Button {
                        detailPost = post
                    } label: {
                        MomentGridThumbnail(media: post.media)
                    }
                    .buttonStyle(.plain)
                    .task(id: paginationTaskID(for: post, in: viewerTaggedPosts, isLoading: isLoadingViewerTagged, hasMore: viewerTaggedHasMore)) {
                        guard let viewer = store.viewer,
                              shouldLoadMore(afterAppearing: post, in: viewerTaggedPosts, isLoading: isLoadingViewerTagged, hasMore: viewerTaggedHasMore)
                        else { return }

                        Task {
                            await loadMoreViewerTaggedPosts(for: viewer, reset: false)
                        }
                    }
                }
            }
            .padding(.horizontal, -AppLayout.screenPadding)

            if isLoadingViewerTagged && !viewerTaggedPosts.isEmpty {
                ProgressView()
                    .tint(accent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
        }
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsContent: some View {
        if isLoadingViewerStats && viewerProfileStats == nil {
            ProgressView()
                .tint(accent)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else {
            ProfileStatsCards(
                stats: viewerProfileStats ?? .empty,
                friendNightsOut: friendNightsOut,
                isLoadingFriendRank: isLoadingFriendRankStats
            )
            .task {
                guard !store.isLayoutPreview else { return }
                guard !didLoadFriendRankStats && !isLoadingFriendRankStats else { return }
                await loadFriendNightsOut()
            }
        }
    }

    private func loadFriendNightsOut() async {
        guard !isLoadingFriendRankStats else { return }
        isLoadingFriendRankStats = true
        defer { isLoadingFriendRankStats = false }

        let friends = store.friends
        guard !friends.isEmpty else {
            didLoadFriendRankStats = true
            return
        }

        var results: [Int] = []
        await withTaskGroup(of: Int?.self) { group in
            for friend in friends {
                group.addTask {
                    let result = await self.store.loadProfileStats(for: friend)
                    return result.stats.nightsOut
                }
            }
            for await nightsOut in group {
                if let nightsOut {
                    results.append(nightsOut)
                }
            }
        }

        friendNightsOut = results
        didLoadFriendRankStats = true
    }

    private func paginationTaskID(
        for post: MomentPost,
        in posts: [MomentPost],
        isLoading: Bool,
        hasMore: Bool
    ) -> String {
        "\(post.id.uuidString)-\(posts.count)-\(posts.last?.id.uuidString ?? "none")-\(isLoading)-\(hasMore)"
    }

    private func shouldLoadMore(
        afterAppearing post: MomentPost,
        in posts: [MomentPost],
        isLoading: Bool,
        hasMore: Bool
    ) -> Bool {
        guard hasMore, !isLoading else { return false }
        return posts
            .suffix(Self.paginationPrefetchThreshold)
            .contains { $0.id == post.id }
    }
}

struct SharedProfileHeader<ActionContent: View>: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let profile: UserProfile
    let friendsValue: String
    let friendsLabel: String
    let postsValue: String
    let onFriendsTap: (() -> Void)?
    let onIdentityTap: (() -> Void)?
    let showsAction: Bool
    let topPadding: CGFloat
    let isProminent: Bool
    private let actionContent: ActionContent

    init(
        profile: UserProfile,
        friendsValue: String,
        friendsLabel: String,
        postsValue: String,
        onFriendsTap: (() -> Void)? = nil,
        onIdentityTap: (() -> Void)? = nil,
        showsAction: Bool = true,
        topPadding: CGFloat = 64,
        isProminent: Bool = false,
        @ViewBuilder actionContent: () -> ActionContent
    ) {
        self.profile = profile
        self.friendsValue = friendsValue
        self.friendsLabel = friendsLabel
        self.postsValue = postsValue
        self.onFriendsTap = onFriendsTap
        self.onIdentityTap = onIdentityTap
        self.showsAction = showsAction
        self.topPadding = topPadding
        self.isProminent = isProminent
        self.actionContent = actionContent()
    }

    var body: some View {
        VStack(spacing: 14) {
            if store.isDuoDevice {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 16) {
                        identityArea
                        counters
                    }
                } else {
                    duoIdentity
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    identityArea
                    HStack(spacing: 12) {
                        friendsCounter
                        ProfileHeaderCounterColumn(value: postsValue, label: "Posts")
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(3)
                }
            }

            if showsAction {
                actionContent
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, store.isDuoDevice ? topPadding : 64)
    }

    private var duoIdentity: some View {
        HStack(alignment: .profileIdentityLine, spacing: isProminent ? 20 : 12) {
            identityControl { editableAvatar }
                .alignmentGuide(.profileIdentityLine) { $0[VerticalAlignment.center] }

            VStack(alignment: .leading, spacing: isProminent ? 6 : 3) {
                identityControl(label: profile.displayName) { identityName }

                HStack(alignment: .profileIdentityLine, spacing: isProminent ? 24 : 14) {
                    identityControl(label: usernameAccessibilityLabel) { identityUsername }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    counters.layoutPriority(3)
                }
            }
        }
    }

    private var counters: some View {
        HStack(alignment: .profileIdentityLine, spacing: isProminent ? 28 : 12) {
            friendsCounter
            ProfileHeaderCounterColumn(
                value: postsValue, label: "Posts", isProminent: isProminent,
                alignsWithIdentity: true
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var identityArea: some View {
        identityControl(label: store.isDuoDevice
                        ? "\(profile.displayName), \(usernameAccessibilityLabel). Edit profile" : "Edit profile") {
            identityContent
        }
    }

    private var usernameAccessibilityLabel: String {
        "@\(profile.username)\(profile.isVerified ? ", verified" : "")"
    }

    @ViewBuilder
    private func identityControl<Content: View>(
        label: String = "Edit profile", @ViewBuilder content: () -> Content
    ) -> some View {
        if let onIdentityTap {
            Button(action: onIdentityTap, label: content)
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityHint("Opens your profile photo, name, and username editor.")
        } else {
            content()
        }
    }

    private var identityContent: some View {
        HStack(
            alignment: store.isDuoDevice ? .profileIdentityLine : .center,
            spacing: isProminent ? 20 : 12
        ) {
            editableAvatar
                .alignmentGuide(.profileIdentityLine) { $0[VerticalAlignment.center] }

            identityDetails
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .layoutPriority(2)
    }

    private var identityDetails: some View {
        VStack(alignment: .leading, spacing: isProminent ? 6 : 3) {
            identityName
            identityUsername
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var identityName: some View {
        if isProminent {
            Text(profile.displayName)
                .font(AppTypography.profileNameLarge)
                .foregroundStyle(.white)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(profile.displayName)
                .font(AppTypography.profileName)
                .foregroundStyle(.white)
                .lineLimit(store.isDuoDevice ? (dynamicTypeSize.isAccessibilitySize ? nil : 2) : 1)
                .minimumScaleFactor(store.isDuoDevice ? 0.85 : 0.5)
        }
    }

    private var identityUsername: some View {
        VerifiedUsernameLabel(
            profile: profile,
            font: AppTypography.username,
            spacing: 4,
            badgeSize: isProminent ? 15 : 13
        )
        .lineLimit(1)
        .minimumScaleFactor(store.isDuoDevice ? 0.8 : 0.5)
        .alignmentGuide(.profileIdentityLine) { $0[VerticalAlignment.center] }
    }

    private var editableAvatar: some View {
        TonightAvatarView(
            avatar: profile.avatar, userID: profile.id,
            size: store.isDuoDevice ? (isProminent ? 112 : 76) : 86,
            showsPostCount: !store.isDuoDevice
        )
        .overlay(alignment: .bottomTrailing) {
            if onIdentityTap != nil {
                editProfileBadge
                    .offset(x: 3, y: 3)
            }
        }
    }

    private var editProfileBadge: some View {
        Image(systemName: "pencil")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: isProminent ? 34 : 28, height: isProminent ? 34 : 28)
            .background(accent.opacity(0.82), in: Circle())
            .overlay(
                Circle()
                    .strokeBorder(.white.opacity(0.22), lineWidth: 1)
            )
            .glassEffect(.regular.tint(accent.opacity(0.24)).interactive(), in: .circle)
            .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var friendsCounter: some View {
        if let onFriendsTap {
            Button(action: onFriendsTap) {
                ProfileHeaderCounterColumn(
                    value: friendsValue, label: friendsLabel, isProminent: isProminent,
                    alignsWithIdentity: store.isDuoDevice
                )
            }
            .buttonStyle(.plain)
        } else {
            ProfileHeaderCounterColumn(
                value: friendsValue, label: friendsLabel, isProminent: isProminent,
                alignsWithIdentity: store.isDuoDevice
            )
        }
    }

}

private extension VerticalAlignment {
    private enum ProfileIdentityLine: AlignmentID {
        static func defaultValue(in dimensions: ViewDimensions) -> CGFloat {
            dimensions[VerticalAlignment.center]
        }
    }

    // Keep the avatar center, username, and counter values on one visual line.
    static let profileIdentityLine = VerticalAlignment(ProfileIdentityLine.self)
}

private struct ProfileHeaderCounterColumn: View {
    let value: String
    let label: String
    var isProminent = false
    var alignsWithIdentity = false

    private var usesLeadingAlignment: Bool { isProminent && !alignsWithIdentity }

    private var valueFont: Font {
        if isProminent { return AppTypography.profileCountLarge }
        if alignsWithIdentity { return AppTypography.statNumber }
        return .system(size: 22, weight: .bold, design: .rounded)
    }

    var body: some View {
        VStack(alignment: usesLeadingAlignment ? .leading : .center, spacing: isProminent ? 4 : 3) {
            Text(value)
                .font(valueFont)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .alignmentGuide(.profileIdentityLine) { $0[VerticalAlignment.center] }
            Text(label)
                .font(AppTypography.footnoteMedium)
                .foregroundStyle(AppTheme.softText)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .multilineTextAlignment(usesLeadingAlignment ? .leading : .center)
        .frame(minWidth: isProminent ? 80 : counterColumnWidth, alignment: usesLeadingAlignment ? .leading : .center)
    }

    private var counterColumnWidth: CGFloat {
        label == "Body Count" ? 76 : 54
    }
}

struct ProfileSectionToggle: View {
    @Environment(\.appAccent) private var accent

    @Binding var selectedSection: ProfileView.ProfileSection
    var showsStats = true

    var body: some View {
        Picker("Profile section", selection: $selectedSection) {
            Label("Posts", systemImage: "square.grid.3x3.fill")
                .tag(ProfileView.ProfileSection.moments)
            Label("Tagged", systemImage: "person.crop.rectangle.fill")
                .tag(ProfileView.ProfileSection.tagged)
            if showsStats {
                Label("Stats", systemImage: "chart.bar.fill")
                    .tag(ProfileView.ProfileSection.stats)
            }
        }
        .pickerStyle(.segmented)
        .tint(accent)
        .controlSize(.large)
        .frame(height: 44)
        .frame(maxWidth: .infinity)
    }
}

struct ProfileStatsCards: View {
    @Environment(\.appAccent) private var accent

    @State private var isDrinkStatsPresented = false
    @State private var selectedDrinkPeriodID = ProfileDrinkStatsPeriod.allTime.id

    let stats: ProfileStats
    var friendRank: ProfileFriendRank?
    var friendNightsOut: [Int] = []
    var isLoadingFriendRank: Bool = false

    private var nightUnit: String {
        stats.nightsOut == 1 ? "night" : "nights"
    }

    private var streakNumber: String {
        "\(stats.longestPostingStreak)"
    }

    private var streakUnit: String {
        stats.longestPostingStreak == 1 ? "day" : "days"
    }

    private static let streakDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter
    }()

    private var streakDateRange: String? {
        guard let start = stats.longestPostingStreakStart,
              let end = stats.longestPostingStreakEnd
        else { return nil }

        let formatter = Self.streakDateFormatter

        if Calendar.current.isDate(start, inSameDayAs: end) {
            return formatter.string(from: start)
        }
        return "\(formatter.string(from: start))\n\(formatter.string(from: end))"
    }

    private var topDrinkName: String {
        stats.mostTaggedDrinkName ?? "No drink yet"
    }

    private var topDrinkEmoji: String {
        guard let drinkName = stats.mostTaggedDrinkName else { return "🍸" }
        return DrinkTag.resolvedEmoji(for: drinkName) ?? "🍸"
    }

    private var topDrinkSubtitle: String {
        guard stats.mostTaggedDrinkName != nil else { return "No tags yet" }
        return stats.mostTaggedDrinkCount == 1
            ? "1 tagged"
            : "\(stats.mostTaggedDrinkCount) tagged"
    }

    private var drinkPeriodOptions: [ProfileDrinkStatsPeriod] {
        ProfileDrinkStatsPeriod.options(for: stats.drinkTagEvents)
    }

    private var selectedDrinkPeriod: ProfileDrinkStatsPeriod {
        drinkPeriodOptions.first { $0.id == selectedDrinkPeriodID } ?? .allTime
    }

    private var selectedDrinkSummaries: [ProfileStats.DrinkSummary] {
        stats.drinkSummaries(in: selectedDrinkPeriod)
    }

    private var selectedDrinkCount: Int {
        stats.drinkCount(in: selectedDrinkPeriod)
    }

    private var drinkTotalsSubtitle: String {
        selectedDrinkPeriod.title
    }

    private var friendRankSummary: ProfileFriendRank? {
        if let friendRank, friendRank.groupSize > 1 {
            return friendRank
        }

        guard !isLoadingFriendRank, !friendNightsOut.isEmpty else { return nil }
        return ProfileFriendRank.make(
            targetNightsOut: stats.nightsOut,
            friendNightsOut: friendNightsOut
        )
    }

    /// 1-based rank among all known friends + viewer.
    private var friendGroupRank: Int? {
        friendRankSummary?.rank
    }

    private var friendGroupSize: Int {
        friendRankSummary?.groupSize ?? 1
    }

    private var rankOrdinal: String {
        guard !(isLoadingFriendRank && friendRankSummary == nil) else { return "–" }
        guard let rank = friendGroupRank else { return "–" }
        let tens = (rank / 10) % 10
        guard tens != 1 else { return "\(rank)th" }
        switch rank % 10 {
        case 1: return "\(rank)st"
        case 2: return "\(rank)nd"
        case 3: return "\(rank)rd"
        default: return "\(rank)th"
        }
    }

    private var rankSubtitle: String {
        if isLoadingFriendRank && friendRankSummary == nil { return "Calculating rank…" }
        guard friendGroupRank != nil else { return "No friends yet" }
        return "out of \(friendGroupSize)"
    }

    private var streakTint: Color { AppTheme.barLightRed }
    private var topDrinkTint: Color { AppTheme.barLightBlue }
    private var rankTint: Color { AppTheme.barLightIndigo }
    private var drinkTotalsTint: Color { AppTheme.barLightGreen }

    var body: some View {
        VStack(spacing: 12) {
            nightsHero

            HStack(spacing: 12) {
                streakCard
                topDrinkCard
            }

            friendRankCard
            drinkTotalsCard
        }
        .sheet(isPresented: $isDrinkStatsPresented) {
            DrinkStatsBreakdownSheet(
                stats: stats,
                selectedPeriodID: $selectedDrinkPeriodID
            )
            .presentationDetents([.medium, .large])
            .appSheetDragHandle()
        }
    }

    private var nightsHero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                metricIcon(symbol: "moon.stars.fill", tint: accent, size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Nights Posted Out")
                        .font(AppTypography.metadataEmphasis)
                        .foregroundStyle(.white.opacity(0.72))
                        .textCase(.uppercase)
                        .tracking(1.3)
                }

                Spacer(minLength: 8)
            }

            HStack(alignment: .lastTextBaseline, spacing: 10) {
                Text("\(stats.nightsOut)")
                    .font(AppTypography.statHero)
                    .foregroundStyle(.white)
                    .shadow(color: accent.opacity(0.72), radius: 18)
                    .minimumScaleFactor(0.72)
                    .lineLimit(1)

                Text(nightUnit)
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    accent.opacity(0.24),
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
        .shadow(color: accent.opacity(0.20), radius: 26, y: 12)
        .glassEffect(.regular.tint(accent.opacity(0.14)), in: .rect(cornerRadius: 30))
    }

    private var streakCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            metricHeader(symbol: "flame.fill", title: "Longest Streak", tint: streakTint)

            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(streakNumber)
                    .font(AppTypography.statCard)
                    .foregroundStyle(.white)
                    .shadow(color: streakTint.opacity(0.45), radius: 12)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(streakUnit)
                    .font(AppTypography.rowSubtitleMedium)
                    .foregroundStyle(.white.opacity(0.76))
                    .padding(.bottom, 5)
            }

            Text(streakDateRange ?? "No streak yet")
                .font(AppTypography.rowSubtitle)
                .foregroundStyle(AppTheme.softText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    streakTint.opacity(0.15),
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
        .glassEffect(.regular.tint(streakTint.opacity(0.10)), in: .rect(cornerRadius: 24))
    }

    private var topDrinkCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            metricHeader(symbol: "trophy.fill", title: "Top Drink", tint: topDrinkTint)

            Text(topDrinkEmoji)
                .font(.system(size: 46))
                .frame(width: 58, height: 58)
                .background(.white.opacity(0.08), in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: topDrinkTint.opacity(0.45), radius: 14)

            VStack(alignment: .leading, spacing: 4) {
                Text(topDrinkName)
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(stats.mostTaggedDrinkName == nil ? AppTheme.softText : .white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)

                Text(topDrinkSubtitle)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    topDrinkTint.opacity(0.13),
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
        .glassEffect(.regular.tint(topDrinkTint.opacity(0.08)), in: .rect(cornerRadius: 24))
    }

    private var friendRankCard: some View {
        let tint = rankTint
        return VStack(alignment: .leading, spacing: 12) {
            metricHeader(symbol: "person.2.fill", title: "Friend Rank", tint: tint)

            HStack(alignment: .lastTextBaseline, spacing: 0) {
                Text(rankOrdinal)
                    .font(AppTypography.statCard)
                    .foregroundStyle(friendGroupRank == nil ? AppTheme.softText : .white)
                    .shadow(color: tint.opacity(0.45), radius: 12)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(rankSubtitle)
                    .font(AppTypography.rowSubtitle)
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)

                if friendGroupRank == 1 {
                    Text("Most nights out 🏆")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(tint.opacity(0.85))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 154, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [
                    tint.opacity(0.15),
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
        .glassEffect(.regular.tint(tint.opacity(0.10)), in: .rect(cornerRadius: 24))
    }

    private var drinkTotalsCard: some View {
        let tint = drinkTotalsTint
        return Button {
            isDrinkStatsPresented = true
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    metricHeader(symbol: "list.bullet.rectangle.fill", title: "Drink Totals", tint: tint)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.up.forward")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.62))
                }

                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text("\(selectedDrinkCount)")
                        .font(AppTypography.statTotal)
                        .foregroundStyle(selectedDrinkCount == 0 ? AppTheme.softText : .white)
                        .shadow(color: tint.opacity(0.45), radius: 12)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    Text(selectedDrinkCount == 1 ? "drink" : "drinks")
                        .font(AppTypography.rowSubtitleMedium)
                        .foregroundStyle(.white.opacity(0.76))
                        .padding(.bottom, 7)
                }

                Text(drinkTotalsSubtitle)
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)

                VStack(spacing: 8) {
                    if selectedDrinkSummaries.isEmpty {
                        Text("No drinks tagged")
                            .font(AppTypography.rowSubtitle)
                            .foregroundStyle(AppTheme.softText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(selectedDrinkSummaries.prefix(3)) { summary in
                            drinkTotalPreviewRow(summary)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 178, alignment: .topLeading)
            .background(
                LinearGradient(
                    colors: [
                        tint.opacity(0.14),
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
            .glassEffect(.regular.tint(tint.opacity(0.08)).interactive(), in: .rect(cornerRadius: 24))
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func drinkTotalPreviewRow(_ summary: ProfileStats.DrinkSummary) -> some View {
        HStack(spacing: 10) {
            Text(DrinkTag.resolvedEmoji(for: summary.name) ?? "🍸")
                .font(.system(size: 18))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.08), in: Circle())

            Text(summary.name)
                .font(AppTypography.rowSubtitleMedium)
                .foregroundStyle(.white.opacity(0.86))
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Spacer(minLength: 8)

            Text("\(summary.count)")
                .font(AppTypography.controlLabel)
                .foregroundStyle(.white)
                .monospacedDigit()
        }
    }

    private func metricHeader(symbol: String, title: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            metricIcon(symbol: symbol, tint: tint, size: 30)
            Text(title)
                .font(AppTypography.metadataEmphasis)
                .foregroundStyle(.white.opacity(0.70))
                .textCase(.uppercase)
                .tracking(1.1)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
    }

    private func metricIcon(symbol: String, tint: Color, size: CGFloat) -> some View {
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

private struct DrinkStatsBreakdownSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent

    let stats: ProfileStats
    @Binding var selectedPeriodID: String

    private var periodOptions: [ProfileDrinkStatsPeriod] {
        ProfileDrinkStatsPeriod.options(for: stats.drinkTagEvents)
    }

    private var selectedPeriod: ProfileDrinkStatsPeriod {
        periodOptions.first { $0.id == selectedPeriodID } ?? .allTime
    }

    private var summaries: [ProfileStats.DrinkSummary] {
        stats.drinkSummaries(in: selectedPeriod)
    }

    private var totalCount: Int {
        stats.drinkCount(in: selectedPeriod)
    }

    private var maxCount: Int {
        max(summaries.first?.count ?? 1, 1)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerPanel

                    if summaries.isEmpty {
                        EmptyStateCard(
                            title: "No drinks tagged",
                            symbol: "list.bullet.rectangle"
                        )
                    } else {
                        NightPanel(cornerRadius: AppLayout.panelRadius, padding: 14) {
                            VStack(spacing: 10) {
                                ForEach(summaries) { summary in
                                    DrinkStatsBreakdownRow(
                                        summary: summary,
                                        maxCount: maxCount,
                                        accent: accent
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, AppLayout.screenPadding)
                .padding(.top, AppLayout.secondaryPageTopPadding)
                .padding(.bottom, AppLayout.secondaryPageBottomPadding)
            }
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .appSecondaryPageNavigation(title: "Drink Totals")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(AppTypography.toolbarAction)
                    .foregroundStyle(accent)
                }
            }
        }
    }

    private var headerPanel: some View {
        NightPanel(cornerRadius: AppLayout.panelRadius, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "list.bullet.rectangle.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(accent.opacity(0.22), in: Circle())

                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(totalCount)")
                            .font(AppTypography.statSummary)
                            .foregroundStyle(totalCount == 0 ? AppTheme.softText : .white)
                            .monospacedDigit()

                        Text(totalCount == 1 ? "drink tagged" : "drinks tagged")
                            .font(AppTypography.captionMedium)
                            .foregroundStyle(AppTheme.softText)
                    }

                    Spacer(minLength: 8)
                }

                Menu {
                    ForEach(periodOptions) { period in
                        Button {
                            selectedPeriodID = period.id
                        } label: {
                            if selectedPeriodID == period.id {
                                Label(period.title, systemImage: "checkmark")
                            } else {
                                Text(period.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(selectedPeriod.title)
                            .font(AppTypography.buttonFootnote)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)

                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(AppTheme.softText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.08), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.13), lineWidth: 1))
                }
            }
        }
    }
}

private struct DrinkStatsBreakdownRow: View {
    let summary: ProfileStats.DrinkSummary
    let maxCount: Int
    let accent: Color

    private var progress: CGFloat {
        guard maxCount > 0 else { return 0 }
        return CGFloat(summary.count) / CGFloat(maxCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(DrinkTag.resolvedEmoji(for: summary.name) ?? "🍸")
                    .font(.system(size: 20))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))

                Text(summary.name)
                    .font(AppTypography.rowSubtitleMedium)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 8)

                Text("\(summary.count)")
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.08))

                    Capsule()
                        .fill(accent.opacity(0.78))
                        .frame(width: max(8, proxy.size.width * progress))
                }
            }
            .frame(height: 7)
        }
        .padding(10)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Profile editor sheet (unchanged structure, preserved)

private struct ProfileEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let onSaved: () -> Void

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var pendingCropImage: IdentifiableImage?

    var body: some View {
        @Bindable var store = store
        let accent = store.accentColorChoice.color

        ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    NightPanel(cornerRadius: AppLayout.panelRadius, padding: 20) {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(spacing: 18) {
                                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                    AvatarView(avatar: editorAvatar, size: 96)
                                        .overlay(alignment: .bottomTrailing) {
                                            Image(systemName: "pencil.circle.fill")
                                                .font(.system(size: 24))
                                                .foregroundStyle(.white, accent)
                                                .background(.black, in: Circle())
                                        }
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Profile photo")
                                        .font(AppTypography.rowTitle)
                                        .foregroundStyle(.white)
                                }

                                Spacer()
                            }

                            VStack(alignment: .leading, spacing: 14) {
                                fieldLabel("Display Name")
                                TextField("Your name", text: $store.profileEditor.displayName)
                                    .font(AppTypography.formInput)
                                    .textInputAutocapitalization(.words)
                                    .foregroundStyle(.white)
                                    .tint(accent)
                                    .padding(16)
                                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .strokeBorder(AppTheme.line, lineWidth: 1)
                                    )
                                    .glassEffect(.regular, in: .rect(cornerRadius: 18))

                                fieldLabel("Username")
                                TextField("username", text: $store.profileEditor.username)
                                    .font(AppTypography.formInput)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .foregroundStyle(.white)
                                    .tint(accent)
                                    .padding(16)
                                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .strokeBorder(AppTheme.line, lineWidth: 1)
                                    )
                                    .glassEffect(.regular, in: .rect(cornerRadius: 18))

                                usernameAvailabilityView

                                if let profileEditorMessage = store.profileEditorMessage {
                                    statusRow(
                                        symbol: "exclamationmark.triangle.fill",
                                        tint: Color(hex: "#E16B5C"),
                                        text: profileEditorMessage
                                    )
                                }
                            }
                        }
                    }

                    // Save Changes button
                    Button {
                        Task {
                            if await store.saveProfileEdits() {
                                onSaved()
                                dismiss()
                            }
                        }
                    } label: {
                        if store.isSavingProfile {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        } else {
                            Text("Save Changes")
                                .font(AppTypography.rowTitle)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                    }
                    .disabled(store.isSavingProfile || !store.canSaveProfileEdits)
                    .background(
                        Capsule()
                            .fill(
                                store.canSaveProfileEdits && !store.isSavingProfile
                                    ? accent.opacity(0.85)
                                    : .white.opacity(0.04)
                            )
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                store.canSaveProfileEdits && !store.isSavingProfile
                                    ? accent.opacity(0.55)
                                    : AppTheme.line,
                                lineWidth: 1
                            )
                    )
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .contentShape(Capsule())
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, AppLayout.screenPadding)
                .padding(.top, AppLayout.secondaryPageTopPadding)
                .padding(.bottom, AppLayout.secondaryPageBottomPadding)
            }
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .modifier(MainPageSurface())
            .appSecondaryPageNavigation(title: "Edit Profile")
            .onChange(of: selectedPhotoItem) { _, newValue in
                guard let newValue else { return }
                Task {
                    if let data = try? await newValue.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        pendingCropImage = IdentifiableImage(image: image)
                    }
                    selectedPhotoItem = nil
                }
            }
            .fullScreenCover(item: $pendingCropImage) { wrapper in
                ImageCropSheet(image: wrapper.image) { croppedData in
                    store.profileEditor.profileImageData = croppedData
                    pendingCropImage = nil
                } onCancel: {
                    pendingCropImage = nil
                }
            }
            .task(id: store.normalizedProfileEditorUsername) {
                guard !store.normalizedProfileEditorUsername.isEmpty else { return }
                await store.refreshProfileUsernameAvailability()
            }
    }

    private var editorAvatar: AvatarStyle {
        var avatar = store.viewerIdentity.avatar
        avatar.imageData = store.profileEditor.profileImageData ?? avatar.imageData
        return avatar
    }

    @ViewBuilder
    private var usernameAvailabilityView: some View {
        switch store.profileUsernameAvailability {
        case .unchecked:
            EmptyView()
        case .checking:
            statusRow(
                symbol: "hourglass",
                tint: AppTheme.softText,
                text: "Checking @\(store.normalizedProfileEditorUsername)..."
            )
        case .available(let username, _):
            statusRow(
                symbol: "checkmark.circle.fill",
                tint: AppTheme.activeGreen,
                text: "@\(username) is available"
            )
        case .unavailable(let username, let suggestion):
            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    symbol: "xmark.circle.fill",
                    tint: Color(hex: "#E16B5C"),
                    text: "@\(username) is taken"
                )

                if let suggestion {
                    Button("Use @\(suggestion)") {
                        store.profileEditor.username = suggestion
                    }
                    .buttonStyle(.glass)
                }
            }
        case .invalid(let message), .failed(let message):
            statusRow(
                symbol: "exclamationmark.triangle.fill",
                tint: Color(hex: "#E16B5C"),
                text: message
            )
        }
    }

    private func statusRow(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(AppTypography.footnoteMedium)
                .foregroundStyle(AppTheme.softText)
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.fieldLabel)
            .foregroundStyle(.white)
    }
}

private struct ViewerFriendRow: View {
    let profile: UserProfile
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                TonightAvatarView(avatar: profile.avatar, userID: profile.id, size: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)

                    VerifiedUsernameLabel(profile: profile, font: AppTypography.footnote, badgeSize: 11)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.softText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Square thumbnail for the profile moments grid. Mirrors the resolution
/// logic in `MomentMediaView` (local photoData, then remote URL, then a
/// gradient+symbol placeholder) but lets the container dictate the size
/// via `aspectRatio(1, contentMode: .fill)` instead of baking a fixed
/// height into the frame. Grid cells need container-driven sizing so
/// three columns split the available width cleanly; the standard
/// MomentMediaView was built for feed cards where the height is
/// prescriptive.
private struct MomentGridThumbnail: View {
    let media: MomentMedia

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    if let data = media.photoData,
                       let image = ImageDecodeCache.image(for: data, key: ImageDecodeCache.cacheKey(forLocalData: data, prefix: "moment-grid")) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else if let remotePhotoURL = media.remotePhotoURL {
                        RemoteDecodedImageView(url: remotePhotoURL, contentMode: .fill) {
                            placeholder
                        }
                    } else {
                        placeholder
                    }
                }
            }
        .clipped()
        .overlay(
            Rectangle()
                .strokeBorder(.white.opacity(0.04), lineWidth: 0.5)
        )
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: media.primaryHex), Color(hex: media.secondaryHex)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: media.symbol)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white.opacity(0.88))
        }
    }
}

/// Full-post detail presented when the viewer taps a grid thumbnail.
/// Intentionally reuses `MomentPostCard` so every interaction — likes,
/// overflow menu, save-to-camera-roll, delete — behaves identically to
/// the feed. It prefers the live copy from `store.posts`, but falls back
/// to the tapped profile-grid snapshot so older paged profile posts still
/// open even when they are not part of the current home bootstrap.
private struct MomentDetailSheet: View {
    @Environment(AppStore.self) private var store

    let post: MomentPost

    @State private var friendProfileTarget: UserProfile?
    @State private var commentSheetPostID: UUID?

    private var currentPost: MomentPost? {
        store.livePost(matching: post.id) ?? post
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let currentPost {
                    MomentPostCard(
                        post: currentPost,
                        isFocused: true,
                        onCommentTap: {
                            commentSheetPostID = currentPost.id
                        },
                        onAuthorTap: { profile in
                            // In the Profile tab's detail sheet the
                            // author is almost always the viewer, so
                            // filter that case out. The interesting tap
                            // is on a reactor row in the long-press Likes
                            // sheet, which routes through `onAuthorTap`
                            // as well — that's where this matters.
                            guard profile.id != store.viewer?.id else { return }
                            friendProfileTarget = profile
                        }
                    )
                    .modifier(PostDetailColumn())
                    .padding(.horizontal, store.isDuoDevice ? AppLayout.screenPadding : 0)
                    .padding(.top, store.isDuoDevice ? 12 : 36)
                    .padding(.bottom, 32)
                } else {
                    // Fallback if the post was deleted while the sheet
                    // was open on another device. Rare, but cheaper to
                    // handle than to hope it never happens.
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(AppTheme.softText)
                        Text("This post is no longer available.")
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }
            }
            .onAppear {
                store.cacheProfilePosts([post])
            }
            #if DEBUG
            .task {
                if store.isLayoutPreview,
                   ProcessInfo.processInfo.arguments.contains("--profile-comments-preview") {
                    await Task.yield()
                    commentSheetPostID = post.id
                }
            }
            #endif
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .modifier(MainPageSurface())
            .modifier(DuoModalNavigation(title: "Post"))
            .navigationDestination(item: $friendProfileTarget) { profile in
                FriendProfileView(profile: profile, presentationStyle: .embedded)
            }
            .navigationDestination(item: Binding(
                get: { store.isDuoDevice ? commentSheetPostID : nil },
                set: { commentSheetPostID = $0 }
            )) { postID in
                CommentThreadSheet(postID: postID, initialPost: currentPost, isEmbedded: true)
                    .navigationTitle("Comments")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
            .sheet(item: Binding(
                get: { store.isDuoDevice ? nil : commentSheetPostID },
                set: { commentSheetPostID = $0 }
            )) { postID in
                CommentThreadSheet(postID: postID, initialPost: post)
                    .presentationDetents([.large])
                    .appSheetDragHandle()
            }
        }
        .modifier(DuoSheetSurface())
    }
}

struct ProfileOverlayDestination: View {
    @Environment(AppStore.self) private var store
    let route: ProfileOverlayRoute
    var onProfileSaved: (() -> Void)? = nil

    var body: some View {
        Group {
            if store.isDuoDevice {
                content.modifier(MainPageSurface())
            } else {
                ZStack {
                    AmbientBackground().ignoresSafeArea()
                    content
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    @ViewBuilder
    private var content: some View {
        switch route {
        case .editProfile:
            ProfileEditorSheet(onSaved: {
                onProfileSaved?()
                store.profileOverlayRoute = nil
                store.profileSavedConfirmationTrigger &+= 1
            })
        case .settings:
            ProfileSettingsView()
        case .viewerFriends:
            ViewerFriendsOverlayPage()
        case .userProfile(let profile):
            FriendProfileView(profile: profile, presentationStyle: .embedded)
        }
    }
}

private struct ViewerFriendsOverlayPage: View {
    @Environment(AppStore.self) private var store
    @State private var searchQuery = ""
    @State private var selectedFriend: UserProfile?

    private var filteredFriends: [UserProfile] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.friends }

        return store.friends.filter { friend in
            friend.displayName.lowercased().contains(query)
                || friend.username.lowercased().contains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                searchField

                if store.friends.isEmpty {
                    EmptyStateCard(
                        title: "No friends yet",
                        symbol: "person.2.fill"
                    )
                } else {
                    NightPanel(cornerRadius: AppLayout.panelRadius, padding: 12) {
                        VStack(spacing: 8) {
                            if filteredFriends.isEmpty {
                                Text("No friends match \"\(searchQuery)\"")
                                    .font(AppTypography.rowSubtitle)
                                    .foregroundStyle(AppTheme.softText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 12)
                            } else {
                                ForEach(filteredFriends) { friend in
                                    ViewerFriendRow(profile: friend) {
                                        selectedFriend = friend
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, AppLayout.screenPadding)
            .padding(.top, AppLayout.secondaryPageTopPadding)
            .padding(.bottom, AppLayout.secondaryPageBottomPadding)
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .modifier(MainPageSurface())
        .appSecondaryPageNavigation(title: "Friends")
        .navigationDestination(item: $selectedFriend) { friend in
            FriendProfileView(profile: friend, presentationStyle: .embedded)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.softText)

            TextField("Search friends", text: $searchQuery)
                .font(AppTypography.searchInput)
                .foregroundStyle(.white)
                .tint(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(AppTheme.softText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(.white.opacity(0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(AppTheme.line, lineWidth: 1))
        .glassEffect(.regular, in: .capsule)
    }
}

private struct ProfileScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
