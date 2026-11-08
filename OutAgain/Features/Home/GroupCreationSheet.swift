import SwiftUI

struct GroupCreationSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFriendIDs: Set<UUID> = []
    @State private var groupName: String = ""
    @State private var searchQuery: String = ""
    @FocusState private var isNameFocused: Bool
    @FocusState private var isSearchFocused: Bool

    private var canCreate: Bool { !selectedFriendIDs.isEmpty }

    /// All friends are available in the picker; the panel itself controls how
    /// many rows are visible before scrolling.
    private var displayedFriends: [UserProfile] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.friends }
        return store.friends.filter {
            $0.displayName.lowercased().contains(query) ||
            $0.username.lowercased().contains(query)
        }
    }

    private var friendListViewportHeight: CGFloat {
        let visibleRows = min(displayedFriends.count, GroupCreationLayout.visibleFriendRows)
        guard visibleRows > 0 else { return 0 }
        let dividerCount = max(visibleRows - 1, 0)
        return CGFloat(visibleRows) * GroupCreationLayout.friendRowHeight
            + CGFloat(dividerCount) * GroupCreationLayout.dividerHeight
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    friendPicker
                    nameField
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaPadding(.bottom, store.isDuoDevice && isNameFocused ? 20 : 0)
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .appSecondaryPageNavigation(title: "Create Group")
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
                        createGroup()
                    } label: {
                        if store.isDuoDevice { Label("Create", systemImage: "checkmark") }
                        else { Text("Create").font(AppTypography.button) }
                    }
                    .tint(accent)
                    .disabled(!canCreate)
                    .accessibilityIdentifier("group.create.confirm")
                }
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
                        // Search bar at the top of the panel
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
                            .scrollDisabled(displayedFriends.count <= GroupCreationLayout.visibleFriendRows)
                            .scrollIndicators(displayedFriends.count > GroupCreationLayout.visibleFriendRows ? .visible : .hidden)
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
                    selectedFriendIDs.remove(friend.id)
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
            .frame(height: GroupCreationLayout.friendRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
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

    // MARK: - Actions

    private func createGroup() {
        store.createGroup(
            name: groupName,
            friendIDs: Array(selectedFriendIDs)
        )
        dismiss()
    }
}

private enum GroupCreationLayout {
    static let visibleFriendRows = 5
    static let friendRowHeight: CGFloat = 66
    static let dividerHeight: CGFloat = 1
}
