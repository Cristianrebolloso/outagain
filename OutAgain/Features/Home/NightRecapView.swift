import SwiftUI

struct NightRecapView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let route: NightRecapRoute
    @State private var posts: [MomentPost] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var selectedPost: MomentPost?
    @State private var selectedProfile: UserProfile?
    @State private var isSaving = false
    @State private var savedPostIDs: Set<UUID> = []
    @State private var saveErrorMessage: String?
    @State private var needsPhotoSettings = false
    @State private var isSharingRecap = false

    var body: some View {
        recapContent
        .environment(\.isAppSheet, true)
        .accessibilityIdentifier("night.recap")
        .sensoryFeedback(.success, trigger: savedPostIDs.count)
        .task { await load() }
    }

    private var recapContent: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if isLoading {
                            ProgressView().frame(maxWidth: .infinity)
                                .accessibilityLabel("Loading photos")
                        } else if let error {
                            ContentUnavailableView("Couldn't load the recap", systemImage: "wifi.exclamationmark", description: Text(error))
                            Button("Try Again") { Task { await load() } }.buttonStyle(.glass)
                        } else if posts.isEmpty {
                            ContentUnavailableView("No photos to show", systemImage: "photo.stack")
                        } else {
                            recapSummary
                            LazyVGrid(columns: columns(for: geometry.size.width), alignment: .leading, spacing: 24) {
                                ForEach(posts) { post in
                                    Button { selectedPost = post } label: {
                                        NightRecapPhotoTile(post: post)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Photo by \(post.author.displayName), \(post.createdAt.formatted(date: .complete, time: .shortened))")
                                    .accessibilityHint("Opens the post")
                                    .accessibilityIdentifier("night.recap.photo.\(post.id)")
                                    .contextMenu {
                                        Button { savePhotos([post]) } label: {
                                            Label(savedPostIDs.contains(post.id) ? "Saved" : "Save photo",
                                                  systemImage: savedPostIDs.contains(post.id) ? "checkmark" : "arrow.down.to.line")
                                        }
                                        .disabled(isSaving || savedPostIDs.contains(post.id))
                                    }
                                    .accessibilityAction(named: Text("Save photo")) { savePhotos([post]) }
                                }
                            }
                        }
                    }
                    .padding(AppLayout.screenPadding)
                    .frame(maxWidth: contentMaximumWidth)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(AmbientBackground())
            .navigationTitle("\(route.start.formatted(.dateTime.weekday(.wide)))’s photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
                if !isLoading, error == nil, !posts.isEmpty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saveButtonTitle) { savePhotos(posts) }
                            .disabled(isSaving || unsavedPosts.isEmpty)
                            .accessibilityHint("Saves to Photos")
                            .accessibilityIdentifier("night.recap.save")
                    }
                }
            }
            .alert("Couldn't save photos", isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )) {
                if needsPhotoSettings {
                    Button("Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Button("OK", role: .cancel) { saveErrorMessage = nil }
            } message: {
                Text(saveErrorMessage ?? "Try again.")
            }
            .navigationDestination(item: $selectedProfile) { profile in
                FriendProfileView(profile: profile, presentationStyle: .embedded)
            }
            .sheet(item: $selectedPost) { post in
                ActivityPostDetailSheet(postID: post.id, highlightedCommentID: nil) { profile in
                    selectedPost = nil
                    selectedProfile = profile
                }
            }
            .sheet(isPresented: $isSharingRecap) {
                NightRecapShareView(posts: posts, date: route.start)
            }
        }
    }

    private var recapSummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(posts.count) \(posts.count == 1 ? "photo" : "photos") · \(Set(posts.map(\.author.id)).count) \(Set(posts.map(\.author.id)).count == 1 ? "person" : "people")")
                .font(AppTypography.body)
                .foregroundStyle(.secondary)
            Button {
                isSharingRecap = true
            } label: {
                Label("Share a recap", systemImage: "square.and.arrow.up")
                    .font(AppTypography.button)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glass)
            .tint(.white)
            .accessibilityHint("Choose photos and preview a collage before sharing")
            .accessibilityIdentifier("night.recap.share")
        }
    }

    private var contentMaximumWidth: CGFloat {
        posts.count == 1 ? AppLayout.phoneColumnMaximumWidth : 760
    }

    private var unsavedPosts: [MomentPost] {
        posts.filter { !savedPostIDs.contains($0.id) }
    }

    private var saveButtonTitle: String {
        if isSaving { return "Saving…" }
        if unsavedPosts.isEmpty { return "Saved" }
        return posts.count == 1 ? "Save photo" : "Save all"
    }

    private func savePhotos(_ selection: [MomentPost]) {
        guard !isSaving else { return }
        let pending = selection.filter { !savedPostIDs.contains($0.id) }
        guard !pending.isEmpty else { return }
        isSaving = true
        saveErrorMessage = nil
        needsPhotoSettings = false

        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await CameraRollSaver().save(media: pending.map(\.media))
                savedPostIDs.formUnion(pending.map(\.id))
                UIAccessibility.post(notification: .announcement,
                                     argument: pending.count == 1 ? "Photo saved" : "Photos saved")
            } catch {
                needsPhotoSettings = (error as? CameraRollSaveError) == .permissionDenied
                saveErrorMessage = error.localizedDescription
            }
        }
    }

    private func columns(for width: CGFloat) -> [GridItem] {
        let availableWidth = max(0, min(width, contentMaximumWidth) - AppLayout.screenPadding * 2)
        let minimumWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 280 : 160
        let count = min(max(1, posts.count), 3, max(1, Int((availableWidth + 14) / (minimumWidth + 14))))
        return Array(repeating: GridItem(.flexible(), spacing: 14, alignment: .top), count: count)
    }

    private func load() async {
        guard let viewer = store.viewer else { isLoading = false; return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let fetched: [MomentPost]
            if store.isLayoutPreview {
                fetched = store.posts.filter { $0.createdAt >= route.start && $0.createdAt < route.end }
            } else {
                fetched = try await store.backend.loadNightRecapPosts(viewer: viewer, start: route.start, end: route.end, groupID: route.groupID)
            }
            guard store.viewer?.id == viewer.id else { return }
            posts = store.visiblePosts(fetched).filter(\.hasSummaryPhoto).sorted {
                $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt
            }
            store.cacheProfilePosts(posts)
            if !posts.isEmpty && !store.isLayoutPreview { try? await store.backend.markNightRecapSeen(through: route.end) }
        } catch {
            self.error = "Try again when you're connected."
        }
    }
}

private struct NightRecapPhotoTile: View {
    let post: MomentPost

    private var photoShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: PostPhotoFormat.cornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                // A prescribed media height fills the tile; rounding a fitted
                // image's larger outer frame can leave its visible corners square.
                MomentMediaView(media: post.media, height: geometry.size.height)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .aspectRatio(PostPhotoFormat.aspectRatio, contentMode: .fit)
            .clipShape(photoShape)
            .overlay { photoShape.strokeBorder(AppTheme.line, lineWidth: 1) }

            VerifiedProfileLabel(profile: post.author, spacing: 4) {
                Text(post.author.displayName)
                    .font(AppTypography.rowTitle)
                    .lineLimit(2)
            }
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.primary)
        .contentShape(Rectangle())
    }
}
