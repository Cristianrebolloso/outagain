import SwiftUI

/// Notification context lives wholly in the left pane; the continuing list
/// retains its position and proportions on the right.
struct ActivityCompanionDetail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.duoPageContentWidth) private var paneContentWidth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var postTransition
    let notification: AppNotification
    @State private var showsComments: Bool
    @State private var isLoading = false
    @State private var selectedProfile: UserProfile?

    init(notification: AppNotification) {
        self.notification = notification
        _showsComments = State(initialValue: Self.opensComments(notification.kind))
    }

    private static func opensComments(_ kind: NotificationKind) -> Bool {
        switch kind {
        case .comment, .photoReply, .commentLike, .commentTagged: true
        default: false
        }
    }

    private var profileTarget: UserProfile? {
        switch notification.kind {
        case .friendRequest, .friendAccepted, .profileVerified: notification.actor
        default: notification.postID == nil ? notification.actor : nil
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if notification.kind == .announcement {
                    AnnouncementNotificationContent(notification: notification)
                } else if let profile = profileTarget {
                    FriendProfileView(profile: profile, presentationStyle: .embedded, showsBackButton: false)
                } else if let postID = notification.postID {
                    postDetail(postID)
                } else {
                    ContentUnavailableView(
                        notification.headline, systemImage: notification.kind.symbol
                    )
                }
            }
            // This pane has no navigation rail. Use its full width rather
            // than reserving another system toolbar beside the comments.
            .ignoresSafeArea(.container, edges: .horizontal)
            .navigationDestination(item: $selectedProfile) { profile in
                FriendProfileView(profile: profile, presentationStyle: .embedded)
            }
            .containerBackground(.clear, for: .navigation)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .accessibilityIdentifier("activity.companion")
    }

    private func setCommentsPresented(_ presented: Bool) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.24, extraBounce: 0)) {
            showsComments = presented
        }
    }

    @ViewBuilder
    private func postDetail(_ postID: UUID) -> some View {
        Group {
            if let post = store.livePost(matching: postID), !store.locallyDeletedPostIDs.contains(postID) {
                ZStack(alignment: .topLeading) {
                    if showsComments {
                        VStack(spacing: 0) {
                            Button {
                                setCommentsPresented(false)
                            } label: {
                                HStack(spacing: 12) {
                                    MomentMediaView(media: post.media, height: 80)
                                        .frame(width: 64, height: 80)
                                        .clipped()
                                        .clipShape(.rect(cornerRadius: 12))
                                        .modifier(ActivityPostMorph(namespace: postTransition, postID: post.id, element: .photo))
                                    VStack(alignment: .leading, spacing: 5) {
                                        VerifiedProfileLabel(profile: post.author, spacing: 4, badgeSize: 12) {
                                            Text(post.author.displayName)
                                                .font(AppTypography.rowTitle)
                                                .lineLimit(1)
                                        }
                                        .modifier(ActivityPostMorph(namespace: postTransition, postID: post.id, element: .author))
                                        Text(post.caption).font(AppTypography.rowSubtitle).lineLimit(2)
                                        Label("View post", systemImage: "arrow.up.left.and.arrow.down.right")
                                            .font(AppTypography.actionLabel)
                                            .foregroundStyle(.white)
                                            .padding(.horizontal, 16)
                                            .frame(minHeight: 44)
                                            .primaryGlass(in: .capsule, interactive: true)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(.white)
                                .padding(16)
                            }
                            .buttonStyle(.plain)
                            .tint(.white)
                            .accessibilityIdentifier("activity.comments.viewPost")
                            CommentThreadSheet(
                                postID: postID, highlightedCommentID: notification.commentID,
                                initialPost: post, isEmbedded: true
                            )
                        }
                        .transition(.opacity)
                    } else {
                        ScrollView {
                            MomentPostCard(
                                post: post, isFocused: true,
                                onCommentTap: { setCommentsPresented(true) },
                                onAuthorTap: { selectedProfile = $0 },
                                detailTransition: postTransition
                            )
                            // Match the live page width, including its native rail.
                            .modifier(PostDetailColumn(
                                maximumWidth: paneContentWidth ?? AppLayout.phoneColumnMaximumWidth
                            ))
                            .padding(.top, 12)
                            .padding(.bottom, 24)
                        }
                        .scrollIndicators(.hidden)
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if isLoading {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DuoCompanionPlaceholder(
                    title: "Post unavailable", subtitle: "This post may have been removed.", symbol: "photo")
            }
        }
        .task(id: notification.id) {
            guard !store.isLayoutPreview, !store.locallyDeletedPostIDs.contains(postID) else { return }
            isLoading = true
            await store.refreshPostFromNotification(postID: postID, commentID: notification.commentID)
            isLoading = false
        }
    }
}

struct AnnouncementNotificationContent: View {
    let notification: AppNotification

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(notification.headline)
                    .font(AppTypography.sheetTitle)
                    .foregroundStyle(.white)
                if !notification.detail.isEmpty {
                    Text(notification.detail)
                        .font(AppTypography.body)
                        .foregroundStyle(AppTheme.softText)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppLayout.screenPadding)
        }
    }
}

struct AnnouncementNotificationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let notification: AppNotification

    var body: some View {
        NavigationStack {
            AnnouncementNotificationContent(notification: notification)
                .background(AmbientBackground())
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.large])
        .appSheetDragHandle()
    }
}
