import SwiftUI

/// Full-screen Activity tab. Previously presented as a sheet; promoted to a
/// first-class destination because notifications are the app's primary
/// re-engagement surface and a modal half-sheet was under-selling it.
struct ActivityView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @State private var activeSheet: ActiveNotificationSheet?
    @State private var selectedNotificationID: UUID?
    @State private var isDuoExpanded = false
    @State private var profileNavigationTarget: UserProfile?
    @State private var isTabRefreshing = false
    @State private var isTitleScrolled = false
    @State private var expandedNotificationBundles: Set<String> = []

    private enum ActiveNotificationSheet: Identifiable {
        /// Show the post card; optionally auto-open comments with a highlighted comment.
        case post(UUID, highlightedCommentID: UUID?)
        case announcement(AppNotification)

        var id: String {
            switch self {
            case .post(let postID, let commentID):
                return "post-\(postID.uuidString)-\(commentID?.uuidString ?? "none")"
            case .announcement(let notification):
                return "announcement-\(notification.id.uuidString)"
            }
        }
    }

    // MARK: - Grouping

    private func groupedNotifications(at now: Date) -> [(group: NotificationDates.Group, items: [AppNotification])] {
        let buckets = Dictionary(grouping: store.notifications) {
            NotificationDates.group(for: $0.createdAt, now: now)
        }
        return NotificationDates.Group.allCases.compactMap { group in
            guard let items = buckets[group], !items.isEmpty else { return nil }
            return (group: group, items: items.sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt > $1.createdAt
            })
        }
    }

    @ViewBuilder
    var body: some View {
        TimelineView(.everyMinute) { _ in
            // The initial timeline tick can be the start of this minute.
            // Use the actual clock so newly opened rows are not up to 59s young.
            let now = Date()
            if store.isDuoDevice {
                duoActivity(at: now)
            } else {
                phoneActivity(at: now)
            }
        }
    }

    // Native list rows provide full-swipe dismissal and arbitrate horizontal
    // swipes against vertical scrolling, including on iOS 26.
    private func activityList(
        at now: Date,
        horizontalPadding: CGFloat,
        topPadding: CGFloat,
        maximumWidth: CGFloat = .infinity
    ) -> some View {
        List {
            Group {
                if store.notifications.isEmpty {
                    emptyState
                        .frame(maxWidth: maximumWidth)
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 0, leading: horizontalPadding, bottom: 0, trailing: horizontalPadding))
                } else {
                    ForEach(groupedNotifications(at: now), id: \.group) { section in
                        Text(section.group.rawValue)
                            .font(AppTypography.metadataEmphasis)
                            .foregroundStyle(AppTheme.softText)
                            .textCase(.uppercase)
                            .tracking(1.2)
                            .accessibilityAddTraits(.isHeader)
                            .frame(maxWidth: maximumWidth, alignment: .leading)
                            .frame(maxWidth: .infinity)
                            .listRowInsets(EdgeInsets(top: 6, leading: horizontalPadding, bottom: 14, trailing: horizontalPadding))

                        ForEach(ActivityNotificationBundle.make(from: section.items)) { bundle in
                            if bundle.notifications.count == 1 {
                                notificationListRow(bundle.latest, now: now, horizontalPadding: horizontalPadding, maximumWidth: maximumWidth)
                            } else {
                                notificationBundleRow(bundle, now: now)
                                    .frame(maxWidth: maximumWidth)
                                    .frame(maxWidth: .infinity)
                                    .listRowInsets(EdgeInsets(top: 0, leading: horizontalPadding, bottom: 12, trailing: horizontalPadding))
                                if expandedNotificationBundles.contains(bundle.id) {
                                    ForEach(bundle.notifications) { notification in
                                        notificationListRow(notification, now: now, horizontalPadding: horizontalPadding + 10, maximumWidth: maximumWidth)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .listRowSpacing(0)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.top, topPadding, for: .scrollContent)
        .contentMargins(.bottom, AppLayout.tabBarClearance, for: .scrollContent)
        .frame(maxWidth: .infinity)
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            -(geometry.contentOffset.y + geometry.contentInsets.top)
        } action: { _, offset in
            isTitleScrolled = offset < -8
        }
        .glassPullToRefresh(isRefreshing: isTabRefreshing) { await runManualRefresh() }
    }

    private func notificationListRow(
        _ notification: AppNotification,
        now: Date,
        horizontalPadding: CGFloat,
        maximumWidth: CGFloat
    ) -> some View {
        notificationRow(notification, now: now)
            .frame(maxWidth: maximumWidth)
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 0, leading: horizontalPadding, bottom: 12, trailing: horizontalPadding))
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(role: .destructive) {
                    withAnimation(.snappy(duration: 0.24)) {
                        store.dismissNotification(notification)
                        if selectedNotificationID == notification.id {
                            selectedNotificationID = nil
                        }
                    }
                } label: {
                    Label("Dismiss", systemImage: "trash")
                }
            }
    }

    private func notificationBundleRow(_ bundle: ActivityNotificationBundle, now: Date) -> some View {
        let expanded = expandedNotificationBundles.contains(bundle.id)
        let latest = bundle.latest
        return Button {
            withAnimation(.snappy(duration: 0.24)) {
                if expanded { expandedNotificationBundles.remove(bundle.id) }
                else { expandedNotificationBundles.insert(bundle.id) }
            }
        } label: {
            NightPanel {
                HStack(spacing: 14) {
                    if let actor = latest.actor {
                        AvatarView(avatar: actor.avatar, size: 42)
                    } else {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .foregroundStyle(accent)
                            .frame(width: 42, height: 42)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        notificationTitle(latest, now: now)
                        Text("\(bundle.notifications.count) updates on this post")
                            .font(AppTypography.footnoteMedium)
                            .foregroundStyle(.white.opacity(0.85))
                        Text(NotificationDates.activityLabel(for: latest.createdAt, now: now))
                            .font(AppTypography.caption)
                            .foregroundStyle(AppTheme.softText)
                            .accessibilityLabel(latest.createdAt.formatted(date: .complete, time: .shortened))
                    }
                    Spacer(minLength: 0)
                    VStack(spacing: 10) {
                        if bundle.hasUnread {
                            Circle().fill(accent).frame(width: 8, height: 8)
                        }
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(AppTheme.softText)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: AppLayout.panelRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint(expanded ? "Collapse updates" : "Expand to open or dismiss each update")
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }

    private func phoneActivity(at now: Date) -> some View {
        NavigationStack {
            activityList(at: now, horizontalPadding: 14, topPadding: 12)
            #if DEBUG
            .modifier(DuoScrollPreviewControls())
            #endif
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack(alignment: .firstTextBaseline) {
                    ScrollingPageTitle(title: "Activity", isScrolled: isTitleScrolled)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always, axes: .vertical)
            // Match Profile's ambient surface inside the tab content so Activity
            // does not depend on the native tab container staying transparent.
            .scrollContentBackground(.hidden)
            .modifier(MainPageSurface())
            .onAppear {
                if store.selectedTab == .activity {
                    store.markActivityAsSeen()
                }
            }
            .onChange(of: store.selectedTab) { _, newTab in
                if newTab == .activity {
                    store.markActivityAsSeen()
                }
            }
            .task(id: store.activityTabSelectionTrigger) {
                guard store.selectedTab == .activity,
                      store.activityTabSelectionTrigger > 0
                else { return }

                await refreshActivityData()
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .announcement(let notification):
                    AnnouncementNotificationSheet(notification: notification)
                case .post(let postID, let highlightedCommentID):
                    ActivityPostDetailSheet(
                        postID: postID,
                        highlightedCommentID: highlightedCommentID,
                        onAuthorTap: { profile in
                            activeSheet = nil
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                openProfile(profile)
                            }
                        }
                    )
                    .presentationDetents([.large])
                    .appSheetDragHandle(contentWidth: PostDetailPresentation.sheetWidth)
                }
            }
            .navigationDestination(item: $profileNavigationTarget) { profile in
                FriendProfileView(profile: profile, presentationStyle: .embedded)
            }
        }
    }

    private func duoActivity(at now: Date) -> some View {
        DuoPageLayout(isExpanded: $isDuoExpanded) {
            NavigationStack {
                activityList(
                    at: now,
                    horizontalPadding: AppLayout.screenPadding,
                    topPadding: AppLayout.secondaryPageTopPadding,
                    maximumWidth: isDuoExpanded ? .infinity : AppLayout.phoneColumnMaximumWidth
                )
                #if DEBUG
                .modifier(DuoScrollPreviewControls())
                #endif
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .toolbarBackground(.hidden, for: .navigationBar)
                .navigationBarTitleDisplayMode(.inline)
                .modifier(DuoPageHeader(title: "Activity", isScrolled: isTitleScrolled))
                .modifier(DuoPageViewport())
                .scrollIndicators(.hidden)
                .defaultScrollAnchor(.top, for: .sizeChanges)
                .scrollBounceBehavior(.always, axes: .vertical)
                // Match Profile's ambient surface inside the tab content so Activity
                // does not depend on the native tab container staying transparent.
                .scrollContentBackground(.hidden)
                .modifier(MainPageSurface())
                .onAppear {
                    if store.selectedTab == .activity {
                        store.markActivityAsSeen()
                    }
                }
                .onChange(of: store.selectedTab) { _, newTab in
                    if newTab == .activity {
                        store.markActivityAsSeen()
                    }
                }
                .task(id: store.activityTabSelectionTrigger) {
                    guard store.selectedTab == .activity,
                        store.activityTabSelectionTrigger > 0
                    else { return }

                    await refreshActivityData()
                }
                .sheet(item: $activeSheet) { sheet in
                    switch sheet {
                    case .announcement(let notification):
                        AnnouncementNotificationSheet(notification: notification)
                    case .post(let postID, let highlightedCommentID):
                        ActivityPostDetailSheet(
                            postID: postID,
                            highlightedCommentID: highlightedCommentID,
                            onAuthorTap: { profile in
                                activeSheet = nil
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                    openProfile(profile)
                                }
                            }
                        )
                        .presentationDetents([.large])
                        .appSheetDragHandle(contentWidth: PostDetailPresentation.sheetWidth)
                    }
                }
                .navigationDestination(item: $profileNavigationTarget) { profile in
                    FriendProfileView(profile: profile, presentationStyle: .embedded)
                        .modifier(DuoPageViewport(extendsUnderBottomBar: false))
                }
            }
        } companion: {
            if let notification = selectedNotification {
                ActivityCompanionDetail(notification: notification)
                    .id(notification.id)
            } else {
                DuoCompanionPlaceholder(
                    title: "All caught up",
                    symbol: "bell.badge")
            }
        }
        .onChange(of: isDuoExpanded) { _, expanded in
            if expanded { activeSheet = nil }
        }
    }

    private var selectedNotification: AppNotification? {
        if let selectedNotificationID,
           let selected = store.notifications.first(where: { $0.id == selectedNotificationID }) {
            return selected
        }
        return store.notifications.max(by: { $0.createdAt < $1.createdAt })
    }

    private func showPost(_ postID: UUID, highlightedCommentID: UUID?) {
        activeSheet = .post(postID, highlightedCommentID: highlightedCommentID)
    }

    private func openProfile(_ profile: UserProfile) {
        if profile.id == store.viewer?.id {
            store.selectedTab = .profile
        } else {
            profileNavigationTarget = profile
        }
    }

    private func runManualRefresh() async {
        guard !isTabRefreshing else { return }
        let refreshStartedAt = Date()
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.18)) {
                isTabRefreshing = true
            }
        }

        await refreshActivityData()
        await MainTabRefreshFeedback.waitForMinimumVisibleDuration(since: refreshStartedAt)

        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.18)) {
                isTabRefreshing = false
            }
        }

    }

    private func refreshActivityData() async {
        await store.refreshAppData(silenceErrors: true)
        store.markActivityAsSeen()
    }


    private var emptyState: some View {
        NightPanel(cornerRadius: 28, padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(store.accentColorChoice.color.opacity(0.85))
                Text("No activity yet")
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(.white)
            }
        }
    }

    /// Renders the notification title with the verified badge immediately after
    /// the actor's display name, so it reads "Maddox ✓ replied to your comment"
    /// rather than appending the badge at the sentence end.
    @ViewBuilder
    private func notificationTitle(_ notification: AppNotification, now: Date) -> some View {
        let actor = notification.actor
        let isVerified = actor?.isVerified == true || actor.map { store.purchases.isPlusMember($0.id) } == true
        let actorName = actor?.displayName ?? ""
        let title = notification.headline(at: now)

        if isVerified, !actorName.isEmpty, title.hasPrefix(actorName) {
            let remainder = String(title.dropFirst(actorName.count))
            (Text(actorName).foregroundStyle(.white)
                + Text(" ")
                + Text(Image(systemName: "checkmark.seal.fill"))
                    .font(.system(size: 11, weight: .bold))
                    .baselineOffset(2)
                + Text(remainder).foregroundStyle(.white))
                .font(AppTypography.rowTitle)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        } else {
            Text(title)
                .font(AppTypography.rowTitle)
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
    }

    private func notificationRow(_ notification: AppNotification, now: Date) -> some View {
        Button {
            openNotification(notification)
        } label: {
            NightPanel {
                HStack(alignment: .center, spacing: 14) {
                    if let actor = notification.actor {
                        AvatarView(avatar: actor.avatar, size: 42)
                    } else {
                        Image(systemName: notification.kind.symbol)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(store.accentColorChoice.color)
                            .frame(width: 42, height: 42)
                            .background(.white.opacity(0.05), in: Circle())
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        notificationTitle(notification, now: now)

                        Text(NotificationDates.activityLabel(for: notification.createdAt, now: now))
                            .accessibilityLabel(notification.createdAt.formatted(date: .complete, time: .shortened))
                            .font(AppTypography.caption)
                            .foregroundStyle(AppTheme.softText)
                    }

                    Spacer()

                    if !notification.isRead {
                        Circle()
                            .fill(store.accentColorChoice.color)
                            .frame(width: 10, height: 10)
                    }
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: AppLayout.panelRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func openNotification(_ notification: AppNotification) {
        selectedNotificationID = notification.id
        if notification.kind == .nightRecap {
            store.openNightRecap(notification)
            return
        }
        guard !isDuoExpanded else { return }
        switch notification.kind {
        case .friendRequest, .friendAccepted:
            // Route to People so the viewer can accept/decline without
            // hunting for the right screen.
            store.handleFriendsTabTap()
        case .profileVerified:
            store.selectedTab = .profile
        case .announcement:
            activeSheet = .announcement(notification)
        case .nightRecap:
            break
        case .comment, .photoReply, .commentLike, .commentTagged:
            // Show the post first for context, then auto-open the comment
            // thread on top so the user sees the exact comment in context.
            if let postID = notification.postID {
                showPost(postID, highlightedCommentID: notification.commentID)
            } else if let actor = notification.actor {
                openProfile(actor)
            }
        case .reaction, .friendPost, .venuePulse, .tagged, .sharedMoment, .nearby:
            if let postID = notification.postID {
                showPost(postID, highlightedCommentID: nil)
            } else if let actor = notification.actor {
                openProfile(actor)
            }
        case .groupAdded:
            // Route to the Home tab where the group strip lives so the
            // viewer can immediately see who else is out in their group.
            store.selectedTab = .home
        }
    }


    /// Largest-unit-only relative label. Under a minute reads "now"; below an
    /// hour, minutes; below a day, hours; otherwise days. Deliberately drops
    /// all smaller units so the row stays scannable and never fights for
    /// attention with the title — the SwiftUI built-in `.relative` style
    /// emits two units ("1 min, 23 sec") which reads like a stopwatch.
    static func coarseRelativeLabel(for date: Date, now: Date = Date()) -> String {
        let elapsed = max(0, now.timeIntervalSince(date))

        switch elapsed {
        case ..<60:
            return "now"
        case ..<3_600:
            let minutes = Int(elapsed / 60)
            return "\(minutes)m ago"
        case ..<86_400:
            let hours = Int(elapsed / 3_600)
            return "\(hours)h ago"
        default:
            let days = Int(elapsed / 86_400)
            return "\(days)d ago"
        }
    }
}

// Back-compat alias so callers using the old name don't break mid-refactor.
typealias NotificationsCenterView = ActivityView


/// Post detail sheet that presents the comment thread on top of itself
/// rather than using the dismiss-then-reopen two-step. Owns its own
/// comment sheet state so tapping "Comment" stacks the thread sheet
/// directly over the post without any visible transition gap.
struct ActivityPostDetailSheet: View {
    @Environment(AppStore.self) private var store

    let postID: UUID
    /// When set, the comment thread opens automatically on appear so the
    /// viewer sees the post for context before the comments slide in on top.
    let highlightedCommentID: UUID?
    let onAuthorTap: (UserProfile) -> Void

    @State private var commentSheetPostID: UUID?
    @State private var highlightComment: UUID?
    /// Tracks whether we've kicked off a feed refresh because the requested
    /// post isn't in the local cache. Without this, notifications opening
    /// older posts (or posts the viewer hasn't loaded recently) showed an
    /// empty sheet — just the "Post" nav title with nothing inside, since
    /// the body silently bailed when `store.posts.first(where:)` returned nil.
    @State private var didAttemptTargetedPostLoad = false
    @State private var isLoadingPost = false
    @State private var didAutoOpenCommentThread = false
    @State private var didRefreshPost = false
    @State private var displayedPost: MomentPost?

    private var resolvedPost: MomentPost? {
        store.livePost(matching: postID)
    }

    private var postForDisplay: MomentPost? {
        displayedPost ?? resolvedPost
    }

    private var highlightedCommentIsLoaded: Bool {
        guard let highlightedCommentID else { return true }
        return resolvedPost?.comments.contains(where: { $0.id == highlightedCommentID }) == true
    }

    var body: some View {
        ZStack {
        NavigationStack {
            ScrollView {
                if let post = postForDisplay {
                    MomentPostCard(
                        post: post,
                        isFocused: true,
                        usesLiveStoreUpdates: didRefreshPost,
                        onCommentTap: {
                            highlightComment = nil
                            commentSheetPostID = post.id
                        },
                        onAuthorTap: onAuthorTap
                    )
                    .modifier(PostDetailColumn())
                    .padding(.horizontal, store.isDuoDevice ? AppLayout.screenPadding : 0)
                    .padding(.top, store.isDuoDevice ? 12 : 36)
                    .padding(.bottom, 32)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                } else {
                    // Post isn't in the local cache — kicked off a feed
                    // refresh in `.task` below, show a loading state until
                    // the refresh either finds the post or finishes empty.
                    postUnavailableState
                        .padding(.horizontal, 16)
                        .padding(.top, 80)
                }
            }
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.basedOnSize, axes: .vertical)
            .modifier(MainPageSurface())
            .modifier(DuoModalNavigation(title: "Post"))
            .navigationDestination(item: Binding(
                get: { store.isDuoDevice ? commentSheetPostID : nil },
                set: { commentSheetPostID = $0 }
            )) { sheetPostID in
                CommentThreadSheet(
                    postID: sheetPostID,
                    highlightedCommentID: highlightComment,
                    initialPost: postForDisplay,
                    isEmbedded: true
                )
                .modifier(MainPageSurface())
                .navigationTitle("Comments")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
            }
            .sheet(item: Binding(
                get: { store.isDuoDevice ? nil : commentSheetPostID },
                set: { commentSheetPostID = $0 }
            )) { sheetPostID in
                CommentThreadSheet(
                    postID: sheetPostID,
                    highlightedCommentID: highlightComment,
                    initialPost: postForDisplay
                )
                    // Use .large here so the comment sheet fully covers the
                    // ActivityPostDetailSheet beneath it. A fractional detent
                    // leaves the parent sheet's nav bar visible behind the
                    // comment sheet, causing visual overlap.
                    .presentationDetents([.large])
                    .appSheetDragHandle()
            }
            .task(id: postID) {
                guard !didAttemptTargetedPostLoad else { return }
                didAttemptTargetedPostLoad = true
                if displayedPost == nil {
                    displayedPost = resolvedPost
                }

                // Notification targets must always hit the server. A cached
                // post can be missing the fresh like/comment/tag that caused
                // the notification, so ensure + refresh are intentionally
                // collapsed into this one path.
                isLoadingPost = true
                await store.refreshPostFromNotification(
                    postID: postID,
                    commentID: highlightedCommentID
                )
                if let refreshedPost = resolvedPost {
                    displayedPost = refreshedPost
                }
                didRefreshPost = true
                isLoadingPost = false
                autoOpenCommentThreadIfReady()
            }
            .onAppear {
                if displayedPost == nil {
                    displayedPost = resolvedPost
                }
                // If this sheet was opened from a comment notification, give
                // the post a moment to render then stack the comment thread
                // on top — so the user sees the post for context first.
                autoOpenCommentThreadIfReady()
            }
            .onChange(of: resolvedPost?.id) { _, _ in
                if displayedPost == nil {
                    displayedPost = resolvedPost
                }
                autoOpenCommentThreadIfReady()
            }
            .onChange(of: highlightedCommentIsLoaded) { _, _ in
                autoOpenCommentThreadIfReady()
            }
            .onChange(of: didRefreshPost) { _, _ in
                autoOpenCommentThreadIfReady()
            }
        }
        }
        .modifier(DuoSheetSurface())
        .modifier(PostDetailPresentation())
    }

    private func autoOpenCommentThreadIfReady() {
        guard highlightedCommentID != nil,
              resolvedPost != nil,
              highlightedCommentIsLoaded,
              didRefreshPost,
              !isLoadingPost,
              !didAutoOpenCommentThread
        else { return }

        didAutoOpenCommentThread = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            highlightComment = highlightedCommentID
            commentSheetPostID = postID
        }
    }

    @ViewBuilder
    private var postUnavailableState: some View {
        VStack(spacing: 14) {
            if isLoadingPost || !didAttemptTargetedPostLoad {
                ProgressView()
                    .tint(.white.opacity(0.7))
                    .scaleEffect(1.1)
                Text("Loading post…")
                    .font(AppTypography.button)
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.white.opacity(0.45))
                Text("Post unavailable")
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.white.opacity(0.85))
                Text("The post may have been removed or is no longer visible to you.")
                    .font(AppTypography.rowSubtitle)
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
