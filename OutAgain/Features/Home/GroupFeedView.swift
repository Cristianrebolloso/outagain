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

    private var posts: [MomentPost] { store.groupPosts(for: liveGroup) }
    private var members: [UserProfile] { store.groupMembers(for: liveGroup) }
    private var totalPostCount: Int { posts.count }

    /// Aggregated drink counts across all member posts tonight, highest first.
    private var groupDrinkCounts: [(drink: DrinkTag, count: Int)] {
        var seen: [String: (drink: DrinkTag, count: Int)] = [:]
        var order: [String] = []
        for post in posts {
            let key = post.drink.name
            if seen[key] == nil {
                seen[key] = (post.drink, 0)
                order.append(key)
            }
            seen[key]!.count += 1
        }
        return order.compactMap { seen[$0] }.sorted { $0.count > $1.count }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Drinks first — same position as individual feed
                    if !groupDrinkCounts.isEmpty {
                        drinkSummary
                    }
                    memberRoster
                    postCountHeader
                    feedContent
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    deleteGroupButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button("Edit") { isEditing = true }
                            .font(.body.weight(.medium))
                            .foregroundStyle(AppTheme.softText)

                        Button("Done") { dismiss() }
                            .font(.body.weight(.semibold))
                            .foregroundStyle(accent)
                    }
                }
            }
        }
        .sheet(item: $commentPost) { post in
            CommentThreadSheet(postID: post.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $profileTarget) { profile in
            FriendProfileView(profile: profile)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isEditing) {
            GroupEditSheet(group: liveGroup)
                .environment(store)
                .environment(\.appAccent, accent)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog(
            "Delete this group?",
            isPresented: $isConfirmingDeleteGroup,
            titleVisibility: .visible
        ) {
            Button("Delete group", role: .destructive) {
                store.deleteGroup(group.id)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete this group? This removes it for every member.")
        }
    }

    // MARK: - Drinks summary (mirrors TonightAuthorSheet exactly)

    private var drinkSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tonight's drinks")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(1.1)
                .textCase(.uppercase)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(groupDrinkCounts, id: \.drink.id) { entry in
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
            .scrollIndicators(.hidden)
        }
    }

    // MARK: - Member roster (unpanelled, strip-style tiles)

    private var memberRoster: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Members")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .tracking(1.1)
                .textCase(.uppercase)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(members) { member in
                        memberTile(member)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func memberTile(_ member: UserProfile) -> some View {
        let postCount = posts.filter { $0.author.id == member.id }.count
        let isViewer = member.id == store.viewer?.id

        return Button {
            if !isViewer { profileTarget = member }
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .strokeBorder(postCount > 0 ? accent : AppTheme.line,
                                      lineWidth: postCount > 0 ? 2 : 1)
                        .frame(width: 54, height: 54)
                    AvatarView(avatar: member.avatar, size: 48)
                        .opacity(postCount > 0 ? 1 : 0.55)
                }
                .overlay(alignment: .bottom) {
                    if postCount > 0 {
                        Text("\(postCount)")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(accent, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.black.opacity(0.2), lineWidth: 0.5))
                            .offset(y: 9)
                    }
                }
                .padding(.bottom, postCount > 0 ? 9 : 0)

                Text(isViewer ? "You" : (member.displayName.components(separatedBy: " ").first ?? member.displayName))
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(postCount > 0 ? .white : AppTheme.softText)
                    .lineLimit(1)
                    .frame(maxWidth: 60)
            }
            .frame(width: 64)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Post count header

    @ViewBuilder
    private var postCountHeader: some View {
        if totalPostCount > 0 {
            HStack(spacing: 8) {
                Text("\(totalPostCount)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                Text(totalPostCount == 1 ? "post tonight" : "posts tonight")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Feed

    @ViewBuilder
    private var feedContent: some View {
        if posts.isEmpty {
            EmptyStateCard(
                title: "Nothing posted yet",
                detail: "When anyone in this group posts tonight, it'll show up here.",
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
                }
            }
        }
    }

    private func pluralized(_ name: String) -> String {
        name.lowercased().hasSuffix("s") ? name : "\(name)s"
    }

    // MARK: - Delete (creator only)

    private var isCreator: Bool {
        liveGroup.creatorID == store.viewer?.id
    }

    @ViewBuilder
    private var deleteGroupButton: some View {
        if isCreator {
            Button {
                isConfirmingDeleteGroup = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AppTheme.softText)
            }
        }
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

    @State private var selectedFriendIDs: Set<UUID>
    @State private var groupName: String
    @State private var searchQuery: String = ""
    @State private var isSaving = false
    @FocusState private var isNameFocused: Bool
    @FocusState private var isSearchFocused: Bool

    init(group: NightGroup) {
        self.group = group
        // Pre-populate with existing non-viewer members
        _groupName = State(initialValue: group.name)
        _selectedFriendIDs = State(initialValue: Set(group.memberIDs))
    }

    /// Friends not already the viewer, shown for selection.
    private var displayedFriends: [UserProfile] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pool = query.isEmpty ? Array(store.friends.prefix(5)) : store.friends.filter {
            $0.displayName.lowercased().contains(query) ||
            $0.username.lowercased().contains(query)
        }
        return pool
    }

    private var isCreator: Bool {
        group.creatorID == store.viewer?.id
    }

    var body: some View {
        NavigationStack {
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
            .navigationTitle("Edit Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(AppTheme.softText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task { await saveEdits() }
                    }
                        .font(.body.weight(.bold))
                        .foregroundStyle(isSaving ? AppTheme.softText : accent)
                        .disabled(isSaving)
                }
            }
        }
    }

    // MARK: - Friend picker

    private var friendPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add friends")
                .font(.system(size: 28, weight: .bold, design: .serif))
                .foregroundStyle(.white)

            if store.friends.isEmpty {
                NightPanel(cornerRadius: 20, padding: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.slash.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(AppTheme.softText)
                        Text("Add friends first to create a group.")
                            .font(.system(.subheadline, design: .rounded))
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
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(AppTheme.softText)
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 14)
                        } else {
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
                .font(.system(.subheadline, design: .rounded))
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
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("@\(friend.username)")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(AppTheme.softText)
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
                            .foregroundStyle(.white)
                    }
                }
                .animation(.snappy(duration: 0.16), value: isSelected)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Name field

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Group name")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                Text("optional")
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                    .foregroundStyle(AppTheme.softText.opacity(0.7))
            }

            NightPanel(cornerRadius: 20, padding: 0) {
                TextField("e.g. Maddies Big Naturals", text: $groupName)
                    .font(.system(.body, design: .rounded))
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
