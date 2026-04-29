import SwiftUI

/// Read-only profile surface for a user other than the viewer. Reached by
/// tapping an author's avatar or name on a post, or by tapping a reactor
/// in the long-press Likes sheet. Deliberately mirrors the structure of
/// `ProfileView` (avatar, name, counters, Moments grid, Stats toggle) so
/// the mental model is identical between "me" and "them" — the only
/// differences are the removal of affordances the viewer can't act on:
/// no Edit Profile button, no gear / Settings destination, no delete on
/// individual posts (that's enforced by the card itself via RLS).
struct FriendProfileView: View {
    enum PresentationStyle {
        case sheet
        case embedded
    }

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent

    let profile: UserProfile
    var presentationStyle: PresentationStyle = .sheet

    @State private var selectedSection: ProfileView.ProfileSection = .moments
    @State private var detailPost: MomentPost?
    @State private var friendCount: Int?
    @State private var profileFriends: [UserProfile] = []
    @State private var isLoadingProfileFriends = false
    @State private var didLoadProfileFriends = false
    @State private var isFriendsListPresented = false
    @State private var selectedFriendInGraph: UserProfile?
    @State private var profilePosts: [MomentPost] = []
    @State private var isLoadingPosts = false
    @State private var didLoadPosts = false
    @State private var isConfirmingBlock = false
    @State private var isConfirmingUnblock = false

    private var postsByFriend: [MomentPost] {
        guard !store.blockedUserIDs.contains(profile.id) else { return [] }
        // Prefer the async-loaded list once available; otherwise fall back
        // to what's already in the bootstrap (covers friends).
        if didLoadPosts { return profilePosts }
        return store.sortPostsByRecency(
            store.posts.filter { $0.author.id == profile.id }
        )
    }

    private var taggedPosts: [MomentPost] {
        guard !store.blockedUserIDs.contains(profile.id) else { return [] }
        // Posts where this profile appears as a tagged friend.
        let fromStore = store.posts.filter { $0.taggedFriends.contains(where: { $0.id == profile.id }) }
        let fromLoaded = profilePosts.filter { $0.taggedFriends.contains(where: { $0.id == profile.id }) }
        // Union, de-duplicated.
        var seen = Set<UUID>()
        return (fromStore + fromLoaded)
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var showsTopChrome: Bool {
        presentationStyle == .sheet
    }

    private var isBlockedByViewer: Bool {
        store.blockedUserIDs.contains(profile.id)
    }

    var body: some View {
        Group {
            if presentationStyle == .sheet {
                NavigationStack {
                    content
                }
            } else {
                content
            }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                profileHeader
                sectionToggle

                switch selectedSection {
                case .moments:
                    momentsContent
                case .tagged:
                    taggedContent
                case .stats:
                    statsContent
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 60)
        }
        .scrollIndicators(.hidden)
        .background(AmbientBackground())
        .navigationTitle(showsTopChrome ? "@\(profile.username)" : "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsTopChrome {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accent)
                }
            }
        }
        .sheet(item: $detailPost) { post in
            PostDetailWithComments(post: post, accent: accent)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isFriendsListPresented) {
            friendsListSheet
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task(id: profile.id) {
            async let friendsLoad: Void = loadProfileFriends()
            async let postsLoad: Void = loadProfilePosts()
            _ = await (friendsLoad, postsLoad)
        }
        .onChange(of: isBlockedByViewer) { _, isBlocked in
            if isBlocked {
                profileFriends = []
                friendCount = 0
                profilePosts = []
                didLoadProfileFriends = true
                didLoadPosts = true
                return
            }

            Task {
                async let friendsLoad: Void = loadProfileFriends()
                async let postsLoad: Void = loadProfilePosts()
                _ = await (friendsLoad, postsLoad)
            }
        }
        .confirmationDialog(
            "Block \(profile.displayName)?",
            isPresented: $isConfirmingBlock,
            titleVisibility: .visible
        ) {
            Button("Block User", role: .destructive) {
                store.blockUser(profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes them from your friends, hides their activity, and prevents new friend interactions.")
        }
        .confirmationDialog(
            "Unblock \(profile.displayName)?",
            isPresented: $isConfirmingUnblock,
            titleVisibility: .visible
        ) {
            Button("Unblock User") {
                store.unblockUser(profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They can appear again in search, profiles, and friend flows after your next refresh.")
        }
    }

    // MARK: - Header

    /// Friendship state for the profile being viewed — same logic as
    /// `graphAction(for:)` used in the friends-list sheet, applied to the
    /// top-level profile so we can surface an Add/Accept/Requested button
    /// directly in the header.
    private var profileFriendshipAction: FriendGraphAction {
        graphAction(for: profile)
    }

    private var profileHeader: some View {
        VStack(spacing: 16) {
            TonightAvatarView(avatar: profile.avatar, userID: profile.id, size: 124)

            VStack(spacing: 5) {
                Text(profile.displayName)
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text("@\(profile.username)")
                    .font(.system(.headline, design: .rounded, weight: .medium))
                    .foregroundStyle(AppTheme.softText)
            }

            HStack(spacing: 20) {
                Button {
                    isFriendsListPresented = true
                } label: {
                    counterColumn(value: friendCountText, label: "Friends")
                }
                .buttonStyle(.plain)
                counterColumn(value: postsByFriend.count, label: "Posts")
                counterColumn(value: taggedPosts.count, label: "Tagged")
            }
            .padding(.top, 4)

            // Friendship action button — only shown for users other than
            // the viewer. Active states (Add Friend, Accept Request) render
            // in the viewer's accent color so they're visually prominent.
            // Passive states (Friends, Requested, Blocked) render as soft
            // status chips to communicate the relationship without competing
            // with the active affordances.
            if case .button(let title, let symbol) = profileFriendshipAction {
                Button {
                    handleGraphAction(for: profile)
                } label: {
                    Label(title, systemImage: symbol)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(accent, in: Capsule())
                        .overlay(Capsule().strokeBorder(accent.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.top, 2)
            } else if case .status(let label) = profileFriendshipAction, label != "You" {
                Text(label)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(AppTheme.softText)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(.white.opacity(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .padding(.horizontal, 20)
                    .padding(.top, 2)
            }

            if profile.id != store.viewer?.id {
                moderationButton
                    .padding(.horizontal, 20)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
    }

    private var moderationButton: some View {
        let tint = isBlockedByViewer ? accent.opacity(0.18) : AppTheme.rose.opacity(0.42)
        let foreground = isBlockedByViewer ? accent : Color(hex: "#F2B0A7")

        return Button {
            if isBlockedByViewer {
                isConfirmingUnblock = true
            } else {
                isConfirmingBlock = true
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isBlockedByViewer ? "hand.raised.slash.fill" : "hand.raised.fill")
                    .font(.system(size: 14, weight: .bold))
                Text(isBlockedByViewer ? "Unblock User" : "Block User")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .glassEffect(.regular.tint(tint).interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func counterColumn(value: Int, label: String) -> some View {
        counterColumn(value: "\(value)", label: label)
    }

    private func counterColumn(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(AppTheme.softText)
        }
        .frame(minWidth: 72)
    }

    private var friendCountText: String {
        guard let friendCount else { return "—" }
        return "\(friendCount)"
    }

    private var friendsListSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("\(profile.displayName)'s friends")
                        .font(.system(size: 30, weight: .bold, design: .serif))
                        .foregroundStyle(.white)

                    if isLoadingProfileFriends && profileFriends.isEmpty {
                        NightPanel(cornerRadius: 28, padding: 16) {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .tint(accent)
                                Text("Loading friends")
                                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                                    .foregroundStyle(AppTheme.softText)
                            }
                        }
                    } else if profileFriends.isEmpty {
                        EmptyStateCard(
                            title: "No friends to show",
                            detail: "\(profile.displayName)'s circle will show up here once it grows.",
                            symbol: "person.2.fill"
                        )
                    } else {
                        NightPanel(cornerRadius: 28, padding: 12) {
                            VStack(spacing: 8) {
                                ForEach(profileFriends) { friend in
                                    let isSelf = friend.id == store.viewer?.id
                                    FriendGraphRow(
                                        profile: friend,
                                        action: graphAction(for: friend),
                                        onAction: {
                                            handleGraphAction(for: friend)
                                        },
                                        onRowTap: isSelf ? nil : {
                                            selectedFriendInGraph = friend
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isFriendsListPresented = false }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accent)
                }
            }
            .sheet(item: $selectedFriendInGraph) { friend in
                FriendProfileView(profile: friend)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private func loadProfileFriends() async {
        guard !isBlockedByViewer else {
            profileFriends = []
            friendCount = 0
            didLoadProfileFriends = true
            isLoadingProfileFriends = false
            return
        }

        isLoadingProfileFriends = true
        let loadedFriends = await store.loadFriends(of: profile)
        profileFriends = loadedFriends
        friendCount = loadedFriends.count
        didLoadProfileFriends = true
        isLoadingProfileFriends = false
    }

    private func loadProfilePosts() async {
        guard !isBlockedByViewer else {
            profilePosts = []
            didLoadPosts = true
            isLoadingPosts = false
            return
        }

        isLoadingPosts = true
        let result = await store.loadUserPosts(for: profile)
        profilePosts = result.posts
        didLoadPosts = result.didLoadAuthoritatively
        isLoadingPosts = false
    }

    private func graphAction(for candidate: UserProfile) -> FriendGraphAction {
        if candidate.id == store.viewer?.id {
            return .status("You")
        }

        if store.friends.contains(where: { $0.id == candidate.id }) {
            return .status("Friends")
        }

        if store.outgoingFriendRequests.contains(where: { $0.counterpart.id == candidate.id }) {
            return .status("Requested")
        }

        if store.incomingFriendRequests.contains(where: { $0.counterpart.id == candidate.id }) {
            return .button(title: "Accept", symbol: "checkmark.seal.fill")
        }

        if store.blockedUserIDs.contains(candidate.id) {
            return .status("Blocked")
        }

        return .button(title: "Add", symbol: "person.badge.plus")
    }

    private func handleGraphAction(for candidate: UserProfile) {
        if let incoming = store.incomingFriendRequests.first(where: { $0.counterpart.id == candidate.id }) {
            withAnimation(.snappy(duration: 0.24)) {
                store.acceptIncomingRequest(incoming)
            }
        } else {
            withAnimation(.snappy(duration: 0.24)) {
                store.sendFriendRequest(to: candidate)
            }
        }
    }

    // MARK: - Segmented control

    @Namespace private var friendProfileSectionNamespace

    private var sectionToggle: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 6) {
                segmentButton(title: "Posts", symbol: "square.grid.3x3.fill", section: .moments)
                segmentButton(title: "Tagged", symbol: "person.crop.rectangle.fill", section: .tagged)
                segmentButton(title: "Stats", symbol: "chart.bar.fill", section: .stats)
            }
            .padding(6)
            .background(.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .glassEffect(.regular, in: .capsule)
        }
    }

    private func segmentButton(title: String, symbol: String, section: ProfileView.ProfileSection) -> some View {
        let isSelected = selectedSection == section
        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                selectedSection = section
            }
        } label: {
            ZStack {
                if isSelected {
                    Capsule()
                        .fill(.white.opacity(0.11))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .matchedGeometryEffect(id: "friend_profile_section", in: friendProfileSectionNamespace)
                }
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .bold))
                    Text(title)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                }
                .foregroundStyle(isSelected ? .white : AppTheme.softText)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Moments grid

    @ViewBuilder
    private var momentsContent: some View {
        if isLoadingPosts && postsByFriend.isEmpty {
            ProgressView()
                .tint(accent)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else if postsByFriend.isEmpty {
            Text("No posts yet")
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(AppTheme.softText)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 32)
        } else {
            // Mirrors ProfileView's grid exactly — same columns, same
            // thumbnail contract. The previous bug (first cell rendering
            // as a full-screen strip inside the sheet) was caused by the
            // thumbnail resolving its aspectRatio against a zero-width
            // first pass; the thumbnail now ships with an explicit
            // square frame via the parent-supplied size, so this grid
            // can stay minimal.
            let columns = [
                GridItem(.flexible(), spacing: 4),
                GridItem(.flexible(), spacing: 4),
                GridItem(.flexible(), spacing: 4)
            ]

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(postsByFriend) { post in
                    Button {
                        detailPost = post
                    } label: {
                        FriendMomentGridThumbnail(media: post.media)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Tagged grid

    @ViewBuilder
    private var taggedContent: some View {
        if taggedPosts.isEmpty {
            Text("No tagged posts yet")
                .font(.system(.subheadline, design: .rounded, weight: .medium))
                .foregroundStyle(AppTheme.softText)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 32)
        } else {
            let columns = [
                GridItem(.flexible(), spacing: 4),
                GridItem(.flexible(), spacing: 4),
                GridItem(.flexible(), spacing: 4)
            ]

            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(taggedPosts) { post in
                    Button {
                        detailPost = post
                    } label: {
                        FriendMomentGridThumbnail(media: post.media)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Stats

    private var statsContent: some View {
        let posts = postsByFriend
        let favoriteDrink = store.mostFrequentDrink(in: posts)
        let commonVenue = store.mostFrequentVenue(in: posts)
        let touchpoints = posts.reduce(0) { partial, post in
            partial + post.reactions.reduce(0) { $0 + $1.count } + post.commentCount
        }
        let nightsActive = Set(posts.map { Calendar.current.startOfDay(for: $0.createdAt) }).count

        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                compactStat(
                    label: "Favorite drink",
                    value: favoriteDrink?.name ?? "—"
                )
                compactStat(
                    label: "Common place",
                    value: commonVenue?.name ?? "—"
                )
            }
            HStack(spacing: 12) {
                compactStat(
                    label: "Nights active",
                    value: "\(nightsActive)"
                )
                compactStat(
                    label: "Touchpoints",
                    value: "\(touchpoints)"
                )
            }
        }
    }

    private func compactStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(.caption2, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(1.2)
            Text(value)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

private enum FriendGraphAction: Equatable {
    case button(title: String, symbol: String)
    case status(String)
}

private struct FriendGraphRow: View {
    let profile: UserProfile
    let action: FriendGraphAction
    let onAction: () -> Void
    var onRowTap: (() -> Void)? = nil

    var body: some View {
        let row = HStack(spacing: 14) {
            AvatarView(avatar: profile.avatar, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("@\(profile.username)")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            switch action {
            case .button(let title, let symbol):
                Button(action: onAction) {
                    Label(title, systemImage: symbol)
                        .font(.system(.footnote, design: .rounded, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.glass)
            case .status(let title):
                Text(title)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(AppTheme.softText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.05), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)

        if let onRowTap {
            Button(action: onRowTap) {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            row
        }
    }
}

/// Duplicate of `MomentGridThumbnail` in ProfileView but lifted out so
/// FriendProfileView can render without reaching into a private type.
/// Small duplication cost for cleaner module boundaries; if we end up
/// with a third grid-thumbnail consumer we promote this to a shared
/// component.
private struct FriendMomentGridThumbnail: View {
    let media: MomentMedia

    var body: some View {
        // Idiomatic SwiftUI pattern for a square grid cell: a clear
        // aspect-1 placeholder establishes the cell's size from the
        // grid column width, and the image overlays on top using
        // scaledToFill + clipped. This avoids the collapse-to-strip
        // bug we hit by putting aspectRatio on the image itself: when
        // the image reports zero intrinsic width on first layout the
        // aspect ratio has nothing to compute against, and the frame
        // falls back to whatever maxHeight the container advertises
        // (i.e. the whole sheet). With the Color.clear spacer, the
        // grid column always has a concrete width first, so the
        // aspect math is deterministic.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    if let data = media.photoData, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else if let remotePhotoURL = media.remotePhotoURL {
                        AsyncImage(url: remotePhotoURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            default:
                                placeholder
                            }
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

/// Post detail sheet that owns its own comment-sheet state so that
/// tapping "Comment" opens the thread *on top of* this sheet rather
/// than requiring a dismiss-then-reopen two-step. The comment sheet
/// is a standard `.sheet` presentation anchored to the NavigationStack
/// inside this view, which iOS stacks correctly on top of the existing
/// presentation.
private struct PostDetailWithComments: View {
    @Environment(AppStore.self) private var store

    let post: MomentPost
    let accent: Color

    @State private var commentSheetPostID: UUID?

    var body: some View {
        NavigationStack {
            ScrollView {
                MomentPostCard(
                    post: post,
                    isFocused: true,
                    onCommentTap: {
                        commentSheetPostID = post.id
                    }
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // This Done closes the comment sub-sheet if open;
                    // the parent FriendProfileView sheet is dismissed
                    // via the drag indicator or system back gesture.
                    EmptyView()
                }
            }
            .sheet(item: $commentSheetPostID) { postID in
                CommentThreadSheet(postID: postID)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}
