import PhotosUI
import SwiftUI
import UIKit

struct HomeFeedView: View {
    @Environment(AppStore.self) private var store
    @State private var commentTarget: MomentPost?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                audienceSwitcher
                presenceLayer

                LazyVStack(spacing: 22) {
                    ForEach(store.homeFeedPosts) { post in
                        MomentPostCard(
                            post: post,
                            isFocused: store.selectedPresenceCluster?.relatedPostIDs.contains(post.id) ?? false,
                            onCommentTap: {
                                commentTarget = post
                            }
                        )
                        .scrollTransition(.interactive, axis: .vertical) { content, phase in
                            content
                                .scaleEffect(phase.isIdentity ? 1 : 0.985)
                                .opacity(phase.isIdentity ? 1 : 0.94)
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .task(id: store.presenceClusters.map(\.id)) {
            if store.selectedPresenceClusterID == nil {
                store.selectPresenceCluster(store.presenceClusters.first)
            }
        }
        .sheet(item: $commentTarget) { post in
            CommentThreadSheet(postID: post.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Text("Home")
                .font(.system(size: 42, weight: .bold, design: .serif))
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 12) {
                HeaderNotificationsButton()
                AvatarView(avatar: store.viewerIdentity.avatar, size: 54)
            }
        }
    }

    private var audienceSwitcher: some View {
        FeedScopeSwitcher()
    }

    private var presenceLayer: some View {
        Group {
            if store.hasLiveSignal {
                ActivePresenceRail(
                    activeCount: store.activeNowCount,
                    clusters: store.recentPresenceClusters
                )
            } else {
                EmptyStateCard(
                    title: "Nobody's out yet",
                    detail: store.feedScope == .friends ? "Friends will show up here as soon as someone opens the app or posts." : "Friends-of-friends will show up here when your graph has real overlap.",
                    symbol: "moon.stars.fill"
                )
            }
        }
    }
}

private struct HeaderNotificationsButton: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            store.openNotifications()
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.white.opacity(0.05), in: Circle())
                    .overlay(Circle().strokeBorder(AppTheme.line, lineWidth: 1))
                    .glassEffect(.regular.tint(AppTheme.amber.opacity(0.14)).interactive(), in: .circle)

                if store.unreadNotificationCount > 0 {
                    Text("\(store.unreadNotificationCount)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(AppTheme.amber, in: Capsule())
                        .offset(x: 8, y: -8)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

private struct FeedScopeSwitcher: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(FeedScope.allCases) { scope in
                    let isSelected = store.feedScope == scope

                    Button {
                        withAnimation(.snappy(duration: 0.24)) {
                            store.selectFeedScope(scope)
                        }
                    } label: {
                        Text(scope.title)
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(isSelected ? .white : AppTheme.softText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(
                                Capsule()
                                    .fill(isSelected ? .white.opacity(0.1) : .clear)
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(isSelected ? AppTheme.line : .clear, lineWidth: 1)
                            )
                            .glassEffect(
                                .regular
                                    .tint(isSelected ? AppTheme.amber.opacity(0.18) : .clear)
                                    .interactive(),
                                in: .capsule
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.white.opacity(0.04), in: Capsule())
            .overlay(Capsule().strokeBorder(AppTheme.line, lineWidth: 1))
            .glassEffect(.regular.tint(AppTheme.amber.opacity(0.08)), in: .capsule)
        }
    }
}

private struct ActivePresenceRail: View {
    let activeCount: Int
    let clusters: [PresenceCluster]

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            activePill

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(clusters) { cluster in
                        PresenceClusterTile(cluster: cluster)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private var activePill: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(AppTheme.activeGreen)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(AppTheme.ink, lineWidth: 1))

                Text(activeCount == 1 ? "1 active" : "\(activeCount) active")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Text("Opened or posted")
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(AppTheme.softText)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
        .glassEffect(.regular.tint(AppTheme.amber.opacity(0.12)), in: .rect(cornerRadius: 24))
    }
}

private struct PresenceClusterTile: View {
    @Environment(AppStore.self) private var store
    let cluster: PresenceCluster
    @State private var animateGlow = false

    var body: some View {
        let isSelected = store.selectedPresenceCluster?.id == cluster.id

        Button {
            withAnimation(.snappy(duration: 0.24)) {
                store.selectPresenceCluster(cluster)
            }
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .stroke(
                            isSelected ? AppTheme.warmGold.opacity(0.96) : Color(hex: cluster.anchor.avatar.primaryHex).opacity(0.58),
                            lineWidth: isSelected ? 2.8 : 1.6
                        )
                        .frame(width: 68, height: 68)
                        .scaleEffect(animateGlow ? 1.04 : 0.96)
                        .opacity(animateGlow ? 0.16 : 0.32)

                    AvatarView(avatar: cluster.anchor.avatar, size: 58)
                        .overlay(
                            Circle()
                                .strokeBorder(.white.opacity(isSelected ? 0.18 : 0.08), lineWidth: 1)
                        )

                    if cluster.friends.count > 1 {
                        Text("+\(cluster.friends.count - 1)")
                            .font(.system(.caption2, design: .rounded, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.7), in: Capsule())
                            .overlay(Capsule().strokeBorder(AppTheme.line, lineWidth: 1))
                            .offset(x: 5, y: 5)
                    } else {
                        Circle()
                            .fill(AppTheme.activeGreen)
                            .frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(AppTheme.ink, lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                }

                VStack(spacing: 3) {
                    Text(cluster.title)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(cluster.updatedAt, style: .relative)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(isSelected ? AppTheme.warmGold : AppTheme.softText)
                }
            }
            .frame(width: 70)
        }
        .buttonStyle(.plain)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                animateGlow = true
            }
        }
    }
}

struct MomentPostCard: View {
    @Environment(AppStore.self) private var store
    let post: MomentPost
    var isFocused = false
    var onCommentTap: () -> Void = {}

    private var totalReactions: Int {
        post.reactions.reduce(0) { $0 + $1.count }
    }

    private var togetherLine: String? {
        guard let first = post.taggedFriends.first else { return nil }
        let extra = post.taggedFriends.count - 1
        return extra > 0 ? "With \(first.displayName) +\(extra)" : "With \(first.displayName)"
    }

    var body: some View {
        let tint = Color(hex: post.media.primaryHex)

        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                MomentMediaView(media: post.media, height: 430)
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.black.opacity(0.6), .clear, .black.opacity(0.72)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    .padding(8)

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 12) {
                        AvatarView(avatar: post.author.avatar, size: 56)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(post.author.displayName)
                                .font(.system(size: 28, weight: .bold, design: .serif))
                                .foregroundStyle(.white)

                            if let togetherLine {
                                Text(togetherLine)
                                    .font(.system(.headline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.92))
                            }

                            HStack(spacing: 8) {
                                if let venue = post.venue {
                                    Label(venue.name, systemImage: "mappin.and.ellipse")
                                }

                                Text(post.createdAt, style: .relative)
                            }
                            .font(.system(.footnote, design: .rounded, weight: .semibold))
                            .foregroundStyle(AppTheme.warmGold)
                        }

                        Spacer()

                        VStack(alignment: .trailing, spacing: 10) {
                            if let path = post.connectionPath {
                                contentAwareChip(path, icon: "arrow.triangle.branch", emphasized: false)
                            }

                            Circle()
                                .fill(.black.opacity(0.26))
                                .frame(width: 42, height: 42)
                                .overlay(
                                    Image(systemName: "ellipsis")
                                        .font(.system(size: 16, weight: .bold))
                                        .foregroundStyle(.white)
                                )
                                .overlay(Circle().strokeBorder(.white.opacity(0.08), lineWidth: 1))
                        }
                    }

                    Spacer()
                }
                .padding(20)
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 18) {
                    Button {
                        store.addReaction(.cheers, to: post)
                    } label: {
                        ActionCount(icon: "heart", count: totalReactions, isActive: true)
                    }
                    .buttonStyle(.plain)

                    Button(action: onCommentTap) {
                        ActionCount(icon: "message", count: post.comments.count, isActive: false)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Image(systemName: "bookmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(AppTheme.softText)
                }

                if let preview = post.comments.first {
                    CommentPreview(comment: preview)
                } else if !post.caption.isEmpty {
                    Text(post.caption)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.black.opacity(0.32))
        }
        .background(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(.white.opacity(isFocused ? 0.06 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .shadow(color: tint.opacity(isFocused ? 0.18 : 0.08), radius: 20, y: 10)
    }

    private func contentAwareChip(_ title: String, icon: String, emphasized: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(.caption, design: .rounded, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.24), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .glassEffect(
            .regular
                .tint(Color(hex: post.media.primaryHex).opacity(emphasized ? 0.28 : 0.16))
                .interactive(),
            in: .capsule
        )
    }
}

private struct ActionCount: View {
    let icon: String
    let count: Int
    let isActive: Bool

    var body: some View {
        Label("\(count)", systemImage: icon)
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(isActive ? .white : AppTheme.softText)
    }
}

private struct CommentPreview: View {
    let comment: Comment

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(avatar: comment.author.avatar, size: 26)

            if comment.kind == .photo {
                Label(photoPreviewText, systemImage: "camera.fill")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            } else if comment.kind == .gif {
                Label(gifPreviewText, systemImage: "play.rectangle.fill")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
            } else {
                Text(textPreview)
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(1)
            }
        }
    }

    private var textPreview: String {
        if let replyToDisplayName = comment.replyToDisplayName {
            return "\(comment.author.displayName) to \(replyToDisplayName): \(comment.text)"
        }

        return "\(comment.author.displayName): \(comment.text)"
    }

    private var photoPreviewText: String {
        if let replyToDisplayName = comment.replyToDisplayName {
            return "\(comment.author.displayName) replied to \(replyToDisplayName) with a photo"
        }

        return "\(comment.author.displayName) replied with a photo"
    }

    private var gifPreviewText: String {
        if let replyToDisplayName = comment.replyToDisplayName {
            return "\(comment.author.displayName) replied to \(replyToDisplayName) with a GIF"
        }

        return "\(comment.author.displayName) sent a GIF: \(comment.text)"
    }
}

private struct ThreadCommentNode: Identifiable {
    let comment: Comment
    var replies: [ThreadCommentNode]

    var id: UUID { comment.id }
}

private struct CommentThreadSheet: View {
    @Environment(AppStore.self) private var store

    let postID: UUID

    @State private var mode: CommentComposerMode = .text
    @State private var draftText = ""
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var selectedPhotoData: Data?
    @State private var selectedGIF: String?
    @State private var replyTarget: Comment?

    private let gifReplies = [
        "On my way",
        "Need that",
        "Save me a spot",
        "This room"
    ]

    private var currentPost: MomentPost? {
        store.posts.first(where: { $0.id == postID })
    }

    private var comments: [Comment] {
        (currentPost?.comments ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    private var commentNodes: [ThreadCommentNode] {
        let grouped = Dictionary(grouping: comments, by: \.replyToCommentID)

        func buildNodes(parentID: UUID?) -> [ThreadCommentNode] {
            (grouped[parentID] ?? [])
                .sorted { $0.createdAt < $1.createdAt }
                .map { comment in
                    ThreadCommentNode(comment: comment, replies: buildNodes(parentID: comment.id))
                }
        }

        return buildNodes(parentID: nil)
    }

    private var canSend: Bool {
        switch mode {
        case .text:
            !draftText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .photo:
            selectedPhotoData != nil
        case .gif:
            selectedGIF != nil
        }
    }

    private var sendTitle: String {
        switch mode {
        case .text:
            replyTarget == nil ? "Send" : "Reply"
        case .photo:
            "Send Photo"
        case .gif:
            "Send GIF"
        }
    }

    var body: some View {
        ZStack {
            AmbientBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Comments")
                            .font(.system(size: 32, weight: .bold, design: .serif))
                            .foregroundStyle(.white)

                        if let currentPost {
                            Text("See the thread, like comments, and reply to \(currentPost.author.displayName)'s moment.")
                                .font(.system(.subheadline, design: .rounded, weight: .medium))
                                .foregroundStyle(AppTheme.softText)
                        }
                    }

                    if commentNodes.isEmpty {
                        NightPanel(cornerRadius: 30, padding: 16) {
                            Text("No replies yet. Start the thread.")
                                .font(.system(.subheadline, design: .rounded, weight: .medium))
                                .foregroundStyle(AppTheme.softText)
                        }
                    } else {
                        NightPanel(cornerRadius: 30, padding: 16) {
                            VStack(alignment: .leading, spacing: 18) {
                                ForEach(Array(commentNodes.enumerated()), id: \.element.id) { index, node in
                                    CommentThreadNodeView(
                                        node: node,
                                        postID: postID,
                                        depth: 0,
                                        onReply: { comment in
                                            withAnimation(.snappy(duration: 0.2)) {
                                                replyTarget = comment
                                                mode = .text
                                            }
                                        }
                                    )

                                    if index < commentNodes.count - 1 {
                                        Divider()
                                            .overlay(AppTheme.line)
                                    }
                                }
                            }
                        }
                    }

                    NightPanel(cornerRadius: 30, padding: 16) {
                        VStack(alignment: .leading, spacing: 16) {
                            if let replyTarget {
                                HStack(spacing: 10) {
                                    Text("Replying to \(replyTarget.author.displayName)")
                                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                                        .foregroundStyle(.white)

                                    Spacer()

                                    Button {
                                        self.replyTarget = nil
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

                            HStack(spacing: 10) {
                                ForEach(CommentComposerMode.allCases) { composerMode in
                                    Button {
                                        mode = composerMode
                                    } label: {
                                        GlassPill(title: composerMode.title, icon: composerMode.icon, isActive: mode == composerMode)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            composerBody

                            Button(sendTitle) {
                                submitComment()
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 54)
                            .buttonStyle(.glassProminent)
                            .disabled(!canSend)
                            .opacity(canSend ? 1 : 0.6)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
        }
        .onChange(of: selectedPhotoItem) { _, newValue in
            guard let newValue else { return }

            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self) {
                    selectedPhotoData = data
                }
            }
        }
    }

    @ViewBuilder
    private var composerBody: some View {
        switch mode {
        case .text:
            TextEditor(text: $draftText)
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white)
                .tint(AppTheme.warmGold)
                .padding(14)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        case .photo:
            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.white.opacity(0.05))
                    .frame(height: selectedPhotoData == nil ? 160 : 220)
                    .overlay {
                        if let selectedPhotoData, let image = UIImage(data: selectedPhotoData) {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        } else {
                            VStack(spacing: 10) {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 26, weight: .bold))
                                Text("Choose a photo reply")
                                    .font(.system(.headline, design: .rounded, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                        }
                    }
            }
            .buttonStyle(.plain)
        case .gif:
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                ForEach(gifReplies, id: \.self) { gifReply in
                    Button {
                        selectedGIF = gifReply
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("GIF", systemImage: "play.rectangle.fill")
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                            Text(gifReply)
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .multilineTextAlignment(.leading)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(selectedGIF == gifReply ? .white.opacity(0.12) : .white.opacity(0.05))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(selectedGIF == gifReply ? AppTheme.warmGold.opacity(0.6) : AppTheme.line, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func submitComment() {
        switch mode {
        case .text:
            store.addComment(draftText, kind: .text, toPostID: postID, replyingTo: replyTarget)
        case .photo:
            store.addComment("Photo reply", kind: .photo, toPostID: postID, replyingTo: replyTarget)
        case .gif:
            store.addComment(selectedGIF ?? "", kind: .gif, toPostID: postID, replyingTo: replyTarget)
        }

        resetComposer()
    }

    private func resetComposer() {
        draftText = ""
        selectedPhotoItem = nil
        selectedPhotoData = nil
        selectedGIF = nil
        replyTarget = nil
        mode = .text
    }
}

private struct CommentThreadNodeView: View {
    @Environment(AppStore.self) private var store

    let node: ThreadCommentNode
    let postID: UUID
    let depth: Int
    let onReply: (Comment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CommentThreadRow(
                comment: node.comment,
                onLike: {
                    store.toggleCommentLike(commentID: node.comment.id, inPostID: postID)
                },
                onReply: {
                    onReply(node.comment)
                }
            )
            .padding(.leading, CGFloat(depth) * 18)

            if !node.replies.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    Rectangle()
                        .fill(AppTheme.line)
                        .frame(width: 1)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(node.replies.enumerated()), id: \.element.id) { index, reply in
                            CommentThreadNodeView(
                                node: reply,
                                postID: postID,
                                depth: depth + 1,
                                onReply: onReply
                            )

                            if index < node.replies.count - 1 {
                                Divider()
                                    .overlay(AppTheme.line)
                            }
                        }
                    }
                }
                .padding(.leading, CGFloat(depth) * 18 + 23)
            }
        }
    }
}

private struct CommentThreadRow: View {
    let comment: Comment
    let onLike: () -> Void
    let onReply: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AvatarView(avatar: comment.author.avatar, size: 34)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(comment.author.displayName)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)

                    Text(comment.createdAt, style: .relative)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(AppTheme.softText)
                }

                if let replyToDisplayName = comment.replyToDisplayName {
                    Text("Replying to \(replyToDisplayName)")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(AppTheme.warmGold)
                }

                commentBody

                HStack(spacing: 14) {
                    Button(action: onLike) {
                        Label(
                            comment.likeCount == 0 ? "Like" : "\(comment.likeCount)",
                            systemImage: comment.isLikedByViewer ? "heart.fill" : "heart"
                        )
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(comment.isLikedByViewer ? AppTheme.warmGold : AppTheme.softText)
                    }
                    .buttonStyle(.plain)

                    Button("Reply", action: onReply)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(AppTheme.softText)
                        .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var commentBody: some View {
        switch comment.kind {
        case .text:
            Text(comment.text)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
        case .photo:
            Label("Photo reply", systemImage: "camera.fill")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.white.opacity(0.05), in: Capsule())
        case .gif:
            Label("GIF: \(comment.text)", systemImage: "play.rectangle.fill")
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.white.opacity(0.05), in: Capsule())
        }
    }
}

private enum CommentComposerMode: CaseIterable, Identifiable {
    case text
    case photo
    case gif

    var id: Self { self }

    var title: String {
        switch self {
        case .text:
            "Text"
        case .photo:
            "Photo"
        case .gif:
            "GIF"
        }
    }

    var icon: String {
        switch self {
        case .text:
            "text.bubble.fill"
        case .photo:
            "camera.fill"
        case .gif:
            "play.rectangle.fill"
        }
    }
}
