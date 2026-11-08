// Preserve the existing phone comment sheet independently of Duo pane layout.
import Combine
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct PhoneCommentThreadSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    let postID: UUID
    var highlightedCommentID: UUID? = nil
    var initialPost: MomentPost? = nil

    @State private var draftText = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedPhotoData: Data?
    @State private var selectedPhotoIsGIF = false
    @State private var replyTarget: Comment?
    @State private var composerFocusRequestID = 0
    @State private var isCameraPresented = false
    @State private var isPhotoLibraryPresented = false
    @State private var isPhotoSourceOptionsPresented = false
    @State private var selectedCommentAuthor: UserProfile?
    @State private var pendingCommentAction: Comment?
    @State private var isConfirmingDeleteComment = false
    @State private var isConfirmingReportComment = false
    @State private var reportMessage: String?
    @State private var mentionSuggestions: [UserProfile] = []
    @State private var mentionSearchTask: Task<Void, Never>?
    // How far to lift the composer bar above its natural resting position.
    @State private var keyboardOffset: CGFloat = 0

    private var currentPost: MomentPost? {
        hydratedCurrentPost(
            livePost: store.livePost(matching: postID),
            fallbackPost: initialPost
        )
    }

    private var comments: [Comment] {
        (currentPost?.comments ?? []).sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    private var highlightedCommentIsLoaded: Bool {
        guard let highlightedCommentID else { return false }
        return comments.contains(where: { $0.id == highlightedCommentID })
    }

    private var commentNodes: [ThreadCommentNode] {
        let grouped = Dictionary(grouping: comments, by: \.replyToCommentID)

        func buildNodes(parentID: UUID?) -> [ThreadCommentNode] {
            (grouped[parentID] ?? [])
                .sorted { lhs, rhs in
                    if lhs.createdAt == rhs.createdAt {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.createdAt < rhs.createdAt
                }
                .map { comment in
                    // Only recurse one level deep. Any reply whose parent
                    // is itself already a reply (not a root comment) gets
                    // flattened up — we collect all descendants and attach
                    // them as flat children of the root comment they
                    // belong to. Two visual layers max: root → replies.
                    let replies: [ThreadCommentNode]
                    if parentID == nil {
                        // Building root level — recurse but only one hop.
                        replies = buildNodes(parentID: comment.id)
                    } else {
                        // Building reply level — no further nesting.
                        replies = []
                    }
                    return ThreadCommentNode(comment: comment, replies: replies)
                }
        }

        // Flatten deep replies: any comment whose replyToCommentID points
        // at a reply (not a root) gets attached to that root's reply list.
        var roots = buildNodes(parentID: nil)

        // Collect orphaned deep-replies and attach them to the correct root.
        let rootCommentIDs = Set(roots.map(\.id))
        let allReplyIDs = Set(roots.flatMap { $0.replies.map(\.id) })

        for comment in comments {
            guard
                let replyToID = comment.replyToCommentID,
                !rootCommentIDs.contains(replyToID), // parent is not a root
                !allReplyIDs.contains(comment.id)    // not already placed
            else { continue }

            // Find which root this belongs to by walking up the chain.
            var ancestorID: UUID? = replyToID
            var rootID: UUID? = nil
            while let aid = ancestorID {
                if rootCommentIDs.contains(aid) {
                    rootID = aid
                    break
                }
                ancestorID = comments.first(where: { $0.id == aid })?.replyToCommentID
            }

            if let rootID, let rootIndex = roots.firstIndex(where: { $0.id == rootID }) {
                let node = ThreadCommentNode(comment: comment, replies: [])
                roots[rootIndex].replies.append(node)
            }
        }

        // Re-sort each root's replies by date after flattening.
        for i in roots.indices {
            roots[i].replies.sort { lhs, rhs in
                if lhs.comment.createdAt == rhs.comment.createdAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.comment.createdAt < rhs.comment.createdAt
            }
        }

        return roots
    }

    private var trimmedDraftText: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedDraftText.isEmpty || selectedPhotoData != nil
    }

    private var activeMentionQuery: String? {
        Self.activeMentionQuery(in: draftText)
    }

    private var shouldShowMentionSuggestions: Bool {
        activeMentionQuery != nil && !mentionSuggestions.isEmpty
    }

    private var mentionCandidatePool: [UserProfile] {
        var pool: [UserProfile] = []
        var seen = Set<UUID>()

        func append(_ profile: UserProfile?) {
            guard let profile,
                  profile.id != store.viewer?.id,
                  !store.blockedUserIDs.contains(profile.id),
                  seen.insert(profile.id).inserted
            else { return }
            pool.append(profile)
        }

        append(replyTarget?.author)
        append(currentPost?.author)
        currentPost?.taggedFriends.forEach { append($0) }
        comments.forEach { append($0.author) }
        store.friends.forEach { append($0) }

        return pool
    }

    var body: some View {
        ZStack {
            Group {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            titleSection
                            threadSection
                        }
                        .padding(20)
                        .padding(.top, 12)
                        // Reserve space so the last comment scrolls above the
                        // composer bar. When the keyboard is up the bar is lifted
                        // by keyboardOffset, so content must clear the keyboard
                        // height too — otherwise comments under the keyboard are
                        // unreachable.
                        .padding(.bottom, 80 + keyboardOffset)
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .ignoresSafeArea(.keyboard)
                    .onTapGesture {
                        UIApplication.shared.sendAction(
                            #selector(UIResponder.resignFirstResponder),
                            to: nil, from: nil, for: nil
                        )
                    }
                    .task(id: highlightedCommentID) {
                        await scrollToHighlightedCommentIfReady(proxy)
                    }
                    .onChange(of: highlightedCommentIsLoaded) { _, isLoaded in
                        guard isLoaded else { return }
                        Task {
                            await scrollToHighlightedCommentIfReady(proxy)
                        }
                    }
                }
                .sheet(item: $selectedCommentAuthor) { author in
                    FriendProfileView(profile: author, presentationStyle: .sheet)
                        .presentationDetents([.large])
                        .appSheetDragHandle()
                }
                .overlay(alignment: .bottom) {
                    PhoneComposerBarView(
                        draftText: $draftText,
                        replyTarget: $replyTarget,
                        selectedPhotoItem: $selectedPhotoItem,
                        selectedPhotoData: $selectedPhotoData,
                        selectedPhotoIsGIF: $selectedPhotoIsGIF,
                        mentionSuggestions: $mentionSuggestions,
                        isCameraPresented: $isCameraPresented,
                        isPhotoLibraryPresented: $isPhotoLibraryPresented,
                        focusRequestID: composerFocusRequestID,
                        accent: accent,
                        placeholder: replyTarget == nil ? "Add a comment..." : "Write a reply...",
                        shouldShowMentionSuggestions: shouldShowMentionSuggestions,
                        canSend: canSend,
                        keyboardUp: keyboardOffset > 0,
                        onMentionPick: { applyMentionSuggestion($0) },
                        onSubmit: { submitComment() },
                        onTextChange: { updateMentionSuggestions() }
                    )
                    .offset(y: -keyboardOffset)
                }
                // Disable SwiftUI's automatic keyboard avoidance so the composer
                // bar doesn't get double-moved — once by SwiftUI and once by our
                // manual keyboardOffset. We handle all keyboard layout manually.
                .ignoresSafeArea(.keyboard)
            }
            .presentationBackground {
                AmbientBackground()
                    .environment(\.appBackgroundTheme, store.backgroundTheme)
            }
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [.black.opacity(0.45), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 60)
                .allowsHitTesting(false)
            }
            .background(SheetChromeFix().frame(width: 0, height: 0).allowsHitTesting(false))
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { notification in
                guard let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let keyWindow = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .first?.windows.first(where: \.isKeyWindow)
                let safeBottom = keyWindow?.safeAreaInsets.bottom ?? 0
                let barBottom = (keyWindow?.bounds.height ?? keyboardFrame.maxY) - safeBottom
                withAnimation(.spring(response: 0.22, dampingFraction: 1.0)) {
                    keyboardOffset = max(0, barBottom - keyboardFrame.minY)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                withAnimation(.spring(response: 0.22, dampingFraction: 1.0)) {
                    keyboardOffset = 0
                }
            }
            .onChange(of: selectedPhotoItem) { _, newValue in
                guard let newValue else { return }
                Task {
                    let expectsGIF = newValue.supportedContentTypes.contains(UTType.gif)
                    if let data = try? await newValue.loadTransferable(type: Data.self) {
                        selectedPhotoData = data
                        selectedPhotoIsGIF = expectsGIF || dataLooksLikeGIF(data)
                    }
                }
            }
            .photosPicker(
                isPresented: $isPhotoLibraryPresented,
                selection: $selectedPhotoItem,
                matching: .images,
                preferredItemEncoding: .current
            )
            .fullScreenCover(isPresented: $isCameraPresented) {
                SystemImagePicker(sourceType: .camera, imageData: $selectedPhotoData)
                    .ignoresSafeArea()
            }
            .alert(
                "Delete this comment?",
                isPresented: $isConfirmingDeleteComment,
                actions: {
                Button("Delete comment", role: .destructive) {
                    guard let pendingCommentAction else { return }
                    store.deleteComment(commentID: pendingCommentAction.id, inPostID: postID)
                    self.pendingCommentAction = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingCommentAction = nil
                }
                .tint(.blue)
            }, message: {
                if let pendingCommentAction, canDeleteComment(pendingCommentAction) {
                    Text(deleteCommentMessage(for: pendingCommentAction))
                } else {
                    Text("This removes the comment from the thread.")
                }
            })
            .alert(
                "Report this comment?",
                isPresented: $isConfirmingReportComment,
                actions: {
                Button("Report comment", role: .destructive) {
                    submitCommentReport()
                }
                Button("Cancel", role: .cancel) {
                    pendingCommentAction = nil
                }
                .tint(.blue)
            }, message: {
                Text("We'll flag it for review.")
            })
            .alert("Report status", isPresented: reportAlertBinding) {
                Button("OK", role: .cancel) {
                    reportMessage = nil
                    pendingCommentAction = nil
                }
            } message: {
                Text(reportMessage ?? "We'll take a look.")
            }
            .onAppear {
                seedInitialPostIfNeeded()
            }
            .task(id: postID) {
                seedInitialPostIfNeeded()
                await store.ensureFullCommentsLoaded(
                    for: postID,
                    requiring: highlightedCommentID,
                    fallbackPost: initialPost
                )
            }
            .onDisappear {
                mentionSearchTask?.cancel()
            }
        }
    }

    private func hydratedCurrentPost(
        livePost: MomentPost?,
        fallbackPost: MomentPost?
    ) -> MomentPost? {
        guard var livePost else { return fallbackPost }
        guard let fallbackPost, fallbackPost.id == livePost.id else { return livePost }

        let liveCommentIDs = Set(livePost.comments.map(\.id))
        let missingFallbackComments = fallbackPost.comments.filter { !liveCommentIDs.contains($0.id) }
        if !missingFallbackComments.isEmpty {
            livePost.comments = missingFallbackComments + livePost.comments
        }
        livePost.commentCount = max(
            livePost.commentCount,
            fallbackPost.commentCount,
            livePost.comments.count
        )
        livePost.hasLoadedFullCommentThread = livePost.hasLoadedFullCommentThread
            || fallbackPost.hasLoadedFullCommentThread
        return livePost
    }

    private func seedInitialPostIfNeeded() {
        guard let initialPost, initialPost.id == postID else { return }

        guard let existing = store.livePost(matching: postID) else {
            store.cacheProfilePosts([initialPost])
            return
        }

        let initialHasNewerPreview = initialPost.comments.count > existing.comments.count
        let initialHasNewerCount = initialPost.commentCount > existing.commentCount
        guard initialHasNewerPreview || initialHasNewerCount else { return }

        store.cacheProfilePosts([initialPost])
    }

    private func scrollToHighlightedCommentIfReady(_ proxy: ScrollViewProxy) async {
        guard let highlightedCommentID,
              highlightedCommentIsLoaded
        else { return }

        try? await Task.sleep(for: .milliseconds(200))
        withAnimation(.easeInOut(duration: 0.28)) {
            proxy.scrollTo(highlightedCommentID, anchor: .center)
        }
    }

    private var titleSection: some View {
        EmptyView()
    }

    @ViewBuilder
    private var threadSection: some View {
        let hasCaption = !(currentPost?.caption.isEmpty ?? true)
        let hasComments = !commentNodes.isEmpty
        let isLoading = !hasComments && (currentPost?.commentCount ?? 0) > 0

        // No caption, no loaded comments, no incoming load — render an
        // inviting empty state in place of the panel rather than an empty
        // rounded rectangle. Floats centered in the AmbientBackground for
        // a lighter, more welcoming feel.
        if !hasCaption && !hasComments && !isLoading {
            commentsEmptyState
        } else {
            // Everything lives in one NightPanel: optional caption header,
            // comment rows or loading indicator.
            NightPanel(cornerRadius: AppLayout.panelRadius, padding: 14) {
                VStack(alignment: .leading, spacing: 0) {

                    // ── Caption header — only when the post has a caption ────
                    if let post = currentPost, hasCaption {
                        HStack(spacing: 10) {
                            AvatarView(avatar: post.author.avatar, size: 34)

                            VStack(alignment: .leading, spacing: 2) {
                                VerifiedProfileLabel(profile: post.author, spacing: 4, badgeSize: 11) {
                                    Text(post.author.displayName)
                                        .font(AppTypography.rowTitle)
                                        .foregroundStyle(.white)
                                }
                                Text(post.caption)
                                    .font(AppTypography.callout)
                                    .foregroundStyle(.white.opacity(0.92))
                                    .lineLimit(3)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 10)

                        // Only render the divider when there's something
                        // below it — otherwise the caption is followed by
                        // a hairline floating above empty space.
                        if hasComments || isLoading {
                            Divider()
                                .overlay(AppTheme.line)
                                .padding(.bottom, 10)
                        }
                    }

                    // ── Comment rows ─────────────────────────────────────────
                    if hasComments {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(commentNodes) { node in
                                CommentThreadNodeView(
                                    node: node,
                                    postID: postID,
                                    highlightedCommentID: highlightedCommentID,
                                    onReply: { comment in
                                        if keyboardOffset > 0 {
                                            // Keyboard already visible — animate the banner
                                            // swap in place with a quick fade.
                                            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                                                replyTarget = comment
                                            }
                                        } else {
                                            // Keyboard is coming up — place the banner
                                            // instantly so the whole bar rises as one unit.
                                            replyTarget = comment
                                        }
                                        composerFocusRequestID += 1
                                    },
                                    onAuthorTap: { author in
                                        selectedCommentAuthor = author
                                    },
                                    onMore: { action in
                                        handleCommentOverflowAction(action)
                                    }
                                )
                            }
                        }
                    } else if isLoading {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(accent)
                            Text("Loading comments…")
                                .font(AppTypography.button)
                                .foregroundStyle(.white)
                        }
                    } else if hasCaption {
                        // Caption present, comments empty: prompt the user
                        // inside the same panel so the empty space below
                        // the caption divider has purpose.
                        Text("Be the first to comment")
                            .font(AppTypography.button)
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 8)
                    }

                }
            }
        }
    }

    /// Standalone empty state used when there's nothing to render in the
    /// panel — no caption and no comments. Renders centered against the
    /// sheet's AmbientBackground without panel chrome, so the surface
    /// reads as "open invitation" rather than "loaded but empty."
    private var commentsEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
            Text("Be the first to comment")
                .font(AppTypography.rowTitle)
                .foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }


    private func submitComment() {
        if let selectedPhotoData {
            let kind: CommentKind = selectedPhotoIsGIF ? .gif : .photo
            let fallbackText = selectedPhotoIsGIF ? "GIF reply" : "Photo reply"
            store.addComment(
                trimmedDraftText.isEmpty ? fallbackText : trimmedDraftText,
                kind: kind,
                photoData: selectedPhotoData,
                toPostID: postID,
                replyingTo: replyTarget
            )
        } else {
            store.addComment(trimmedDraftText, kind: .text, toPostID: postID, replyingTo: replyTarget)
        }

        resetComposer()
    }

    private func resetComposer() {
        mentionSearchTask?.cancel()
        draftText = ""
        mentionSuggestions = []
        selectedPhotoItem = nil
        selectedPhotoData = nil
        selectedPhotoIsGIF = false
        replyTarget = nil
    }

    private func updateMentionSuggestions() {
        mentionSearchTask?.cancel()

        guard let query = activeMentionQuery else {
            mentionSuggestions = []
            return
        }

        let localSuggestions = localMentionSuggestions(matching: query)
        mentionSuggestions = localSuggestions

        let remoteQuery = UsernameRules.searchFragment(query)
        guard remoteQuery.count >= 2 else { return }
        let backend = store.backend
        let viewer = store.viewer

        mentionSearchTask = Task {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }

            let remoteSuggestions = (try? await backend.searchUsers(matching: remoteQuery, excluding: viewer)) ?? []
            let mergedSuggestions = mergeMentionSuggestions(
                local: localSuggestions,
                remote: remoteSuggestions,
                matching: remoteQuery
            )

            await MainActor.run {
                guard !Task.isCancelled,
                      UsernameRules.searchFragment(activeMentionQuery ?? "") == remoteQuery
                else { return }
                mentionSuggestions = mergedSuggestions
            }
        }
    }

    private func localMentionSuggestions(matching query: String) -> [UserProfile] {
        let normalizedQuery = UsernameRules.searchFragment(query)
        let pool = mentionCandidatePool

        guard !normalizedQuery.isEmpty else {
            return Array(pool.prefix(5))
        }

        return rankedMentionSuggestions(in: pool, matching: normalizedQuery)
    }

    private func mergeMentionSuggestions(
        local: [UserProfile],
        remote: [UserProfile],
        matching query: String
    ) -> [UserProfile] {
        var merged: [UserProfile] = []
        var seen = Set<UUID>()

        func append(_ profile: UserProfile) {
            guard profile.id != store.viewer?.id,
                  !store.blockedUserIDs.contains(profile.id),
                  seen.insert(profile.id).inserted
            else { return }
            merged.append(profile)
        }

        local.forEach(append)
        rankedMentionSuggestions(in: remote, matching: query).forEach(append)
        return Array(merged.prefix(5))
    }

    private func rankedMentionSuggestions(in profiles: [UserProfile], matching query: String) -> [UserProfile] {
        profiles
            .compactMap { profile -> (Int, String, UserProfile)? in
                let username = UsernameRules.normalized(profile.username)
                let displayName = profile.displayName.lowercased()

                let rank: Int
                if username == query {
                    rank = 0
                } else if username.hasPrefix(query) {
                    rank = 1
                } else if displayName.hasPrefix(query) {
                    rank = 2
                } else if displayName.contains(query) {
                    rank = 3
                } else {
                    return nil
                }

                return (rank, profile.displayName.lowercased(), profile)
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
                return lhs.1 < rhs.1
            }
            .map(\.2)
    }

    private func applyMentionSuggestion(_ profile: UserProfile) {
        draftText = Self.replacingActiveMention(in: draftText, with: profile.username)
        mentionSuggestions = []
    }

    private func canDeleteComment(_ comment: Comment) -> Bool {
        store.canDeleteComment(comment, inPostID: postID)
    }

    private func handleCommentOverflowAction(_ action: CommentOverflowAction) {
        switch action {
        case .report(let comment):
            pendingCommentAction = comment
            isConfirmingReportComment = true
        case .delete(let comment):
            pendingCommentAction = comment
            isConfirmingDeleteComment = true
        }
    }

    private func deleteCommentMessage(for comment: Comment) -> String {
        guard let currentPost, let viewer = store.viewer else {
            return "This removes the comment from the thread."
        }

        if comment.author.id == viewer.id && currentPost.author.id == viewer.id {
            return "This removes your comment from your post for everyone."
        }

        if comment.author.id == viewer.id {
            return "This removes your comment for everyone."
        }

        return "This removes their comment from your post."
    }

    private func submitCommentReport() {
        guard let commentToReport = pendingCommentAction else {
            reportMessage = "Couldn't find that comment to report anymore."
            return
        }

        Task { @MainActor in
            do {
                try await store.reportComment(commentToReport, inPostID: postID)
                reportMessage = "Thanks. We'll review this comment."
            } catch {
                reportMessage = error.localizedDescription
            }
        }
    }

    private var reportAlertBinding: Binding<Bool> {
        Binding(
            get: { reportMessage != nil },
            set: { isPresented in
                if !isPresented {
                    reportMessage = nil
                    pendingCommentAction = nil
                }
            }
        )
    }

    private static let activeMentionRegex = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9_])@([A-Za-z0-9_]*)$"#,
        options: []
    )

    private static func activeMentionQuery(in text: String) -> String? {
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = activeMentionRegex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }

        return String(text[range])
    }

    private static func replacingActiveMention(in text: String, with username: String) -> String {
        let nsRange = NSRange(text.startIndex..., in: text)
        guard let match = activeMentionRegex.firstMatch(in: text, options: [], range: nsRange),
              let fullRange = Range(match.range(at: 0), in: text)
        else { return text }

        return text.replacingCharacters(in: fullRange, with: "@\(UsernameRules.normalized(username)) ")
    }
}

private func dataLooksLikeGIF(_ data: Data) -> Bool {
    data.prefix(6).starts(with: [0x47, 0x49, 0x46, 0x38])
}

// MARK: - Sheet edge-attachment fix
//
// On iOS 26, a sheet presented with a custom `.presentationBackground` at
// non-`.large` detents renders as a floating card: rounded corners on all
// four sides, gaps to the screen's left/right edges, and a gap above the
// home indicator. SwiftUI exposes no API to change this; we have to reach
// the underlying `UISheetPresentationController` and configure it directly.
//
// What we set:
//
//   • `prefersEdgeAttachedInCompactHeight = true` — pin the sheet's bottom
//     to the screen's bottom edge.
//   • `widthFollowsPreferredContentSizeWhenEdgeAttached = false` — keep
//     the sheet at full screen width regardless of content size.
//   • `preferredCornerRadius = 28` — explicit top-corner radius; iOS 26
//     uses larger default radii that exaggerate the floating-card look.
//
// Additionally we override the presented view controller's `view.frame`
// at layout time so the sheet's container view extends to all four edges
// of its parent. iOS 26 applies a default lateral inset to non-`.large`
// detent sheets at the UIView level, even when the presentation
// controller is configured for edge attachment; we undo that by stretching
// the view back out to its parent's bounds on each layout pass.
//
// `SheetChromeFix` hosts an empty UIView whose only job is to walk the
// responder chain to the presented view controller and apply the
// configuration. It re-runs on every layout pass (the sheet's frame can
// change as the user drags between detents), which keeps the fix sticky.
private struct SheetChromeFix: UIViewRepresentable {
    func makeUIView(context: Context) -> ChromeFixView { ChromeFixView() }
    func updateUIView(_ uiView: ChromeFixView, context: Context) {
        uiView.applyFix()
    }

    final class ChromeFixView: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyFix()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyFix()
        }

        func applyFix() {
            // Walk the responder chain up to the presented view controller,
            // then read its sheet presentation controller. Edge-attachment
            // flags ensure the sheet itself is full-width and bottom-flush;
            // we no longer need to wrestle individual ancestor frames since
            // the composer is now mounted as the keyboard's accessory view
            // at the window level (see KeyboardAccessoryMounter).
            var responder: UIResponder? = self
            while let next = responder?.next {
                if let viewController = next as? UIViewController,
                   let sheet = viewController.sheetPresentationController {
                    sheet.prefersEdgeAttachedInCompactHeight = true
                    sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = false
                    sheet.preferredCornerRadius = 28
                    return
                }
                responder = next
            }
        }
    }
}

// MARK: - Composer bar (pure SwiftUI)

/// Pure-SwiftUI composer bar. Pinned to the bottom of the screen via an
/// overlay and lifted above the keyboard via a `keyboardOffset` computed from
/// UIResponder notifications in `PhoneCommentThreadSheet`. No UIKit responder chain
/// involved — layout is always correct from the first frame.
struct PhoneComposerBarView: View {
    @Binding var draftText: String
    @Binding var replyTarget: Comment?
    @Binding var selectedPhotoItem: PhotosPickerItem?
    @Binding var selectedPhotoData: Data?
    @Binding var selectedPhotoIsGIF: Bool
    @Binding var mentionSuggestions: [UserProfile]
    @Binding var isCameraPresented: Bool
    @Binding var isPhotoLibraryPresented: Bool

    let focusRequestID: Int
    let accent: Color
    let placeholder: String
    let shouldShowMentionSuggestions: Bool
    let canSend: Bool
    let keyboardUp: Bool
    let onMentionPick: (UserProfile) -> Void
    let onSubmit: () -> Void
    let onTextChange: () -> Void

    private var safeAreaBottom: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first(where: \.isKeyWindow)?
            .safeAreaInsets.bottom ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if shouldShowMentionSuggestions {
                mentionSuggestionsList
            }

            if let comment = replyTarget {
                replyBanner(comment)
                    .transition(.opacity)
            }

            if let data = selectedPhotoData {
                selectedPhotoPreview(data: data, isGIF: selectedPhotoIsGIF)
            }

            HStack(alignment: .center, spacing: 10) {
                Menu {
                    Button {
                        isCameraPresented = true
                    } label: {
                        Label("Take Photo", systemImage: "camera")
                    }
                    Button {
                        isPhotoLibraryPresented = true
                    } label: {
                        Label("Choose from Library", systemImage: "photo.on.rectangle")
                    }
                    if selectedPhotoData != nil {
                        Button(role: .destructive) {
                            selectedPhotoItem = nil
                            selectedPhotoData = nil
                        } label: {
                            Label("Remove Photo", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .primaryGlass(in: .circle, interactive: true)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .accessibilityLabel("Add photo")

                inputPill
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        // When the keyboard is up the bar's bottom edge sits on the keyboard
        // top — no bottom padding needed. When the keyboard is down, add the
        // safe area inset so the content clears the home indicator.
        .padding(.bottom, keyboardUp ? 10 : (safeAreaBottom + 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Color.black.opacity(0.96)
                .ignoresSafeArea(edges: .bottom)
        }
        .overlay(alignment: .top) {
            Divider().overlay(Color.white.opacity(0.12))
        }
    }

    private func replyBanner(_ comment: Comment) -> some View {
        HStack(spacing: 8) {
            Text("Replying to \(comment.author.displayName)")
                .font(AppTypography.buttonFootnote)
                .foregroundStyle(.white)

            Button {
                replyTarget = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.78))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 12)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .background(.white.opacity(0.22), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.28), lineWidth: 1))
    }

    private var inputPill: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if draftText.isEmpty {
                    Text(placeholder)
                        .font(AppTypography.body)
                        .foregroundStyle(AppTheme.softText)
                        // Match textContainerInset top (8pt) and lineFragmentPadding (4pt)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }

                PhoneComposerTextView(
                    text: $draftText,
                    accent: UIColor(accent),
                    focusRequestID: focusRequestID,
                    onChange: onTextChange
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if canSend {
                Button(action: onSubmit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .primaryGlass(in: .circle, interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .contentShape(Circle())
                .accessibilityLabel("Post comment")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            Color(red: 0.20, green: 0.20, blue: 0.21),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var mentionSuggestionsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(mentionSuggestions.prefix(5))) { profile in
                Button {
                    onMentionPick(profile)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(avatar: profile.avatar, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.displayName)
                                .font(AppTypography.button)
                                .foregroundStyle(.white)
                            VerifiedUsernameLabel(
                                profile: profile,
                                font: AppTypography.usernameCompact,
                                badgeSize: 10
                            )
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
    }

    private func selectedPhotoPreview(data: Data, isGIF: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            if isGIF {
                AnimatedGIFView(data: data)
                    .frame(maxWidth: .infinity, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(AppTheme.line, lineWidth: 1))
            } else if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(AppTheme.line, lineWidth: 1))
            }

            Button {
                selectedPhotoItem = nil
                selectedPhotoData = nil
                selectedPhotoIsGIF = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.black.opacity(0.45), in: Circle())
                    .padding(12)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - UIKit-bridged composer text view
//
// SwiftUI's `TextField` wraps a private UITextField that we cannot configure
// as a true UIResponder for the keyboard system's accessory mechanism. The
// composer's text input is therefore a real UITextView bridged through
// `UIViewRepresentable`. State binds back to the SwiftUI `@State draftText`
// so all surrounding logic (mention parsing, submit, reset) keeps working.

/// UITextView subclass that invalidates its intrinsic size on every layout
/// pass so the SwiftUI ZStack containing it always has an accurate height.
final class PhoneSelfSizingTextView: UITextView {
    override func layoutSubviews() {
        super.layoutSubviews()
        invalidateIntrinsicContentSize()
    }
}

struct PhoneComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let accent: UIColor
    let focusRequestID: Int
    let onChange: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PhoneSelfSizingTextView {
        let view = PhoneSelfSizingTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.textColor = .white
        view.tintColor = accent
        let descriptor = UIFontDescriptor
            .preferredFontDescriptor(withTextStyle: .body)
            .withDesign(.rounded) ?? UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        view.font = UIFont(descriptor: descriptor, size: 0)
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 4
        view.isScrollEnabled = false
        view.autocapitalizationType = .sentences
        view.autocorrectionType = .yes
        view.smartQuotesType = .yes
        view.keyboardAppearance = .dark
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ uiView: PhoneSelfSizingTextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
            uiView.invalidateIntrinsicContentSize()
        }
        uiView.tintColor = accent
        if focusRequestID > context.coordinator.lastHandledFocusRequestID {
            context.coordinator.lastHandledFocusRequestID = focusRequestID
            DispatchQueue.main.async { uiView.becomeFirstResponder() }
        }
    }

    // sizeThatFits is the correct SwiftUI hook for UIViewRepresentable sizing.
    // SwiftUI calls this to know how tall to make the view. We return the text
    // view's natural content height, capped at 5 lines.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PhoneSelfSizingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let lineHeight = uiView.font?.lineHeight ?? 20
        let insets = uiView.textContainerInset.top + uiView.textContainerInset.bottom
        let maxHeight = lineHeight * 5 + insets
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let height = min(measured, maxHeight)
        let shouldScroll = measured > maxHeight + 1
        if uiView.isScrollEnabled != shouldScroll {
            uiView.isScrollEnabled = shouldScroll
        }
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PhoneComposerTextView
        var lastHandledFocusRequestID = 0

        init(_ parent: PhoneComposerTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.onChange()
            textView.invalidateIntrinsicContentSize()
        }
    }
}

private enum CommentOverflowAction {
    case report(Comment)
    case delete(Comment)
}

private struct ThreadCommentNode: Identifiable {
    let comment: Comment
    var replies: [ThreadCommentNode]

    var id: UUID { comment.id }
}

// Make ThreadCommentNode mutable for flattening deep replies in the
// comment tree builder above.
extension ThreadCommentNode {
    mutating func appendReply(_ node: ThreadCommentNode) {
        replies.append(node)
    }
}

private struct CommentThreadNodeView: View {
    @Environment(AppStore.self) private var store

    let node: ThreadCommentNode
    let postID: UUID
    let highlightedCommentID: UUID?
    let onReply: (Comment) -> Void
    let onAuthorTap: (UserProfile) -> Void
    let onMore: (CommentOverflowAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CommentThreadRow(
                comment: node.comment,
                postID: postID,
                isHighlighted: node.comment.id == highlightedCommentID,
                onLike: {
                    store.toggleCommentLike(commentID: node.comment.id, inPostID: postID)
                },
                onReply: {
                    onReply(node.comment)
                },
                onAuthorTap: {
                    onAuthorTap(node.comment.author)
                },
                onMore: { action in
                    onMore(action)
                }
            )

            if !node.replies.isEmpty {
                HStack(alignment: .top, spacing: CommentThreadLayout.threadRailContentSpacing) {
                    Color.clear
                        .frame(width: CommentThreadLayout.threadRailWidth)

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(node.replies) { reply in
                            // Replies render flat at depth 1 — no further
                            // nesting regardless of replyToCommentID chain.
                            CommentThreadRow(
                                comment: reply.comment,
                                postID: postID,
                                isHighlighted: reply.comment.id == highlightedCommentID,
                                onLike: {
                                    store.toggleCommentLike(commentID: reply.comment.id, inPostID: postID)
                                },
                                onReply: {
                                    // Always reply to the root comment so
                                    // the thread stays flat.
                                    onReply(node.comment)
                                },
                                onAuthorTap: {
                                    onAuthorTap(reply.comment.author)
                                },
                                onMore: { action in
                                    onMore(action)
                                }
                            )
                        }
                    }
                }
                .padding(.leading, CommentThreadLayout.threadRailLeading)
            }
        }
    }
}

private enum CommentThreadLayout {
    static let avatarSize: CGFloat = 34
    static let threadRailWidth: CGFloat = 1
    static var threadRailLeading: CGFloat {
        (avatarSize - threadRailWidth) / 2
    }
    static let threadRailContentSpacing: CGFloat = 18.5
}

private struct CommentThreadRow: View {
    @Environment(\.appAccent) private var accent
    @Environment(AppStore.self) private var store
    let comment: Comment
    let postID: UUID
    let isHighlighted: Bool
    let onLike: () -> Void
    let onReply: () -> Void
    let onAuthorTap: () -> Void
    let onMore: (CommentOverflowAction) -> Void

    private var isViewersOwnComment: Bool {
        guard let viewerID = store.viewer?.id else { return false }
        return comment.author.id == viewerID
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onAuthorTap) {
                AvatarView(avatar: comment.author.avatar, size: CommentThreadLayout.avatarSize)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .lastTextBaseline, spacing: 8) {
                            Button(action: onAuthorTap) {
                                VerifiedProfileLabel(profile: comment.author, spacing: 4, badgeSize: 11, badgeOffsetY: -0.5) {
                                    Text(comment.author.displayName)
                                        .font(AppTypography.rowTitle)
                                        .foregroundStyle(.white)
                                }
                            }
                            .buttonStyle(.plain)

                            Text(comment.createdAt.minuteGranularityRelative)
                                .font(AppTypography.metadata)
                                .foregroundStyle(AppTheme.softText)
                        }
                    }

                    Spacer(minLength: 0)

                    Menu {
                        if !isViewersOwnComment {
                            Button {
                                onMore(.report(comment))
                            } label: {
                                Label("Report comment", systemImage: "flag")
                            }
                        }

                        if store.canDeleteComment(comment, inPostID: postID) {
                            Button(role: .destructive) {
                                onMore(.delete(comment))
                            } label: {
                                Label("Delete comment", systemImage: "trash")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(AppTheme.softText)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                commentBody
                    .padding(.top, 0)
                    .padding(.bottom, 10)

                HStack(spacing: 14) {
                    Button(action: onLike) {
                        Label(
                            comment.likeCount == 0 ? "Like" : "\(comment.likeCount)",
                            systemImage: comment.isLikedByViewer ? "heart.fill" : "heart"
                        )
                        .font(AppTypography.button)
                        .foregroundStyle(comment.isLikedByViewer ? accent : AppTheme.softText)
                    }
                    .buttonStyle(.plain)

                    Button("Reply", action: onReply)
                        .font(AppTypography.button)
                        .foregroundStyle(AppTheme.softText)
                        .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .id(comment.id)
    }

    @ViewBuilder
    private var commentBody: some View {
        switch comment.kind {
        case .text:
            Text(comment.text)
                .font(AppTypography.callout)
                .foregroundStyle(.white.opacity(0.92))
        case .photo:
            VStack(alignment: .leading, spacing: 10) {
                CommentPhotoAttachment(comment: comment)

                if !comment.text.isEmpty, comment.text != "Photo reply" {
                    Text(comment.text)
                        .font(AppTypography.callout)
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        case .gif:
            VStack(alignment: .leading, spacing: 10) {
                CommentPhotoAttachment(comment: comment)

                if !comment.text.isEmpty, comment.text != "GIF reply" {
                    Text(comment.text)
                        .font(AppTypography.callout)
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        }
    }
}

private struct CommentPhotoAttachment: View {
    let comment: Comment

    var body: some View {
        Group {
            if let photoData = comment.photoData {
                // Detect GIF by checking for the GIF magic bytes (GIF87a / GIF89a).
                let isGIF = photoData.prefix(6).starts(with: [0x47, 0x49, 0x46]) // "GIF"
                if isGIF {
                    AnimatedGIFView(data: photoData)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if let image = UIImage(data: photoData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    placeholder
                }
            } else if let remotePhotoURL = comment.remotePhotoURL {
                // Load remote media as raw data so we can detect and animate
                // GIFs. AsyncImage renders a static frame for GIFs — feeding
                // the data through AnimatedGIFView is the only path that plays.
                RemoteMediaView(url: remotePhotoURL)
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.white.opacity(0.05))
            .frame(height: 100)
            .overlay(
                Image(systemName: "camera.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppTheme.softText)
            )
    }
}

/// Fetches remote image/GIF data and renders it correctly.
/// Uses `URLSession` so we get the raw bytes and can detect GIFs;
/// `AsyncImage` would discard animation frames.
private struct RemoteMediaView: View {
    let url: URL

    @State private var loadedData: Data? = nil
    @State private var loadError = false

    var body: some View {
        Group {
            if let data = loadedData {
                let isGIF = data.prefix(6).starts(with: [0x47, 0x49, 0x46])
                if isGIF {
                    AnimatedGIFView(data: data)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else {
                    loadingPlaceholder
                }
            } else if loadError {
                loadingPlaceholder
            } else {
                loadingPlaceholder
                    .task { await fetchData() }
            }
        }
    }

    private var loadingPlaceholder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.white.opacity(0.05))
            .frame(height: 160)
            .overlay(
                ProgressView()
                    .tint(.white.opacity(0.4))
            )
    }

    private func fetchData() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            await MainActor.run { loadedData = data }
        } catch {
            await MainActor.run { loadError = true }
        }
    }
}

/// A SwiftUI wrapper around `UIImageView` that plays animated GIFs.
/// `UIImage(data:)` does NOT animate — `UIImage.animatedImage(with:duration:)`
/// does. We decode frames via `CGImageSource` to preserve per-frame delays.
private struct AnimatedGIFView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        if let animated = Self.animatedImage(from: data) {
            imageView.image = animated
        } else {
            imageView.image = UIImage(data: data)
        }
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {}

    /// Decodes all frames from GIF data and returns an animated `UIImage`.
    static func animatedImage(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }

        var frames: [UIImage] = []
        var totalDuration: Double = 0

        for i in 0 ..< count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            frames.append(UIImage(cgImage: cgImage))

            // Read the per-frame delay from the GIF properties.
            let properties = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any]
            let gifProperties = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gifProperties?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                ?? (gifProperties?[kCGImagePropertyGIFDelayTime] as? Double)
                ?? 0.1
            totalDuration += max(delay, 0.02) // clamp pathological 0-delay frames
        }

        return UIImage.animatedImage(with: frames, duration: totalDuration)
    }
}

private struct SystemImagePicker: UIViewControllerRepresentable {
    let sourceType: UIImagePickerController.SourceType
    @Binding var imageData: Data?
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(sourceType) ? sourceType : .photoLibrary
        picker.delegate = context.coordinator
        picker.allowsEditing = false
        // Full-screen so the camera viewfinder fills the display edge-to-edge.
        // Presenting as a sheet clips the preview behind the drag handle.
        picker.modalPresentationStyle = .fullScreen
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: SystemImagePicker

        init(parent: SystemImagePicker) {
            self.parent = parent
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage
            parent.imageData = image?.jpegData(compressionQuality: 0.88)
            parent.dismiss()
        }
    }
}
