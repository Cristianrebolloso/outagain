import SwiftUI

/// Full-screen Activity tab. Previously presented as a sheet; promoted to a
/// first-class destination because notifications are the app's primary
/// re-engagement surface and a modal half-sheet was under-selling it.
struct ActivityView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @State private var activeSheet: ActiveNotificationSheet?
    @State private var isShowingRefreshConfirmation = false

    private enum ActiveNotificationSheet: Identifiable {
        /// Show the post card; optionally auto-open comments with a highlighted comment.
        case post(UUID, highlightedCommentID: UUID?)
        case friendProfile(UserProfile)

        var id: String {
            switch self {
            case .post(let postID, let commentID):
                return "post-\(postID.uuidString)-\(commentID?.uuidString ?? "none")"
            case .friendProfile(let profile):
                return "profile-\(profile.id.uuidString)"
            }
        }
    }

    // MARK: - Grouping

    private enum NotificationGroup: String, CaseIterable {
        case today = "Today"
        case thisWeek = "This Week"
        case thisMonth = "This Month"
        case older = "Older"
    }

    private func group(for date: Date, now: Date = Date()) -> NotificationGroup {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return .today }
        if let weekAgo = cal.date(byAdding: .day, value: -7, to: now), date >= weekAgo { return .thisWeek }
        if let monthAgo = cal.date(byAdding: .month, value: -1, to: now), date >= monthAgo { return .thisMonth }
        return .older
    }

    private var groupedNotifications: [(group: NotificationGroup, items: [AppNotification])] {
        let now = Date()
        var buckets: [NotificationGroup: [AppNotification]] = [:]
        for n in store.notifications {
            let g = group(for: n.createdAt, now: now)
            buckets[g, default: []].append(n)
        }
        return NotificationGroup.allCases.compactMap { g in
            guard let items = buckets[g], !items.isEmpty else { return nil }
            return (group: g, items: items)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Header row: title + clear-all button
                HStack(alignment: .firstTextBaseline) {
                    Text("Activity")
                        .font(.system(size: 32, weight: .bold, design: .serif))
                        .foregroundStyle(.white)

                    Spacer()

                    if !store.notifications.isEmpty {
                        Button("Clear All") {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                store.clearAllNotifications()
                            }
                        }
                        .buttonStyle(.glass)
                    }
                }

                if store.notifications.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: 12, pinnedViews: .sectionHeaders) {
                        ForEach(groupedNotifications, id: \.group) { section in
                            Section {
                                ForEach(section.items) { notification in
                                    notificationRow(notification)
                                }
                            } header: {
                                Text(section.group.rawValue)
                                    .font(.system(.caption, design: .rounded, weight: .semibold))
                                    .foregroundStyle(AppTheme.softText)
                                    .textCase(.uppercase)
                                    .tracking(1.2)
                                    .padding(.top, 6)
                                    .padding(.bottom, 2)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        // Fill the full available height so the ScrollView has a definite
        // frame to scroll within. Without this, a bare ScrollView in a ZStack
        // sizes to its content and is never scrollable. NavigationStack-wrapped
        // tabs (Home, Profile) get this for free; Activity is nav-stack-free
        // so we apply it explicitly.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable {
            await performManualRefresh()
        }
        .scrollIndicators(.hidden)
        // Consistent with Home / Friends / Profile: hide the default
        // scroll content background before applying the ambient so the
        // gradient reaches the edges regardless of NavigationStack
        // chrome. Activity worked before this line because its layout
        // happened to avoid the default fill, but the explicit modifier
        // guards against future SwiftUI behavior drift.
        .scrollContentBackground(.hidden)
        .background(Color.clear)
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
        .overlay(alignment: .top) {
            if isShowingRefreshConfirmation {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                    Text("Refreshed")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .post(let postID, let highlightedCommentID):
                ActivityPostDetailSheet(
                    postID: postID,
                    highlightedCommentID: highlightedCommentID,
                    onAuthorTap: { profile in
                        activeSheet = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            if profile.id == store.viewer?.id {
                                store.selectedTab = .profile
                            } else {
                                activeSheet = .friendProfile(profile)
                            }
                        }
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            case .friendProfile(let profile):
                FriendProfileView(profile: profile)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func performManualRefresh() async {
        await store.refreshAppData(silenceErrors: true)

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

    private var emptyState: some View {
        NightPanel(cornerRadius: 28, padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "bell.slash.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(store.accentColorChoice.color.opacity(0.85))
                Text("Nothing yet tonight")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Friend posts, reactions, and requests land here.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
            }
        }
    }

    private func notificationRow(_ notification: AppNotification) -> some View {
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
                        Text(notification.title)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)

                        Text(notification.detail)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(AppTheme.softText)
                            .lineLimit(2)

                        Text(Self.coarseRelativeLabel(for: notification.createdAt))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(store.accentColorChoice.color.opacity(0.82))
                    }

                    Spacer()

                    if !notification.isRead {
                        Circle()
                            .fill(store.accentColorChoice.color)
                            .frame(width: 10, height: 10)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func openNotification(_ notification: AppNotification) {
        switch notification.kind {
        case .friendRequest, .friendAccepted:
            // Route to the Friends tab showing pending requests so the
            // viewer can accept/decline without hunting for the right screen.
            store.friendsPageMode = .people
            store.selectedTab = .friends
        case .comment, .photoReply:
            // Show the post first for context, then auto-open the comment
            // thread on top so the user sees what was commented on.
            if let postID = notification.postID {
                activeSheet = .post(postID, highlightedCommentID: notification.commentID)
            } else if let actor = notification.actor {
                activeSheet = .friendProfile(actor)
            }
        case .reaction, .friendPost, .venuePulse, .tagged, .sharedMoment, .nearby:
            if let postID = notification.postID {
                activeSheet = .post(postID, highlightedCommentID: nil)
            } else if let actor = notification.actor {
                activeSheet = .friendProfile(actor)
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
private struct ActivityPostDetailSheet: View {
    @Environment(AppStore.self) private var store

    let postID: UUID
    /// When set, the comment thread opens automatically on appear so the
    /// viewer sees the post for context before the comments slide in on top.
    let highlightedCommentID: UUID?
    let onAuthorTap: (UserProfile) -> Void

    @State private var commentSheetPostID: UUID?
    @State private var highlightComment: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                if let post = store.posts.first(where: { $0.id == postID }) {
                    MomentPostCard(
                        post: post,
                        isFocused: true,
                        onCommentTap: {
                            highlightComment = nil
                            commentSheetPostID = post.id
                        },
                        onAuthorTap: onAuthorTap
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                }
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Post")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $commentSheetPostID) { sheetPostID in
                CommentThreadSheet(postID: sheetPostID, highlightedCommentID: highlightComment)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            .onAppear {
                // If this sheet was opened from a comment notification, give
                // the post a moment to render then stack the comment thread
                // on top — so the user sees the post for context first.
                if highlightedCommentID != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        highlightComment = highlightedCommentID
                        commentSheetPostID = postID
                    }
                }
            }
        }
    }
}
