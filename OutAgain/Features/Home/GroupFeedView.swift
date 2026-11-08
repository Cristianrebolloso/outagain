import SwiftUI

struct GroupFeedView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    let group: NightGroup

    @State private var commentPost: MomentPost? = nil
    @State private var profileTarget: UserProfile? = nil
    @State private var isEditing = false
    @State private var isConfirmingDeleteGroup = false

    // Resolved live group from store so mutations (rename/delete) propagate
    private var liveGroup: NightGroup {
        store.nightGroups.first(where: { $0.id == group.id }) ?? group
    }

    private var navTitle: String {
        let trimmed = liveGroup.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Group" : trimmed
    }

    private let contentHorizontalPadding: CGFloat = 16
    private var posts: [MomentPost] { store.groupPosts(for: liveGroup) }
    private var members: [UserProfile] { store.groupMembers(for: liveGroup) }
    private var totalPostCount: Int { posts.count }

    /// Aggregated drink recap across all member posts tonight. Keeps the
    /// first-seen order from newest posts, so the freshest drinks stay high.
    private var groupDrinkSummaries: [GroupDrinkSummary] {
        var seen: [String: GroupDrinkSummary] = [:]
        var order: [String] = []

        for post in posts {
            guard let drink = post.drink else { continue }
            let key = AppStore.normalizedDrinkName(drink.name)

            if var summary = seen[key] {
                summary.count += 1
                summary.authorIDs.insert(post.author.id)
                seen[key] = summary
            } else {
                seen[key] = GroupDrinkSummary(
                    id: key,
                    drink: drink,
                    count: 1,
                    latestPostDate: post.createdAt,
                    authorIDs: [post.author.id]
                )
                order.append(key)
            }
        }

        return order.compactMap { seen[$0] }
    }

    private var latestPostDate: Date? {
        posts.first?.createdAt
    }

    private var activeMemberIDs: Set<UUID> {
        Set(posts.map(\.author.id))
    }

    private var activeMemberCount: Int {
        activeMemberIDs.count
    }

    private var groupDrinkTitle: String {
        "\(possessiveName(navTitle)) drinks"
    }

    private var groupNightTitle: String {
        "\(navTitle) tonight"
    }

    private var groupNightSubtitle: String {
        guard totalPostCount > 0 else {
            return "Waiting for the first post"
        }

        return activeMemberCount == 0
            ? "no active members"
            : "\(ActivityNightText.memberCountLabel(activeMemberCount)) active"
    }

    private var drinkListItems: [ActivityDrinkListItem] {
        groupDrinkSummaries.map { summary in
            let memberCount = summary.authorIDs.count
            let detail = memberCount > 0 ? ActivityNightText.memberCountLabel(memberCount) : nil

            return ActivityDrinkListItem(
                id: summary.id,
                drink: summary.drink,
                count: summary.count,
                detail: detail
            )
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    groupRecap
                    feedContent
                }
                .padding(.horizontal, contentHorizontalPadding)
                .padding(.top, store.isDuoDevice ? 12 : 36)
                .padding(.bottom, 40)
                .modifier(PostDetailColumn())
            }
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .modifier(MainPageSurface())
            .navigationTitle(store.isDuoDevice ? navTitle : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if store.isDuoDevice {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close group", systemImage: "xmark") { dismiss() }
                    }
                }
            }
            .navigationDestination(item: $profileTarget) { profile in
                FriendProfileView(profile: profile, presentationStyle: .embedded)
            }
            .navigationDestination(isPresented: Binding(
                get: { store.isDuoDevice && isEditing },
                set: { isEditing = $0 }
            )) {
                GroupEditSheet(group: liveGroup, isEmbedded: true)
            }
            .navigationDestination(item: Binding(
                get: { store.isDuoDevice ? commentPost : nil },
                set: { commentPost = $0 }
            )) { post in
                CommentThreadSheet(postID: post.id, initialPost: post, isEmbedded: true)
                    .modifier(MainPageSurface())
                    .navigationTitle("Comments")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(.hidden, for: .navigationBar)
            }
        }
        .modifier(DuoSheetSurface())
        .modifier(PostDetailPresentation())
        .sheet(item: Binding(
            get: { store.isDuoDevice ? nil : commentPost },
            set: { commentPost = $0 }
        )) { post in
            CommentThreadSheet(postID: post.id, initialPost: post)
                .presentationDetents([.fraction(0.6), .large])
                .appSheetDragHandle()
        }
        .sheet(isPresented: Binding(
            get: { !store.isDuoDevice && isEditing },
            set: { isEditing = $0 }
        )) {
            GroupEditSheet(group: liveGroup)
                .environment(store)
                .environment(\.appAccent, accent)
                .presentationDetents([.large])
                .appSheetDragHandle()
        }
        .alert(
            "Delete this group?",
            isPresented: $isConfirmingDeleteGroup,
            actions: {
            Button("Delete group", role: .destructive) {
                store.deleteGroup(liveGroup.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
                .tint(.blue)
        }, message: {
            Text("Are you sure you want to delete this group? This removes it for every member.")
        })
    }

    // MARK: - Group recap

    private var groupRecap: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActivityNightOverviewCard(
                title: groupNightTitle,
                subtitle: groupNightSubtitle,
                value: "\(totalPostCount)",
                unit: totalPostCount == 1 ? "post" : "posts",
                stats: [
                    ActivityNightOverviewStat(
                        symbol: "play.fill",
                        title: "Started",
                        value: ActivityNightText.startedTimeLabel(for: posts),
                        tint: AppTheme.barLightGreen
                    ),
                    ActivityNightOverviewStat(
                        symbol: "clock.fill",
                        title: "Latest",
                        value: ActivityNightText.latestTimeLabel(latestPostDate),
                        tint: AppTheme.barLightBlue
                    )
                ],
                tint: accent
            )

            ActivityDrinkListCard(
                title: groupDrinkTitle,
                items: drinkListItems,
                tint: AppTheme.barLightGreen
            )

            HStack(spacing: 10) {
                Button {
                    isEditing = true
                } label: {
                    Label("Edit group", systemImage: "pencil")
                        .font(AppTypography.button)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .contentShape(Capsule())
                .primaryGlass(in: .capsule, interactive: true)

                if isCreator {
                    groupActionsMenu
                }
            }
        }
    }

    private var groupActionsMenu: some View {
        Menu {
            Button(role: .destructive) {
                isConfirmingDeleteGroup = true
            } label: {
                Label("Delete Group", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .primaryGlass(in: .circle, interactive: true)
        }
        .accessibilityLabel("Group actions")
    }

    // MARK: - Feed

    @ViewBuilder
    private var feedContent: some View {
        if posts.isEmpty {
            EmptyStateCard(
                title: "Nothing posted yet",
                symbol: "moon.stars.fill"
            )
            .padding(.top, 16)
        } else {
            LazyVStack(spacing: 20) {
                ForEach(posts) { post in
                    MomentPostCard(
                        post: post,
                        isFocused: true,
                        onCommentTap: { commentPost = post },
                        onAuthorTap: { profile in
                            if profile.id == store.viewer?.id {
                                dismiss()
                                store.selectedTab = .profile
                            } else {
                                profileTarget = profile
                            }
                        }
                    )
                    .padding(.horizontal, -contentHorizontalPadding)
                }
            }
        }
    }

    private var isCreator: Bool {
        liveGroup.creatorID == store.viewer?.id
    }

    private func possessiveName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Group's" }

        if trimmed.lowercased().hasSuffix("s") {
            return "\(trimmed)'"
        }

        return "\(trimmed)'s"
    }

    private struct GroupDrinkSummary: Identifiable {
        let id: String
        let drink: DrinkTag
        var count: Int
        let latestPostDate: Date
        var authorIDs: Set<UUID>
    }

}

// MARK: - Group Edit Sheet

/// Mirrors GroupCreationSheet but pre-populates the existing group's
/// name and member list. The viewer can add more friends or rename,
/// then save — existing members are preserved and new ones are appended.
private struct GroupEditSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    let group: NightGroup
    let isEmbedded: Bool

    @State private var selectedFriendIDs: Set<UUID>
    @State private var groupName: String
    @State private var searchQuery: String = ""
    @State private var isSaving = false
    @FocusState private var isNameFocused: Bool
    @FocusState private var isSearchFocused: Bool

    init(group: NightGroup, isEmbedded: Bool = false) {
        self.group = group
        self.isEmbedded = isEmbedded
        // Pre-populate with existing non-viewer members
        _groupName = State(initialValue: group.name)
        _selectedFriendIDs = State(initialValue: Set(group.memberIDs))
    }

    /// Friends not already the viewer, shown for selection.
    private var displayedFriends: [UserProfile] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pool = query.isEmpty ? store.friends : store.friends.filter {
            $0.displayName.lowercased().contains(query) ||
            $0.username.lowercased().contains(query)
        }
        return pool
    }

    private var friendListViewportHeight: CGFloat {
        let visibleRows = min(displayedFriends.count, GroupEditLayout.visibleFriendRows)
        guard visibleRows > 0 else { return 0 }
        let dividerCount = max(visibleRows - 1, 0)
        return CGFloat(visibleRows) * GroupEditLayout.friendRowHeight
            + CGFloat(dividerCount) * GroupEditLayout.dividerHeight
    }

    private var isCreator: Bool {
        group.creatorID == store.viewer?.id
    }

    @ViewBuilder
    var body: some View {
        if isEmbedded {
            editor
                .navigationBarBackButtonHidden()
        } else {
            NavigationStack { editor }
        }
    }

    private var editor: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Any member can add more friends to the group.
                    // Removing existing members is blocked at the row level
                    // (the picker disables deselection of original members).
                    friendPicker
                    nameField
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .appSecondaryPageNavigation(title: "Edit Group")
            .scrollDismissesKeyboard(.interactively)
            .safeAreaPadding(.bottom, store.isDuoDevice && isNameFocused ? 20 : 0)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        if store.isDuoDevice { Label("Cancel", systemImage: "xmark") }
                        else { Text("Cancel") }
                    }
                        .foregroundStyle(AppTheme.softText)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await saveEdits() }
                    } label: {
                        if store.isDuoDevice { Label("Save", systemImage: "checkmark") }
                        else { Text("Save") }
                    }
                        .font(AppTypography.button)
                        .foregroundStyle(isSaving ? AppTheme.softText : accent)
                        .disabled(isSaving)
                }
            }
    }

    // MARK: - Friend picker

    private var friendPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add friends")
                .font(AppTypography.sectionTitle)
                .foregroundStyle(.white)

            if store.friends.isEmpty {
                NightPanel(cornerRadius: 20, padding: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.slash.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(AppTheme.softText)
                        Text("Add friends first to create a group.")
                            .font(AppTypography.rowSubtitle)
                            .foregroundStyle(AppTheme.softText)
                    }
                }
            } else {
                NightPanel(cornerRadius: 24, padding: 4) {
                    VStack(spacing: 0) {
                        searchBar
                            .padding(.horizontal, 12)
                            .padding(.top, 10)
                            .padding(.bottom, 6)

                        Divider()
                            .overlay(AppTheme.line)

                        if displayedFriends.isEmpty {
                            HStack {
                                Text("No friends match \"\(searchQuery)\"")
                                    .font(AppTypography.rowSubtitle)
                                    .foregroundStyle(AppTheme.softText)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(displayedFriends) { friend in
                                        friendRow(friend)

                                        if friend.id != displayedFriends.last?.id {
                                            Divider()
                                                .overlay(AppTheme.line)
                                                .padding(.leading, 66)
                                        }
                                    }
                                }
                            }
                            .frame(height: friendListViewportHeight)
                            .scrollDisabled(displayedFriends.count <= GroupEditLayout.visibleFriendRows)
                            .scrollIndicators(displayedFriends.count > GroupEditLayout.visibleFriendRows ? .visible : .hidden)
                        }
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.softText)

            TextField("Search friends", text: $searchQuery)
                .font(AppTypography.searchInput)
                .foregroundStyle(.white)
                .tint(accent)
                .focused($isSearchFocused)
                .submitLabel(.search)
                .onSubmit { isSearchFocused = false }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.softText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
    }

    private func friendRow(_ friend: UserProfile) -> some View {
        let isSelected = selectedFriendIDs.contains(friend.id)

        return Button {
            withAnimation(.snappy(duration: 0.18)) {
                if isSelected {
                    // Don't allow deselecting original members — only additions
                    // can be removed. Original members are protected so the
                    // group doesn't silently shrink when someone taps by mistake.
                    if !group.memberIDs.contains(friend.id) {
                        selectedFriendIDs.remove(friend.id)
                    }
                } else {
                    selectedFriendIDs.insert(friend.id)
                }
            }
        } label: {
            HStack(spacing: 14) {
                AvatarView(avatar: friend.avatar, size: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(friend.displayName)
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(.white)
                    VerifiedUsernameLabel(profile: friend, font: AppTypography.usernameCompact, badgeSize: 10)
                }

                Spacer()

                ZStack {
                    Circle()
                        .fill(isSelected ? accent : .white.opacity(0.08))
                        .frame(width: 26, height: 26)
                    Circle()
                        .strokeBorder(isSelected ? accent : AppTheme.line, lineWidth: 1.5)
                        .frame(width: 26, height: 26)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(AppTheme.foregroundOnAccent(accent))
                    }
                }
                .animation(.snappy(duration: 0.16), value: isSelected)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(height: GroupEditLayout.friendRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Name field

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Group name")
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(.white)
                Text("optional")
                    .font(AppTypography.rowSubtitleMedium)
                    .foregroundStyle(AppTheme.softText.opacity(0.7))
            }

            NightPanel(cornerRadius: 20, padding: 0) {
                TextField("e.g. Maddies Big Naturals", text: $groupName)
                    .font(AppTypography.body)
                    .foregroundStyle(.white)
                    .tint(accent)
                    .focused($isNameFocused)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .submitLabel(.done)
                    .onSubmit { isNameFocused = false }
            }
        }
    }

    // MARK: - Save

    private func saveEdits() async {
        let original = group.memberIDs
        // Any member can add friends; nobody can remove existing members
        // (the picker's tap handler guards against deselecting original IDs).
        let added = selectedFriendIDs.subtracting(Set(original))
        let finalMemberIDs = original + Array(added)
        let updated = NightGroup(
            id: group.id,
            name: groupName,
            creatorID: group.creatorID,
            memberIDs: finalMemberIDs,
            createdAt: group.createdAt
        )
        isSaving = true
        let didSave = await store.saveGroupEdits(updated)
        isSaving = false
        if didSave {
            dismiss()
        }
    }
}

private enum GroupEditLayout {
    static let visibleFriendRows = 5
    static let friendRowHeight: CGFloat = 66
    static let dividerHeight: CGFloat = 1
}
