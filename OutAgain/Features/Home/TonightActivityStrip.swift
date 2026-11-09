import SwiftUI

/// Faces and recency describe posts in the current 7am-to-7am night.
/// A post is activity, not a claim that someone is still out right now.
struct TonightActivityStrip: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @State private var clock: Date = .now

    var onFriendPostTap: (UUID) -> Void
    var onFriendProfileTap: (UserProfile) -> Void
    var onCreateGroupTap: () -> Void = {}
    var onGroupTap: (NightGroup) -> Void = { _ in }

    private var entries: [AppStore.TonightEntry] {
        store.tonightEntries.filter { $0.hasPostedTonight }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Posted tonight")
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.white)
                Spacer(minLength: 4)
                Button(action: onCreateGroupTap) {
                    Label("Groups", systemImage: "person.3.fill")
                        .font(AppTypography.button)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.glass)
                .tint(.white)
                .accessibilityHint("Create a group")
                .accessibilityIdentifier("home.groups")
            }
            .padding(.horizontal, AppLayout.screenPadding)

            if entries.isEmpty && store.nightGroups.isEmpty {
                Text("No posts tonight yet.")
                    .font(AppTypography.rowSubtitle)
                    .foregroundStyle(AppTheme.softText)
                    .padding(.horizontal, AppLayout.screenPadding)
            } else {
                storyTiles
            }
        }
        .padding(.vertical, 4)
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                clock = .now
            }
        }
    }

    private var storyTiles: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 12) {
                // Friends stay first; group controls no longer push faces offscreen.
                ForEach(entries) { entry in
                    friendTile(for: entry)
                }
                if !entries.isEmpty && !store.nightGroups.isEmpty {
                    Rectangle()
                        .fill(AppTheme.line)
                        .frame(width: 1, height: 48)
                        .padding(.top, 4)
                }
                ForEach(store.nightGroups) { group in
                    groupTile(for: group)
                }
            }
            .padding(.horizontal, AppLayout.screenPadding)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.hidden)
    }

    private func friendTile(for entry: AppStore.TonightEntry) -> some View {
        Button { onFriendPostTap(entry.profile.id) } label: {
            VStack(spacing: 4) {
                AvatarView(avatar: entry.profile.avatar, size: 48)
                    .padding(3)
                    .overlay(Circle().strokeBorder(accent, lineWidth: 2))
                VerifiedProfileLabel(profile: entry.profile, spacing: 1, badgeSize: 8, badgeOffsetY: -0.35) {
                    Text(entry.isViewer ? "You" : entry.profile.displayName.firstName)
                        .font(AppTypography.metadataEmphasis)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                if let lastPosted = entry.lastPostedAt {
                    Text(Self.compactTimeAgo(from: lastPosted, now: clock))
                        .font(AppTypography.chipSmall)
                        .foregroundStyle(AppTheme.softText)
                        .lineLimit(1)
                }
            }
            .frame(width: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(entry.isViewer ? "Your" : entry.profile.displayName + "'s") posts tonight")
        .accessibilityValue("\(entry.postsTonightCount) posts")
        .accessibilityHint("Shows all posts from this night")
    }

    private func groupTile(for group: NightGroup) -> some View {
        let avatars = Array(store.groupMembers(for: group).prefix(3).map(\.avatar))
        let postCount = store.groupPostCount(for: group)
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)

        return Button { onGroupTap(group) } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle().strokeBorder(postCount > 0 ? accent : AppTheme.line, lineWidth: 2)
                    if avatars.isEmpty {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(AppTheme.softText)
                    } else {
                        ForEach(Array(avatars.enumerated()), id: \.offset) { index, avatar in
                            AvatarView(avatar: avatar, size: avatars.count == 1 ? 48 : 30)
                                .offset(groupAvatarOffset(index: index, total: avatars.count))
                                .zIndex(Double(avatars.count - index))
                        }
                    }
                }
                .frame(width: 54, height: 54)
                Text(name.isEmpty ? "Group" : name)
                    .font(AppTypography.metadataEmphasis)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(postCount == 1 ? "1 post" : "\(postCount) posts")
                    .font(AppTypography.chipSmall)
                    .foregroundStyle(AppTheme.softText)
            }
            .frame(width: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func groupAvatarOffset(index: Int, total: Int) -> CGSize {
        switch (total, index) {
        case (1, _): return .zero
        case (2, 0): return CGSize(width: -8, height: -4)
        case (2, 1): return CGSize(width: 8, height: 4)
        case (_, 0): return CGSize(width: -8, height: -7)
        case (_, 1): return CGSize(width: 8, height: -7)
        default: return CGSize(width: 0, height: 8)
        }
    }

    static func compactTimeAgo(from date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case 0..<60: return "\(seconds)s ago"
        case 60..<3600: return "\(seconds / 60)m ago"
        case 3600..<86400: return "\(seconds / 3600)h ago"
        default: return "\(seconds / 86400)d ago"
        }
    }
}

private extension String {
    var firstName: String {
        split(separator: " ").first.map(String.init) ?? self
    }
}
