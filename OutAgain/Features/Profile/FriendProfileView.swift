import SwiftUI
import UIKit

/// Read-only profile surface for a user other than the viewer. Reached by
/// tapping an author's avatar or name on a post, or by tapping a reactor
/// in the long-press Likes sheet. Deliberately mirrors the structure of
/// `ProfileView` (avatar, name, counters, Moments grid, Stats toggle) so
/// the mental model is identical between "me" and "them" — the only
/// differences are the removal of affordances the viewer can't act on:
/// no Edit Profile button, no gear / Settings destination, no delete on
/// individual posts (that's enforced by the card itself via RLS).
struct FriendProfileView: View {
    private static let paginationPrefetchThreshold = 6

    enum PresentationStyle {
        case sheet
        case embedded
    }

    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    @Environment(\.profileSceneThemes) private var sceneThemes

    let profile: UserProfile
    var presentationStyle: PresentationStyle = .sheet
    var showsBackButton = true
    var onBack: (() -> Void)? = nil

    @State private var profileGridWidth: CGFloat = 360
    @State private var selectedSection: ProfileView.ProfileSection = .moments
    @State private var detailPost: MomentPost?
    @State private var friendCount: Int?
    @State private var profileFriends: [UserProfile] = []
    @State private var isLoadingProfileFriends = false
    @State private var didLoadProfileFriends = false
    @State private var isFriendsListPresented = false
    @State private var profileFriendsSearchQuery = ""
    @State private var selectedFriendInGraph: UserProfile?
    @State private var shouldNavigateToOwnProfile = false
    @State private var profilePosts: [MomentPost] = []
    @State private var profilePostCount: Int?
    @State private var hasMoreProfilePosts = true
    @State private var nextProfilePageBefore: Date?
    @State private var isLoadingPosts = false
    @State private var didLoadPosts = false

    // Tagged section state
    @State private var taggedPostsList: [MomentPost] = []
    @State private var hasMoreTaggedPosts = true
    @State private var nextTaggedPageBefore: Date?
    @State private var isLoadingTaggedPosts = false
    @State private var didLoadTaggedPosts = false

    @State private var profileStats: ProfileStats?
    @State private var isLoadingProfileStats = false
    @State private var didLoadProfileStats = false
    @State private var profileFriendRank: ProfileFriendRank?
    @State private var profileFriendNightsOut: [Int] = []
    @State private var isLoadingProfileFriendRankStats = false
    @State private var didLoadProfileFriendRankStats = false

    @State private var fetchedBackgroundTheme: BackgroundTheme?
    @State private var didLoadBackgroundTheme = false
    @State private var isConfirmingRemoveFriend = false
    @State private var isConfirmingBlock = false
    @State private var isConfirmingUnblock = false
    @State private var isConfirmingReport = false
    @State private var isConfirmingAdminBan = false
    @State private var isConfirmingAdminContentDelete = false

    private var postsByFriend: [MomentPost] {
        guard !isBlockedByViewer else { return [] }
        return profilePosts
    }

    private var displayedPostCount: Int {
        profilePostCount ?? postsByFriend.count
    }

    private var isBlockedByViewer: Bool {
        guard !store.isViewerAdmin else { return false }
        return store.blockedUserIDs.contains(profile.id)
    }

    private var isFriendOfViewer: Bool {
        store.friends.contains(where: { $0.id == profile.id })
    }

    private var unlocksPrivateProfileContent: Bool {
        store.canViewPrivateProfileContent(of: profile)
    }

    private var showsProfileActions: Bool {
        profile.id != store.viewer?.id
    }

    private var freshestProfile: UserProfile {
        if profile.id == store.viewer?.id {
            return store.viewerIdentity
        }

        let candidates: [UserProfile] =
            store.friends
            + store.suggestedFriends
            + store.blockedUsers
            + store.incomingFriendRequests.map(\.counterpart)
            + store.outgoingFriendRequests.map(\.counterpart)
            + store.adminAllUsers
            + store.posts.flatMap { [$0.author] + $0.taggedFriends }
            + profilePosts.map(\.author)
            + taggedPostsList.map(\.author)

        return candidates.first(where: { $0.id == profile.id }) ?? profile
    }

    private var displayedProfile: UserProfile {
        var resolvedProfile = freshestProfile
        if resolvedProfile.backgroundTheme == nil {
            resolvedProfile.backgroundTheme = fetchedBackgroundTheme
        }
        return resolvedProfile
    }

    private var profileBackgroundTheme: BackgroundTheme {
        if profile.id == store.viewer?.id {
            return store.backgroundTheme
        }

        // Use a cached theme immediately. If it is unknown, keep the viewer's
        // palette until the independent theme request resolves.
        return fetchedBackgroundTheme ?? displayedProfile.backgroundTheme
            ?? (didLoadBackgroundTheme ? .standard : store.backgroundTheme)
    }

    private var removeFriendConfirmationTitle: String {
        "Remove \(profile.displayName) as a friend?"
    }

    private var blockConfirmationTitle: String {
        "Block \(profile.displayName)?"
    }

    private var unblockConfirmationTitle: String {
        "Unblock \(profile.displayName)?"
    }

    private var reportConfirmationTitle: String {
        "Report \(profile.displayName)?"
    }

    private var adminBanConfirmationTitle: String {
        freshestProfile.isBanned
            ? "Unban @\(freshestProfile.username)?"
            : "Ban @\(freshestProfile.username)?"
    }

    private var adminContentDeleteConfirmationTitle: String {
        "Delete all content for @\(freshestProfile.username)?"
    }

    var body: some View {
        Group {
            if presentationStyle == .sheet {
                NavigationStack {
                    profileRoot
                }
            } else {
                profileRoot
            }
        }
        .modifier(ProfileSceneThemeSource(theme: profileBackgroundTheme))
    }

    @ViewBuilder
    private var profileRoot: some View {
        content
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                profileHeader

                if unlocksPrivateProfileContent {
                    sectionToggle

                    switch selectedSection {
                    case .moments:
                        momentsContent
                    case .tagged:
                        taggedContent
                    case .stats:
                        statsContent
                    }
                } else {
                    lockedProfileContent
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .padding(.bottom, 60)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            profileGridWidth = max(0, width - 40)
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .background {
            // Embedded Duo profiles reveal the one full-window backdrop,
            // including the neighboring feed/search pane and navigation rail.
            if !store.isDuoDevice || presentationStyle == .sheet || sceneThemes == nil {
                AmbientBackground(overrideTheme: profileBackgroundTheme)
                    .ignoresSafeArea()
            }
        }
        .containerBackground(.clear, for: .navigation)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar(store.isDuoDevice ? .visible : .hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(!store.isDuoDevice || !showsBackButton || onBack != nil)
        .background(SwipeBackEnabler())
        .overlay(alignment: .topLeading) {
            if showsBackButton && !store.isDuoDevice {
                profileBackButton
                    .padding(.top, 8)
                    .padding(.leading, 24)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsProfileActions && !store.isDuoDevice {
                profileActionsMenu
                    .padding(.top, 8)
                    .padding(.trailing, 24)
            }
        }
        .toolbar {
            if store.isDuoDevice {
                if showsBackButton && (onBack != nil || presentationStyle == .sheet) {
                    ToolbarItem(placement: .cancellationAction) { duoProfileBackButton }
                }
                if showsProfileActions {
                    ToolbarItem(placement: .topBarTrailing) { profileActionsMenu }
                }
            }
        }
        .sheet(item: $detailPost) { post in
            PostDetailWithComments(post: post)
                .modifier(ProfileSceneThemeSource(theme: profileBackgroundTheme))
                .modifier(PostDetailPresentation())
                .presentationDetents([.large])
                .appSheetDragHandle(contentWidth: PostDetailPresentation.sheetWidth)
        }
        .navigationDestination(isPresented: $isFriendsListPresented) {
            friendsListPage
                .modifier(ProfileSceneThemeSource(theme: profileBackgroundTheme))
                .task {
                    if profileFriends.isEmpty {
                        await loadProfileFriends()
                    }
                }
        }
        .task(id: profile.id) {
            await loadProfileData()
        }
        .task(id: profile.id) {
            guard !store.isLayoutPreview, !isBlockedByViewer else { return }
            let theme = await store.loadBackgroundTheme(for: profile.id)
            guard !Task.isCancelled else { return }
            fetchedBackgroundTheme = theme
            didLoadBackgroundTheme = true
        }
        .onChange(of: shouldNavigateToOwnProfile) { _, navigate in
            guard navigate else { return }
            // Pop the friends list push, dismiss the FriendProfileView sheet,
            // and land on the real Profile tab — all as one seamless action.
            @Bindable var store = store
            store.selectedTab = .profile
            dismiss()
        }
        .onChange(of: isBlockedByViewer) { _, isBlocked in
            if isBlocked {
                profileFriends = []
                friendCount = 0
                resetLockedProfileContent()
                didLoadProfileFriends = true
                return
            }

            Task {
                await loadProfileData()
            }
        }
        .onChange(of: isFriendOfViewer) { _, _ in
            Task {
                await loadProfileData()
            }
        }
        .onChange(of: store.locallyDeletedPostIDs) { _, deletedPostIDs in
            removeDeletedPosts(deletedPostIDs)
        }
        .alert(
            removeFriendConfirmationTitle,
            isPresented: $isConfirmingRemoveFriend,
            actions: {
            Button("Remove Friend", role: .destructive) {
                store.unfriend(profile)
            }
            Button("Cancel", role: .cancel) {}
                .tint(.blue)
        }, message: {
            Text("They'll be removed from your friends list, but you can still find their profile again later.")
        })
        .alert(
            blockConfirmationTitle,
            isPresented: $isConfirmingBlock,
            actions: {
            Button("Block User", role: .destructive) {
                store.blockUser(profile)
            }
            Button("Cancel", role: .cancel) {}
                .tint(.blue)
        }, message: {
            Text("This removes them from your friends, hides their activity, and prevents new friend interactions.")
        })
        .alert(
            unblockConfirmationTitle,
            isPresented: $isConfirmingUnblock,
            actions: {
            Button("Unblock User") {
                store.unblockUser(profile)
            }
            Button("Cancel", role: .cancel) {}
                .tint(.blue)
        }, message: {
            Text("They can appear again in search, profiles, and friend flows after your next refresh.")
        })
        .alert(
            reportConfirmationTitle,
            isPresented: $isConfirmingReport,
            actions: {
            Button("Report User", role: .destructive) {
                store.reportUser(profile)
            }
            Button("Cancel", role: .cancel) {}
                .tint(.blue)
        }, message: {
            Text("We'll review this account. Reporting is anonymous.")
        })
        .alert(
            adminBanConfirmationTitle,
            isPresented: $isConfirmingAdminBan,
            actions: {
            if freshestProfile.isBanned {
                Button("Unban User") {
                    store.setUserBanned(false, for: freshestProfile)
                }
            } else {
                Button("Ban User", role: .destructive) {
                    store.setUserBanned(true, for: freshestProfile)
                }
            }
            Button("Cancel", role: .cancel) {}
                .tint(.blue)
        })
        .alert(
            adminContentDeleteConfirmationTitle,
            isPresented: $isConfirmingAdminContentDelete,
            actions: {
            Button("Delete Content", role: .destructive) {
                store.deleteUserContent(freshestProfile)
            }
            Button("Cancel", role: .cancel) {}
                .tint(.blue)
        }, message: {
            Text("Removes posts, comments, reactions, groups, notifications, and reports.")
        })
    }

    // MARK: - Header

    private var friendsCounterLabel: String {
        profile.normalizedUsername == "landon" ? "Body Count" : "Friends"
    }

    private var profileHeader: some View {
        SharedProfileHeader(
            profile: displayedProfile,
            friendsValue: friendCountText,
            friendsLabel: friendsCounterLabel,
            postsValue: postCountText,
            onFriendsTap: profileFriendsTapAction,
            showsAction: showsProfileRelationshipControl,
            topPadding: 64
        ) {
            profileRelationshipControl
        }
    }

    private var profileFriendsTapAction: (() -> Void)? {
        guard hasBrowsableFriendsList else { return nil }
        return { openProfileFriendsList() }
    }

    private func openProfileFriendsList() {
        profileFriendsSearchQuery = ""
        isFriendsListPresented = true
    }

    private var showsProfileRelationshipControl: Bool {
        switch graphAction(for: profile) {
        case .button:
            return true
        case .status(let title):
            return title != "Friends" && title != "You"
        }
    }

    private var profileBackButton: some View {
        Button {
            if let onBack { onBack() } else { dismiss() }
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .primaryGlass(in: .circle, interactive: true)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .contentShape(Circle())
        .accessibilityLabel("Back")
        .accessibilityIdentifier("profile.back")
    }

    private var duoProfileBackButton: some View {
        duoBackButton {
            if let onBack { onBack() } else { dismiss() }
        }
    }

    private func duoBackButton(action: @escaping () -> Void) -> some View {
        Button("Back", systemImage: "chevron.left", action: action)
            .accessibilityIdentifier("profile.back")
    }

    private var profileActionsMenu: some View {
        Menu {
            if store.isViewerAdmin {
                let isVerified = freshestProfile.isVerified
                Button {
                    store.setVerified(!isVerified, for: profile)
                } label: {
                    Label(
                        isVerified ? "Remove Verified Badge" : "Mark as Verified",
                        systemImage: isVerified ? "checkmark.seal.fill" : "checkmark.seal"
                    )
                }

                if store.canAdminModerate(freshestProfile) {
                    if freshestProfile.isBanned {
                        Button {
                            isConfirmingAdminBan = true
                        } label: {
                            Label("Unban User", systemImage: "checkmark.shield.fill")
                        }
                    } else {
                        Button(role: .destructive) {
                            isConfirmingAdminBan = true
                        } label: {
                            Label("Ban User", systemImage: "hand.raised.fill")
                        }
                    }

                    Button(role: .destructive) {
                        isConfirmingAdminContentDelete = true
                    } label: {
                        Label("Delete All Content", systemImage: "trash.fill")
                    }
                }

                Divider()
            }

            if isFriendOfViewer && !isBlockedByViewer {
                Button(role: .destructive) {
                    isConfirmingRemoveFriend = true
                } label: {
                    Label("Remove Friend", systemImage: "person.badge.minus")
                }
            }

            if isBlockedByViewer {
                Button {
                    isConfirmingUnblock = true
                } label: {
                    Label("Unblock User", systemImage: "hand.raised.slash")
                }
            } else {
                Button(role: .destructive) {
                    isConfirmingBlock = true
                } label: {
                    Label("Block User", systemImage: "hand.raised")
                }
            }

            Button(role: .destructive) {
                isConfirmingReport = true
            } label: {
                Label("Report User", systemImage: "flag")
            }
        } label: {
            if store.isDuoDevice {
                Label("Profile actions", systemImage: "ellipsis")
            } else {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .primaryGlass(in: .circle, interactive: true)
                    .contentShape(Circle())
            }
        }
        .contentShape(Circle())
        .accessibilityLabel("Profile actions")
        .accessibilityIdentifier("profile.actions")
    }

    @ViewBuilder
    private var profileRelationshipControl: some View {
        switch graphAction(for: profile) {
        case .button(let title, _):
            Button {
                handleGraphAction(for: profile)
            } label: {
                Text(title)
                    .font(AppTypography.button)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(accent, in: Capsule())
                    .overlay(Capsule().strokeBorder(accent.opacity(0.5), lineWidth: 1))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
        case .status(let title):
            Text(title)
                .font(AppTypography.button)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.white.opacity(0.04), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                .glassEffect(.regular, in: .capsule)
        }
    }

    private var curatedFriendCount: String? {
        store.appConfig["curated_follower_count:\(profile.normalizedUsername)"]
    }

    private var hasBrowsableFriendsList: Bool {
        curatedFriendCount == nil && unlocksPrivateProfileContent
    }

    private var friendCountText: String {
        if let curated = curatedFriendCount { return curated }
        guard let friendCount else { return "—" }
        return "\(friendCount)"
    }

    private var postCountText: String {
        // Counts are public even on locked profiles — only the posts
        // themselves stay private. `profilePostCount` is fetched directly
        // (RLS-bypassing RPC) for non-friends; for friends it's the value
        // returned alongside the first paginated posts page.
        guard let profilePostCount else { return "—" }
        return "\(profilePostCount)"
    }

    private var filteredProfileFriends: [UserProfile] {
        let query = profileFriendsSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return profileFriends }

        return profileFriends.filter { friend in
            friend.displayName.lowercased().contains(query)
                || friend.username.lowercased().contains(query)
        }
    }

    private func loadProfileData() async {
        if store.isLayoutPreview {
            profilePosts = store.posts.filter { $0.author.id == profile.id }
            profilePostCount = profilePosts.count
            friendCount = store.friends.count
            hasMoreProfilePosts = false
            didLoadPosts = true
            didLoadTaggedPosts = true
            didLoadProfileStats = true
            profileStats = .empty
            return
        }
        guard !isBlockedByViewer else {
            profileFriends = []
            friendCount = 0
            didLoadProfileFriends = true
            isLoadingProfileFriends = false
            profileFriendRank = nil
            profileFriendNightsOut = []
            didLoadProfileFriendRankStats = true
            isLoadingProfileFriendRankStats = false
            resetLockedProfileContent()
            return
        }

        async let friendsLoad: Void = loadProfileFriends()

        if unlocksPrivateProfileContent {
            async let postsLoad: Void = loadProfilePosts()
            async let taggedLoad: Void = loadTaggedPosts()
            async let statsLoad: Void = loadProfileStats()
            _ = await (friendsLoad, postsLoad, taggedLoad, statsLoad)
        } else {
            resetLockedProfileContent()
            // Lock hides the posts themselves but the COUNT is public — fetch
            // it directly so the header shows the real number instead of "—".
            async let lockedCountLoad: Void = loadLockedProfilePostCount()
            _ = await (friendsLoad, lockedCountLoad)
        }
    }

    private func loadLockedProfilePostCount() async {
        let count = await store.loadPostCount(of: profile)
        if let count {
            profilePostCount = count
        }
    }

    private func resetLockedProfileContent() {
        profilePosts = []
        profilePostCount = nil
        hasMoreProfilePosts = false
        nextProfilePageBefore = nil
        isLoadingPosts = false
        didLoadPosts = true

        taggedPostsList = []
        hasMoreTaggedPosts = false
        nextTaggedPageBefore = nil
        isLoadingTaggedPosts = false
        didLoadTaggedPosts = true

        profileStats = nil
        isLoadingProfileStats = false
        didLoadProfileStats = true
        profileFriendRank = nil
        profileFriendNightsOut = []
        isLoadingProfileFriendRankStats = false
        didLoadProfileFriendRankStats = true
        detailPost = nil
        selectedSection = .moments
    }

    private func removeDeletedPosts(_ deletedPostIDs: Set<UUID>) {
        guard !deletedPostIDs.isEmpty else { return }
        profilePosts.removeAll { deletedPostIDs.contains($0.id) }
        taggedPostsList.removeAll { deletedPostIDs.contains($0.id) }
        if let detailPost, deletedPostIDs.contains(detailPost.id) {
            self.detailPost = nil
        }
        if let profilePostCount {
            self.profilePostCount = max(0, profilePostCount - deletedPostIDs.count)
        }
    }

    private var friendsListPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                profileFriendsSearchField

                if isLoadingProfileFriends && profileFriends.isEmpty {
                    NightPanel(cornerRadius: AppLayout.panelRadius, padding: 16) {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(accent)
                            Text("Loading friends")
                                .font(AppTypography.rowSubtitleMedium)
                                .foregroundStyle(AppTheme.softText)
                        }
                    }
                } else if profileFriends.isEmpty {
                    EmptyStateCard(
                        title: "No friends to show",
                        symbol: "person.2.fill"
                    )
                } else {
                    NightPanel(cornerRadius: AppLayout.panelRadius, padding: 12) {
                        VStack(spacing: 8) {
                            if filteredProfileFriends.isEmpty {
                                Text("No friends match \"\(profileFriendsSearchQuery)\"")
                                    .font(AppTypography.rowSubtitle)
                                    .foregroundStyle(AppTheme.softText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 12)
                            } else {
                                ForEach(filteredProfileFriends) { friend in
                                    let isSelf = friend.id == store.viewer?.id
                                    FriendGraphRow(
                                        profile: friend,
                                        action: graphAction(for: friend),
                                        onAction: {
                                            handleGraphAction(for: friend)
                                        },
                                        onRowTap: isSelf ? { shouldNavigateToOwnProfile = true } : {
                                            selectedFriendInGraph = friend
                                        }
                                    )
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
        .background {
            AmbientBackground()
                .ignoresSafeArea()
        }
        .modifier(ProfileFriendsNavigation(isDuo: store.isDuoDevice))
        .navigationDestination(item: $selectedFriendInGraph) { friend in
            FriendProfileView(profile: friend, presentationStyle: .embedded)
        }
    }

    private var profileFriendsSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.softText)

            TextField("Search friends", text: $profileFriendsSearchQuery)
                .font(AppTypography.searchInput)
                .foregroundStyle(.white)
                .tint(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !profileFriendsSearchQuery.isEmpty {
                Button {
                    profileFriendsSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(AppTheme.softText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
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
        async let friendsFetch = store.loadFriends(of: profile)
        async let countFetch = store.loadFriendCount(of: profile)
        let (loadedFriends, loadedCount) = await (friendsFetch, countFetch)
        profileFriends = loadedFriends
        // Use the authoritative count RPC — the friends list may be
        // RLS-restricted for non-friends, so its .count would show 0.
        friendCount = loadedCount ?? loadedFriends.count
        didLoadProfileFriends = true
        isLoadingProfileFriends = false
    }

    private func loadProfilePosts() async {
        guard !isBlockedByViewer, unlocksPrivateProfileContent else {
            resetLockedProfileContent()
            return
        }

        profilePosts = []
        profilePostCount = nil
        hasMoreProfilePosts = true
        nextProfilePageBefore = nil
        didLoadPosts = false
        await loadMoreProfilePosts(reset: true)
    }

    private func loadMoreProfilePosts(reset: Bool) async {
        guard unlocksPrivateProfileContent else {
            resetLockedProfileContent()
            return
        }
        guard reset || hasMoreProfilePosts else { return }
        guard !isLoadingPosts else { return }

        isLoadingPosts = true
        defer { isLoadingPosts = false }

        let result = await store.loadUserPostsPage(
            for: profile,
            before: reset ? nil : nextProfilePageBefore,
            limit: AppStore.profilePostsPageSize
        )

        if reset {
            // Only replace if the server returned posts — an empty result on
            // reset is almost always a transient backend issue, not a signal
            // that the user truly has no posts. Guard preserves any previously
            // loaded grid if a second load fires unexpectedly.
            if !result.posts.isEmpty {
                profilePosts = result.posts
            }
        } else {
            let existingIDs = Set(profilePosts.map(\.id))
            profilePosts += result.posts.filter { !existingIDs.contains($0.id) }
        }

        if let totalCount = result.totalCount {
            profilePostCount = totalCount
        }
        hasMoreProfilePosts = result.hasMore
        nextProfilePageBefore = profilePosts.last?.createdAt
        didLoadPosts = true
    }

    private func loadTaggedPosts() async {
        guard !isBlockedByViewer, unlocksPrivateProfileContent else {
            resetLockedProfileContent()
            return
        }
        taggedPostsList = []
        hasMoreTaggedPosts = true
        nextTaggedPageBefore = nil
        didLoadTaggedPosts = false
        await loadMoreTaggedPosts(reset: true)
    }

    private func loadMoreTaggedPosts(reset: Bool) async {
        guard unlocksPrivateProfileContent else {
            resetLockedProfileContent()
            return
        }
        guard reset || hasMoreTaggedPosts else { return }
        guard !isLoadingTaggedPosts else { return }

        isLoadingTaggedPosts = true
        defer { isLoadingTaggedPosts = false }

        let result = await store.loadTaggedPostsPage(
            for: profile,
            before: reset ? nil : nextTaggedPageBefore,
            limit: AppStore.profilePostsPageSize
        )

        if reset {
            if !result.posts.isEmpty {
                taggedPostsList = result.posts
            }
        } else {
            let existingIDs = Set(taggedPostsList.map(\.id))
            taggedPostsList += result.posts.filter { !existingIDs.contains($0.id) }
        }

        hasMoreTaggedPosts = result.hasMore
        nextTaggedPageBefore = taggedPostsList.last?.createdAt
        didLoadTaggedPosts = true
    }

    private func loadProfileStats() async {
        guard !isBlockedByViewer, unlocksPrivateProfileContent else {
            resetLockedProfileContent()
            return
        }
        guard !isLoadingProfileStats else { return }

        profileStats = nil
        didLoadProfileStats = false
        isLoadingProfileStats = true
        defer { isLoadingProfileStats = false }

        let result = await store.loadProfileStats(for: profile)
        profileStats = result.stats
        didLoadProfileStats = true
    }

    private func loadProfileFriendRank() async {
        guard !isBlockedByViewer, unlocksPrivateProfileContent else {
            profileFriendRank = nil
            profileFriendNightsOut = []
            didLoadProfileFriendRankStats = true
            isLoadingProfileFriendRankStats = false
            return
        }
        guard !isLoadingProfileFriendRankStats else { return }

        profileFriendRank = nil
        profileFriendNightsOut = []
        didLoadProfileFriendRankStats = false
        isLoadingProfileFriendRankStats = true
        defer { isLoadingProfileFriendRankStats = false }

        if let rank = await store.loadProfileFriendRank(for: profile) {
            profileFriendRank = rank
            didLoadProfileFriendRankStats = true
            return
        }

        let comparisonFriends: [UserProfile]
        if didLoadProfileFriends {
            comparisonFriends = profileFriends
        } else {
            comparisonFriends = await store.loadFriends(of: profile)
            profileFriends = comparisonFriends
            friendCount = friendCount ?? comparisonFriends.count
            didLoadProfileFriends = true
        }

        guard !comparisonFriends.isEmpty else {
            didLoadProfileFriendRankStats = true
            return
        }

        var results: [Int] = []
        await withTaskGroup(of: Int?.self) { group in
            for friend in comparisonFriends {
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

        profileFriendNightsOut = results
        didLoadProfileFriendRankStats = true
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

    private var lockedProfileContent: some View {
        EmptyStateCard(
            title: "Friends only",
            detail: "Add \(profile.displayName) to see their posts.",
            symbol: "lock.fill"
        )
        .padding(.top, 4)
    }

    // MARK: - Segmented control

    private var sectionToggle: some View {
        ProfileSectionToggle(selectedSection: $selectedSection)
    }

    // MARK: - Moments grid

    @ViewBuilder
    private var momentsContent: some View {
        let posts = postsByFriend

        if isLoadingPosts && posts.isEmpty {
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
            // Mirrors ProfileView's grid exactly — same columns, same
            // thumbnail contract. The previous bug (first cell rendering
            // as a full-screen strip inside the sheet) was caused by the
            // thumbnail resolving its aspectRatio against a zero-width
            // first pass; the thumbnail now ships with an explicit
            // square frame via the parent-supplied size, so this grid
            // can stay minimal.
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: store.isDuoDevice ? AppLayout.photoGridColumnCount(width: profileGridWidth) : 3)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(posts) { post in
                    Button {
                        store.cacheProfilePosts([post])
                        detailPost = post
                    } label: {
                        FriendMomentGridThumbnail(media: post.media)
                    }
                    .buttonStyle(.plain)
                    .task(id: paginationTaskID(for: post, in: posts, isLoading: isLoadingPosts, hasMore: hasMoreProfilePosts)) {
                        guard shouldLoadMore(afterAppearing: post, in: posts, isLoading: isLoadingPosts, hasMore: hasMoreProfilePosts) else { return }

                        Task {
                            await loadMoreProfilePosts(reset: false)
                        }
                    }
                }
            }
            .padding(.horizontal, -20)

            if isLoadingPosts && !posts.isEmpty {
                ProgressView()
                    .tint(accent)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
        }
    }

    // MARK: - Tagged grid

    @ViewBuilder
    private var taggedContent: some View {
        if isLoadingTaggedPosts && taggedPostsList.isEmpty {
            ProgressView()
                .tint(accent)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else if taggedPostsList.isEmpty {
            Text("No tagged posts yet")
                .font(AppTypography.rowSubtitleMedium)
                .foregroundStyle(AppTheme.softText)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 32)
        } else {
            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: store.isDuoDevice ? AppLayout.photoGridColumnCount(width: profileGridWidth) : 3)

            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(taggedPostsList) { post in
                    Button {
                        detailPost = post
                    } label: {
                        FriendMomentGridThumbnail(media: post.media)
                    }
                    .buttonStyle(.plain)
                    .task(id: paginationTaskID(for: post, in: taggedPostsList, isLoading: isLoadingTaggedPosts, hasMore: hasMoreTaggedPosts)) {
                        guard shouldLoadMore(afterAppearing: post, in: taggedPostsList, isLoading: isLoadingTaggedPosts, hasMore: hasMoreTaggedPosts) else { return }

                        Task {
                            await loadMoreTaggedPosts(reset: false)
                        }
                    }
                }
            }
            .padding(.horizontal, -20)

            if isLoadingTaggedPosts && !taggedPostsList.isEmpty {
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
        if isLoadingProfileStats && profileStats == nil {
            ProgressView()
                .tint(accent)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else {
            ProfileStatsCards(
                stats: profileStats ?? .empty,
                friendRank: profileFriendRank,
                friendNightsOut: profileFriendNightsOut,
                isLoadingFriendRank: isLoadingProfileFriendRankStats
            )
            .task {
                guard !didLoadProfileFriendRankStats && !isLoadingProfileFriendRankStats else { return }
                await loadProfileFriendRank()
            }
        }
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

private enum FriendGraphAction: Equatable {
    case button(title: String, symbol: String)
    case status(String)
}

private struct FriendGraphRow: View {
    @Environment(\.appAccent) private var accent
    let profile: UserProfile
    let action: FriendGraphAction
    let onAction: () -> Void
    var onRowTap: (() -> Void)? = nil

    var body: some View {
        let row = HStack(spacing: 14) {
            AvatarView(avatar: profile.avatar, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                VerifiedUsernameLabel(profile: profile, font: AppTypography.footnote, badgeSize: 11)
            }

            Spacer(minLength: 8)

            switch action {
            case .button(let title, let symbol):
                Button(action: onAction) {
                    Label(title, systemImage: symbol)
                        .font(AppTypography.buttonFootnote)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(accent, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            case .status(let title):
                Text(title)
                    .font(AppTypography.buttonFootnote)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(.white.opacity(0.08), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
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
                    if let data = media.photoData,
                       let image = ImageDecodeCache.image(for: data, key: ImageDecodeCache.cacheKey(forLocalData: data, prefix: "friend-moment-grid")) {
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

/// Re-enables the UINavigationController's interactive pop gesture after
/// SwiftUI disables it via navigationBarBackButtonHidden(true).
/// UIViewControllerRepresentable is used instead of UIViewRepresentable
/// because a UIViewController embedded in a NavigationStack has a direct
/// .navigationController reference — no responder-chain traversal needed.
private struct SwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> SwipeBackEnablerVC {
        SwipeBackEnablerVC()
    }

    func updateUIViewController(_ vc: SwipeBackEnablerVC, context: Context) {
        vc.enableInteractivePopWhenAttached()
    }
}

private final class SwipeBackEnablerVC: UIViewController, UIGestureRecognizerDelegate {
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        enableInteractivePopWhenAttached()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        enableInteractivePopWhenAttached()
    }

    func enableInteractivePopWhenAttached() {
        guard let gesture = navigationController?.interactivePopGestureRecognizer else {
            DispatchQueue.main.async { [weak self] in
                self?.enableInteractivePopWhenAttached()
            }
            return
        }

        gesture.isEnabled = true
        gesture.delegate = self
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        (navigationController?.viewControllers.count ?? 0) > 1
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
                .modifier(PostDetailColumn())
                .padding(.horizontal, store.isDuoDevice ? AppLayout.screenPadding : 0)
                .padding(.top, store.isDuoDevice ? 12 : 36)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .modifier(MainPageSurface())
            .modifier(DuoModalNavigation(title: "Post"))
            .navigationDestination(item: Binding(
                get: { store.isDuoDevice ? commentSheetPostID : nil },
                set: { commentSheetPostID = $0 }
            )) { postID in
                CommentThreadSheet(postID: postID, initialPost: post, isEmbedded: true)
                    .modifier(MainPageSurface())
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

private struct ProfileFriendsNavigation: ViewModifier {
    let isDuo: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isDuo {
            content
                .toolbar(.visible, for: .navigationBar)
        } else {
            content.appSecondaryPageNavigation(title: "Friends")
        }
    }
}
