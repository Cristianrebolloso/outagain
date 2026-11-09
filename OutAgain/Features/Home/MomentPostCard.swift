import MapKit
import SwiftUI

struct MomentPostCard: View {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions

    let post: MomentPost
    var isFocused = false
    var usesLiveStoreUpdates = true
    var isPreview = false
    var onCommentTap: () -> Void = {}
    /// Called when the viewer taps the author avatar or name. The host
    /// decides how to present the friend profile — the home feed pushes
    /// onto its NavigationStack, the moment detail sheet presents
    /// modally — so we stay agnostic here. Default is a no-op for hosts
    /// that haven't wired this yet (e.g. previews).
    var onAuthorTap: (UserProfile) -> Void = { _ in }
    /// Opt-in continuity for the Activity post-to-comments transition.
    var detailTransition: Namespace.ID? = nil

    @State private var isSavingToCameraRoll = false
    @State private var didSaveToCameraRoll = false
    @State private var saveErrorMessage: String?
    @State private var isConfirmingReport = false
    @State private var isConfirmingDeletePost = false
    @State private var reportMessage: String?
    @State private var pendingDeletePost: MomentPost?
    @State private var reactorSheetKind: ReactionKind?
    @State private var isTaggedFriendsCardPresented = false
    @State private var isOverlayDismissalShieldPresented = false
    /// Reverse-geocoded locality for posts with a coordinate but no venue.
    /// Populated once on appear; nil until resolved or if geocoding fails.
    @State private var resolvedLocality: String?

    private let cameraRollSaver = CameraRollSaver()

    private var livePost: MomentPost {
        guard usesLiveStoreUpdates else { return post }
        return store.livePost(matching: post.id) ?? post
    }

    private var cheersCount: Int {
        livePost.reactions.first(where: { $0.kind == .cheers })?.count ?? 0
    }

    private var locationTitle: String? {
        if livePost.isSharedLocally == true { return resolvedLocality.map { "Local · \($0)" } ?? "Local · Approximate area" }
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

    private var canDeletePost: Bool {
        store.canDeletePost(livePost)
    }

    private var commentActionTitle: String {
        livePost.commentCount == 0 ? "Comment" : "\(livePost.commentCount)"
    }

    private var likeActionTitle: String {
        cheersCount == 0 ? "Like" : "\(cheersCount)"
    }

    private var recentCommentPreviews: [Comment] {
        let chronologicalComments = livePost.comments.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt < rhs.createdAt
        }
        return Array(chronologicalComments.prefix(2))
    }

    private var captionSummary: AttributedString {
        var author = AttributedString("\(livePost.author.displayName) ")
        author.font = AppTypography.feedCaptionAuthor

        var caption = AttributedString(livePost.caption)
        caption.font = AppTypography.callout

        return author + caption
    }

    @Environment(\.appAccent) private var accent

    private var metadataTint: Color { accent }
    private let drinkStripHorizontalInset: CGFloat = 14

    // ── Photo + header overlay ─────────────────────────────────────────────

    /// Full-width photo at its natural aspect ratio, with the author header
    /// floating over the top. No fixed height — the photo sizes itself via
    /// .fit so portrait, landscape, and square shots all display correctly.
    @ViewBuilder
    private var photoWithHeaderOverlay: some View {
        MomentMediaView(media: livePost.media)
            .modifier(ActivityPostMorph(namespace: detailTransition, postID: livePost.id, element: .photo))
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 2)
                    .onEnded {
                        likePostIfNeeded()
                    }
            )
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
                        // drinkStrip keeps 8pt internal vertical padding so
                        // Liquid Glass press states do not clip. A 6pt outer
                        // inset makes the visible pill edge land 14pt from
                        // the photo/footer edge, matching the left inset.
                        .padding(.bottom, 6)
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
            ScrollView(.horizontal) {
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
                .padding(.vertical, 8)
            }
            .contentMargins(.horizontal, drinkStripHorizontalInset, for: .scrollContent)
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .horizontalScrollEdgeFade(width: 56, tolerance: 1)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let drink = livePost.drink {
            drinkPill(drink: drink, label: drink.name)
                .padding(.horizontal, drinkStripHorizontalInset)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Appends "s" only when the name doesn't already end with one.
    /// Handles "Dos Equis" → "Dos Equis", "Diet Coke" → "Diet Cokes",
    /// "Drunk Cig" → "Drunk Cigs", etc.
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

        // Cap display at 70 characters then show the full text dynamically:
        // first try to shrink the font down to 76% before wrapping to a
        // second line, so short names stay one line and long ones wrap cleanly.
        let displayLabel = label.count > 70
            ? String(label.prefix(70)) + "…"
            : label

        return HStack(alignment: .center, spacing: 8) {
            DrinkIconView(drink: resolvedDrink, size: 22)
            Text(displayLabel)
                .font(AppTypography.controlLabel)
                .minimumScaleFactor(0.76)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // Primary glass — surface chrome on the post card.
        .primaryGlass(in: .capsule, interactive: true)
        .contentShape(Capsule())
    }

    /// Header row: avatar + name/tags on the left, time badge + 3-dot on the right.
    private var postHeaderRow: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar taps the author directly — no menu needed for the image
            Button {
                onAuthorTap(livePost.author)
            } label: {
                AvatarView(avatar: livePost.author.avatar, size: 50)
            }
            .buttonStyle(.plain)

            // Author name + tagged-friend pills stacked vertically
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    onAuthorTap(livePost.author)
                } label: {
                    HStack(alignment: .lastTextBaseline, spacing: 7) {
                        VerifiedProfileLabel(profile: livePost.author, spacing: 6, badgeSize: 18, badgeOffsetY: -1.5) {
                            Text(livePost.author.displayName)
                                .font(AppTypography.feedAuthor)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
                        }
                        .modifier(ActivityPostMorph(namespace: detailTransition, postID: livePost.id, element: .author))
                        Text(ActivityView.coarseRelativeLabel(for: livePost.createdAt))
                            .font(AppTypography.metadata)
                            .foregroundStyle(.white)
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

            if !isPreview {
                Menu {
                    overflowMenu
                } label: {
                    // Primary glass — surface chrome, not selection chrome.
                    Color.clear
                        .frame(width: 44, height: 44)
                        .overlay(
                            Image(systemName: "ellipsis")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                        )
                        .contentShape(Circle())
                        .primaryGlass(in: .circle, interactive: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Tagged-friend display. One friend → single pill tapping to their
    /// profile. Two or more → a single collapsed "+N friends" pill that
    /// opens an inline card listing everyone. This keeps the header row
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
                        VerifiedProfileLabel(profile: friend, spacing: 4, badgeSize: 10, badgeOffsetY: -0.5) {
                            Text(friend.displayName)
                                .font(AppTypography.pillSmall)
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 11)
                    .padding(.vertical, 5)
                    // Primary glass — surface chrome on the post card.
                    .primaryGlass(in: .capsule, interactive: true)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .contentShape(Capsule())
                .padding(.vertical, 4)
            } else {
                Button {
                    showTaggedFriendsCard()
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
                            .font(AppTypography.pillSmall)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .padding(.leading, 4)
                    .padding(.trailing, 11)
                    .padding(.vertical, 5)
                    // Primary glass — surface chrome on the post card.
                    .primaryGlass(in: .capsule, interactive: true)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .contentShape(Capsule())
                .padding(.vertical, 4)
                .accessibilityLabel("Tagged friends")
            }
        }
    }

    var body: some View {
        let tint = Color(hex: livePost.media.primaryHex)

        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // ── Full-width photo with header overlaid at the top ──────────
                photoWithHeaderOverlay

                // ── Footer panel ──────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    actionBar

                    if !livePost.caption.isEmpty || !recentCommentPreviews.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            // Keep the author's caption visible even after
                            // people start commenting on the post.
                            if !livePost.caption.isEmpty {
                                Text(captionSummary)
                                .foregroundStyle(.white)
                                .lineLimit(3)
                            }

                            if !recentCommentPreviews.isEmpty {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(recentCommentPreviews) { comment in
                                        CommentPreview(comment: comment)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    Rectangle()
                        .fill(.white.opacity(isFocused ? 0.018 : 0.012))
                        .glassEffect(.regular, in: .rect)
                        .opacity(isFocused ? 0.68 : 0.56)
                }
            }

            if let reactorSheetKind {
                reactorOverlay(for: reactorSheetKind)
                    .zIndex(1)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if isTaggedFriendsCardPresented {
                taggedFriendsOverlay(friends: livePost.taggedFriends)
                    .zIndex(2)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if isOverlayDismissalShieldPresented {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {}
                    .zIndex(3)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: PostPhotoFormat.cornerRadius, style: .continuous)
                .fill(.white.opacity(isFocused ? 0.06 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PostPhotoFormat.cornerRadius, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: PostPhotoFormat.cornerRadius, style: .continuous))
        .shadow(color: tint.opacity(isFocused ? 0.18 : 0.08), radius: 20, y: 10)
        .animation(.snappy(duration: 0.22), value: reactorSheetKind)
        .animation(.snappy(duration: 0.22), value: isTaggedFriendsCardPresented)
        .alert(
            "Report this post?",
            isPresented: $isConfirmingReport,
            actions: {
            Button("Report post", role: .destructive) {
                submitReport()
            }
            Button("Cancel", role: .cancel) {}
                .tint(.blue)
        }, message: {
            Text("We'll flag it for review.")
        })
        .alert(
            "Delete this post?",
            isPresented: $isConfirmingDeletePost,
            actions: {
            Button("Delete post", role: .destructive) {
                if let pendingDeletePost {
                    store.deletePost(pendingDeletePost)
                }
                pendingDeletePost = nil
            }
            Button("Cancel", role: .cancel) {
                pendingDeletePost = nil
            }
            .tint(.blue)
        }, message: {
            Text("This removes it for everyone. Reactions and comments go with it.")
        })
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
        .task(id: livePost.id) {
            // Reverse-geocode once per coordinate to resolve "Current location"
            // to "Waco, TX" style locality. Only runs when the post has a raw
            // coordinate but no venue — venues already have a name. Results
            // are cached on AppStore by rounded coordinate so a busy feed
            // (or scrolling past 30 cards) doesn't fire 30 redundant geocoder
            // round-trips — Apple throttles aggressive callers.
            guard !isPreview,
                  livePost.venue == nil,
                  let coordinate = livePost.location?.coordinate
            else { return }

            if let cached = store.cachedLocality(
                forLatitude: coordinate.latitude,
                longitude: coordinate.longitude
            ) {
                resolvedLocality = cached
                return
            }

            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            let geocoder = CLGeocoder()
            if let placemark = try? await geocoder.reverseGeocodeLocation(location).first {
                let city = placemark.locality
                let state = placemark.administrativeArea
                let formatted: String?
                if let city, let state {
                    formatted = "\(city), \(state)"
                } else if let city {
                    formatted = city
                } else {
                    formatted = nil
                }
                if let formatted {
                    resolvedLocality = formatted
                    store.storeResolvedLocality(
                        formatted,
                        forLatitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )
                }
            }
        }
        .modifier(PostCardPreviewInteraction(isPreview: isPreview, post: livePost))
    }

    private var metadataSection: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock.fill")
                .font(.system(size: 14, weight: .bold))
            Text(livePost.createdAt.minuteGranularityRelative)
                .font(AppTypography.button)
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
        ViewThatFits(in: .horizontal) {
            actionButtons()
            actionButtons(showsActionTitles: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionButtons(showsActionTitles: Bool = true) -> some View {
        HStack(spacing: 18) {
            PostActionLabel(
                icon: isPostLiked ? "heart.fill" : "heart",
                title: showsActionTitles || cheersCount > 0 ? likeActionTitle : nil,
                isActive: isPostLiked
            )
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.35)
                    .exclusively(before: TapGesture())
                    .onEnded { value in
                        switch value {
                        case .first(true):
                            showReactorCardIfAvailable()
                        case .second:
                            togglePostLike()
                        default:
                            break
                        }
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(isPostLiked ? "Unlike" : "Like")

            Button(action: onCommentTap) {
                PostActionLabel(
                    icon: "message",
                    title: showsActionTitles || livePost.commentCount > 0 ? commentActionTitle : nil,
                    isActive: false
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(livePost.commentCount == 0 ? "Comment" : "Open comments, \(livePost.commentCount) comments")
        }
    }

    private func reactorOverlay(for kind: ReactionKind) -> some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissReactorCard()
                }

            ReactorListCard(
                post: livePost,
                kind: kind,
                onDismiss: dismissReactorCard,
                onSelectReactor: { profile in
                    dismissReactorCard()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        onAuthorTap(profile)
                    }
                }
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func taggedFriendsOverlay(friends: [UserProfile]) -> some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissTaggedFriendsCard()
                }

            TaggedFriendsCard(
                friends: friends,
                onDismiss: dismissTaggedFriendsCard,
                onSelectFriend: { friend in
                    dismissTaggedFriendsCard()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                        onAuthorTap(friend)
                    }
                }
            )
            .padding(.horizontal, 10)
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func dismissReactorCard() {
        armOverlayDismissalShield()
        withAnimation(.snappy(duration: 0.2)) {
            reactorSheetKind = nil
        }
    }

    private func showReactorCardIfAvailable() {
        guard cheersCount > 0 else { return }
        withAnimation(.snappy(duration: 0.22)) {
            isOverlayDismissalShieldPresented = false
            isTaggedFriendsCardPresented = false
            reactorSheetKind = .cheers
        }
    }

    private func showTaggedFriendsCard() {
        guard livePost.taggedFriends.count > 1 else { return }
        withAnimation(.snappy(duration: 0.22)) {
            isOverlayDismissalShieldPresented = false
            reactorSheetKind = nil
            isTaggedFriendsCardPresented = true
        }
    }

    private func dismissTaggedFriendsCard() {
        armOverlayDismissalShield()
        withAnimation(.snappy(duration: 0.2)) {
            isTaggedFriendsCardPresented = false
        }
    }

    private func armOverlayDismissalShield() {
        isOverlayDismissalShieldPresented = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
            isOverlayDismissalShieldPresented = false
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

    private func likePostIfNeeded() {
        guard !isPostLiked else { return }
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

        // Location — only shown when the post has a coordinate. No fallback
        // "No location" label; if there's nothing to show, the row is omitted.
        if livePost.resolvedCoordinate != nil {
            Button(action: openLocationInMaps) {
                Label(locationTitle ?? "Current location", systemImage: locationIcon)
            }
        }

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

        // Delete appears last for posts the viewer can moderate.
        if canDeletePost {
            Button(role: .destructive) {
                pendingDeletePost = livePost
                isConfirmingDeletePost = true
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
        mapItem.name = livePost.isSharedLocally == true ? "Approximate area" : livePost.venue?.name ?? "\(livePost.author.displayName)'s location"
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
        .font(AppTypography.buttonFootnote)
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
        .font(AppTypography.metadataEmphasis)
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

/// Preserve the real card's appearance while replacing every interactive
/// descendant with a single informational accessibility element in previews.
private struct PostCardPreviewInteraction: ViewModifier {
    let isPreview: Bool
    let post: MomentPost

    @ViewBuilder
    func body(content: Content) -> some View {
        if isPreview {
            content
                .allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Post preview by \(post.author.displayName)")
                .accessibilityValue([post.drink?.name, post.caption.isEmpty ? nil : post.caption]
                    .compactMap { $0 }.joined(separator: ". "))
                .accessibilityAddTraits(.isImage)
        } else {
            content
        }
    }
}

private struct PostActionLabel: View {
    let icon: String
    let title: String?
    let isActive: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .symbolEffect(.bounce, value: isActive)

            if let title {
                Text(title)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .font(AppTypography.actionLabel)
        .foregroundStyle(isActive ? .white : AppTheme.softText)
        .fixedSize(horizontal: true, vertical: false)
        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
        .animation(.snappy(duration: 0.22), value: title)
        .animation(.snappy(duration: 0.22), value: isActive)
    }
}

private struct CommentPreview: View {
    @Environment(AppStore.self) private var store
    let comment: Comment

    var body: some View {
        // Home-feed comment previews are intentionally text-only. Photo and
        // GIF replies render the same name + descriptor line as text replies,
        // with no thumbnail and no leading media glyph — the feed card stays
        // visually quiet while still surfacing engagement. The full media
        // is visible by tapping into the post's comment thread.
        HStack(spacing: 10) {
            switch comment.kind {
            case .photo:
                previewLine(profile: comment.author, detail: photoPreviewDetail)
                    .lineLimit(1)
            case .gif:
                previewLine(profile: comment.author, detail: gifPreviewDetail)
                    .lineLimit(1)
            default:
                previewLine(profile: comment.author, detail: textPreviewDetail)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private func previewLine(profile: UserProfile, detail: String) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text(profile.displayName)
                .font(AppTypography.pill)
                .foregroundStyle(.white.opacity(0.96))

            if profile.isVerified || store.purchases.isPlusMember(profile.id) {
                VerifiedBadgeView(size: 10, isPlusMember: store.purchases.isPlusMember(profile.id))
            }

            Text(detail)
                .font(AppTypography.pillMedium)
                .foregroundStyle(.white.opacity(0.88))
        }
    }

    private var textPreviewDetail: String {
        return ": \(comment.text)"
    }

    private var photoPreviewDetail: String {
        return " replied with a photo"
    }

    private var gifPreviewDetail: String {
        return " replied with a GIF"
    }
}

/// Presented inline on long-press of the Like count. Shows the list of
/// people who reacted to this post with the given kind. If the reactor
/// profile list wasn't hydrated by the feed decoder (can happen for
/// aggregate counts from cached summaries, or in the mock-data seed), we
/// fall back to a single "N people reacted" line so the affordance still
/// delivers — just without the row-level identity.
private struct ReactorListCard: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    let post: MomentPost
    let kind: ReactionKind
    let onDismiss: () -> Void
    let onSelectReactor: (UserProfile) -> Void

    private var currentPost: MomentPost {
        store.livePost(matching: post.id) ?? post
    }

    private var currentSummary: ReactionSummary? {
        currentPost
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
        currentPost
            .fullyLoadedReactionKinds
            .contains(kind)
    }

    private var listMaxHeight: CGFloat {
        InlinePeopleCardLayout.listMaxHeight
    }

    var body: some View {
        NightPanel(cornerRadius: 24, padding: 0, interactive: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: reactionIcon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(sheetTitle)
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(.white)
                        Text("\(totalCount) \(totalCount == 1 ? "person" : "people")")
                            .font(AppTypography.metadata)
                            .foregroundStyle(AppTheme.softText)
                    }

                    Spacer()

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.softText)
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: InlinePeopleCardLayout.rowSpacing) {
                        reactorContent
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: listMaxHeight)
            }
            .padding(16)
        }
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.32), radius: 22, y: 12)
        .task(id: "\(post.id.uuidString)-\(kind.rawValue)") {
            if !store.posts.contains(where: { $0.id == post.id }) {
                store.cacheProfilePosts([post])
            }
            await store.ensureReactorsLoaded(for: kind, inPostID: post.id)
        }
    }

    @ViewBuilder
    private var reactorContent: some View {
        if totalCount > 0 && reactors.isEmpty && !hasLoadedFullList {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(accent)
                Text("Loading people who reacted…")
                    .font(AppTypography.button)
                    .foregroundStyle(.white)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppTheme.line, lineWidth: 1)
            )
        } else if reactors.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(totalCount) \(totalCount == 1 ? "person" : "people") reacted")
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.white)
                Text("Individual names will appear once this post syncs.")
                    .font(AppTypography.rowSubtitle)
                    .foregroundStyle(AppTheme.softText)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(AppTheme.line, lineWidth: 1)
            )
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

    private var sheetTitle: String {
        switch kind {
        case .cheers: return "Likes"
        case .spark: return "Locked In"
        case .fire: return "Fire"
        case .dislike: return "Reactions"
        }
    }

    private var reactionIcon: String {
        switch kind {
        case .cheers: return "heart.fill"
        case .spark: return "sparkles"
        case .fire: return "flame.fill"
        case .dislike: return "heart.fill"
        }
    }

    private func reactorRow(_ profile: UserProfile) -> some View {
        HStack(spacing: 12) {
            AvatarView(avatar: profile.avatar, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(profile.displayName)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.white)
                VerifiedUsernameLabel(profile: profile, font: AppTypography.username, badgeSize: 11)
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

private enum InlinePeopleCardLayout {
    static let rowSpacing: CGFloat = 10
    static let rowHeight: CGFloat = 68
    static let visibleRowCount: CGFloat = 4

    static var listMaxHeight: CGFloat {
        rowHeight * visibleRowCount + rowSpacing * (visibleRowCount - 1)
    }
}

private struct TaggedFriendsCard: View {
    let friends: [UserProfile]
    let onDismiss: () -> Void
    let onSelectFriend: (UserProfile) -> Void

    var body: some View {
        NightPanel(cornerRadius: 24, padding: 0, interactive: true) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("Tagged")
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(.white)
                        Text("\(friends.count) \(friends.count == 1 ? "person" : "people")")
                            .font(AppTypography.metadata)
                            .foregroundStyle(AppTheme.softText)
                    }

                    Spacer()

                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(AppTheme.softText)
                            .frame(width: 32, height: 32)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: InlinePeopleCardLayout.rowSpacing) {
                        ForEach(friends) { friend in
                            Button {
                                onSelectFriend(friend)
                            } label: {
                                friendRow(friend)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: InlinePeopleCardLayout.listMaxHeight)
            }
            .padding(16)
        }
        .background(.black.opacity(0.16), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.32), radius: 22, y: 12)
    }

    private func friendRow(_ friend: UserProfile) -> some View {
        HStack(spacing: 12) {
            AvatarView(avatar: friend.avatar, size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(friend.displayName)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.white)
                VerifiedUsernameLabel(profile: friend, font: AppTypography.username, badgeSize: 11)
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
