import SwiftUI

struct AdminReportsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    private let embedsNavigationStack: Bool

    // Content opened from the "Open" affordance on a report card. Each route
    // matches a target type: post → post detail sheet, comment → comment thread
    // sheet with the offending comment highlighted, user → push the profile.
    @State private var openedPost: MomentPost?
    @State private var openedCommentTarget: CommentOpenTarget?
    @State private var openedProfile: UserProfile?
    @State private var isLoadingOpen = false
    @State private var pendingReportConfirmation: AdminReportConfirmation?

    init(embedsNavigationStack: Bool = true) {
        self.embedsNavigationStack = embedsNavigationStack
    }

    private struct CommentOpenTarget: Identifiable {
        let id: UUID            // commentID, doubles as Identifiable key
        let postID: UUID
        let post: MomentPost?
    }

    private struct AdminReportConfirmation: Identifiable {
        enum Kind: String {
            case review
            case deletePost
            case deleteComment
            case ban
        }

        let kind: Kind
        let report: ContentReport

        var id: String { "\(kind.rawValue)-\(report.id)" }

        var title: String {
            switch kind {
            case .review:
                return "Mark report reviewed?"
            case .deletePost:
                return "Delete this post?"
            case .deleteComment:
                return "Delete this comment?"
            case .ban:
                return "Ban this user?"
            }
        }

        var message: String {
            switch kind {
            case .review:
                return "This keeps the content but closes the report."
            case .deletePost:
                return "The post will be removed for everyone and this report will be marked actioned."
            case .deleteComment:
                return "The comment will be removed for everyone and this report will be marked actioned."
            case .ban:
                return "@\(report.targetAuthorUsername) will be blocked from future posting, commenting, reacting, and friend actions."
            }
        }

        var actionTitle: String {
            switch kind {
            case .review:
                return "Mark Reviewed"
            case .deletePost:
                return "Delete Post"
            case .deleteComment:
                return "Delete Comment"
            case .ban:
                return "Ban User"
            }
        }

        var isDestructive: Bool {
            kind != .review
        }
    }

    var body: some View {
        Group {
            if embedsNavigationStack {
                NavigationStack {
                    reportsContent
                }
            } else {
                reportsContent
            }
        }
        .sheet(item: $openedPost) { post in
            ReportedPostPreviewSheet(post: post)
                .modifier(PostDetailPresentation())
                .environment(store)
                .environment(\.appAccent, accent)
                .presentationDetents([.large])
                .appSheetDragHandle(contentWidth: PostDetailPresentation.sheetWidth)
        }
        .sheet(item: $openedCommentTarget) { target in
            CommentThreadSheet(
                postID: target.postID,
                highlightedCommentID: target.id,
                initialPost: target.post
            )
            .environment(store)
            .environment(\.appAccent, accent)
            .presentationDetents([.fraction(0.6), .large])
            .appSheetDragHandle()
        }
        .alert(
            pendingReportConfirmation?.title ?? "Confirm action",
            isPresented: adminReportConfirmationBinding,
            presenting: pendingReportConfirmation
        ) { confirmation in
            Button(
                confirmation.actionTitle,
                role: confirmation.isDestructive ? .destructive : nil
            ) {
                performReportConfirmation(confirmation)
                pendingReportConfirmation = nil
            }
            Button("Cancel", role: .cancel) {
                pendingReportConfirmation = nil
            }
            .tint(.blue)
        } message: { confirmation in
            Text(confirmation.message)
        }
    }

    private var reportsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if !store.isDuoDevice { header }

                if let message = store.adminReportsMessage {
                    statusBanner(message)
                }

                if store.adminReports.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(store.adminReports) { report in
                            reportCard(report)
                        }

                        if store.hasMoreAdminReports {
                            if store.isLoadingAdminReports {
                                ProgressView()
                                    .tint(accent)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                            } else {
                                Color.clear
                                    .frame(height: 1)
                                    .onAppear {
                                        store.loadAdminReportsNextPage()
                                    }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, AppLayout.screenPadding)
            .padding(.top, store.isDuoDevice ? AppLayout.secondaryPageTopPadding : 12)
            .padding(.bottom, AppLayout.tabBarClearance)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always, axes: .vertical)
        .scrollContentBackground(.hidden)
        .modifier(DuoPageHeader(title: "Reports"))
        .toolbar {
            if store.isDuoDevice {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh reports", systemImage: "arrow.clockwise") {
                        store.loadAdminReportsNextPage(reset: true)
                    }
                }
            }
        }
        .background {
            AmbientBackground()
                .ignoresSafeArea()
        }
        .refreshable {
            store.loadAdminReportsNextPage(reset: true)
        }
        .task {
            if store.adminReports.isEmpty {
                store.loadAdminReportsNextPage(reset: true)
            }
        }
        .task(id: store.activityTabSelectionTrigger) {
            guard store.selectedTab == .activity,
                  store.isViewerAdmin,
                  store.activityTabSelectionTrigger > 0
            else { return }

            store.loadAdminReportsNextPage(reset: true)
        }
        .navigationDestination(item: $openedProfile) { profile in
            FriendProfileView(profile: profile, presentationStyle: .embedded)
        }
    }

    // MARK: - Header & empty / banner states

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Reports")
                .font(AppTypography.pageTitle)
                .foregroundStyle(.white)

            Spacer()

            Button {
                store.loadAdminReportsNextPage(reset: true)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Refresh reports")
        }
    }

    private var emptyState: some View {
        NightPanel(cornerRadius: 28, padding: 20) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.85))
                Text(store.isLoadingAdminReports ? "Loading reports" : "No reports")
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(.white)
                Text(store.isLoadingAdminReports ? "Checking the moderation queue." : "New post, comment, and user reports will show up here.")
                    .font(AppTypography.rowSubtitle)
                    .foregroundStyle(AppTheme.softText)
            }
        }
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(AppTypography.rowSubtitleMedium)
        }
        .foregroundStyle(.white.opacity(0.84))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Report card

    private func reportCard(_ report: ContentReport) -> some View {
        NightPanel(cornerRadius: 28, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: iconName(for: report))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(0.06), in: Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(for: report))
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Text(Self.relativeDateFormatter.localizedString(for: report.createdAt, relativeTo: .now))
                            .font(AppTypography.metadata)
                            .foregroundStyle(AppTheme.softText)
                    }

                    Spacer()

                    statusButton(for: report)
                }

                VStack(alignment: .leading, spacing: 6) {
                    metadataRow(label: "Reporter", value: "@\(report.reporterUsername)")
                    metadataRow(label: "Target", value: "@\(report.targetAuthorUsername)")
                }

                Text(report.targetExcerpt)
                    .font(AppTypography.rowSubtitle)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(3)

                if !report.detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(report.detail)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppTheme.softText)
                        .lineLimit(3)
                }

                actionRow(for: report)
            }
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(AppTypography.metadataEmphasis)
                .foregroundStyle(AppTheme.softText)
                .textCase(.uppercase)
            Text(value)
                .font(AppTypography.button)
                .foregroundStyle(.white)
        }
    }

    // MARK: - Action row

    private func actionRow(for report: ContentReport) -> some View {
        VStack(spacing: 8) {
            if report.isOpen {
                Button("Mark Reviewed") {
                    confirmReview(report)
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
                .tint(accent)
            }

            HStack(spacing: 8) {
                if let deleteTitle = deleteActionTitle(for: report) {
                    Button(deleteTitle) {
                        confirmDelete(report)
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Color(hex: "#FF6B6B"))
                }

                Button("Ban") {
                    confirmBan(report)
                }
                .buttonStyle(.glass)
                .frame(maxWidth: .infinity)
                .foregroundStyle(Color(hex: "#FF6B6B"))
            }
        }
        .font(AppTypography.button)
    }

    private func deleteActionTitle(for report: ContentReport) -> String? {
        if report.targetType == ContentReportTarget.post.rawValue, report.targetPostID != nil {
            return "Delete Post"
        }
        if report.targetType == ContentReportTarget.comment.rawValue, report.targetCommentID != nil {
            return "Delete Comment"
        }
        return nil
    }

    // MARK: - Status pill / Open affordance

    @ViewBuilder
    private func statusButton(for report: ContentReport) -> some View {
        if canOpen(report) {
            Button {
                openReport(report)
            } label: {
                statusPillLabel(for: report)
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .accessibilityLabel(openAccessibilityLabel(for: report))
            .disabled(isLoadingOpen)
        } else {
            statusPillLabel(for: report)
                .accessibilityLabel("Status: \(report.status.capitalized)")
        }
    }

    private func statusPillLabel(for report: ContentReport) -> some View {
        let isOpen = report.isOpen
        return HStack(spacing: 5) {
            Text(report.status.capitalized)
                .font(AppTypography.metadataEmphasis)
            if canOpen(report) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
            }
        }
        .foregroundStyle(isOpen ? accent : AppTheme.softText)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.white.opacity(isOpen ? 0.10 : 0.05), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .contentShape(Capsule())
    }

    private func canOpen(_ report: ContentReport) -> Bool {
        if report.targetPostID != nil { return true }
        if report.targetType == ContentReportTarget.user.rawValue { return true }
        return false
    }

    private func openAccessibilityLabel(for report: ContentReport) -> String {
        switch report.targetType {
        case ContentReportTarget.post.rawValue: "Open reported post"
        case ContentReportTarget.comment.rawValue: "Open reported comment"
        case ContentReportTarget.user.rawValue: "Open reported user profile"
        default: "Open report"
        }
    }

    // MARK: - Open behavior

    private func openReport(_ report: ContentReport) {
        switch report.targetType {
        case ContentReportTarget.post.rawValue:
            openReportedPost(report)
        case ContentReportTarget.comment.rawValue:
            openReportedComment(report)
        case ContentReportTarget.user.rawValue:
            openReportedUser(report)
        default:
            break
        }
    }

    private func openReportedPost(_ report: ContentReport) {
        guard let postID = report.targetPostID else { return }

        if let post = store.posts.first(where: { $0.id == postID }) {
            openedPost = post
            return
        }

        Task {
            isLoadingOpen = true
            let loaded = await store.ensurePostLoaded(id: postID)
            isLoadingOpen = false
            if loaded, let post = store.posts.first(where: { $0.id == postID }) {
                openedPost = post
            } else {
                store.adminReportsMessage = "Couldn't open that post — it may have been deleted."
            }
        }
    }

    private func openReportedComment(_ report: ContentReport) {
        guard let postID = report.targetPostID, let commentID = report.targetCommentID else { return }

        if let post = store.posts.first(where: { $0.id == postID }) {
            openedCommentTarget = CommentOpenTarget(id: commentID, postID: postID, post: post)
            return
        }

        Task {
            isLoadingOpen = true
            let loaded = await store.ensurePostLoaded(id: postID)
            isLoadingOpen = false
            if loaded, let post = store.posts.first(where: { $0.id == postID }) {
                openedCommentTarget = CommentOpenTarget(id: commentID, postID: postID, post: post)
            } else {
                store.adminReportsMessage = "Couldn't open that comment — the post may have been deleted."
            }
        }
    }

    private func openReportedUser(_ report: ContentReport) {
        if let profile = resolveTargetProfile(for: report) {
            openedProfile = profile
        } else {
            store.adminReportsMessage = "Couldn't find @\(report.targetAuthorUsername)."
        }
    }

    private func resolveTargetProfile(for report: ContentReport) -> UserProfile? {
        let targetID = report.targetAuthorID

        if let profile = store.adminAllUsers.first(where: { $0.id == targetID }) {
            return profile
        }
        if let profile = store.friends.first(where: { $0.id == targetID }) {
            return profile
        }
        if let post = store.posts.first(where: { $0.author.id == targetID }) {
            return post.author
        }
        return nil
    }

    // MARK: - Destructive action confirmations

    private func confirmReview(_ report: ContentReport) {
        pendingReportConfirmation = AdminReportConfirmation(kind: .review, report: report)
    }

    private func confirmDelete(_ report: ContentReport) {
        if report.targetType == ContentReportTarget.post.rawValue {
            pendingReportConfirmation = AdminReportConfirmation(kind: .deletePost, report: report)
        } else if report.targetType == ContentReportTarget.comment.rawValue {
            pendingReportConfirmation = AdminReportConfirmation(kind: .deleteComment, report: report)
        }
    }

    private func confirmBan(_ report: ContentReport) {
        pendingReportConfirmation = AdminReportConfirmation(kind: .ban, report: report)
    }

    private func performReportConfirmation(_ confirmation: AdminReportConfirmation) {
        switch confirmation.kind {
        case .review:
            store.resolveAdminReport(confirmation.report)
        case .deletePost:
            store.deleteReportedPost(confirmation.report)
        case .deleteComment:
            store.deleteReportedComment(confirmation.report)
        case .ban:
            store.banReportedUser(confirmation.report)
        }
    }

    private var adminReportConfirmationBinding: Binding<Bool> {
        Binding {
            pendingReportConfirmation != nil
        } set: { isPresented in
            if !isPresented {
                pendingReportConfirmation = nil
            }
        }
    }

    // MARK: - Labels

    private func title(for report: ContentReport) -> String {
        switch report.targetType {
        case ContentReportTarget.post.rawValue:
            "Post report"
        case ContentReportTarget.comment.rawValue:
            "Comment report"
        case ContentReportTarget.user.rawValue:
            "User report"
        default:
            "Report"
        }
    }

    private func iconName(for report: ContentReport) -> String {
        switch report.targetType {
        case ContentReportTarget.post.rawValue:
            "photo.fill"
        case ContentReportTarget.comment.rawValue:
            "text.bubble.fill"
        case ContentReportTarget.user.rawValue:
            "person.crop.circle.badge.exclamationmark.fill"
        default:
            "flag.fill"
        }
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

/// Minimal sheet that shows a reported post in isolation so the admin can
/// inspect it before deciding. Reuses MomentPostCard so the admin sees exactly
/// what other users see.
private struct ReportedPostPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent

    let post: MomentPost

    var body: some View {
        NavigationStack {
            ScrollView {
                MomentPostCard(post: post, isFocused: true)
                    .modifier(PostDetailColumn())
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .modifier(MainPageSurface())
            .appSecondaryPageNavigation(title: "Reported Post")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(AppTypography.toolbarAction)
                        .foregroundStyle(accent)
                }
            }
        }
        .modifier(DuoSheetSurface())
    }
}
