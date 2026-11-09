import SwiftUI
import UIKit

/// Captured photo and optional details share one screen. The live camera keeps
/// its own layout; only the still image moves from that guide into this review.
struct PostPhotoReviewView<Details: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasStartedEntry = false
    @State private var revealsDetails = false
    @State private var hasFinishedEntry = false
    @State private var isPhotoExpanded = false
    @State private var portraitDetailsHeight: CGFloat = 0
    @State private var footerHeight: CGFloat = 0

    let photoData: Data?
    let sampleSymbol: String
    let captureFrame: CGRect?
    let isDuoDevice: Bool
    let shareLocally: Bool
    let canPost: Bool
    let isSubmitting: Bool
    let isCaptionFocused: Bool
    let isFriendSearchFocused: Bool
    let onBack: () -> Void
    let onAudience: () -> Void
    let onPost: () -> Void
    let onInspectPhoto: () -> Void
    @ViewBuilder let details: Details

    private var focusedDetail: PostReviewScrollTarget? {
        if isFriendSearchFocused { return .friends }
        if isCaptionFocused { return .caption }
        return nil
    }

    private var isEditingDetails: Bool { focusedDetail != nil }

    var body: some View {
        ScrollViewReader { scroll in
            GeometryReader { geometry in
                reviewLayout(size: geometry.size, geometry: geometry)
                    .allowsHitTesting(!isPhotoExpanded)
                    .accessibilityHidden(isPhotoExpanded)
                    .overlayPreferenceValue(ReviewPhotoBoundsKey.self) { anchor in
                        if let anchor {
                            photoLayer(in: geometry, previewFrame: geometry[anchor])
                        }
                    }
            }
            .task(id: focusedDetail) {
                guard let focusedDetail else { return }
                // Native focus reveals the text baseline; also reveal the whole
                // padded field after the keyboard and pinned footer settle.
                do { try await Task.sleep(for: .milliseconds(350)) }
                catch { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    scroll.scrollTo(focusedDetail, anchor: .bottom)
                }
            }
        }
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(isPhotoExpanded ? "Close photo" : "Back", systemImage: "chevron.left") {
                    if isPhotoExpanded { togglePhotoExpansion() }
                    else { onBack() }
                }
                    .tint(.white)
                    .accessibilityIdentifier("post.close")
            }
            if !isPhotoExpanded { audienceToolbar }
        }
        .disabled(isSubmitting)
        .accessibilityIdentifier("camera.review")
        .task {
            await animateCaptureIntoReview()
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            let cyclesPhoto = arguments.contains("--post-photo-cycle-preview")
            if arguments.contains("--duo-layout-preview"),
               arguments.contains("--post-expanded-preview") || cyclesPhoto {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                togglePhotoExpansion()
                if cyclesPhoto {
                    try? await Task.sleep(for: .milliseconds(1200))
                    guard !Task.isCancelled else { return }
                    togglePhotoExpansion()
                }
            }
            #endif
        }
    }

    @ViewBuilder
    private func reviewLayout(size: CGSize, geometry: GeometryProxy) -> some View {
        #if canImport(SwiftUICore, _version: 8.1)
            if #available(iOS 27.1, *), isDuoDevice,
               geometry.reservedRegions(kind: .division).contains(where: { $0.frame.width > $0.frame.height }) {
                ArrangementView {
                    GeometryReader { region in
                        let fitted = PostPhotoFormat.fittedSize(in: CGSize(
                            width: max(0, region.size.width - 40),
                            height: max(0, region.size.height - 32)))
                        photoSlot(size: fitted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                } secondary: {
                    detailsColumn
                }
                .arrangementViewStyle(DuoTabletopCameraStyle())
            } else {
                flatReview(size: size, bottomInset: geometry.safeAreaInsets.bottom)
            }
        #else
            flatReview(size: size, bottomInset: geometry.safeAreaInsets.bottom)
        #endif
    }

    @ToolbarContentBuilder
    private var audienceToolbar: some ToolbarContent {
        #if canImport(SwiftUICore, _version: 8.1)
            if #available(iOS 27.1, *), isDuoDevice {
                ToolbarItem(placement: .primaryAction) { audienceButton }
                    .axisBehavior(.verticalPreferred)
            } else {
                ToolbarItem(placement: .primaryAction) { audienceButton }
            }
        #else
            ToolbarItem(placement: .primaryAction) { audienceButton }
        #endif
    }

    private var audienceButton: some View {
        Button(action: onAudience) {
            if isDuoDevice {
                Text(shareLocally ? "Friends\n+ Local" : "Friends")
                    .font(AppTypography.caption2Emphasis)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize()
                    .frame(width: 44, height: 44)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: shareLocally ? "location.circle" : "person.2")
                    Text(shareLocally ? "Friends + Local" : "Friends")
                        .font(AppTypography.rowSubtitle)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
            }
        }
        .foregroundStyle(.white)
        .tint(.white)
        .accessibilityLabel("Audience: \(shareLocally ? "Friends and Local" : "Friends")")
        .accessibilityHint("Change who can see this post")
        .accessibilityIdentifier("post.audience")
    }

    @ViewBuilder
    private func flatReview(size: CGSize, bottomInset: CGFloat) -> some View {
        // Include the keyboard's inset when choosing a layout so focusing a
        // field cannot turn a portrait review into a two-column review.
        if size.width >= 640 && size.width > size.height + bottomInset && !dynamicTypeSize.isAccessibilitySize {
            HStack(alignment: .top, spacing: 12) {
                GeometryReader { pane in
                    photoSlot(size: PostPhotoFormat.fittedSize(in: CGSize(
                        width: max(0, pane.size.width - 40),
                        height: min(440, max(0, pane.size.height - 32)))))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                // The still photo retains its size and center behind the
                // keyboard; only the editable column needs to avoid it.
                .ignoresSafeArea(.keyboard, edges: .bottom)
                detailsColumn.frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 12)
        } else {
            ScrollView {
                VStack(spacing: 20) {
                    let height = portraitPhotoHeight(in: size)
                    photoSlot(size: PostPhotoFormat.fittedSize(in: CGSize(
                        width: max(0, size.width - 40), height: height)))
                        .frame(maxWidth: .infinity)
                    details
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            portraitDetailsHeight = $0
                        }
                        .opacity(revealsDetails ? 1 : 0)
                        .offset(y: revealsDetails ? 0 : 12)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) { actionFooter }
        }
    }

    private func portraitPhotoHeight(in size: CGSize) -> CGFloat {
        let ideal: CGFloat
        if isEditingDetails {
            ideal = min(96, max(64, size.height * 0.20))
        } else if isDuoDevice && size.width < 640 {
            ideal = min(200, max(144, size.height * 0.30))
        } else {
            ideal = min(270, max(160, size.height * 0.33))
        }
        guard isDuoDevice, size.width < 640, portraitDetailsHeight > 0 else { return ideal }
        // Use the room actually left by the form, including selected friends
        // and wrapped captions. Long accessibility content can still scroll.
        let spacing: CGFloat = 8 + 20 + 16
        let available = size.height - portraitDetailsHeight - max(footerHeight, 74) - spacing
        return min(ideal, max(64, available))
    }

    private var detailsColumn: some View {
        ScrollView {
            details
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) { actionFooter }
        .opacity(revealsDetails ? 1 : 0)
    }

    private func photoSlot(size: CGSize) -> some View {
        Color.clear
            .frame(width: size.width, height: size.height)
        .anchorPreference(key: ReviewPhotoBoundsKey.self, value: .bounds) { $0 }
        .accessibilityHidden(true)
        #if DEBUG
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            if ProcessInfo.processInfo.arguments.contains("--duo-layout-preview"),
               ProcessInfo.processInfo.arguments.contains("--post-keyboard-layout-check") {
                FileHandle.standardError.write(Data("Review photo frame: \(frame); editing: \(isEditingDetails)\n".utf8))
            }
        }
        #endif
    }

    private func photoLayer(in geometry: GeometryProxy, previewFrame: CGRect) -> some View {
        // Keep a single decoded photo mounted for capture, expand and close.
        // Animating one frame avoids matched-view insertion/removal fades.
        let viewport = expandedViewport(in: geometry)
        let fitted = PostPhotoFormat.fittedSize(in: CGSize(
            width: max(0, viewport.width - 24), height: max(0, viewport.height - 24)))
        let expandedFrame = CGRect(
            x: viewport.midX - fitted.width / 2, y: viewport.midY - fitted.height / 2,
            width: fitted.width, height: fitted.height)
        let globalFrame = geometry.frame(in: .global)
        let sourceFrame = captureFrame?.offsetBy(dx: -globalFrame.minX, dy: -globalFrame.minY) ?? expandedFrame
        let displayedFrame = isPhotoExpanded ? expandedFrame : (revealsDetails ? previewFrame : sourceFrame)
        let clipFrame = isPhotoExpanded ? viewport : CGRect(origin: .zero, size: geometry.size)
        return ZStack {
            Color.black
                .ignoresSafeArea()
                .opacity(isPhotoExpanded ? 1 : 0)
                .accessibilityHidden(true)
                .onTapGesture { togglePhotoExpansion() }
                .allowsHitTesting(isPhotoExpanded)
            Button(action: togglePhotoExpansion) {
                photo
                    .frame(width: displayedFrame.width, height: displayedFrame.height)
                    .contentShape(RoundedRectangle(cornerRadius: PostPhotoFormat.cornerRadius))
            }
            .buttonStyle(.plain)
            .position(x: displayedFrame.midX, y: displayedFrame.midY)
            .disabled(!hasFinishedEntry)
            .accessibilityHidden(!hasFinishedEntry)
            .accessibilityLabel(isPhotoExpanded ? "Expanded photo" : "Your photo")
            .accessibilityHint(isPhotoExpanded ? "Double-tap to return to the smaller preview" : "Double-tap to enlarge")
            .accessibilityIdentifier(isPhotoExpanded ? "post.photo.expanded" : "post.photo")
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .mask {
            Rectangle()
                .frame(width: clipFrame.width, height: clipFrame.height)
                .position(x: clipFrame.midX, y: clipFrame.midY)
        }
        .accessibilityAddTraits(isPhotoExpanded ? .isModal : [])
        .accessibilityAction(.escape) {
            if isPhotoExpanded { togglePhotoExpansion() }
        }
    }

    private func expandedViewport(in geometry: GeometryProxy) -> CGRect {
        guard isDuoDevice else { return CGRect(origin: .zero, size: geometry.size) }
        // Preserve the native horizontal safe area beside the status/control
        // rail, but center vertically in the display, including when a keyboard
        // is dismissing. The normal left-pane preview keeps its own layout.
        let insets = geometry.safeAreaInsets
        return CGRect(x: 0, y: -insets.top, width: geometry.size.width,
                      height: geometry.size.height + insets.top + insets.bottom)
    }

    private func togglePhotoExpansion() {
        guard hasFinishedEntry else { return }
        if !isPhotoExpanded { onInspectPhoto() }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) {
            isPhotoExpanded.toggle()
        }
    }

    private var photo: some View {
        ReviewPhotoImage(photoData: photoData, sampleSymbol: sampleSymbol)
        .clipShape(RoundedRectangle(cornerRadius: PostPhotoFormat.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PostPhotoFormat.cornerRadius, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        }
    }

    private var actionFooter: some View {
        VStack(spacing: 6) {
            if shareLocally && !canPost && !isSubmitting {
                Button("Location needed for Local", systemImage: "location.circle", action: onAudience)
                    .font(AppTypography.caption)
                    .foregroundStyle(.white)
                    .padding(.bottom, 4)
            }
            PostSubmitButton(isEnabled: canPost && !isSubmitting, isSubmitting: isSubmitting, action: onPost)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .background(Color.black)
        .opacity(revealsDetails ? 1 : 0)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
            footerHeight = $0
        }
    }

    @MainActor
    private func animateCaptureIntoReview() async {
        guard !hasStartedEntry else { return }
        hasStartedEntry = true
        guard !reduceMotion else {
            revealsDetails = true
            hasFinishedEntry = true
            return
        }
        // Lay out the destination first so the still image starts exactly at
        // the measured camera guide, even when native Duo bars change edges.
        do {
            try await Task.sleep(for: .milliseconds(20))
            withAnimation(.easeInOut(duration: 0.28)) { revealsDetails = true }
            try await Task.sleep(for: .milliseconds(300))
        } catch { }
        // If navigation interrupts the animation, returning must still show
        // the finished photo instead of leaving an invisible placeholder.
        revealsDetails = true
        hasFinishedEntry = true
    }
}

enum PostReviewScrollTarget: Hashable {
    case friends
    case caption
}

/// Keep one decoded image throughout the size animation so SwiftUI does not
/// crossfade newly decoded copies of the same capture while it is moving.
private struct ReviewPhotoImage: View {
    @State private var image: UIImage?
    let sampleSymbol: String

    init(photoData: Data?, sampleSymbol: String) {
        _image = State(initialValue: photoData.flatMap { UIImage(data: $0) })
        self.sampleSymbol = sampleSymbol
    }

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                LinearGradient(colors: [Color(hex: "#41245D"), Color(hex: "#153F54")],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: sampleSymbol).font(.system(size: 40)).foregroundStyle(.white)
            }
        }
    }
}

private struct ReviewPhotoBoundsKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>? { nil }
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct PostSubmitButton: View {
    @Environment(\.appAccent) private var accent
    let isEnabled: Bool
    var isSubmitting = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isSubmitting {
                    ProgressView().tint(AppTheme.foregroundOnAccent(accent))
                    Text("Posting…")
                } else {
                    Label("Post", systemImage: "paperplane.fill")
                }
            }
                .font(AppTypography.rowTitle)
                .foregroundStyle(AppTheme.foregroundOnAccent(accent))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(accent.opacity(0.9), in: Capsule())
                .overlay(Capsule().strokeBorder(accent, lineWidth: 1.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
        .accessibilityIdentifier("post.publish")
    }
}

struct PostAudienceSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions
    @Environment(\.appAccent) private var accent
    let onApplyLocation: () -> Void

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    Image(systemName: "person.2.fill")
                    Text("Friends").font(AppTypography.rowTitle)
                    Spacer()
                    Image(systemName: "checkmark").foregroundStyle(accent)
                }
                .padding(18)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 10) {
                    Toggle(isOn: $store.postDraft.shareLocally) {
                        Label("Also share to Local", systemImage: "location.circle")
                            .font(AppTypography.rowTitle)
                    }
                    .toggleStyle(AppAccentToggleStyle(accent: accent))
                    .accessibilityIdentifier("post.shareLocally")
                    if store.postDraft.shareLocally {
                        Text("Your post will be visible to anyone within 35 miles of your location for 48 hours.")
                            .font(AppTypography.caption)
                            .foregroundStyle(AppTheme.softText)
                            .fixedSize(horizontal: false, vertical: true)
                        if permissions.locationStatus == .denied {
                            Button("Allow Location in Settings") { permissions.openSettings() }
                                .font(AppTypography.caption)
                        } else if !store.canPublishDraft {
                            HStack(spacing: 10) {
                                ProgressView().controlSize(.mini)
                                Button("Get location", action: requestLocation)
                                    .font(AppTypography.caption)
                            }
                            .accessibilityLabel("Getting your location for Local")
                        }
                    }
                }
                .padding(18)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 20))
            }
            .padding(20)
        }
        .onChange(of: store.postDraft.shareLocally) { _, enabled in
            if enabled { requestLocation() }
        }
    }

    private func requestLocation() {
        if !store.isLayoutPreview { permissions.requestLocation() }
        onApplyLocation()
    }
}
