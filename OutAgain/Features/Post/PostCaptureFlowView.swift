import AVFoundation
import CoreLocation
import SwiftUI
import UIKit
import Vision

struct PostCaptureFlowView: View {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    @Environment(\.scenePhase) private var scenePhase

    /// Injected from AppStore.sharedCamera so the pipeline is pre-warmed
    /// by openPostFlow() before this view appears.
    @State var camera: CameraPipeline
    let presentationID: UUID
    private var pendingCapturedPhotoData: Data? {
        get { camera.capturedPhotoData }
        nonmutating set { camera.capturedPhotoData = newValue }
    }
    @State private var captureDelay = 0
    @State private var countdown: Int?
    @State private var captureTimerTask: Task<Void, Never>?
    @State private var showsSubjectPreview = false
    @State private var subjectPreviewAvailable = false
    @State private var lensFlipRotationDegrees: Double = 0
    @State private var tagSearch = ""
    @State private var suggestedDrinkID: UUID?
    @State private var pinnedAddedDrinkID: UUID?   // drink chosen from the full picker
    @State private var isAudiencePresented = false
    @State private var cameraGuideFrame: CGRect?
    @State private var isSubmitting = false
    @State private var submittedPhotoData: Data?
    @State private var drinkSuggestionTask: Task<Void, Never>?
    @FocusState private var focusedField: CaptureComposerField?

    private let venueMatchRadius: CLLocationDistance = 500

    // Original phone chrome. Duo's larger controls never change these metrics.
    private static let captureAccessoryButtonSize: CGFloat = 58
    private static let captureAccessoryIconPointSize: CGFloat = 20
    private static let captureBarHorizontalInset: CGFloat = 78
    private static let flashSymbolAnimationDuration: Double = 0.12
    private static let lensFlipSpringResponse: Double = 0.34
    private static let lensFlipSpringDamping: Double = 0.72

    @ViewBuilder
    var body: some View {
        #if DEBUG
        // Render the accessory's exact surface for UI checks even when the
        // simulator cannot start the live camera required to route an accessory.
        if store.isLayoutPreview && ProcessInfo.processInfo.arguments.contains("--duo-subject-preview-layout") {
            FullScreenSubjectPreview {
                CameraSubjectPreviewView(renderer: camera.subjectPreview, device: nil)
            }
            .task { await DuoLayoutFixtures.checkSubjectFrames(camera.subjectPreview) }
        } else {
            cameraFlow
        }
        #else
        cameraFlow
        #endif
    }

    private var cameraFlow: some View {
        NavigationStack {
            ZStack {
                postCaptureFlowBackground

                if isReviewingCapture {
                    captureReviewView
                } else {
                    captureView
                }
            }
            .toolbar(isReviewingCapture ? .visible : .hidden, for: .navigationBar)
            .sheet(isPresented: $isAudiencePresented) {
                audienceSheet
            }
            .disabled(isSubmitting)
            .interactiveDismissDisabled(isSubmitting)
            .alert("Couldn’t post", isPresented: Binding(
                get: { store.postPublishError != nil },
                set: { if !$0 { store.postPublishError = nil } }
            )) {
                Button("OK") { store.postPublishError = nil }
            } message: {
                Text(store.postPublishError ?? "Please try again.")
            }
            .onChange(of: pendingCapturedPhotoData != nil, initial: true) { _, hasPhoto in
                if hasPhoto { confirmCapturedPhoto() }
            }
            .task {
                if store.isLayoutPreview {
                    camera.setupState = .failed("Simulator layout preview")
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--post-audience-preview") {
                        isAudiencePresented = true
                    }
                    if ProcessInfo.processInfo.arguments.contains("--post-transition-preview") {
                        try? await Task.sleep(for: .seconds(3))
                        guard !Task.isCancelled else { return }
                        pendingCapturedPhotoData = ImageCompressor.postCapture(
                            from: DuoLayoutFixtures.cameraScene(), previewSize: camera.capturePreviewSize)
                    }
                    if ProcessInfo.processInfo.arguments.contains("--post-review-flow-checks") {
                        await checkReviewFlow()
                    }
                    #endif
                    return
                }
                guard !isReviewingCapture else { return }
                camera.beginPresentation(id: presentationID)
                async let prepared: Void = camera.prepare(supportsSubjectPreview: store.isDuoDevice)
                if !store.isLayoutPreview { permissions.requestLocation() }
                applySuggestedLocation()
                await prepared
            }
            .onChange(of: permissions.currentLocation?.timestamp) { _, _ in
                applySuggestedLocation()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, !store.isLayoutPreview, !isReviewingCapture else { return }
                if camera.setupState != .preparing {
                    Task { await camera.prepare(supportsSubjectPreview: store.isDuoDevice) }
                }
            }
            .onChange(of: showsSubjectPreview) { _, enabled in
                camera.setSubjectPreviewEnabled(enabled, presentationID: presentationID)
            }
            .onChange(of: canShowSubjectPreview) { _, canShow in
                if !canShow { showsSubjectPreview = false }
            }
            .onDisappear {
                captureTimerTask?.cancel()
                drinkSuggestionTask?.cancel()
                showsSubjectPreview = false
                camera.endPresentation(id: presentationID)
            }
            .modifier(CameraSubjectPreviewModifier(
                camera: camera,
                isDuoDevice: store.isDuoDevice,
                isEnabled: $showsSubjectPreview,
                isAvailable: $subjectPreviewAvailable
            ))
        }
    }

    private var isComposing: Bool {
        store.postDraft.capturedPhotoData != nil || store.postDraft.isUsingSampleCapture
    }

    private var isReviewingCapture: Bool {
        isComposing || pendingCapturedPhotoData != nil || isSubmitting
    }

    private var canShowSubjectPreview: Bool {
        camera.supportsSubjectPreview && camera.lensMode.isRear && !isComposing && !isReviewingCapture && camera.setupState == .ready
    }

    /// Review continues on black so the photo and details stay the focus.
    @ViewBuilder
    private var postCaptureFlowBackground: some View {
        if isReviewingCapture {
            Color.black.ignoresSafeArea()
        } else {
            ZStack {
                AppTheme.backgroundGradient
                Color.black.opacity(0.26)
            }
            .ignoresSafeArea()
        }
    }

    /// The pill row the composer renders. Draws from `composerDrinks` (already
    /// capped at 10, recency-ranked) with two promotion rules applied on top:
    ///   1. A drink picked from the full catalog pins to the front so the
    ///      user can see it immediately after selecting or adding it.
    ///   2. When the viewer has no post history, the vision-suggested drink
    ///      earns the head slot.
    private var orderedDrinks: [DrinkTag] {
        var drinks = store.composerDrinks

        // Include the picked drink even when it was outside the recent ten.
        if let pinnedID = pinnedAddedDrinkID,
           let pinned = store.drinks.first(where: { $0.id == pinnedID }) {
            drinks.removeAll { $0.id == pinnedID }
            return [pinned] + drinks.prefix(9)
        }

        let viewerHasHistory = !store.viewerPosts.isEmpty
        guard !viewerHasHistory,
              let suggestedDrinkID,
              let suggestedIndex = drinks.firstIndex(where: { $0.id == suggestedDrinkID })
        else {
            return drinks
        }

        let suggested = drinks.remove(at: suggestedIndex)
        return [suggested] + drinks
    }

    private var filteredFriends: [UserProfile] {
        let query = PeopleSearchRules.normalized(tagSearch)
        let base = store.friends.sorted { lhs, rhs in
            return lhs.displayName < rhs.displayName
        }

        guard !query.isEmpty else { return base }

        return base.filter { friend in
            friend.displayName.lowercased().contains(query) || friend.username.lowercased().contains(query)
        }
    }

    private var activeLocationSnapshot: LocationSnapshot? {
        permissions.currentLocationSnapshot ?? store.postDraft.location
    }

    private var nearestVenueMatch: (venue: Venue, distance: CLLocationDistance)? {
        guard let snapshot = activeLocationSnapshot else { return nil }
        let location = CLLocation(latitude: snapshot.latitude, longitude: snapshot.longitude)

        guard let venue = store.venues.min(by: { lhs, rhs in
            distance(from: location, to: lhs) < distance(from: location, to: rhs)
        }) else {
            return nil
        }

        return (venue, distance(from: location, to: venue))
    }

    private var resolvedVenue: Venue? {
        if let selected = store.selectedVenueForDraft {
            return selected
        }

        guard let nearestVenueMatch, nearestVenueMatch.distance <= venueMatchRadius else { return nil }
        return nearestVenueMatch.venue
    }

    private var placeTitle: String {
        // When we've matched a known venue (within `venueMatchRadius`),
        // show its name — it's strictly more specific than the city.
        // When we haven't, the resolved locality ("Waco, TX") is the
        // headline; accuracy prose is noise the poster doesn't care
        // about at the moment of posting.
        if let resolvedVenue {
            return resolvedVenue.name
        }

        if let locality = permissions.currentLocality {
            return locality
        }

        if activeLocationSnapshot != nil {
            return "Current location"
        }

        switch permissions.locationStatus {
        case .denied:
            return "Location off"
        case .notDetermined, .granted:
            return "Finding place"
        }
    }

    private var placeDetail: String? {
        // Detail text only earns a slot when it adds information beyond
        // the title. For venues that means neighborhood; for non-venue
        // fixes we intentionally return nil so the row reads as a
        // single-line "Waco, TX" rather than repeating itself.
        if let resolvedVenue {
            return "\(resolvedVenue.neighborhood), \(resolvedVenue.city)"
        }

        if permissions.currentLocality != nil {
            return nil
        }

        if activeLocationSnapshot != nil {
            return "Using your current location"
        }

        if permissions.locationStatus == .denied {
            return "Allow location to attach where this happened."
        }

        return "Waiting for GPS"
    }

    private func lensTogglePill(buttonHeight: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach([CameraCaptureMode.ultraWide, .back], id: \.self) { mode in
                let isSelected = camera.lensMode == mode
                Button {
                    Task { await camera.switchTo(mode) }
                } label: {
                    Text(mode == .back ? "1×" : "0.5×")
                        .font(AppTypography.pill)
                        .foregroundStyle(isSelected ? .black : .white)
                        .frame(width: max(64, buttonHeight * 1.25), height: buttonHeight)
                        .background(
                            isSelected
                                ? Color.white
                                : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(
                    camera.setupState != .ready || camera.isCapturing || countdown != nil
                        || (mode == .ultraWide && !camera.hasUltraWide)
                )
                .animation(.snappy(duration: 0.18), value: camera.lensMode)
            }
        }
        .padding(4)
        .background(.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private var showsUnavailableCameraControls: Bool {
        #if targetEnvironment(simulator)
            true
        #else
            store.isLayoutPreview
        #endif
    }

    @ViewBuilder
    private var captureView: some View {
        if store.isDuoDevice { captureLayout(reviewing: false) }
        else { standardCaptureView }
    }

    @ViewBuilder
    private var captureReviewView: some View {
        let review = PostPhotoReviewView(
            photoData: pendingCapturedPhotoData ?? store.postDraft.capturedPhotoData ?? submittedPhotoData,
            sampleSymbol: store.postDraft.sampleSymbol,
            captureFrame: cameraGuideFrame,
            isDuoDevice: store.isDuoDevice,
            shareLocally: store.postDraft.shareLocally,
            canPost: store.canPublishDraft,
            isSubmitting: isSubmitting,
            isCaptionFocused: focusedField == .caption,
            isFriendSearchFocused: focusedField == .tagSearch,
            onClose: closeFlow,
            onAudience: {
                focusedField = nil
                isAudiencePresented = true
            },
            onPost: publishPhoto,
            onRetake: retakePhoto,
            onInspectPhoto: { focusedField = nil }
        ) {
            composerView()
        }
        #if DEBUG
        if store.isLayoutPreview && ProcessInfo.processInfo.arguments.contains("--post-wide-preview") {
            // Exercise the actual wide layout without controlling a user's Duo.
            if ProcessInfo.processInfo.arguments.contains("--post-keyboard-layout-check") {
                GeometryReader { viewport in
                    review.frame(width: 900)
                        // Keep a 600pt review viewport before the keyboard,
                        // then let native keyboard avoidance reduce it.
                        .padding(.top, max(0, viewport.size.height + viewport.safeAreaInsets.bottom - 600))
                }
            } else {
                review.frame(width: 900, height: 600)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else { review }
        #else
        review
        #endif

    }

    private func captureLayout(reviewing: Bool) -> some View {
        GeometryReader { safeArea in
            GeometryReader { geometry in
                #if canImport(SwiftUICore, _version: 8.1)
                    if #available(iOS 27.1, *), geometry.reservedRegions(kind: .division)
                        .contains(where: { $0.frame.width > $0.frame.height }) {
                        ArrangementView {
                            framedCapturePreview(reviewing: reviewing, showsZoom: false)
                        } secondary: {
                            tabletopControls(reviewing: reviewing)
                        }
                        .arrangementViewStyle(DuoTabletopCameraStyle())
                    } else {
                        duoFlatCaptureLayout(
                            size: geometry.size, safeAreaInsets: safeArea.safeAreaInsets,
                            reviewing: reviewing)
                    }
                #else
                    duoFlatCaptureLayout(
                        size: geometry.size, safeAreaInsets: safeArea.safeAreaInsets,
                        reviewing: reviewing)
                #endif
            }
            .ignoresSafeArea(.container)
        }
        .accessibilityIdentifier(reviewing ? "camera.review" : "camera.capture")
    }

    @ViewBuilder
    private func duoFlatCaptureLayout(size: CGSize, safeAreaInsets: EdgeInsets, reviewing: Bool) -> some View {
        if size.width >= 640 && size.width > size.height {
            // Each physical half gets an explicit, clipped frame. Neither the
            // viewfinder's aspect ratio nor a control's ideal width moves the split.
            HStack(spacing: 0) {
                framedCapturePreview(reviewing: reviewing)
                    .frame(width: size.width / 2, height: size.height)
                    .clipped()
                captureControls(reviewing: reviewing)
                    .frame(width: size.width / 2, height: size.height)
                    .clipped()
            }
            .frame(width: size.width, height: size.height)
        } else {
            // An open portrait window is wide enough for two columns, but its
            // useful camera layout is still a viewfinder above bottom controls.
            flatCaptureLayout(
                size: CGSize(width: size.width, height: max(0, size.height - safeAreaInsets.top - safeAreaInsets.bottom)),
                safeAreaInsets: safeAreaInsets,
                reviewing: reviewing)
                .padding(.top, safeAreaInsets.top)
                .padding(.bottom, safeAreaInsets.bottom)
        }
    }

    @ViewBuilder
    private func flatCaptureLayout(size: CGSize, safeAreaInsets: EdgeInsets, reviewing: Bool) -> some View {
        if size.width > size.height * 1.15 {
            HStack(spacing: 0) {
                capturePreviewRegion(reviewing: reviewing, safeAreaInsets: safeAreaInsets)
                captureControls(reviewing: reviewing)
                    .frame(width: min(420, max(300, size.width * 0.44)))
            }
        } else {
            VStack(spacing: 0) {
                capturePreviewRegion(reviewing: reviewing, safeAreaInsets: safeAreaInsets)
                captureControls(reviewing: reviewing)
                    .frame(height: min(244, max(208, size.height * 0.32)))
            }
        }
    }

    private func capturePreviewRegion(reviewing: Bool, safeAreaInsets: EdgeInsets) -> some View {
        GeometryReader { geometry in
            let horizontalPadding = min(20, geometry.size.width * 0.05)
            let available = CGSize(
                width: min(700, geometry.size.width) - horizontalPadding * 2,
                height: max(0, geometry.size.height - (reviewing ? 70 : 16)))
            let photoSize = PostPhotoFormat.fittedSize(in: available)
            VStack(spacing: 10) {
                if reviewing {
                    HStack {
                        iconButton(symbol: "chevron.left") { closeFlow() }
                            .accessibilityLabel("Close camera")
                        Spacer()
                    }
                }
                Group {
                    if reviewing { previewCard(size: photoSize) } else { cameraPreviewCard(size: photoSize) }
                }
                .overlay(alignment: .bottom) {
                    if !reviewing, camera.hasUltraWide || showsUnavailableCameraControls {
                        lensTogglePill(buttonHeight: 44)
                            .opacity(camera.lensMode.isRear ? 1 : 0)
                            .allowsHitTesting(camera.lensMode.isRear)
                            .accessibilityHidden(!camera.lensMode.isRear)
                            .padding(.bottom, 12)
                    }
                }
                .overlay {
                    if let countdown {
                        Text("\(countdown)")
                            .font(AppTypography.brandHero)
                            .foregroundStyle(.white)
                            .accessibilityLabel("Photo in \(countdown) seconds")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, 8)
            .frame(maxWidth: 700, maxHeight: .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Center the viewfinder in the usable display beside Duo's status bar.
        .padding(.leading, safeAreaInsets.leading)
        .padding(.trailing, safeAreaInsets.trailing)
    }

    @ViewBuilder
    private func captureControls(reviewing: Bool) -> some View {
        if reviewing {
            reviewActionBar
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            RegularCameraControls(
                camera: camera, showsPreview: $showsSubjectPreview, captureDelay: $captureDelay,
                previewAvailable: subjectPreviewAvailable && camera.supportsSubjectPreview, isCountingDown: countdown != nil,
                onCapture: beginTimedCapture, onClose: closeFlow
            )
        }
    }

    private func framedCapturePreview(reviewing: Bool, showsZoom: Bool = true) -> some View {
        GeometryReader { geometry in
            let guide = PostPhotoFormat.fittedSize(in: geometry.size)
            ZStack {
                if reviewing {
                    previewCard(size: guide)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    captureSurface
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    // Fill this physical half with the live scene. The rounded
                    // guide describes exactly the 4:5 crop retained in the post.
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: geometry.size))
                        let guideRect = CGRect(
                            x: (geometry.size.width - guide.width) / 2,
                            y: (geometry.size.height - guide.height) / 2,
                            width: guide.width, height: guide.height)
                        path.addPath(RoundedRectangle(
                            cornerRadius: PostPhotoFormat.cornerRadius, style: .continuous
                        ).path(in: guideRect))
                    }
                    .fill(.black.opacity(0.22), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    RoundedRectangle(cornerRadius: PostPhotoFormat.cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.65), lineWidth: 1)
                        .frame(width: guide.width, height: guide.height)
                        .allowsHitTesting(false)
                    VStack {
                        Spacer()
                        if showsZoom && (camera.hasUltraWide || showsUnavailableCameraControls) {
                            lensTogglePill(buttonHeight: 44)
                                .opacity(camera.lensMode.isRear ? 1 : 0)
                                .allowsHitTesting(camera.lensMode.isRear)
                                .accessibilityHidden(!camera.lensMode.isRear)
                        }
                    }
                    .padding(.bottom, 12)
                    .frame(width: guide.width, height: guide.height)
                }
                if let countdown {
                    Text("\(countdown)").font(AppTypography.brandHero).foregroundStyle(.white)
                }
            }
        }
        .clipped()
        .accessibilityIdentifier("camera.framed.preview")
    }

    private func tabletopControls(reviewing: Bool) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 12)
            if reviewing {
                reviewActionBar.controlSize(.extraLarge)
            } else {
                HStack(spacing: 48) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.12)) { camera.toggleFlash() }
                    } label: {
                        Label(
                            camera.flashMode == .on ? "Flash on" : "Flash off",
                            systemImage: camera.flashMode == .on ? "bolt.fill" : "bolt.slash.fill"
                        )
                        .frame(width: 100, height: 96)
                    }
                    .buttonStyle(.glass)
                    .tint(camera.flashMode == .on ? AppTheme.lightningGold : .white)
                    .disabled(!camera.isFlashAvailable || camera.setupState != .ready)
                    .accessibilityIdentifier("camera.tabletop.flash")

                    Button {
                        beginTimedCapture()
                    } label: {
                        Circle().fill(.white)
                            .overlay(Circle().strokeBorder(AppTheme.smoke, lineWidth: 6).padding(8))
                            .frame(width: 124, height: 124)
                    }
                    .buttonStyle(.plain)
                    .disabled(camera.isCapturing || countdown != nil || camera.setupState != .ready)
                    .accessibilityLabel("Take photo")
                    .accessibilityIdentifier("camera.shutter")

                    Button {
                        Task { await camera.switchLens() }
                    } label: {
                        Label("Flip", systemImage: "arrow.triangle.2.circlepath.camera")
                            .frame(width: 100, height: 96)
                    }
                    .buttonStyle(.glass)
                    .disabled(
                        !camera.canSwitchLens || camera.setupState != .ready || camera.isCapturing || countdown != nil)
                }
                .labelStyle(.titleAndIcon)
                .font(AppTypography.button)
                lensTogglePill(buttonHeight: 52)
                    .disabled(!camera.lensMode.isRear)
                HStack(spacing: 24) {
                    Button {
                        closeFlow()
                    } label: {
                        tabletopSecondaryLabel("Close", systemImage: "xmark")
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    if subjectPreviewAvailable && camera.supportsSubjectPreview && camera.lensMode.isRear {
                        Button {
                            showsSubjectPreview.toggle()
                        } label: {
                            tabletopSecondaryLabel(showsSubjectPreview ? "Preview on" : "Preview", systemImage: "rectangle.on.rectangle")
                        }
                        .buttonStyle(.glass)
                        .frame(maxWidth: .infinity)
                        .disabled(camera.setupState != .ready)
                        .accessibilityLabel(showsSubjectPreview ? "Hide preview" : "Show preview")
                    }
                    Menu {
                        Button("Timer off") { captureDelay = 0 }
                        Button("3 seconds") { captureDelay = 3 }
                        Button("10 seconds") { captureDelay = 10 }
                    } label: {
                        tabletopSecondaryLabel(captureDelay == 0 ? "Timer off" : "\(captureDelay)s timer", systemImage: "timer")
                    }
                    .buttonStyle(.glass)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("camera.timer")
                }
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .tint(.white)
        .accessibilityIdentifier("camera.tabletop.controls")
    }

    private func tabletopSecondaryLabel(_ title: String, systemImage: String) -> some View {
        CameraControlLabel(title: title, systemImage: systemImage)
    }

    private func beginTimedCapture() {
        guard !camera.isCapturing, countdown == nil else { return }
        guard captureDelay > 0 else {
            captureMoment()
            return
        }
        captureTimerTask = Task { @MainActor in
            for remaining in stride(from: captureDelay, through: 1, by: -1) {
                countdown = remaining
                do { try await Task.sleep(for: .seconds(1)) } catch {
                    countdown = nil
                    return
                }
            }
            countdown = nil
            guard !Task.isCancelled else { return }
            captureMoment()
        }
    }

    private var standardLensTogglePill: some View {
        HStack(spacing: 0) {
            ForEach([CameraCaptureMode.ultraWide, .back], id: \.self) { mode in
                let isSelected = camera.lensMode == mode
                Button {
                    Task { await camera.switchTo(mode) }
                } label: {
                    Text(mode == .back ? "1×" : "0.5×")
                        .font(AppTypography.pill)
                        .foregroundStyle(isSelected ? .black : .white)
                        .frame(width: 64, height: 32)
                        .background(
                            isSelected
                                ? Color.white
                                : Color.clear,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .animation(.snappy(duration: 0.18), value: camera.lensMode)
            }
        }
        .padding(4)
        .background(.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
    }

    private var standardCaptureView: some View {
        GeometryReader { proxy in
            let bottomInset = proxy.safeAreaInsets.bottom
            let previewHeight = min(max(proxy.size.height * 0.62, 420), 620)

            VStack(spacing: 0) {
                HStack {
                    iconButton(symbol: "chevron.left") {
                        closeFlow()
                    }

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer(minLength: 24)

                cameraPreviewCard(height: previewHeight)
                    .padding(.horizontal, 20)

                Spacer()

                ZStack {
                    // Shutter always perfectly centered
                    Button {
                        captureMoment()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(.white)
                                .frame(width: 84, height: 84)

                            Circle()
                                .strokeBorder(AppTheme.smoke, lineWidth: 5)
                                .frame(width: 72, height: 72)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(camera.isCapturing)
                    .opacity(camera.isCapturing ? 0.65 : 1)

                    // Flanking buttons sit left and right of shutter on the same row.
                    HStack {
                        if camera.isFlashAvailable {
                            iconChromeButton(size: Self.captureAccessoryButtonSize) {
                                withAnimation(.easeInOut(duration: Self.flashSymbolAnimationDuration)) {
                                    camera.toggleFlash()
                                }
                            } label: {
                                Image(systemName: camera.flashMode == .on ? "bolt.fill" : "bolt.slash.fill")
                                    .font(.system(size: Self.captureAccessoryIconPointSize, weight: .bold))
                                    .foregroundStyle(camera.flashMode == .on ? AppTheme.lightningGold : .white)
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        } else {
                            Color.clear.frame(
                                width: Self.captureAccessoryButtonSize,
                                height: Self.captureAccessoryButtonSize
                            )
                        }

                        Spacer()

                        if camera.canSwitchLens {
                            iconChromeButton(
                                size: Self.captureAccessoryButtonSize,
                                isDisabled: camera.isCapturing
                            ) {
                                withAnimation(.spring(response: Self.lensFlipSpringResponse, dampingFraction: Self.lensFlipSpringDamping)) {
                                    lensFlipRotationDegrees += 180
                                }
                                Task { await camera.switchLens() }
                            } label: {
                                Image(systemName: "arrow.triangle.2.circlepath.camera")
                                    .font(.system(size: Self.captureAccessoryIconPointSize, weight: .bold))
                                    .foregroundStyle(.white)
                                    .rotation3DEffect(
                                        .degrees(lensFlipRotationDegrees),
                                        axis: (x: 0, y: 1, z: 0),
                                        perspective: 0.5
                                    )
                            }
                        } else {
                            Color.clear.frame(
                                width: Self.captureAccessoryButtonSize,
                                height: Self.captureAccessoryButtonSize
                            )
                        }
                    }
                }
                .padding(.horizontal, Self.captureBarHorizontalInset)

                if camera.hasUltraWide {
                    standardLensTogglePill
                        .padding(.top, 28)
                        .opacity(camera.lensMode.isRear ? 1 : 0)
                        .allowsHitTesting(camera.lensMode.isRear)
                        .accessibilityHidden(!camera.lensMode.isRear)
                }

                Spacer().frame(height: max(bottomInset + 28, 48))
            }
        }
    }

    private var audienceSheet: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                PostAudienceSheet(onApplyLocation: applySuggestedLocation)
            }
            .navigationTitle("Who can see this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") {
                        focusedField = nil
                        isAudiencePresented = false
                    }
                    .accessibilityIdentifier("post.sheet.done")
                }
            }
        }
        .presentationDetents([.height(340), .medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .interactiveDismissDisabled(isSubmitting)
    }

    private func composerView() -> some View {
        let captionBinding = Binding<String>(
            get: { store.postDraft.caption },
            set: { store.postDraft.caption = PostDraft.limitedCaption($0) }
        )
        return CaptureComposerView(
            orderedDrinksExcludingLast: orderedDrinksExcludingLast,
            lastPostedDrink: lastPostedDrinkFromCatalog,
            filteredFriends: filteredFriends,
            tagSearch: $tagSearch,
            caption: captionBinding,
            focusedField: $focusedField,
            onToggleDrink: { drink in
                store.toggleDrink(drink)
            },
            onSelectDrink: { drink in
                store.selectDrink(drink)
                pinnedAddedDrinkID = drink.id
                focusedField = nil
            },
            onAddDrinkNamed: addDrink(named:emoji:)
        )
    }

    /// The last-posted drink resolved from store.drinks by name, so the ID
    /// matches what selectDrink/selectedDrinkForDraft use. Backend-reconstructed
    /// post drinks have stableUUID-derived IDs that differ from the catalog IDs
    /// in store.drinks, so passing the raw post drink to the repeat pill causes
    /// selectDrink to store an ID that selectedDrinkForDraft can never find.
    private var lastPostedDrinkFromCatalog: DrinkTag? {
        store.latestPostedDrinkFromCatalog
    }

    /// Drink pills minus the last-posted drink, which is shown separately
    /// as the "Repeat last" pill at the head of the row. Prevents duplicates.
    private var orderedDrinksExcludingLast: [DrinkTag] {
        guard let last = lastPostedDrinkFromCatalog else { return orderedDrinks }
        return orderedDrinks.filter {
            $0.name.localizedCaseInsensitiveCompare(last.name) != .orderedSame
        }
    }

    private func repeatLastPill(drink: DrinkTag) -> some View {
        let isSelected = store.postDraft.selectedDrinkIDs.contains(drink.id)
        return Button {
            store.toggleDrink(drink)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(.subheadline, weight: .bold))
                Text(drink.name)
                    .lineLimit(1)
            }
            .font(AppTypography.controlLabel)
            .foregroundStyle(isSelected ? AppTheme.foregroundOnAccent(accent) : .white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Capsule().fill(isSelected ? accent : .clear))
            .overlay(Capsule().strokeBorder(isSelected ? accent : .white.opacity(0.10), lineWidth: isSelected ? 2.5 : 1.5))
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }

    private var captureSurface: some View {
        Group {
            #if DEBUG
            if store.isLayoutPreview && ProcessInfo.processInfo.arguments.contains("--duo-camera-scene"),
               let image = UIImage(data: DuoLayoutFixtures.cameraScene()) {
                GeometryReader { geometry in
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .overlay(alignment: .topLeading) {
                            Text("Camera layout preview")
                                .font(AppTypography.caption)
                                .padding(12)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(12)
                        }
                }
            } else { liveCaptureSurface }
            #else
            liveCaptureSurface
            #endif
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            camera.capturePreviewSize = size
        }
        .onGeometryChange(for: CGRect.self) { geometry in
            let frame = geometry.frame(in: .global)
            return PostPhotoFormat.centerCropRect(in: geometry.size)
                .offsetBy(dx: frame.minX, dy: frame.minY)
        } action: { frame in
            // Measurement only: it does not change the live preview's layout.
            if !isReviewingCapture { cameraGuideFrame = frame }
        }
    }

    private var liveCaptureSurface: some View {
        Group {
            if case .ready = camera.setupState {
                CameraPreviewView(previewLayer: camera.primaryPreviewLayer, isMirrored: camera.lensMode == .front, adaptsToDuoOrientation: store.isDuoDevice) {
                    camera.captureRotationAngle = $0
                }
            } else if store.isDuoDevice {
                ZStack {
                    Color.black
                    VStack(spacing: 12) {
                        switch camera.setupState {
                        case .idle, .preparing:
                            ProgressView().tint(.white)
                            Text("Opening camera…")
                        case .denied:
                            Image(systemName: "camera")
                            Text("Allow camera access in Settings to take a photo.")
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.glass)
                        case .failed:
                            Image(systemName: "camera")
                            Text("Camera unavailable")
                            Button("Try again") { Task { await camera.prepare(supportsSubjectPreview: store.isDuoDevice) } }
                                .buttonStyle(.glass)
                        case .ready:
                            EmptyView()
                        }
                    }
                    .font(AppTypography.rowSubtitle)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(24)
                }
            } else {
                Color.black
            }
        }
    }

    private func cameraPreviewCard(height: CGFloat) -> some View {
        captureSurface
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(AppTheme.line, lineWidth: 1)
            )
            .glassEffect(.regular, in: .rect(cornerRadius: 30))
    }

    private func cameraPreviewCard(size: CGSize) -> some View {
        captureSurface
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: PostPhotoFormat.cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: PostPhotoFormat.cornerRadius, style: .continuous)
                    .strokeBorder(AppTheme.line, lineWidth: 1)
            )
            .glassEffect(.regular, in: .rect(cornerRadius: PostPhotoFormat.cornerRadius))
    }

    private func previewCard(size: CGSize) -> some View {
        ZStack {
            if let data = pendingCapturedPhotoData ?? store.postDraft.capturedPhotoData,
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                LinearGradient(
                    colors: [
                        Color(hex: store.selectedDrinkForDraft?.primaryHex ?? "#2A1815"),
                        Color(hex: store.selectedDrinkForDraft?.secondaryHex ?? "#B86831")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Image(systemName: store.postDraft.sampleSymbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: PostPhotoFormat.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PostPhotoFormat.cornerRadius, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: PostPhotoFormat.cornerRadius))
    }

    private func addDrink(named rawName: String, emoji: String?) {
        guard let drink = store.addCustomDrink(named: rawName, emoji: emoji) else { return }
        suggestedDrinkID = drink.id
        pinnedAddedDrinkID = drink.id
        focusedField = nil
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(AppTypography.pillSmall)
            .foregroundStyle(.white)
            .tracking(1.8)
    }

    private func iconChromeButton(
        size: CGFloat,
        isDisabled: Bool = false,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> some View
    ) -> some View {
        Button(action: action) {
            label()
                .frame(width: size, height: size)
                .background(.black.opacity(0.22), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    private func iconButton(
        symbol: String,
        symbolForeground: Color? = nil,
        size: CGFloat = 44,
        iconPointSize: CGFloat = 16,
        action: @escaping () -> Void
    ) -> some View {
        iconChromeButton(size: size, action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconPointSize, weight: .bold))
                .foregroundStyle(symbolForeground ?? .white)
        }
    }

    private func captureMoment() {
        if store.isDuoDevice && camera.setupState != .ready { return }
        if !store.isLayoutPreview { permissions.requestLocation() }
        applySuggestedLocation()
        if camera.setupState == .ready {
            camera.capturePhoto(optimizedForDuo: store.isDuoDevice)
        } else {
            tagSearch = ""
            suggestedDrinkID = nil
            store.useSampleCapture()
            applySuggestedLocation()
        }
    }

    private func closeFlow() {
        captureTimerTask?.cancel()
        focusedField = nil
        camera.endPresentation(id: presentationID)
        store.closePostFlow()
        dismiss()
    }

    private func retakePhoto() {
        guard !isSubmitting else { return }
        focusedField = nil
        isAudiencePresented = false
        drinkSuggestionTask?.cancel()
        suggestedDrinkID = nil
        // Retake replaces just the photo; keep any optional details already entered.
        store.clearDraftCapture(preservingDetails: true)
        camera.clearCapture()
        camera.beginPresentation(id: presentationID)
        if !store.isLayoutPreview {
            Task { await camera.prepare(supportsSubjectPreview: store.isDuoDevice) }
        }
    }

    private func confirmCapturedPhoto() {
        guard let pendingCapturedPhotoData else { return }
        store.applyCapturedPhoto(pendingCapturedPhotoData, lensMode: camera.lensMode)
        showsSubjectPreview = false
        camera.endPresentation(id: presentationID)
        applySuggestedLocation()
        suggestDrink(from: pendingCapturedPhotoData)
        self.pendingCapturedPhotoData = nil
    }

    private func publishPhoto() {
        guard !isSubmitting else { return }
        focusedField = nil
        applySuggestedLocation()
        guard store.canPublishDraft else { return }
        isSubmitting = true
        submittedPhotoData = store.postDraft.capturedPhotoData
        drinkSuggestionTask?.cancel()
        camera.endPresentation(id: presentationID)
        store.pendingMaddoxPlayer = store.selectedDrinksForDraft.contains {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .localizedCaseInsensitiveCompare("Maddox") == .orderedSame
        }
        // The root cover owns dismissal after posting from the inline review.
        Task { @MainActor in
            await store.publishDraft()
            isSubmitting = false
        }
    }

    #if DEBUG
    /// Exercise the same capture acceptance, Retake, and Post actions with the
    /// network-free fixture store. Never runs for a signed-in production store.
    @MainActor private func checkReviewFlow() async {
        guard store.isLayoutPreview else { return }
        try? await Task.sleep(for: .milliseconds(200))
        precondition(store.postDraft.capturedPhotoData != nil && pendingCapturedPhotoData == nil)
        precondition(store.canPublishDraft && !store.postDraft.shareLocally)
        precondition(store.postDraft.selectedDrinkIDs.isEmpty, "Quick Post must not add hidden drink tags")
        store.postDraft.caption = "Keep this caption"
        let friendIDs = Set(store.friends.prefix(1).map(\.id))
        store.postDraft.taggedFriendIDs = friendIDs
        retakePhoto()
        precondition(!isReviewingCapture && !store.canPublishDraft)
        precondition(store.postDraft.caption == "Keep this caption" && store.postDraft.taggedFriendIDs == friendIDs)
        pendingCapturedPhotoData = DuoLayoutFixtures.reviewPhoto()
        try? await Task.sleep(for: .milliseconds(200))
        precondition(isReviewingCapture && pendingCapturedPhotoData == nil && store.canPublishDraft)
        try? await Task.sleep(for: .milliseconds(400))
        let before = store.posts.count
        publishPhoto()
        precondition(isSubmitting && store.isPostFlowPresented)
        publishPhoto()
        try? await Task.sleep(for: .milliseconds(200))
        precondition(!isSubmitting && store.isPostFlowPresented)
        precondition(store.posts.count == before, "Failed publish must remove its optimistic post")
        precondition(store.postDraft.caption == "Keep this caption" && store.postDraft.capturedPhotoData != nil)
        precondition(store.postPublishError != nil, "Failed publish must explain how to retry")
        FileHandle.standardError.write(Data("PASS: capture review, Retake, duplicate-tap guard, failed publish retains photo and details\n".utf8))
    }
    #endif

    private func applySuggestedLocation() {
        let match = nearestVenueMatch
        let matchDistance = match?.distance ?? .greatestFiniteMagnitude
        let suggestedVenue = matchDistance <= venueMatchRadius ? match?.venue : nil
        store.applyDraftLocation(activeLocationSnapshot, suggestedVenue: suggestedVenue)
    }

    private func suggestDrink(from data: Data) {
        drinkSuggestionTask?.cancel()
        drinkSuggestionTask = Task {
            guard let category = await DrinkVisionSuggestionEngine.suggestCategory(from: data),
                  !Task.isCancelled,
                  let suggestedDrink = suggestedDrink(for: category)
            else {
                return
            }

            suggestedDrinkID = suggestedDrink.id

            // Rank a suggestion in Add details, but never silently tag a quick post.
        }
    }

    private func suggestedDrink(for category: SuggestedDrinkCategory) -> DrinkTag? {
        switch category {
        case .beer:
            return store.drinks.first { $0.name.localizedCaseInsensitiveContains("Beer") }
        case .wine:
            return store.drinks.first { $0.name.localizedCaseInsensitiveContains("Wine") }
        case .martini:
            return store.drinks.first { $0.name.localizedCaseInsensitiveContains("Martini") }
        case .negroni:
            return store.drinks.first { $0.name.localizedCaseInsensitiveContains("Negroni") }
        case .highball:
            return store.drinks.first { $0.name.localizedCaseInsensitiveContains("Highball") }
        case .paloma:
            return store.drinks.first { $0.name.localizedCaseInsensitiveContains("Paloma") }
        }
    }

    private func distance(from location: CLLocation, to venue: Venue) -> CLLocationDistance {
        let venueLocation = CLLocation(latitude: venue.latitude, longitude: venue.longitude)
        return location.distance(from: venueLocation)
    }

    @ViewBuilder
    private var reviewActionBar: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 14) {
                HStack(spacing: 14) {
                    reviewActionButton(
                        title: "Retake",
                        systemImage: "camera.rotate",
                        prominence: .secondary,
                        action: retakePhoto
                    )
                    reviewActionButton(
                        title: "Post",
                        systemImage: "paperplane.fill",
                        prominence: .primary,
                        action: publishPhoto
                    )
                }
            }
        } else {
            HStack(spacing: 14) {
                reviewActionButton(
                    title: "Retake",
                    systemImage: "camera.rotate",
                    prominence: .secondary,
                    action: retakePhoto
                )
                reviewActionButton(
                    title: "Post",
                    systemImage: "paperplane.fill",
                    prominence: .primary,
                    action: publishPhoto
                )
            }
        }
    }

    private func reviewActionButton(
        title: String,
        systemImage: String,
        prominence: ReviewActionProminence,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(AppTypography.rowTitle)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(ReviewActionButtonStyleModifier(accentColor: accent, prominence: prominence))
        .contentShape(Capsule())
    }
}

private enum ReviewActionProminence {
    case primary
    case secondary
}

private struct ReviewActionButtonStyleModifier: ViewModifier {
    let accentColor: Color
    let prominence: ReviewActionProminence

    // When the accent is white the filled button would render white-on-white.
    // Use black text so the label remains legible against the white fill.
    private var primaryForeground: Color {
        AppTheme.foregroundOnAccent(accentColor)
    }

    func body(content: Content) -> some View {
        switch prominence {
        case .primary:
            content
                .foregroundStyle(primaryForeground)
                .background(accentColor.opacity(0.9), in: Capsule())
                .overlay(Capsule().strokeBorder(accentColor, lineWidth: 1.5))
                .glassCapsule(interactive: true, tint: accentColor.opacity(0.22))
                .contentShape(Capsule())
        case .secondary:
            content
                .foregroundStyle(.white)
                .background(.white.opacity(0.04), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                .glassCapsule(interactive: true)
                .contentShape(Capsule())
        }
    }
}

private extension View {
    @ViewBuilder
    func glassCapsule(interactive: Bool, tint: Color = .clear) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.tint(tint).interactive(interactive), in: .capsule)
        } else {
            self.background(.ultraThinMaterial, in: Capsule())
        }
    }
}

/// Horizontal scroll row of friend tag pills. Extracted into its own struct
/// so the Swift type checker can resolve `ForEach<[UserProfile], UUID, _>`
/// independently, without being confused by the complex ViewBuilder context
/// of its parent.
private struct FriendTagRow: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    let friends: [UserProfile]

    private let horizontalBleed: CGFloat = 20
    private let fadeWidth: CGFloat = 48
    private let edgeTolerance: CGFloat = 4

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(friends) { friend in
                    let isSelected = store.postDraft.taggedFriendIDs.contains(friend.id)
                    Button {
                        store.toggleTaggedFriend(friend)
                    } label: {
                        HStack(spacing: 8) {
                            AvatarView(avatar: friend.avatar, size: 26)
                            Text(friend.displayName)
                                .lineLimit(1)
                        }
                        .font(AppTypography.button)
                        .foregroundStyle(.white)
                        .padding(.leading, 11)
                        .padding(.trailing, 10)
                        .padding(.vertical, 9)
                        .background(
                            Capsule()
                                .fill(isSelected ? accent.opacity(0.16) : .white.opacity(0.045))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(
                                    isSelected ? accent : AppTheme.line,
                                    lineWidth: isSelected ? 2.5 : 1
                                )
                        )
                        .shadow(color: isSelected ? accent.opacity(0.34) : .clear, radius: 10, x: 0, y: 0)
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .contentShape(Capsule())
                }
            }
            .padding(.vertical, 8)
        }
        .contentMargins(.horizontal, horizontalBleed, for: .scrollContent)
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .horizontalScrollEdgeFade(width: fadeWidth, tolerance: edgeTolerance)
        .padding(.horizontal, -horizontalBleed)
    }
}

/// The optional fields live directly below the captured photo. The review owns
/// scrolling and the persistent Post/Retake footer so there is only one form.
private struct CaptureComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    let orderedDrinksExcludingLast: [DrinkTag]
    let lastPostedDrink: DrinkTag?
    let filteredFriends: [UserProfile]
    @Binding var tagSearch: String
    @Binding var caption: String
    @FocusState.Binding var focusedField: CaptureComposerField?
    let onToggleDrink: (DrinkTag) -> Void
    let onSelectDrink: (DrinkTag) -> Void
    let onAddDrinkNamed: (String, String?) -> Void

    init(
        orderedDrinksExcludingLast: [DrinkTag],
        lastPostedDrink: DrinkTag?,
        filteredFriends: [UserProfile],
        tagSearch: Binding<String>,
        caption: Binding<String>,
        focusedField: FocusState<CaptureComposerField?>.Binding,
        onToggleDrink: @escaping (DrinkTag) -> Void,
        onSelectDrink: @escaping (DrinkTag) -> Void,
        onAddDrinkNamed: @escaping (String, String?) -> Void
    ) {
        self.orderedDrinksExcludingLast = orderedDrinksExcludingLast
        self.lastPostedDrink = lastPostedDrink
        self.filteredFriends = filteredFriends
        self._tagSearch = tagSearch
        self._caption = caption
        self._focusedField = focusedField
        self.onToggleDrink = onToggleDrink
        self.onSelectDrink = onSelectDrink
        self.onAddDrinkNamed = onAddDrinkNamed
    }

    @State private var showsDrinkPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            drinkSection
            tagFriendsSection
                .id(PostReviewScrollTarget.friends)
            captionSection
                .id(PostReviewScrollTarget.caption)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if store.isLayoutPreview {
                try? await Task.sleep(for: .milliseconds(arguments.contains("--post-keyboard-layout-check") ? 3000 : 500))
                guard !Task.isCancelled else { return }
                if arguments.contains("--post-caption-preview") { focusedField = .caption }
                if arguments.contains("--post-friend-search-preview") { focusedField = .tagSearch }
                if arguments.contains("--post-friend-no-results-preview") {
                    tagSearch = "zzzz"
                    focusedField = .tagSearch
                }
                if arguments.contains("--post-drink-picker-preview") { showsDrinkPicker = true }
            }
            #endif
        }
        .navigationDestination(isPresented: $showsDrinkPicker) {
            DrinkPickerView(onSelectDrink: onSelectDrink, onAddDrinkNamed: onAddDrinkNamed)
                .environment(store)
                .environment(\.appAccent, accent)
        }
    }

    // MARK: - Optional details

    @ViewBuilder
    private var drinkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                composerSectionTitle("Drink")

                Spacer(minLength: 12)

                composerToolButton(title: "Find drink", symbol: "magnifyingglass") {
                    focusedField = nil
                    showsDrinkPicker = true
                }
            }

            DrinkPillGrid(
                drinks: orderedDrinksExcludingLast,
                lastDrink: lastPostedDrink,
                selectedDrinkIDs: Set(store.postDraft.selectedDrinkIDs),
                onToggle: onToggleDrink
            )
        }
    }

    @ViewBuilder
    private var tagFriendsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                composerSectionTitle("Tag friends")

                Spacer()

                let count = store.postDraft.taggedFriendIDs.count
                if count > 0 {
                    Text("\(count) tagged")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(accent.opacity(0.12), in: Capsule())
                }
            }

            composerSearchField(
                placeholder: "Search friends",
                text: $tagSearch,
                focusedField: .tagSearch
            )

            if focusedField == .tagSearch || !tagSearch.isEmpty {
                if filteredFriends.isEmpty {
                    Text("No friends found")
                        .font(AppTypography.caption)
                        .foregroundStyle(AppTheme.softText)
                } else {
                    FriendTagRow(friends: filteredFriends)
                }
            } else if !store.postDraft.taggedFriendIDs.isEmpty {
                FriendTagRow(friends: store.friends.filter {
                    store.postDraft.taggedFriendIDs.contains($0.id)
                })
            }
        }
    }

    @ViewBuilder
    private var captionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                composerSectionTitle("Caption")
                Spacer()
                if caption.count >= 100 {
                    Text("\(caption.count)/\(PostDraft.captionCharacterLimit)")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(caption.count >= PostDraft.captionCharacterLimit ? Color(hex: "#FFD166") : AppTheme.softText)
                }

                if focusedField == .caption {
                    Button {
                        focusedField = nil
                    } label: {
                        Image(systemName: "keyboard.chevron.compact.down")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.softText)
                            .frame(width: 34, height: 30)
                            .background(.white.opacity(0.05), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            TextField("Add a caption", text: $caption, axis: .vertical)
                .accessibilityLabel("Caption")
                .accessibilityIdentifier("post.caption")
                .focused($focusedField, equals: .caption)
                .font(AppTypography.body)
                .foregroundStyle(.white)
                .tint(accent)
                .lineLimit(1...3)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
            .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
    }

    private func composerSectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(AppTypography.pillSmall)
            .foregroundStyle(.white.opacity(0.78))
            .tracking(1.6)
    }

    private func composerToolButton(
        title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(AppTypography.captionMedium)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(minHeight: 44)
                .background(.white.opacity(0.05), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .glassEffect(.regular.interactive(), in: .capsule)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .accessibilityIdentifier("post.findDrink")
    }

    private func composerSearchField(
        placeholder: String,
        text: Binding<String>,
        focusedField targetField: CaptureComposerField
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.softText)

            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: targetField)
                .submitLabel(.done)
                .onSubmit { focusedField = nil }
                .accessibilityIdentifier("post.friendSearch")
                .font(AppTypography.searchInput)
                .foregroundStyle(.white)
                .tint(accent)

            if !text.wrappedValue.isEmpty {
                Button {
                    text.wrappedValue = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

private struct PostFlowBlockingOverlay<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .allowsHitTesting(true)
    }
}

private struct DrinkPickerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""
    @State private var isEditingDrinks = false
    @FocusState private var isSearchFocused: Bool

    // Step 2: custom drink confirmation state
    @State private var pendingCustomDrinkName: String? = nil
    @State private var pendingCustomEmoji: String? = nil
    @State private var isPickingEmoji = false

    let onDismiss: (() -> Void)?
    let onSelectDrink: (DrinkTag) -> Void
    let onAddDrinkNamed: (String, String?) -> Void

    init(
        onDismiss: (() -> Void)? = nil,
        onSelectDrink: @escaping (DrinkTag) -> Void,
        onAddDrinkNamed: @escaping (String, String?) -> Void
    ) {
        self.onDismiss = onDismiss
        self.onSelectDrink = onSelectDrink
        self.onAddDrinkNamed = onAddDrinkNamed
    }

    private var searchableDrinks: [DrinkTag] {
        AppStore.deduplicatedDrinks(store.drinks + SeedCatalog.drinks)
    }

    private var trimmedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedQuery: String {
        AppStore.normalizedDrinkName(searchText)
    }

    private var exactSearchMatch: DrinkTag? {
        guard !normalizedQuery.isEmpty else { return nil }
        return searchableDrinks.first {
            AppStore.normalizedDrinkName($0.name) == normalizedQuery
        }
    }

    private var searchResults: [DrinkTag] {
        guard !normalizedQuery.isEmpty else { return searchableDrinks }

        let filtered = searchableDrinks.filter { drink in
            let name = AppStore.normalizedDrinkName(drink.name)
            let subtitle = AppStore.normalizedDrinkName(drink.subtitle)
            return name.contains(normalizedQuery) || subtitle.contains(normalizedQuery)
        }

        return filtered.sorted { lhs, rhs in
            let lhsName = AppStore.normalizedDrinkName(lhs.name)
            let rhsName = AppStore.normalizedDrinkName(rhs.name)
            if (lhsName == normalizedQuery) != (rhsName == normalizedQuery) {
                return lhsName == normalizedQuery
            }
            let lhsStarts = lhsName.hasPrefix(normalizedQuery)
            let rhsStarts = rhsName.hasPrefix(normalizedQuery)
            if lhsStarts != rhsStarts { return lhsStarts && !rhsStarts }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var typedDrinkPreview: DrinkTag {
        exactSearchMatch ?? DrinkTag(
            id: UUID(),
            name: trimmedQuery,
            subtitle: "Custom",
            symbol: "takeoutbag.and.cup.and.straw.fill",
            emoji: DrinkTag.resolvedEmoji(for: trimmedQuery),
            primaryHex: "#B86831",
            secondaryHex: "#2A1815"
        )
    }

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    isSearchFocused = false
                }

            if let pendingName = pendingCustomDrinkName {
                customDrinkConfirmView(name: pendingName)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .trailing).combined(with: .opacity)
                    ))
            } else {
                searchView
                    .transition(.asymmetric(
                        insertion: .move(edge: .leading).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: pendingCustomDrinkName)
        .appSecondaryPageNavigation(title: pendingCustomDrinkName == nil ? "Drinks" : "Name your drink")
        .modifier(PostDetailColumn(maximumWidth: PostDetailPresentation.sheetWidth))
        .background(Color.black.ignoresSafeArea())
        .navigationBarBackButtonHidden(pendingCustomDrinkName != nil)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if pendingCustomDrinkName == nil {
                    Button("Edit list", systemImage: "slider.horizontal.3") {
                        isSearchFocused = false
                        isEditingDrinks = true
                    }
                    .tint(.white)
                    .accessibilityIdentifier("post.editDrinks")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                if pendingCustomDrinkName != nil {
                    Button {
                        withAnimation { pendingCustomDrinkName = nil }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationDestination(isPresented: $isEditingDrinks) {
            DrinkListEditView()
        }
        .overlay {
            if isPickingEmoji {
                PostFlowBlockingOverlay {
                    DrinkEmojiPickerSheet(
                        drinkName: pendingCustomDrinkName ?? "",
                        onDismiss: { isPickingEmoji = false },
                        onSelect: { chosen in
                            pendingCustomEmoji = chosen
                        }
                    )
                    .environment(\.appAccent, accent)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(20)
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.88), value: isPickingEmoji)
        .task {
            #if DEBUG
            guard store.isLayoutPreview else { return }
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--post-drink-search-preview") { searchText = "Margarita" }
            if arguments.contains("--post-drink-custom-preview") { searchText = "Moonlight mocktail" }
            if arguments.contains("--post-drink-edit-preview") { isEditingDrinks = true }
            if arguments.contains("--post-drink-selected-preview"), let drink = store.drinks.last {
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                chooseDrink(drink)
                FileHandle.standardError.write(Data("Drink picker preview selected: \(drink.name); draft selection retained: \(store.postDraft.selectedDrinkIDs.contains(drink.id))\n".utf8))
            }
            #endif
        }
    }

    // MARK: Step 1 — find, select, or add

    private var searchView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                searchField

                if !searchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        sectionTitle(trimmedQuery.isEmpty ? "All drinks" : "Matches")

                        ForEach(searchResults) { drink in
                            let isSelected = store.postDraft.selectedDrinkIDs.contains(drink.id)
                            DrinkAddRow(
                                drink: drink,
                                title: drink.name,
                                buttonTitle: isSelected ? "Selected" : (catalogDrink(matching: drink) != nil ? "Select" : "Add"),
                                isDisabled: isSelected,
                                action: { chooseDrink(drink) }
                            )
                        }
                    }
                }

                if !trimmedQuery.isEmpty && exactSearchMatch == nil {
                    VStack(alignment: .leading, spacing: 9) {
                        sectionTitle("Add your drink")
                        DrinkAddRow(
                            drink: typedDrinkPreview,
                            title: trimmedQuery,
                            buttonTitle: "Add",
                            isDisabled: false,
                            action: {
                                isSearchFocused = false
                                pendingCustomDrinkName = trimmedQuery
                                pendingCustomEmoji = DrinkTag.resolvedEmoji(for: trimmedQuery)
                            }
                        )
                    }
                }

            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 28)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: Step 2 — confirm name + emoji

    private func customDrinkConfirmView(name: String) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: 80)

            VStack(spacing: 28) {
                // Emoji tap target
                Button {
                    isPickingEmoji = true
                } label: {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(hex: "#B86831"), Color(hex: "#2A1815")],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 88, height: 88)

                        if let emoji = pendingCustomEmoji {
                            Text(emoji)
                                .font(.system(size: 42))
                        } else {
                            Image(systemName: "takeoutbag.and.cup.and.straw.fill")
                                .font(.system(size: 34, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                        }

                        // Edit badge
                        Circle()
                            .fill(Color(hex: "#B86831"))
                            .frame(width: 26, height: 26)
                            .overlay(
                                Image(systemName: "pencil")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            )
                            .offset(x: 28, y: 28)
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .contentShape(Circle())

                VStack(spacing: 7) {
                    Text(name)
                        .font(AppTypography.captureSectionTitle)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text(pendingCustomEmoji != nil ? "Tap the icon to change emoji" : "Tap the icon to add an emoji")
                        .font(AppTypography.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }

                Button {
                    addDrink(named: name, emoji: pendingCustomEmoji)
                } label: {
                    Text("Add Drink")
                        .font(AppTypography.button)
                        .foregroundStyle(AppTheme.foregroundOnAccent(accent))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(accent.opacity(0.92), in: Capsule())
                        .overlay(Capsule().strokeBorder(accent, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .glassCapsule(interactive: true, tint: accent.opacity(0.16))
                .contentShape(Capsule())
            }
            .padding(.horizontal, 32)

            Spacer()
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundStyle(AppTheme.softText)

            TextField("Find or add a drink", text: $searchText)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($isSearchFocused)
                .submitLabel(.done)
                .onSubmit { isSearchFocused = false }
                .accessibilityIdentifier("post.drinkSearch")
                .font(AppTypography.searchInput)
                .foregroundStyle(.white)
                .tint(accent)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(AppTypography.pillSmall)
            .foregroundStyle(.white.opacity(0.82))
            .tracking(1.6)
    }

    private func catalogDrink(matching drink: DrinkTag) -> DrinkTag? {
        store.drinks.first {
            AppStore.normalizedDrinkName($0.name) == AppStore.normalizedDrinkName(drink.name)
        }
    }

    private func chooseDrink(_ drink: DrinkTag) {
        if let existing = catalogDrink(matching: drink) {
            onSelectDrink(existing)
            close()
        } else {
            addDrink(named: drink.name, emoji: drink.emoji)
        }
    }

    private func addDrink(named name: String, emoji: String?) {
        onAddDrinkNamed(name, emoji)
        close()
    }

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

// MARK: - Emoji Picker Sheet

private struct DrinkEmojiPickerSheet: View {
    @Environment(\.appAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    let drinkName: String
    var onDismiss: (() -> Void)? = nil
    let onSelect: (String?) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 6)

    var body: some View {
        ZStack {
            AmbientBackground()
                .ignoresSafeArea()

            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {}

            VStack(spacing: 18) {
                Capsule()
                    .fill(.white.opacity(0.45))
                    .frame(width: 44, height: 5)
                    .padding(.top, 10)

                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Choose Emoji")
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(.white)

                        Text("For \"\(drinkName)\"")
                            .font(AppTypography.captionMedium)
                            .foregroundStyle(AppTheme.softText)
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        onSelect(nil)
                        close()
                    } label: {
                        Text("Skip")
                            .font(AppTypography.button)
                            .foregroundStyle(accent)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 11)
                            .background(.white.opacity(0.05), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(DrinkEmojiCatalog.emojis, id: \.self) { emoji in
                            Button {
                                onSelect(emoji)
                                close()
                            } label: {
                                Text(emoji)
                                    .font(.system(size: 30))
                                    .frame(width: 52, height: 52)
                                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private func close() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }
}

private struct DrinkAddRow: View {
    @Environment(\.appAccent) private var accent

    let drink: DrinkTag
    let title: String
    let buttonTitle: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: drink.primaryHex), Color(hex: drink.secondaryHex)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                DrinkIconView(drink: drink, size: 26)
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)

            Text(title)
                .font(AppTypography.bodyMedium)
                .foregroundStyle(.white)
                .lineLimit(1)

            Spacer(minLength: 10)

            Button(action: action) {
                Text(buttonTitle)
                    .font(AppTypography.button)
                    .foregroundStyle(isDisabled ? AppTheme.softText : AppTheme.foregroundOnAccent(accent))
                    .frame(minWidth: 70)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(
                        Capsule()
                            .fill(isDisabled ? .white.opacity(0.06) : accent.opacity(0.92))
                    )
                    .overlay(
                        Capsule()
                            .strokeBorder(isDisabled ? .white.opacity(0.12) : accent, lineWidth: 1)
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
            .glassCapsule(interactive: !isDisabled, tint: isDisabled ? .clear : accent.opacity(0.16))
            .contentShape(Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        )
        .glassEffect(.regular.tint(Color(hex: drink.secondaryHex).opacity(0.10)), in: .rect(cornerRadius: 22))
    }
}

/// One swipeable row keeps the full review compact, with the last-used drink first.
private struct DrinkPillGrid: View {
    @Environment(\.appAccent) private var accent

    let drinks: [DrinkTag]
    let lastDrink: DrinkTag?
    /// Current selected drink ID set — effectively zero or one item.
    let selectedDrinkIDs: Set<UUID>
    /// Tapping any pill calls this; the store decides whether to select or clear it.
    let onToggle: (DrinkTag) -> Void

    init(
        drinks: [DrinkTag],
        lastDrink: DrinkTag?,
        selectedDrinkIDs: Set<UUID>,
        onToggle: @escaping (DrinkTag) -> Void
    ) {
        self.drinks = drinks
        self.lastDrink = lastDrink
        self.selectedDrinkIDs = selectedDrinkIDs
        self.onToggle = onToggle
    }

    private var choices: [DrinkTag] { (lastDrink.map { [$0] } ?? []) + drinks }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(choices) { drink in
                        pill(drink)
                    }
                }
                .padding(.vertical, 3)
            }
            .fixedSize(horizontal: false, vertical: true)
            .scrollClipDisabled()
            .horizontalScrollEdgeFade(width: 18, tolerance: 2)
            .onAppear {
                if let selected = selectedDrinkIDs.first { scroll.scrollTo(selected, anchor: .center) }
            }
        }
    }

    private func pill(_ drink: DrinkTag) -> some View {
        drinkButton(drink: drink, isSelected: selectedDrinkIDs.contains(drink.id))
            .id(drink.id)
    }

    @ViewBuilder
    private func drinkButton(drink: DrinkTag, isSelected: Bool) -> some View {
        // Single button — tapping selects this drink, or clears it if it is
        // already the active choice.
        Button {
            onToggle(drink)
        } label: {
            HStack(spacing: 7) {
                DrinkIconView(drink: drink, size: 26)
                Text(drink.name)
                    .lineLimit(1)
            }
            .font(AppTypography.controlLabel)
            .foregroundStyle(.white)
            .padding(.leading, 14)
            .padding(.trailing, 14)
            .padding(.vertical, 11)
            .background(
                Capsule()
                    .fill(isSelected ? accent.opacity(0.16) : .white.opacity(0.045))
            )
            .overlay(
                Capsule()
                    .strokeBorder(
                        isSelected ? accent : .white.opacity(0.12),
                        lineWidth: isSelected ? 2.5 : 1.5
                    )
            )
            .shadow(color: isSelected ? accent.opacity(0.34) : .clear, radius: 10, x: 0, y: 0)
            .glassEffect(.regular.interactive(), in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contentShape(Capsule())
        .padding(.vertical, 5)
    }
}

/// Simple left-aligned flow layout that wraps children into rows.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        y += rowHeight
        return CGSize(width: width, height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private enum CaptureComposerField: Hashable {
    case tagSearch
    case caption
}

private enum SuggestedDrinkCategory {
    case beer
    case wine
    case martini
    case negroni
    case highball
    case paloma
}

private enum DrinkVisionSuggestionEngine {
    nonisolated static func suggestCategory(from data: Data) async -> SuggestedDrinkCategory? {
        await Task.detached(priority: .utility) {
            let classifyRequest = VNClassifyImageRequest()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .fast
            textRequest.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(data: data, options: [:])

            do {
                try handler.perform([classifyRequest, textRequest])
            } catch {
                return nil
            }

            let imageLabels = (classifyRequest.results ?? [])
                .prefix(8)
                .map { $0.identifier.lowercased() }

            let recognizedText = (textRequest.results ?? [])
                .prefix(8)
                .compactMap { $0.topCandidates(1).first?.string.lowercased() }

            let joined = (imageLabels + recognizedText).joined(separator: " ")

            if matches(joined, keywords: ["beer", "lager", "ale", "ipa", "stout", "pilsner", "heineken", "coors", "miller", "bud", "modelo", "corona"]) {
                return .beer
            }

            if matches(joined, keywords: ["wine", "cabernet", "merlot", "pinot", "chardonnay", "sauvignon"]) {
                return .wine
            }

            if matches(joined, keywords: ["martini", "espresso", "coffee", "cocktail glass"]) {
                return .martini
            }

            if matches(joined, keywords: ["negroni", "campari"]) {
                return .negroni
            }

            if matches(joined, keywords: ["highball", "whiskey", "bourbon", "scotch", "suntory"]) {
                return .highball
            }

            if matches(joined, keywords: ["paloma", "mezcal", "tequila", "grapefruit"]) {
                return .paloma
            }

            return nil
        }
        .value
    }

    nonisolated private static func matches(_ haystack: String, keywords: [String]) -> Bool {
        keywords.contains { haystack.contains($0) }
    }
}
