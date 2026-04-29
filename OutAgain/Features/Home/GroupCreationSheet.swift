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

    /// Top 5 friends by display name, then filtered by search query if active.
    private var displayedFriends: [UserProfile] {
        let top5 = Array(store.friends.prefix(5))
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return top5 }
        return store.friends.filter {
            $0.displayName.lowercased().contains(query) ||
            $0.username.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    pitchHeader
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
            .navigationTitle("Create Group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(AppTheme.softText)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") { createGroup() }
                        .font(.body.weight(.bold))
                        .foregroundStyle(canCreate ? accent : AppTheme.softText)
                        .disabled(!canCreate)
                }
            }
        }
    }

    // MARK: - Pitch header

    private var pitchHeader: some View {
        NightPanel(cornerRadius: 24, padding: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(accent)
                    Text("One feed for your group")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                }
                Text("Add friends and every post you all make tonight shows up in one shared feed.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
                    .fixedSize(horizontal: false, vertical: true)
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

    // MARK: - Actions

    private func createGroup() {
        store.createGroup(
            name: groupName,
            friendIDs: Array(selectedFriendIDs)
        )
        dismiss()
    }
}
