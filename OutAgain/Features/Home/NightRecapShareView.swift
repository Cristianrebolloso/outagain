import SwiftUI
import UIKit

/// Sharing is a separate, deliberate flow: nothing leaves the app until the
/// viewer chooses photos, reviews the exact export, and opens the share sheet.
struct NightRecapShareView: View {
    @Environment(\.dismiss) private var dismiss
    let posts: [MomentPost]
    let date: Date
    @State private var selection = Set<UUID>()
    @State private var preview: UIImage?
    @State private var isPreparing = false
    @State private var isSaving = false
    @State private var didSave = false
    @State private var showShareSheet = false
    @State private var errorMessage: String?
    @State private var needsPhotoSettings = false

    private var selectedPosts: [MomentPost] {
        NightRecapExport.selectedPosts(from: posts, ids: selection)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let preview {
                        previewContent(preview)
                    } else {
                        selectionContent
                            .disabled(isPreparing)
                    }
                }
                .padding(AppLayout.screenPadding)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .background(AmbientBackground())
            .navigationTitle(preview == nil ? "Choose photos" : "Your recap")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
                if preview != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Edit") {
                            preview = nil
                            didSave = false
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { bottomAction }
            .alert("Couldn't prepare your recap", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                if needsPhotoSettings {
                    Button("Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "Try again.") }
            .sheet(isPresented: $showShareSheet) {
                if let preview {
                    NightRecapActivitySheet(image: preview)
                        .presentationDetents([.medium, .large])
                }
            }
        }
        .environment(\.isAppSheet, true)
        .accessibilityIdentifier("night.recap.share.editor")
    }

    private var selectionContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(selection.count) of \(NightRecapExport.maximumPhotos) selected")
                .font(AppTypography.buttonFootnote)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 14) {
                ForEach(posts) { post in
                    Button { toggle(post.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            GeometryReader { geometry in
                                MomentMediaView(media: post.media, height: geometry.size.height)
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                            }
                            .aspectRatio(PostPhotoFormat.aspectRatio, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Image(systemName: selection.contains(post.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title2.weight(.semibold))
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(selection.contains(post.id) ? Color.black : Color.white, Color.white)
                                    .padding(8)
                                    .background(.black.opacity(0.35), in: Circle())
                                    .padding(6)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(.white.opacity(selection.contains(post.id) ? 1 : 0.12), lineWidth: selection.contains(post.id) ? 3 : 1)
                            }
                            Text(post.author.displayName)
                                .font(AppTypography.buttonFootnote)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .disabled(!selection.contains(post.id) && selection.count == NightRecapExport.maximumPhotos)
                    .opacity(!selection.contains(post.id) && selection.count == NightRecapExport.maximumPhotos ? 0.5 : 1)
                    .accessibilityLabel("Photo by \(post.author.displayName), \(selection.contains(post.id) ? "selected" : "not selected")")
                    .accessibilityHint("Adds or removes this photo from your recap")
                }
            }
        }
    }

    private func previewContent(_ image: UIImage) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 390)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 26).strokeBorder(.white.opacity(0.16)) }
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Recap preview with \(selectedPosts.count) selected photos from \(date.formatted(date: .complete, time: .omitted))")
            Button {
                save(image)
            } label: {
                Label(isSaving ? "Saving…" : didSave ? "Saved to Photos" : "Save to Photos", systemImage: didSave ? "checkmark" : "arrow.down.to.line")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.glass)
            .tint(.white)
            .disabled(isSaving || didSave)
        }
    }

    private var bottomAction: some View {
        Button {
            if preview != nil {
                showShareSheet = true
            } else {
                preparePreview()
            }
        } label: {
            HStack(spacing: 10) {
                if isPreparing { ProgressView().tint(.black) }
                else { Image(systemName: preview == nil ? "photo.on.rectangle.angled" : "square.and.arrow.up") }
                Text(isPreparing ? "Preparing…" : preview == nil ? "Preview recap" : "Share recap")
                    .font(AppTypography.button)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
        }
        .buttonStyle(.glassProminent)
        .tint(.white)
        .foregroundStyle(.black)
        .disabled(selection.isEmpty || isPreparing)
        .padding(.horizontal, AppLayout.screenPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .accessibilityIdentifier("night.recap.share.preview")
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) }
        else if selection.count < NightRecapExport.maximumPhotos { selection.insert(id) }
    }

    private func preparePreview() {
        guard !isPreparing, !selectedPosts.isEmpty else { return }
        isPreparing = true
        needsPhotoSettings = false
        let chosen = selectedPosts
        Task { @MainActor in
            defer { isPreparing = false }
            do { preview = try await NightRecapExport.makeImage(posts: chosen, date: date) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    private func save(_ image: UIImage) {
        guard !isSaving, let data = image.jpegData(compressionQuality: 0.94) else { return }
        isSaving = true
        needsPhotoSettings = false
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await CameraRollSaver().save(media: MomentMedia(photoData: data, primaryHex: "000000", secondaryHex: "000000", symbol: "photo"))
                didSave = true
            } catch {
                needsPhotoSettings = (error as? CameraRollSaveError) == .permissionDenied
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct NightRecapActivitySheet: UIViewControllerRepresentable {
    let image: UIImage

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [image, "Our night on Out Again", URL(string: "https://cristianrebolloso.github.io/")!], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
