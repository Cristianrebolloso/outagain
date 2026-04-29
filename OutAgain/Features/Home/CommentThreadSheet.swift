import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CommentThreadSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    let postID: UUID
    var highlightedCommentID: UUID? = nil

    @State private var draftText = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedPhotoData: Data?
    @State private var selectedPhotoIsGIF = false
    @State private var replyTarget: Comment?
    @State private var isCameraPresented = false
    @State private var isPhotoLibraryPresented = false
    @State private var isPhotoSourceOptionsPresented = false
    @State private var selectedCommentAuthor: UserProfile?
    @State private var pendingCommentAction: Comment?
    @State private var isConfirmingDeleteComment = false
    @State private var isConfirmingReportComment = false
    @State private var reportMessage: String?

    private var currentPost: MomentPost? {
        store.posts.first(where: { $0.id == postID })
    }

    private var comments: [Comment] {
        (currentPost?.comments ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    private var commentNodes: [ThreadCommentNode] {
        let grouped = Dictionary(grouping: comments, by: \.replyToCommentID)
        // Top-level comment IDs so we can identify which replies go
        // directly under a root comment vs. are nested deeper.
        let rootIDs = Set((grouped[nil] ?? []).map(\.id))

        func buildNodes(parentID: UUID?) -> [ThreadCommentNode] {
            (grouped[parentID] ?? [])
                .sorted { $0.createdAt < $1.createdAt }
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
            roots[i].replies.sort { $0.comment.createdAt < $1.comment.createdAt }
        }

        return roots
    }

    private var trimmedDraftText: String {
        draftText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !trimmedDraftText.isEmpty || selectedPhotoData != nil
    }

    var body: some View {
        // NavigationStack lets us push FriendProfileView onto the stack
        // when a commenter's avatar/name is tapped, avoiding the multiple-
        // sheet conflict that occurs when trying to layer a .sheet on top
        // of an already-presented sheet from the same view hierarchy.
        NavigationStack {
            ZStack {
                AmbientBackground()

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            titleSection
                            threadSection
                            composerSection
                        }
                        .padding(20)
                        .padding(.bottom, 12)
                    }
                    .scrollIndicators(.hidden)
                    .task(id: highlightedCommentID) {
                        guard let highlightedCommentID else { return }
                        try? await Task.sleep(for: .milliseconds(200))
                        withAnimation(.easeInOut(duration: 0.28)) {
                            proxy.scrollTo(highlightedCommentID, anchor: .center)
                        }
                    }
                }
            }
            .navigationDestination(item: $selectedCommentAuthor) { author in
                FriendProfileView(profile: author, presentationStyle: .embedded)
            }
            .navigationBarHidden(true)
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
        .sheet(isPresented: $isCameraPresented) {
            SystemImagePicker(sourceType: .camera, imageData: $selectedPhotoData)
        }
        .confirmationDialog("Add a photo", isPresented: $isPhotoSourceOptionsPresented, titleVisibility: .visible) {
            Button("Take Photo") {
                isCameraPresented = true
            }

            Button("Choose from Library") {
                isPhotoLibraryPresented = true
            }

            if selectedPhotoData != nil {
                Button("Remove Photo", role: .destructive) {
                    selectedPhotoItem = nil
                    selectedPhotoData = nil
                }
            }
        }
        .confirmationDialog(
            "Delete this comment?",
            isPresented: $isConfirmingDeleteComment,
            titleVisibility: .visible
        ) {
            Button("Delete comment", role: .destructive) {
                guard let pendingCommentAction else { return }
                store.deleteComment(commentID: pendingCommentAction.id, inPostID: postID)
                self.pendingCommentAction = nil
            }
            Button("Cancel", role: .cancel) {
                pendingCommentAction = nil
            }
        } message: {
            if let pendingCommentAction, canDeleteComment(pendingCommentAction) {
                Text(deleteCommentMessage(for: pendingCommentAction))
            } else {
                Text("This removes the comment from the thread.")
            }
        }
        .confirmationDialog(
            "Report this comment?",
            isPresented: $isConfirmingReportComment,
            titleVisibility: .visible
        ) {
            Button("Report comment", role: .destructive) {
                submitCommentReport()
            }
            Button("Cancel", role: .cancel) {
                pendingCommentAction = nil
            }
        } message: {
            Text("We'll flag it for review.")
        }
        .alert("Report status", isPresented: reportAlertBinding) {
            Button("OK", role: .cancel) {
                reportMessage = nil
                pendingCommentAction = nil
            }
        } message: {
            Text(reportMessage ?? "We'll take a look.")
        }
        .task(id: postID) {
            await store.ensureFullCommentsLoaded(for: postID)
        }
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Comments")
                .font(.system(size: 32, weight: .bold, design: .serif))
                .foregroundStyle(.white)
        }
    }

    @ViewBuilder
    private var threadSection: some View {
        if !commentNodes.isEmpty {
            NightPanel(cornerRadius: 30, padding: 16) {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(commentNodes.enumerated()), id: \.element.id) { index, node in
                        CommentThreadNodeView(
                            node: node,
                            postID: postID,
                            highlightedCommentID: highlightedCommentID,
                            onReply: { comment in
                                withAnimation(.snappy(duration: 0.2)) {
                                    replyTarget = comment
                                }
                            },
                            onAuthorTap: { author in
                                selectedCommentAuthor = author
                            },
                            onMore: { action in
                                handleCommentOverflowAction(action)
                            }
                        )

                        if index < commentNodes.count - 1 {
                            Divider()
                                .overlay(AppTheme.line)
                        }
                    }
                }
            }
        } else if (currentPost?.commentCount ?? 0) > 0 {
            NightPanel(cornerRadius: 30, padding: 20) {
                HStack(spacing: 12) {
                    ProgressView()
                        .tint(accent)
                    Text("Loading comments…")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
    }

    private var composerSection: some View {
        NightPanel(cornerRadius: 30, padding: 16) {
            VStack(alignment: .leading, spacing: 16) {
                if let replyTarget {
                    replyBanner(replyTarget)
                }

                if let selectedPhotoData {
                    selectedPhotoPreview(data: selectedPhotoData, isGIF: selectedPhotoIsGIF)
                }

                HStack(alignment: .center, spacing: 10) {
                    Button {
                        isPhotoSourceOptionsPresented = true
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(AppTheme.charcoal)
                            .frame(width: 36, height: 36)
                            .background(accent, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add photo")

                    composerInput
                }
            }
        }
    }

    private func replyBanner(_ comment: Comment) -> some View {
        HStack(spacing: 10) {
            Text("Replying to \(comment.author.displayName)")
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)

            Spacer()

            Button {
                replyTarget = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppTheme.softText)
                    .frame(width: 26, height: 26)
                    .background(.white.opacity(0.05), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var composerInput: some View {
        HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if draftText.isEmpty {
                    Text(replyTarget == nil ? "Add a comment..." : "Write a reply...")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(AppTheme.softText)
                        .padding(.top, 8)
                }

                TextField("", text: $draftText, axis: .vertical)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(.white)
                    .tint(accent)
                    .textInputAutocapitalization(.sentences)
                    .lineLimit(1 ... 5)
                    .padding(.vertical, 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if canSend {
                Button {
                    submitComment()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.charcoal)
                        .frame(width: 36, height: 36)
                        .background(accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Post comment")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
    }

    private func selectedPhotoPreview(data: Data, isGIF: Bool) -> some View {
        ZStack(alignment: .topTrailing) {
            if isGIF {
                AnimatedGIFView(data: data)
                    .frame(maxWidth: .infinity, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(AppTheme.line, lineWidth: 1)
                    )
            } else if let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(AppTheme.line, lineWidth: 1)
                    )
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
        draftText = ""
        selectedPhotoItem = nil
        selectedPhotoData = nil
        selectedPhotoIsGIF = false
        replyTarget = nil
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
}

private func dataLooksLikeGIF(_ data: Data) -> Bool {
    data.prefix(6).starts(with: [0x47, 0x49, 0x46, 0x38])
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
        VStack(alignment: .leading, spacing: 12) {
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
                HStack(alignment: .top, spacing: 12) {
                    Rectangle()
                        .fill(AppTheme.line)
                        .frame(width: 1)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(node.replies.enumerated()), id: \.element.id) { index, reply in
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

                            if index < node.replies.count - 1 {
                                Divider()
                                    .overlay(AppTheme.line)
                            }
                        }
                    }
                }
                .padding(.leading, 23)
            }
        }
    }
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
                AvatarView(avatar: comment.author.avatar, size: 34)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button(action: onAuthorTap) {
                        Text(comment.author.displayName)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Text(comment.createdAt.minuteGranularityRelative)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(AppTheme.softText)

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

                if let replyToDisplayName = comment.replyToDisplayName {
                    Text("Replying to \(replyToDisplayName)")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(accent)
                }

                commentBody

                HStack(spacing: 14) {
                    Button(action: onLike) {
                        Label(
                            comment.likeCount == 0 ? "Like" : "\(comment.likeCount)",
                            systemImage: comment.isLikedByViewer ? "heart.fill" : "heart"
                        )
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(comment.isLikedByViewer ? accent : AppTheme.softText)
                    }
                    .buttonStyle(.plain)

                    Button("Reply", action: onReply)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(AppTheme.softText)
                        .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isHighlighted ? accent.opacity(0.12) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(isHighlighted ? accent.opacity(0.45) : .clear, lineWidth: 1)
        )
        .id(comment.id)
    }

    @ViewBuilder
    private var commentBody: some View {
        switch comment.kind {
        case .text:
            Text(comment.text)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        case .photo:
            VStack(alignment: .leading, spacing: 10) {
                CommentPhotoAttachment(comment: comment)

                if !comment.text.isEmpty, comment.text != "Photo reply" {
                    Text(comment.text)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        case .gif:
            VStack(alignment: .leading, spacing: 10) {
                CommentPhotoAttachment(comment: comment)

                if !comment.text.isEmpty, comment.text != "GIF reply" {
                    Text(comment.text)
                        .font(.system(.body, design: .rounded))
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
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else if let image = UIImage(data: photoData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        RoundedRectangle(cornerRadius: 18, style: .continuous)
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
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else if let image = UIImage(data: data) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
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
        RoundedRectangle(cornerRadius: 18, style: .continuous)
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
