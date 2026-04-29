import MapKit
import SwiftUI
import UIKit

struct MomentPostCard: View {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions

    let post: MomentPost
    var isFocused = false
    var onCommentTap: () -> Void = {}
    /// Called when the viewer taps the author avatar or name. The host
    /// decides how to present the friend profile — the home feed pushes
    /// onto its NavigationStack, the moment detail sheet presents
    /// modally — so we stay agnostic here. Default is a no-op for hosts
    /// that haven't wired this yet (e.g. previews).
    var onAuthorTap: (UserProfile) -> Void = { _ in }

    @State private var isSavingToCameraRoll = false
    @State private var didSaveToCameraRoll = false
    @State private var saveErrorMessage: String?
    @State private var isConfirmingDelete = false
    @State private var isConfirmingReport = false
    @State private var reportMessage: String?
    @State private var reactorSheetKind: ReactionKind?
    @State private var isTaggedFriendsSheetPresented = false
    /// Reverse-geocoded locality for posts with a coordinate but no venue.
    /// Populated once on appear; nil until resolved or if geocoding fails.
    @State private var resolvedLocality: String?

    private let cameraRollSaver = CameraRollSaver()

    private var livePost: MomentPost {
        store.posts.first(where: { $0.id == post.id }) ?? post
    }

    private var cheersCount: Int {
        livePost.reactions.first(where: { $0.kind == .cheers })?.count ?? 0
    }

    private var locationTitle: String? {
        if let venue = livePost.venue {
            return venue.name
        }

        if livePost.location != nil {
            return resolvedLocality ?? "Current location"
        }

        return nil
    }

    private var locationIcon: String {
        livePost.venue == nil ? "location.fill" : "mappin.and.ellipse"
    }

    private var distanceFromViewerLabel: String? {
        livePost.distance(from: permissions.currentLocation)?.milesAwayLabel
    }

    private var canSaveToCameraRoll: Bool {
        livePost.media.photoData != nil || livePost.media.remotePhotoURL != nil
    }

    private var isPostLiked: Bool {
        livePost.viewerReactionKinds.contains(.cheers)
    }

    /// True when the viewer authored this post — used to gate the delete
    /// affordance in the overflow menu. Matches the server-side RLS rule
    /// so the UI never offers an action the backend would reject.
    private var isViewersOwnPost: Bool {
        guard let viewerID = store.viewer?.id else { return false }
        return livePost.author.id == viewerID
    }

    private var commentActionTitle: String {
        livePost.commentCount == 0 ? "Comment" : "\(livePost.commentCount)"
    }

    private var likeActionTitle: String {
        cheersCount == 0 ? "Like" : "\(cheersCount)"
    }

    @Environment(\.appAccent) private var accent

    private var metadataTint: Color { accent }

    // ── Photo + header overlay ─────────────────────────────────────────────

    /// Full-width photo at its natural aspect ratio, with the author header
    /// floating over the top. No fixed height — the photo sizes itself via
    /// .fit so portrait, landscape, and square shots all display correctly.
    @ViewBuilder
    private var photoWithHeaderOverlay: some View {
        MomentMediaView(media: livePost.media)
            .overlay(alignment: .top) {
                // Gradient scrim so white text stays legible on bright photos
                LinearGradient(
                    colors: [.black.opacity(0.60), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
            }
            .overlay(alignment: .top) {
                postHeaderRow
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            }
            .overlay(alignment: .bottomLeading) {
                // Soft gradient scrim behind the pills only — no bar, no background
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.50)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 90)

                    drinkStrip
                        .padding(.horizontal, 14)
                        .padding(.bottom, 14)
                }
            }
    }

    /// Drink strip shown at the bottom of the photo.
    /// Each card shows the cumulative nightly order *through that post*,
    /// so the first post shows the first drink, the second shows the first
    /// two drinks, and so on.
    @ViewBuilder
    private var drinkStrip: some View {
        let counts = store.nightlyDrinkCounts(for: livePost.author.id, through: livePost.id)

        if counts.count > 1 || counts.first?.count ?? 0 > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(counts, id: \.drink.id) { entry in
                        drinkPill(
                            drink: entry.drink,
                            label: entry.count > 1
                                ? "\(entry.count) \(pluralized(entry.drink.name))"
                                : entry.drink.name
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            drinkPill(drink: livePost.drink, label: livePost.drink.name)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Appends "s" only when the name doesn't already end with one.
    /// Handles "Dos Equis" → "Dos Equis", "Diet Coke" → "Diet Cokes",
    /// "Whiskey" → "Whiskeys" (intentional — the goal is readable, not
    /// linguistically perfect irregular plurals like "Whiskies").
    private func pluralized(_ name: String) -> String {
        name.lowercased().hasSuffix("s") ? name : "\(name)s"
    }

    private func drinkPill(drink: DrinkTag, label: String) -> some View {
        // Posts store drinks denormalised — the embedded DrinkTag has no
        // imageName because the backend doesn't persist that field. Resolve
        // the live catalog entry by name so asset-catalog images (beer,
        // shotglass) are shown instead of falling back to an SF Symbol.
        let resolvedDrink = store.drinks.first(where: {
            $0.name.localizedCaseInsensitiveCompare(drink.name) == .orderedSame
        }) ?? drink

        return HStack(spacing: 8) {
            DrinkIconView(drink: resolvedDrink, size: 22)
            Text(label)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
    }

    /// Header row: avatar + name/tags on the left, time badge + 3-dot on the right.
    private var postHeaderRow: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar taps the author directly — no menu needed for the image
            Button {
                onAuthorTap(livePost.author)
            } label: {
                AvatarView(avatar: livePost.author.avatar, size: 54)
            }
            .buttonStyle(.plain)

            // Author name + tagged-friend pills stacked vertically
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    onAuthorTap(livePost.author)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(livePost.author.displayName)
                            .font(.system(size: 26, weight: .bold, design: .serif))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                        Text(ActivityView.coarseRelativeLabel(for: livePost.createdAt))
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.60))
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(-1)
                    }
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                }
                .buttonStyle(.plain)

                if !livePost.taggedFriends.isEmpty {
                    taggedFriendPills
                }

                if let path = livePost.connectionPath {
                    connectionChip(path, icon: "arrow.triangle.branch")
                }
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            Menu {
                overflowMenu
            } label: {
                Circle()
                    .fill(.white.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "ellipsis")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    )
                    .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .contentShape(Circle())
            }
            .glassEffect(.regular.interactive(), in: .circle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Tagged-friend display. One friend → single pill tapping to their
    /// profile. Two or more → a single collapsed "+N with friends" pill
    /// that opens a sheet listing everyone. This keeps the header row
    /// clean regardless of how many people were tagged.
    private var taggedFriendPills: some View {
        let friends = livePost.taggedFriends

        return Group {
            if friends.count == 1, let friend = friends.first {
                // Single friend — tap straight through to their profile
                Button {
                    onAuthorTap(friend)
                } label: {
                    HStack(spacing: 6) {
                        AvatarView(avatar: friend.avatar, size: 22)
                        Text(friend.displayName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 11)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            } else {
                // Multiple friends — collapsed pill, tap opens sheet
                Button {
                    isTaggedFriendsSheetPresented = true
                } label: {
                    HStack(spacing: 6) {
                        // Stack the first two avatars with slight overlap
                        ZStack(alignment: .leading) {
                            ForEach(Array(friends.prefix(2).enumerated()), id: \.offset) { index, friend in
                                AvatarView(avatar: friend.avatar, size: 22)
                                    .offset(x: CGFloat(index) * 13)
                            }
                        }
                        .frame(width: friends.count > 1 ? 35 : 22, height: 22)

                        Text("+\(friends.count) friends")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 11)
                    .padding(.vertical, 5)
                    .background(.white.opacity(0.10), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    var body: some View {
        let tint = Color(hex: livePost.media.primaryHex)

        VStack(spacing: 0) {
            // ── Full-width photo with header overlaid at the top ──────────
            photoWithHeaderOverlay

            // ── Footer panel ──────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                actionBar

                if let preview = livePost.comments.first {
                    CommentPreview(comment: preview)
                } else if !livePost.caption.isEmpty {
                    Text(livePost.caption)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(3)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.white.opacity(isFocused ? 0.06 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: tint.opacity(isFocused ? 0.18 : 0.08), radius: 20, y: 10)
        .confirmationDialog(
            "Delete this post?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete post", role: .destructive) {
                store.deletePost(livePost)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes it for everyone. Reactions and comments go with it.")
        }
        .confirmationDialog(
            "Report this post?",
            isPresented: $isConfirmingReport,
            titleVisibility: .visible
        ) {
            Button("Report post", role: .destructive) {
                submitReport()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("We'll flag it for review.")
        }
        .alert("Couldn't save photo", isPresented: saveErrorBinding) {
            Button("OK", role: .cancel) {
                saveErrorMessage = nil
            }
        } message: {
            Text(saveErrorMessage ?? "Try again in a moment.")
        }
        .alert("Report status", isPresented: reportAlertBinding) {
            Button("OK", role: .cancel) {
                reportMessage = nil
            }
        } message: {
            Text(reportMessage ?? "We'll take a look.")
        }
        .sheet(isPresented: $isTaggedFriendsSheetPresented) {
            TaggedFriendsSheet(
                friends: livePost.taggedFriends,
                onSelectFriend: { friend in
                    isTaggedFriendsSheetPresented = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                        onAuthorTap(friend)
                    }
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $reactorSheetKind) { kind in
            ReactorListSheet(
                postID: livePost.id,
                kind: kind,
                onSelectReactor: { profile in
                    reactorSheetKind = nil
                    // Same two-step hand-off the profile tab uses to
                    // transition between sheets on iPhone: dismiss the
                    // current one and wait a beat before surfacing the
                    // next. Without the delay the presentation silently
                    // no-ops because SwiftUI won't stack sheets.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
                        onAuthorTap(profile)
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .task(id: livePost.id) {
            // Reverse-geocode once per post to resolve "Current location" to
            // "Waco, TX" style locality. Only runs when the post has a raw
            // coordinate but no venue — venues already have a name.
            guard livePost.venue == nil,
                  let coordinate = livePost.location?.coordinate
            else { return }

            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let geocoder = CLGeocoder()
            if let placemark = try? await geocoder.reverseGeocodeLocation(location).first {
                let city = placemark.locality
                let state = placemark.administrativeArea
                if let city, let state {
                    resolvedLocality = "\(city), \(state)"
                } else if let city {
                    resolvedLocality = city
                }
            }
        }
    }

    private var metadataSection: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.fill")
                .font(.system(size: 14, weight: .bold))
            Text(livePost.createdAt.minuteGranularityRelative)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.18), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(2)
    }

    private var actionBar: some View {
        HStack(spacing: 18) {
            Button(action: togglePostLike) {
                PostActionLabel(
                    icon: isPostLiked ? "heart.fill" : "heart",
                    title: likeActionTitle,
                    isActive: isPostLiked
                )
            }
            .buttonStyle(.plain)
            // Long-press opens the reactor sheet. We gate on count > 0
            // so a press on an empty state doesn't open an empty sheet.
            // The ReactionKind is carried into the sheet via state so
            // one day we can support non-cheers reactions with their own
            // lists; today cheers is the only surfaced kind.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.35)
                    .onEnded { _ in
                        guard cheersCount > 0 else { return }
                        reactorSheetKind = .cheers
                    }
            )

            Button(action: onCommentTap) {
                PostActionLabel(
                    icon: "message",
                    title: commentActionTitle,
                    isActive: false
                )
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
    }

    private var saveErrorBinding: Binding<Bool> {
        Binding(
            get: { saveErrorMessage != nil },
            set: { isPresented in
                if !isPresented {
                    saveErrorMessage = nil
                }
            }
        )
    }

    private var reportAlertBinding: Binding<Bool> {
        Binding(
            get: { reportMessage != nil },
            set: { isPresented in
                if !isPresented {
                    reportMessage = nil
                }
            }
        )
    }

    private func togglePostLike() {
        withAnimation(.snappy(duration: 0.22)) {
            store.addReaction(.cheers, to: livePost)
        }
    }

    @ViewBuilder
    private var overflowMenu: some View {
        // Save photo — first so it's the easiest action to reach
        Button(action: saveToCameraRoll) {
            Label(saveMenuTitle, systemImage: saveMenuSymbol)
        }
        .disabled(isSavingToCameraRoll || !canSaveToCameraRoll)

        // Location — venue name or reverse-geocoded city, opens Maps on tap
        Button(action: openLocationInMaps) {
            Label(locationTitle ?? "No location", systemImage: locationIcon)
        }
        .disabled(livePost.resolvedCoordinate == nil)

        // Distance from viewer (only shown when location permission is granted
        // and the post has a coordinate)
        if let distanceFromViewerLabel {
            Button {} label: {
                Label(distanceFromViewerLabel, systemImage: "location.north.line.fill")
            }
            .disabled(true)
        }

        if !isViewersOwnPost {
            Divider()

            Button {
                isConfirmingReport = true
            } label: {
                Label("Report post", systemImage: "flag")
            }
        }

        // Delete appears last and only for the viewer's own posts.
        if isViewersOwnPost {
            Button(role: .destructive) {
                isConfirmingDelete = true
            } label: {
                Label("Delete post", systemImage: "trash")
            }
        }
    }

    private func saveToCameraRoll() {
        guard !isSavingToCameraRoll else { return }
        let media = livePost.media

        isSavingToCameraRoll = true
        saveErrorMessage = nil

        Task {
            do {
                try await cameraRollSaver.save(media: media)
                await MainActor.run {
                    isSavingToCameraRoll = false
                    withAnimation(.snappy(duration: 0.22)) {
                        didSaveToCameraRoll = true
                    }
                }

                try? await Task.sleep(for: .seconds(1.6))

                await MainActor.run {
                    withAnimation(.snappy(duration: 0.22)) {
                        didSaveToCameraRoll = false
                    }
                }
            } catch {
                await MainActor.run {
                    isSavingToCameraRoll = false
                    saveErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func openLocationInMaps() {
        guard let coordinate = livePost.resolvedCoordinate else { return }

        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let address = locationTitle.flatMap { MKAddress(fullAddress: $0, shortAddress: nil) }
        let mapItem = MKMapItem(location: location, address: address)
        mapItem.name = livePost.venue?.name ?? "\(livePost.author.displayName)'s location"
        mapItem.openInMaps()
    }

    private func submitReport() {
        let postToReport = livePost

        Task { @MainActor in
            do {
                try await store.reportPost(postToReport)
                reportMessage = "Thanks. We'll review this post."
            } catch {
                reportMessage = error.localizedDescription
            }
        }
    }

    private var saveMenuTitle: String {
        if isSavingToCameraRoll {
            return "Saving..."
        }

        return didSaveToCameraRoll ? "Saved to Camera Roll" : "Save to Camera Roll"
    }

    private var saveMenuSymbol: String {
        if isSavingToCameraRoll {
            return "arrow.down.circle"
        }

        return didSaveToCameraRoll ? "checkmark" : "arrow.down.to.line"
    }

    private func metadataBadge(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))

            Text(title)
                .lineLimit(1)
        }
        .font(.system(.footnote, design: .rounded, weight: .semibold))
        .foregroundStyle(metadataTint)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.24), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }

    private func connectionChip(_ title: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
            Text(title)
        }
        .font(.system(.caption, design: .rounded, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.black.opacity(0.24), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 1))
        .glassEffect(
            .regular
                .tint(Color(hex: livePost.media.primaryHex).opacity(0.16))
                .interactive(),
            in: .capsule
        )
    }
}

private struct PostActionLabel: View {
    let icon: String
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .symbolEffect(.bounce, value: isActive)

            Text(title)
                .contentTransition(.numericText())
        }
        .font(.system(size: 15, weight: .semibold, design: .rounded))
        .foregroundStyle(isActive ? .white : AppTheme.softText)
        .animation(.snappy(duration: 0.22), value: title)
        .animation(.snappy(duration: 0.22), value: isActive)
    }
}

private struct CommentPreview: View {
    let comment: Comment

    var body: some View {
        HStack(spacing: 10) {
            // Home-feed previews stay text/media-only. Do not surface the
            // comment author's avatar here, even for photo or GIF replies.
            if comment.kind == .photo {
                if comment.hasPhotoAttachment {
                    HStack(spacing: 10) {
                        CommentPhotoThumbnail(comment: comment, size: 34)
                        previewLine(
                            username: comment.author.displayName,
                            detail: photoPreviewDetail
                        )
                            .lineLimit(1)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.72))
                        previewLine(
                            username: comment.author.displayName,
                            detail: photoPreviewDetail
                        )
                    }
                }
            } else if comment.kind == .gif {
                HStack(spacing: 6) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                    previewLine(
                        username: comment.author.displayName,
                        detail: gifPreviewDetail
                    )
                    .lineLimit(1)
                }
            } else {
                previewLine(
                    username: comment.author.displayName,
                    detail: textPreviewDetail
                )
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func previewLine(username: String, detail: String) -> some View {
        HStack(spacing: 0) {
            Text(username)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))
            Text(detail)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
        }
    }

    private var textPreviewDetail: String {
        if let replyToDisplayName = comment.replyToDisplayName {
            return " to \(replyToDisplayName): \(comment.text)"
        }

        return ": \(comment.text)"
    }

    private var photoPreviewDetail: String {
        if let replyToDisplayName = comment.replyToDisplayName {
            return " replied to \(replyToDisplayName) with a photo"
        }

        return " replied with a photo"
    }

    private var gifPreviewDetail: String {
        if let replyToDisplayName = comment.replyToDisplayName {
            return " replied to \(replyToDisplayName) with a GIF"
        }

        return " sent a GIF: \(comment.text)"
    }
}

/// Presented on long-press of the Like count. Shows the list of people
/// who reacted to this post with the given kind. If the reactor profile
/// list wasn't hydrated by the feed decoder (can happen for aggregate
/// counts from cached summaries, or in the mock-data seed), we fall back
/// to a single "N people reacted" line so the sheet still delivers on
/// the affordance — just without the row-level identity.
private struct ReactorListSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent

    let postID: UUID
    let kind: ReactionKind
    let onSelectReactor: (UserProfile) -> Void

    private var currentSummary: ReactionSummary? {
        store.posts
            .first(where: { $0.id == postID })?
            .reactions
            .first(where: { $0.kind == kind })
    }

    private var totalCount: Int {
        currentSummary?.count ?? 0
    }

    private var reactors: [UserProfile] {
        currentSummary?.reactors ?? []
    }

    private var hasLoadedFullList: Bool {
        store.posts
            .first(where: { $0.id == postID })?
            .fullyLoadedReactionKinds
            .contains(kind) ?? false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if totalCount > 0 && reactors.isEmpty && !hasLoadedFullList {
                        NightPanel(cornerRadius: 24, padding: 18) {
                            HStack(spacing: 12) {
                                ProgressView()
                                    .tint(accent)
                                Text("Loading people who reacted…")
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                    } else if reactors.isEmpty {
                        NightPanel(cornerRadius: 24, padding: 18) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(totalCount) \(totalCount == 1 ? "person" : "people") reacted")
                                    .font(.system(.headline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text("Individual names will appear once this post syncs.")
                                    .font(.system(.subheadline, design: .rounded))
                                    .foregroundStyle(AppTheme.softText)
                            }
                        }
                    } else {
                        ForEach(reactors) { profile in
                            Button {
                                onSelectReactor(profile)
                            } label: {
                                reactorRow(profile)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground())
            .navigationTitle(sheetTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accent)
                }
            }
        }
        .task(id: kind) {
            await store.ensureReactorsLoaded(for: kind, inPostID: postID)
        }
    }

    private var sheetTitle: String {
        switch kind {
        case .cheers: return "Likes"
        case .spark: return "Locked In"
        case .fire: return "Fire"
        }
    }

    private func reactorRow(_ profile: UserProfile) -> some View {
        HStack(spacing: 12) {
            AvatarView(avatar: profile.avatar, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text("@\(profile.username)")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(AppTheme.softText)
        }
        .padding(14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
    }
}

private struct TaggedFriendsSheet: View {
    @Environment(\.appAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    let friends: [UserProfile]
    let onSelectFriend: (UserProfile) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(friends) { friend in
                        Button {
                            onSelectFriend(friend)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(avatar: friend.avatar, size: 40)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friend.displayName)
                                        .font(.system(.headline, design: .rounded, weight: .semibold))
                                        .foregroundStyle(.white)
                                    Text("@\(friend.username)")
                                        .font(.system(.subheadline, design: .rounded))
                                        .foregroundStyle(AppTheme.softText)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(AppTheme.softText)
                            }
                            .padding(14)
                            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(AppTheme.line, lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Tagged Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accent)
                }
            }
        }
    }
}

private struct CommentPhotoThumbnail: View {
    let comment: Comment
    let size: CGFloat

    var body: some View {
        Group {
            if let photoData = comment.photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let remotePhotoURL = comment.remotePhotoURL {
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
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.white.opacity(0.06))
            .overlay(
                Image(systemName: "camera.fill")
                    .font(.system(size: size * 0.34, weight: .bold))
                    .foregroundStyle(AppTheme.softText)
            )
    }
}
