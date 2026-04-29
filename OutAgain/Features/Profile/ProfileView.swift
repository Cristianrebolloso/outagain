import PhotosUI
import SwiftUI
import UIKit

/// Profile restructured to behave like a social profile rather than a
/// settings drawer. The header carries identity and the two counters
/// that matter (friends, moments) — "nights" was removed because it
/// correlates near-perfectly with moment count in practice and the extra
/// number dilutes rather than informs. A segmented control flips between
/// the viewer's own posts (grid, Instagram-style) and a slim Stats
/// readout. Settings were pulled out into their own destination behind
/// a gear icon so identity and administration stop competing for the
/// same scroll.
struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @State private var isEditProfilePresented = false
    @State private var isSettingsPresented = false
    @State private var selectedSection: ProfileSection = .moments
    @State private var detailPost: MomentPost?
    @State private var isEditingFavoriteDrink = false
    @State private var favoriteDrinkDraft = ""
    @State private var isShowingRefreshConfirmation = false
    @AppStorage(AppStore.profileFavoriteDrinkKey) private var savedFavoriteDrink: String = ""

    // The bootstrap tonight-feed only carries posts from the last ~20 hours
    // (limit 30). Without an explicit fetch the viewer's own profile grid
    // silently omits older posts. We call loadUserPosts on appear — that
    // function merges results into store.posts so viewerPosts stays the
    // source of truth for the grid and counter, and deduplicates on its
    // own so tapping back and forth doesn't double-insert rows.
    @State private var loadedViewerPostsForID: UUID?

    enum ProfileSection: Hashable {
        case moments
        case tagged
        case stats
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                profileHeader
                sectionToggle

                switch selectedSection {
                case .moments:
                    momentsContent
                case .tagged:
                    viewerTaggedContent
                case .stats:
                    statsContent
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 0)
            .padding(.bottom, 120)
        }
        .refreshable {
            await performManualRefresh()
        }
        .scrollIndicators(.hidden)
        // Match Activity / Home: the warm ambient is the default surface
        // language for every in-session screen. Hiding the ScrollView's
        // default content background lets the ambient render through
        // the full viewport even inside a NavigationStack.
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .overlay(alignment: .top) {
            if isShowingRefreshConfirmation {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                    Text("Refreshed")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.72), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(AppTheme.line, lineWidth: 1)
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(store.accentColorChoice.color)
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(AppTheme.line, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .padding(.top, 0)
            .padding(.trailing, 20)
        }
        .sheet(isPresented: $isEditProfilePresented) {
            ProfileEditorSheet()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isSettingsPresented) {
            ProfileSettingsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $detailPost) { post in
            MomentDetailSheet(postID: post.id)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .task(id: store.viewer?.id) {
            guard let viewer = store.viewer else { return }
            guard loadedViewerPostsForID != viewer.id else { return }

            let result = await store.loadUserPosts(for: viewer)
            if result.didLoadAuthoritatively {
                loadedViewerPostsForID = viewer.id
            }
        }
    }

    private func performManualRefresh() async {
        await store.refreshAppData(silenceErrors: true)

        await MainActor.run {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                isShowingRefreshConfirmation = true
            }
        }

        try? await Task.sleep(for: .seconds(1.1))

        await MainActor.run {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                isShowingRefreshConfirmation = false
            }
        }
    }

    // MARK: - Header

    private var profileHeader: some View {
        VStack(spacing: 16) {
            TonightAvatarView(avatar: store.viewerIdentity.avatar, userID: store.viewerIdentity.id, size: 124)

            VStack(spacing: 5) {
                Text(store.viewerIdentity.displayName)
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text("@\(store.viewerIdentity.username)")
                    .font(.system(.headline, design: .rounded, weight: .medium))
                    .foregroundStyle(AppTheme.softText)
            }

            HStack(spacing: 32) {
                // Tapping Friends navigates to the Friends tab → people list
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        store.friendsPageMode = .people
                        store.selectedTab = .friends
                    }
                } label: {
                    counterColumn(value: store.friends.count, label: "Friends")
                }
                .buttonStyle(.plain)

                counterColumn(value: store.viewerPosts.count, label: "Posts")
            }
            .padding(.top, 4)

            Button {
                store.beginProfileEditing()
                isEditProfilePresented = true
            } label: {
                Text("Edit Profile")
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.07), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1))
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
            .padding(.top, 6)
            .padding(.horizontal, 20)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 44)
    }

    private func counterColumn(value: Int, label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(.caption, design: .rounded, weight: .medium))
                .foregroundStyle(AppTheme.softText)
        }
        .frame(minWidth: 72)
    }

    // MARK: - Segmented control

    @Namespace private var profileSectionNamespace

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

    private func segmentButton(title: String, symbol: String, section: ProfileSection) -> some View {
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
                        .matchedGeometryEffect(id: "profile_section_selection", in: profileSectionNamespace)
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
        if store.viewerPosts.isEmpty {
            Text("No posts yet")
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
                ForEach(store.viewerPosts) { post in
                    Button {
                        detailPost = post
                    } label: {
                        momentGridCell(post: post)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func momentGridCell(post: MomentPost) -> some View {
        MomentGridThumbnail(media: post.media)
    }

    // MARK: - Tagged

    @ViewBuilder
    private var viewerTaggedContent: some View {
        let taggedPosts = store.posts
            .filter { $0.taggedFriends.contains(where: { $0.id == store.viewer?.id }) }
            .sorted { $0.createdAt > $1.createdAt }

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
                        MomentGridThumbnail(media: post.media)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Stats

    private var statsContent: some View {
        let recap = store.weeklyRecap
        let favDrink = savedFavoriteDrink.isEmpty ? nil : savedFavoriteDrink

        return VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Favorite drink — tappable, viewer can set it manually
                Button {
                    favoriteDrinkDraft = savedFavoriteDrink
                    isEditingFavoriteDrink = true
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("FAVORITE DRINK")
                            .font(.system(.caption2, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .tracking(1.2)
                        if let favDrink {
                            Text(favDrink)
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        } else {
                            Text("Tap to add")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(store.accentColorChoice.color.opacity(0.7))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(favDrink == nil ? store.accentColorChoice.color.opacity(0.35) : .white.opacity(0.12), lineWidth: 1)
                    )
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                }
                .buttonStyle(.plain)

                compactStat(
                    label: "Common place",
                    value: recap.commonVenue?.name ?? "—"
                )
            }
            HStack(spacing: 12) {
                compactStat(
                    label: "Nights active",
                    value: "\(recap.nightsActive)"
                )
                compactStat(
                    label: "Touchpoints",
                    value: "\(recap.totalInteractions)"
                )
            }
        }
        .sheet(isPresented: $isEditingFavoriteDrink) {
            favoriteDrinkEditor
                .presentationDetents([.height(260)])
                .presentationDragIndicator(.visible)
        }
    }

    private var favoriteDrinkEditor: some View {
        let accent = store.accentColorChoice.color
        return VStack(alignment: .leading, spacing: 20) {
            Text("Favorite Drink")
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(.white)

            TextField("e.g. Espresso Martini", text: $favoriteDrinkDraft)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white)
                .tint(accent)
                .textInputAutocapitalization(.words)
                .padding(16)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
                .glassEffect(.regular, in: .rect(cornerRadius: 18))

            HStack(spacing: 12) {
                if !savedFavoriteDrink.isEmpty {
                    Button("Clear") {
                        store.setProfileFavoriteDrink(nil)
                        isEditingFavoriteDrink = false
                    }
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(.white.opacity(0.06), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .buttonStyle(.plain)
                }

                Button("Save") {
                    store.setProfileFavoriteDrink(favoriteDrinkDraft)
                    isEditingFavoriteDrink = false
                }
                .font(.system(.subheadline, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(accent.opacity(0.25), in: Capsule())
                .overlay(Capsule().strokeBorder(accent.opacity(0.5), lineWidth: 1))
                .glassEffect(.regular.interactive(), in: .capsule)
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .padding(24)
        .background(AmbientBackground())
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

// MARK: - Profile editor sheet (unchanged structure, preserved)

private struct ProfileEditorSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var pendingCropImage: UIImage?

    var body: some View {
        @Bindable var store = store
        let accent = store.accentColorChoice.color

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    NightPanel(cornerRadius: 32, padding: 20) {
                        VStack(alignment: .leading, spacing: 18) {
                            SectionEyebrow(title: "Edit Profile")

                            HStack(spacing: 18) {
                                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                    AvatarView(avatar: editorAvatar, size: 96)
                                        .overlay(alignment: .bottomTrailing) {
                                            Image(systemName: "pencil.circle.fill")
                                                .font(.system(size: 24))
                                                .foregroundStyle(.white, accent)
                                                .background(.black, in: Circle())
                                        }
                                }
                                .buttonStyle(.plain)

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("Profile photo")
                                        .font(.system(.headline, design: .rounded, weight: .semibold))
                                        .foregroundStyle(.white)

                                    Text("Tap to choose a new image.")
                                        .font(.system(.subheadline, design: .rounded))
                                        .foregroundStyle(AppTheme.softText)
                                }

                                Spacer()
                            }

                            VStack(alignment: .leading, spacing: 14) {
                                fieldLabel("Display Name", accent: accent)
                                TextField("Your name", text: $store.profileEditor.displayName)
                                    .textInputAutocapitalization(.words)
                                    .foregroundStyle(.white)
                                    .tint(accent)
                                    .padding(16)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .strokeBorder(AppTheme.line, lineWidth: 1)
                                    )
                                    .glassEffect(.regular, in: .rect(cornerRadius: 18))

                                fieldLabel("Username", accent: accent)
                                TextField("username", text: $store.profileEditor.username)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                                    .foregroundStyle(.white)
                                    .tint(accent)
                                    .padding(16)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                                            .strokeBorder(AppTheme.line, lineWidth: 1)
                                    )
                                    .glassEffect(.regular, in: .rect(cornerRadius: 18))

                                usernameAvailabilityView

                                if let profileEditorMessage = store.profileEditorMessage {
                                    statusRow(
                                        symbol: "exclamationmark.triangle.fill",
                                        tint: Color(hex: "#E16B5C"),
                                        text: profileEditorMessage
                                    )
                                }
                            }
                        }
                    }

                    // Save Changes button
                    Button {
                        Task {
                            if await store.saveProfileEdits() {
                                dismiss()
                            }
                        }
                    } label: {
                        if store.isSavingProfile {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        } else {
                            Text("Save Changes")
                                .font(.system(.headline, design: .rounded, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        }
                    }
                    .disabled(!store.canSaveProfileEdits)
                    .background(
                        Capsule()
                            .fill(store.canSaveProfileEdits ? accent.opacity(0.85) : .white.opacity(0.08))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(store.canSaveProfileEdits ? accent.opacity(0.55) : AppTheme.line, lineWidth: 1)
                    )
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task {
                            if await store.saveProfileEdits() {
                                dismiss()
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .disabled(!store.canSaveProfileEdits)
                }
            }
        }
        .onChange(of: selectedPhotoItem) { _, newValue in
            guard let newValue else { return }
            Task {
                if let data = try? await newValue.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    pendingCropImage = image
                }
            }
        }
        .fullScreenCover(item: Binding(
            get: { pendingCropImage.map { IdentifiableImage(image: $0) } },
            set: { if $0 == nil { pendingCropImage = nil } }
        )) { wrapper in
            ImageCropSheet(image: wrapper.image) { croppedData in
                store.profileEditor.profileImageData = croppedData
                pendingCropImage = nil
            } onCancel: {
                pendingCropImage = nil
            }
        }
        .task(id: store.normalizedProfileEditorUsername) {
            guard !store.normalizedProfileEditorUsername.isEmpty else { return }
            await store.refreshProfileUsernameAvailability()
        }
    }

    private var editorAvatar: AvatarStyle {
        var avatar = store.viewerIdentity.avatar
        avatar.imageData = store.profileEditor.profileImageData ?? avatar.imageData
        return avatar
    }

    @ViewBuilder
    private var usernameAvailabilityView: some View {
        switch store.profileUsernameAvailability {
        case .unchecked:
            EmptyView()
        case .checking:
            statusRow(
                symbol: "hourglass",
                tint: AppTheme.softText,
                text: "Checking @\(store.normalizedProfileEditorUsername)..."
            )
        case .available(let username, _):
            statusRow(
                symbol: "checkmark.circle.fill",
                tint: AppTheme.activeGreen,
                text: "@\(username) is available"
            )
        case .unavailable(let username, let suggestion):
            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    symbol: "xmark.circle.fill",
                    tint: Color(hex: "#E16B5C"),
                    text: "@\(username) is taken"
                )

                if let suggestion {
                    Button("Use @\(suggestion)") {
                        store.profileEditor.username = suggestion
                    }
                    .buttonStyle(.glass)
                }
            }
        case .invalid(let message), .failed(let message):
            statusRow(
                symbol: "exclamationmark.triangle.fill",
                tint: Color(hex: "#E16B5C"),
                text: message
            )
        }
    }

    private func statusRow(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.system(.footnote, design: .rounded, weight: .medium))
                .foregroundStyle(AppTheme.softText)
        }
    }

    private func fieldLabel(_ title: String, accent: Color = AppAccentKey.defaultValue) -> some View {
        Text(title.uppercased())
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundStyle(accent.opacity(0.8))
            .tracking(1.4)
    }
}

/// Square thumbnail for the profile moments grid. Mirrors the resolution
/// logic in `MomentMediaView` (local photoData, then remote URL, then a
/// gradient+symbol placeholder) but lets the container dictate the size
/// via `aspectRatio(1, contentMode: .fill)` instead of baking a fixed
/// height into the frame. Grid cells need container-driven sizing so
/// three columns split the available width cleanly; the standard
/// MomentMediaView was built for feed cards where the height is
/// prescriptive.
private struct MomentGridThumbnail: View {
    let media: MomentMedia

    var body: some View {
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

/// Full-post detail presented when the viewer taps a grid thumbnail.
/// Intentionally reuses `MomentPostCard` so every interaction — likes,
/// overflow menu, save-to-camera-roll, delete — behaves identically to
/// the feed. The sheet looks the post up by ID on each render so a
/// delete from inside the overflow menu collapses the sheet naturally
/// (when the post disappears from `store.posts` the sheet's content
/// goes empty and the host dismisses via the binding flip).
private struct MomentDetailSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    let postID: UUID

    @State private var friendProfileTarget: UserProfile?
    @State private var commentSheetPostID: UUID?

    private var post: MomentPost? {
        store.posts.first(where: { $0.id == postID })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let post {
                    MomentPostCard(
                        post: post,
                        isFocused: true,
                        onCommentTap: {
                            commentSheetPostID = post.id
                        },
                        onAuthorTap: { profile in
                            // In the Profile tab's detail sheet the
                            // author is almost always the viewer, so
                            // filter that case out. The interesting tap
                            // is on a reactor row in the long-press Likes
                            // sheet, which routes through `onAuthorTap`
                            // as well — that's where this matters.
                            guard profile.id != store.viewer?.id else { return }
                            friendProfileTarget = profile
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 32)
                } else {
                    // Fallback if the post was deleted while the sheet
                    // was open on another device. Rare, but cheaper to
                    // handle than to hope it never happens.
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(AppTheme.softText)
                        Text("This post is no longer available.")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                }
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Post")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                        .foregroundStyle(accent)
                }
            }
            .sheet(item: $friendProfileTarget) { profile in
                FriendProfileView(profile: profile)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
            .sheet(item: $commentSheetPostID) { postID in
                CommentThreadSheet(postID: postID)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }
}
