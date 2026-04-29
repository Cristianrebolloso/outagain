import SwiftUI

/// Stories-style horizontal strip that sits at the top of Home and
/// surfaces who's out tonight. This is intentionally an *activity*
/// strip — we show posts-tonight count and recency, never drink counts.
/// App Review guideline 1.4.3 (no encouragement of excessive alcohol
/// use) plus the broader product stance that Out Again rewards *showing
/// up*, not *consuming*.
///
/// Design choices worth documenting because they shape the incentive:
///
///   - **The number is the hero.** Every active tile renders a gold
///     count pill under the avatar. Ring-only signaling was too quiet
///     and hid the thing the strip is trying to motivate. A visible
///     count creates the social pulse that rewards the act of posting.
///
///   - **The viewer is not on the strip until they've posted.** The
///     tab bar already owns the create affordance in gold — a second
///     Post entry point (avatar tile with a plus) duplicates that and
///     weakens both surfaces. Absence of the viewer from the active
///     strip is a stronger incentive than a placeholder tile with a
///     "+" on it. Once they post, they rejoin the strip like anyone
///     else.
///
///   - **Inactive friends stay visible, dimmed.** Their tile shows a
///     muted ring and an em-dash in the count slot. The alternative —
///     hiding them — would mean the strip disappears on slow nights,
///     which erases the social weight that makes posting feel worth
///     it. Keeping them present, just quiet, is the compromise.
///
/// Interaction model:
///   - Active friend tile → their latest tonight post (the viewer's
///     interest is in the moment, not the profile history).
///   - Inactive friend tile → their profile (there's no moment to
///     open, so the profile is the sensible fallback).
///   - Viewer's own tile, when present → same as active friend
///     (surfaces their latest moment).
struct TonightActivityStrip: View {
    @Environment(AppStore.self) private var store

    /// Closure invoked when the viewer taps a friend tile that has posts
    /// tonight. Passes the author's profile ID so the host can look up
    /// all of that user's tonight posts — not just the latest one.
    var onFriendPostTap: (UUID) -> Void
    /// Closure invoked when the viewer taps a friend tile with no
    /// post tonight — routes to that friend's profile. Same ownership
    /// rationale as above.
    var onFriendProfileTap: (UserProfile) -> Void
    /// Invoked when the user taps the "Create Group" button.
    var onCreateGroupTap: () -> Void = {}
    /// Invoked when the user taps an existing group tile.
    var onGroupTap: (NightGroup) -> Void = { _ in }

    /// Drives the time-ago labels so "4m" ticks to "5m" while the
    /// viewer has Home open. Re-bound every 30 seconds, which is
    /// fine-grained enough that no label is ever more than 30s stale
    /// and coarse enough to avoid needless view invalidation. Also
    /// feeds the bucket/sort calculation indirectly by prompting a
    /// re-read of `store.tonightEntries` on each tick — if a friend
    /// crosses the 30-minute just-posted threshold while Home is open,
    /// the strip reorders without needing a store mutation.
    @Environment(\.appAccent) private var accent
    @State private var clock: Date = .now

    private var entries: [AppStore.TonightEntry] { store.tonightEntries }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    // Group tiles appear before individual friend tiles.
                    // Existing groups first, then the create button.
                    ForEach(store.nightGroups) { group in
                        groupTile(for: group)
                    }

                    createGroupButton

                    // Divider between group cluster and friends, only when
                    // groups exist so the strip doesn't gain visual weight
                    // when empty.
                    if !store.nightGroups.isEmpty {
                        Rectangle()
                            .fill(AppTheme.line)
                            .frame(width: 1, height: 48)
                            .padding(.horizontal, 2)
                    }

                    ForEach(entries) { entry in
                        tile(for: entry)
                    }
                }
                // Leading 20pt aligns tiles with the rest of the feed content.
                // Trailing 20pt gives the last tile breathing room so its
                // avatar ring is never clipped by the screen edge.
                .padding(.leading, 20)
                .padding(.trailing, 20)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
        }
        .task {
            // 30-second heartbeat keeps time-ago labels fresh and lets
            // the bucketed sort reflow when someone crosses the
            // just-posted boundary. Task cancellation handles tab
            // switches — the loop dies when Home unmounts.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                clock = .now
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Tonight")
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(.white)

            if store.hasAnyFriendPostedTonight {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                    .opacity(0.9)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - Tiles

    @ViewBuilder
    private func tile(for entry: AppStore.TonightEntry) -> some View {
        Button {
            handleTap(on: entry)
        } label: {
            VStack(spacing: 4) {
                avatarRing(for: entry)
                    .overlay(alignment: .bottom) {
                        // Anchor the pill to the avatar's bottom
                        // edge and translate it down by roughly
                        // half its height so it sits *across* the
                        // ring instead of on top of the face.
                        // Same visual grammar as an app-icon
                        // badge: reads as "attached to this
                        // identity" without covering the portrait.
                        if entry.hasPostedTonight {
                            countPill(for: entry)
                                .offset(y: 10)
                        }
                    }
                    // Reserve the overhang so the time-ago label
                    // (or em-dash) below has a stable baseline
                    // across active and inactive tiles.
                    .padding(.bottom, 10)

                Text(entry.isViewer ? "You" : entry.profile.displayName.firstName)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(entry.hasPostedTonight ? .white : AppTheme.softText)
                    .lineLimit(1)
                    .frame(maxWidth: 68)
                    .minimumScaleFactor(0.8)

                if entry.hasPostedTonight, let lastPosted = entry.lastPostedAt {
                    Text(Self.compactTimeAgo(from: lastPosted, now: clock))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent.opacity(0.88))
                        .lineLimit(1)
                } else {
                    Text("—")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.softText.opacity(0.5))
                }
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Group tiles

    /// Compact tile for an existing NightGroup. Renders a stacked avatar pile
    /// (up to 3 members) with the aggregate post count as the hero number,
    /// matching the visual grammar of individual friend tiles.
    private func groupTile(for group: NightGroup) -> some View {
        let members = store.groupMembers(for: group)
        let postCount = store.groupPostCount(for: group)
        let avatars = members.prefix(3).map(\.avatar)

        return Button { onGroupTap(group) } label: {
            VStack(spacing: 4) {
                ZStack {
                    // Multi-avatar stack within the ring
                    Circle()
                        .strokeBorder(postCount > 0 ? accent : AppTheme.line, lineWidth: postCount > 0 ? 2.5 : 1)
                        .frame(width: 66, height: 66)

                    groupAvatarStack(avatars: Array(avatars))
                        .opacity(postCount > 0 ? 1 : 0.55)
                }
                .overlay(alignment: .bottom) {
                    if postCount > 0 {
                        groupCountPill(postCount: postCount)
                            .offset(y: 10)
                    }
                }
                .padding(.bottom, postCount > 0 ? 10 : 0)

                let trimmedName = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
                // Primary label: user's name if they gave one, otherwise "Group"
                Text(trimmedName.isEmpty ? "Group" : trimmedName)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(postCount > 0 ? .white : AppTheme.softText)
                    .lineLimit(1)
                    .frame(maxWidth: 68)
                    .minimumScaleFactor(0.8)

                // Sub-label: only show "Group" tag when a custom name exists,
                // otherwise show the time-ago / dash like friend tiles do.
                if !trimmedName.isEmpty {
                    Text("Group")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent.opacity(0.88))
                } else {
                    Text(postCount > 0 && group.createdAt > Date.distantPast
                         ? TonightActivityStrip.compactTimeAgo(from: group.createdAt)
                         : "—")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(postCount > 0 ? accent.opacity(0.88) : AppTheme.softText.opacity(0.5))
                }
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
    }

    private func groupAvatarStack(avatars: [AvatarStyle]) -> some View {
        let size: CGFloat = 52
        let overlap: CGFloat = 16

        return ZStack {
            ForEach(Array(avatars.enumerated()), id: \.offset) { index, avatar in
                AvatarView(avatar: avatar, size: size * 0.62)
                    .offset(groupAvatarOffset(index: index, total: avatars.count))
                    .zIndex(Double(avatars.count - index))
            }
        }
        .frame(width: size, height: size)
    }

    private func groupAvatarOffset(index: Int, total: Int) -> CGSize {
        switch (total, index) {
        case (1, _):
            return .zero
        case (2, 0):
            return CGSize(width: -9, height: -4)
        case (2, 1):
            return CGSize(width: 9, height: 4)
        case (_, 0):
            return CGSize(width: -10, height: -8)
        case (_, 1):
            return CGSize(width: 10, height: -8)
        default:
            return CGSize(width: 0, height: 8)
        }
    }

    private func groupCountPill(postCount: Int) -> some View {
        HStack(spacing: 3) {
            Text("\(postCount)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
            Text(postCount == 1 ? "post" : "posts")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.black.opacity(0.72))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(accent, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
    }

    /// The "Create Group" entry point. Renders as a dotted-circle tile that
    /// reads as a placeholder/invite — visually adjacent to the friend tiles
    /// but immediately distinct as an action rather than a person.
    private var createGroupButton: some View {
        Button { onCreateGroupTap() } label: {
            VStack(spacing: 4) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                        )
                        .foregroundStyle(accent.opacity(0.55))
                        .frame(width: 66, height: 66)

                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(accent.opacity(0.85))
                }
                .padding(.bottom, 0)

                Text("Create\nGroup")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(accent.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: 68)
                    .foregroundStyle(accent.opacity(0.65))
            }
            .frame(width: 72)
        }
        .buttonStyle(.plain)
    }

    /// The count pill is the hero element on every active tile.
    /// Now rendered as a compact capsule that overlays the bottom
    /// edge of the avatar (see `tile(for:)`), so this view is just
    /// the pill itself — the time-ago label lives on its own line
    /// below the avatar composite and is rendered by the tile.
    /// Legibility against arbitrary avatar photos is handled by
    /// the gold fill + dark hairline stroke, which gives the pill
    /// enough contrast against both light and dark portraits.
    private func countPill(for entry: AppStore.TonightEntry) -> some View {
        HStack(spacing: 3) {
            Text("\(entry.postsTonightCount)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(.black)
            Text(entry.postsTonightCount == 1 ? "post" : "posts")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.black.opacity(0.72))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(accent, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
    }

    /// Produces "12s ago", "4m ago", "2h ago", "1d ago" — still
    /// compact enough to fit under a 72pt-wide tile without
    /// wrapping. Appending "ago" adds 4 characters but meaningfully
    /// improves comprehension: "4m" read cold can scan as "4
    /// minutes of video" or similar; "4m ago" is unambiguous.
    /// Still cheaper than RelativeDateTimeFormatter ("4 minutes
    /// ago") which eats 3x the width and renders "ago" inconsistently
    /// across locales. `now` is injected so callers can drive
    /// re-renders via a ticking state variable.
    static func compactTimeAgo(from date: Date, now: Date = .now) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case 0..<60:
            return "\(seconds)s ago"
        case 60..<3600:
            return "\(seconds / 60)m ago"
        case 3600..<86400:
            return "\(seconds / 3600)h ago"
        default:
            return "\(seconds / 86400)d ago"
        }
    }

    @ViewBuilder
    private func avatarRing(for entry: AppStore.TonightEntry) -> some View {
        let avatarSize: CGFloat = 60
        let ringInset: CGFloat = 3

        ZStack {
            // Ring: gold if they've posted tonight, muted hairline
            // otherwise. No plus/placeholder treatment — the viewer's
            // tile only appears on the strip once they've posted, and
            // the bottom-bar Post button owns the create affordance.
            if entry.hasPostedTonight {
                Circle()
                    .strokeBorder(accent, lineWidth: 2.5)
                    .frame(width: avatarSize + ringInset * 2, height: avatarSize + ringInset * 2)
            } else {
                Circle()
                    .strokeBorder(AppTheme.line, lineWidth: 1)
                    .frame(width: avatarSize + ringInset * 2, height: avatarSize + ringInset * 2)
            }

            AvatarView(avatar: entry.profile.avatar, size: avatarSize)
                .opacity(entry.hasPostedTonight ? 1 : 0.55)
        }
        .frame(width: avatarSize + ringInset * 2, height: avatarSize + ringInset * 2)
    }

    // MARK: - Tap routing

    private func handleTap(on entry: AppStore.TonightEntry) {
        if entry.hasPostedTonight {
            // Pass the author ID — the host resolves all tonight posts
            // for that user so every post shows up in the sheet, not
            // just the single latest one.
            onFriendPostTap(entry.profile.id)
        } else {
            onFriendProfileTap(entry.profile)
        }
    }
}

private extension String {
    /// Displayed first-name only to keep the tile narrow. Falls back
    /// to the whole string if there's no space, which is fine for
    /// single-word display names.
    var firstName: String {
        split(separator: " ").first.map(String.init) ?? self
    }
}
