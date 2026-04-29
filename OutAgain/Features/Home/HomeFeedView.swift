import SwiftUI

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

struct HomeFeedView: View {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions
    @State private var activeSheet: ActiveHomeSheet?
    @State private var tonightAuthorTarget: UUID?   // author ID whose tonight posts to show
    @State private var homeTabRefreshTask: Task<Void, Never>?

    private enum ActiveHomeSheet: Identifiable {
        case comments(MomentPost)
        case friendProfile(UserProfile)
        case groupFeed(NightGroup)
        case groupCreation

        var id: String {
            switch self {
            case .comments(let post):
                return "comments-\(post.id.uuidString)"
            case .friendProfile(let profile):
                return "profile-\(profile.id.uuidString)"
            case .groupFeed(let group):
                return "group-\(group.id.uuidString)"
            case .groupCreation:
                return "group-creation"
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Color.clear
                        .frame(height: 0)
                        .id("home-feed-top")

                    TonightActivityStrip(
                        onFriendPostTap: { authorID in
                            tonightAuthorTarget = authorID
                        },
                        onFriendProfileTap: { profile in
                            activeSheet = .friendProfile(profile)
                        },
                        onCreateGroupTap: {
                            activeSheet = .groupCreation
                        },
                        onGroupTap: { group in
                            activeSheet = .groupFeed(group)
                        }
                    )
                    // Strip sits outside the horizontal padding so its ScrollView
                    // bleeds to the screen edge and the last avatar isn't clipped.
                    // feedPosts carries its own padding below.
                    feedPosts
                        .padding(.horizontal, 20)
                }
                .padding(.top, 8)
                .padding(.bottom, 120)
            }
            .refreshable {
                await performManualRefresh()
            }
            .scrollIndicators(.hidden)
            // Paint the warm ambient under the feed so Home reads like
            // Activity does — one visual language across tabs. The
            // shell's AmbientBackground is already below the NavigationStack,
            // but SwiftUI's ScrollView lays down an opaque content
            // background by default on iOS 17+, which masks it. Hiding that
            // default and explicitly applying the ambient here gives a
            // deterministic result regardless of NavigationStack behavior.
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .task {
                permissions.requestLocation()
            }
            .onChange(of: store.homeTabSelectionTrigger) { _, _ in
                proxy.scrollTo("home-feed-top", anchor: .top)

                homeTabRefreshTask?.cancel()
                homeTabRefreshTask = Task {
                    await performManualRefresh()
                }
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
                    CommentThreadSheet(postID: post.id)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                case .friendProfile(let profile):
                    FriendProfileView(profile: profile)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                case .groupFeed(let group):
                    GroupFeedView(group: group)
                        .environment(\.appAccent, store.accentColorChoice.color)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
                case .groupCreation:
                    GroupCreationSheet()
                        .environment(\.appAccent, store.accentColorChoice.color)
                        .presentationDetents([.large])
                        .presentationDragIndicator(.visible)
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
                            if profile.id == store.viewer?.id {
                                store.selectedTab = .profile
                            } else {
                                activeSheet = .friendProfile(profile)
                            }
                        }
                    },
                    onDismiss: { tonightAuthorTarget = nil }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var feedPosts: some View {
        LazyVStack(spacing: 22) {
            ForEach(store.homeFeedPosts) { post in
                MomentPostCard(
                    post: post,
                    isFocused: false,
                    onCommentTap: {
                        activeSheet = .comments(post)
                    },
                    onAuthorTap: { profile in
                        if profile.id == store.viewer?.id {
                            store.selectedTab = .profile
                        } else {
                            activeSheet = .friendProfile(profile)
                        }
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

    private func performManualRefresh() async {
        await store.refreshAppData(silenceErrors: true)
    }
}

// MARK: - Tonight Author Sheet

/// Shows all of a given author's tonight posts in a scrollable feed.
/// The count on the strip pill and the number of cards here are always
/// in sync because both derive from the same store posts array filtered
/// by the same tonightWindow calculation.
private struct TonightAuthorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    let authorID: UUID
    let onCommentTap: (MomentPost) -> Void
    let onAuthorTap: (UserProfile) -> Void
    let onDismiss: () -> Void

    /// All posts by this author within tonight's window, newest first.
    private var tonightPosts: [MomentPost] {
        let window = AppStore.tonightWindow(reference: .now)
        return store.posts
            .filter { $0.author.id == authorID && window.contains($0.createdAt) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var authorName: String {
        tonightPosts.first?.author.displayName
            ?? store.friends.first(where: { $0.id == authorID })?.displayName
            ?? "Tonight"
    }

    /// Drink counts for tonight's window, same source as the post-card pill.
    private var drinkCounts: [(drink: DrinkTag, count: Int)] {
        store.nightlyDrinkCounts(for: authorID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !drinkCounts.isEmpty {
                        drinkSummaryHeader
                    }

                    if tonightPosts.isEmpty {
                        // Defensive fallback — shouldn't normally show
                        // because the strip only routes here when count > 0.
                        EmptyStateCard(
                            title: "No posts yet tonight",
                            detail: "Posts from this friend will appear here once they go out.",
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
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground())
            .navigationTitle(authorName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accent)
                }
            }
        }
    }

    /// Horizontal pill row summarising every drink tagged tonight,
    /// with a count badge when more than one of the same drink appears.
    private var drinkSummaryHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tonight's drinks")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(1.1)
                .textCase(.uppercase)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(drinkCounts, id: \.drink.id) { entry in
                        HStack(spacing: 6) {
                            DrinkIconView(drink: entry.drink, size: 22)

                            Text(entry.count > 1
                                 ? "\(entry.count) \(pluralized(entry.drink.name))"
                                 : entry.drink.name)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.white.opacity(0.08), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    }
                }
            }
        }
    }

    private func pluralized(_ name: String) -> String {
        name.lowercased().hasSuffix("s") ? name : "\(name)s"
    }
}
