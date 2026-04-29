import CoreLocation
import SwiftUI
import UIKit
import Vision

struct PostCaptureFlowView: View {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent

    @State private var camera = CameraPipeline()
    @State private var pendingCapturedPhotoData: Data?
    @State private var tagSearch = ""
    @State private var suggestedDrinkID: UUID?
    @State private var didManuallyChooseDrink = false
    @State private var isEnteringCustomDrink = false
    @State private var customDrinkDraft = ""
    @State private var pinnedCustomDrinkID: UUID?   // freshly-added custom drink, always shown first
    @FocusState private var focusedField: CaptureComposerField?

    private let venueMatchRadius: CLLocationDistance = 500

    var body: some View {
        NavigationStack {
            ZStack {
                AmbientBackground()

                if isComposing {
                    composerView()
                } else if isReviewingCapture {
                    captureReviewView
                } else {
                    captureView
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await camera.prepare()
                permissions.requestLocation()
                applySuggestedLocation()
            }
            .onChange(of: camera.capturedPhotoData) { _, newValue in
                guard let newValue else { return }
                pendingCapturedPhotoData = newValue
            }
            .onChange(of: permissions.currentLocation?.timestamp) { _, _ in
                applySuggestedLocation()
            }
            .onDisappear {
                camera.stopSession()
            }
        }
    }

    private var isComposing: Bool {
        store.postDraft.capturedPhotoData != nil || store.postDraft.isUsingSampleCapture
    }

    private var isReviewingCapture: Bool {
        pendingCapturedPhotoData != nil
    }

    /// The pill row the composer renders. Draws from `composerDrinks` (already
    /// capped at 8, recency-ranked) with two promotion rules applied on top:
    ///   1. A freshly-added custom drink always pins to the front so the
    ///      user can see and select it immediately after typing it.
    ///   2. When the viewer has no post history, the vision-suggested drink
    ///      earns the head slot.
    private var orderedDrinks: [DrinkTag] {
        var drinks = store.composerDrinks

        // Always surface a just-added custom drink at the front
        if let pinnedID = pinnedCustomDrinkID,
           let idx = drinks.firstIndex(where: { $0.id == pinnedID }) {
            let pinned = drinks.remove(at: idx)
            drinks.insert(pinned, at: 0)
            return drinks
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
        let query = tagSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = store.friends.sorted { lhs, rhs in
            let lhsSelected = store.postDraft.taggedFriendIDs.contains(lhs.id)
            let rhsSelected = store.postDraft.taggedFriendIDs.contains(rhs.id)

            if lhsSelected != rhsSelected {
                return lhsSelected && !rhsSelected
            }

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

    private var lensTogglePill: some View {
        HStack(spacing: 0) {
            ForEach([CameraCaptureMode.ultraWide, .back], id: \.self) { mode in
                let isSelected = camera.lensMode == mode
                Button {
                    Task { await camera.switchTo(mode) }
                } label: {
                    Text(mode == .back ? "1×" : "0.5×")
                        .font(.system(size: 14, weight: isSelected ? .bold : .semibold, design: .rounded))
                        .foregroundStyle(isSelected ? .black : .white)
                        .frame(width: 52, height: 32)
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

    private var captureView: some View {
        GeometryReader { proxy in
            let bottomInset = proxy.safeAreaInsets.bottom
            let previewHeight = min(max(proxy.size.height * 0.62, 420), 620)

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    iconButton(symbol: "chevron.left") {
                        closeFlow()
                    }

                    Spacer()

                    if case .ready = camera.setupState {
                        Label(camera.lensMode.rawValue, systemImage: camera.lensMode.systemImage)
                            .font(.system(.caption, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(.black.opacity(0.25), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    }

                    if camera.canSwitchLens {
                        iconButton(symbol: "arrow.triangle.2.circlepath.camera") {
                            Task {
                                await camera.switchLens()
                            }
                        }
                        .disabled(camera.isCapturing)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer(minLength: 72)

                cameraPreviewCard(height: previewHeight)
                    .padding(.horizontal, 20)

                Spacer()

                if camera.hasUltraWide && camera.lensMode.isRear {
                    lensTogglePill
                        .padding(.bottom, 16)
                }

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
                .padding(.bottom, max(bottomInset, 20))
            }
        }
    }

    private var captureReviewView: some View {
        GeometryReader { proxy in
            let bottomInset = proxy.safeAreaInsets.bottom
            let previewHeight = min(max(proxy.size.height * 0.62, 420), 620)

            ZStack {
                AmbientBackground()
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 72)

                    previewCard(height: previewHeight)
                        .padding(.horizontal, 20)

                    Spacer()

                    reviewActionBar
                        .padding(.horizontal, 20)
                        .padding(.bottom, max(bottomInset, 20))
                }
            }
        }
    }

    private func composerView() -> some View {
        let captionBinding = Binding<String>(
            get: { store.postDraft.caption },
            set: { store.postDraft.caption = $0 }
        )
        return CaptureComposerView(
            orderedDrinksExcludingLast: orderedDrinksExcludingLast,
            lastPostedDrink: lastPostedDrinkFromCatalog,
            filteredFriends: filteredFriends,
            isEnteringCustomDrink: $isEnteringCustomDrink,
            customDrinkDraft: $customDrinkDraft,
            tagSearch: $tagSearch,
            caption: captionBinding,
            focusedField: $focusedField,
            onReturnToCamera: returnToCamera,
            onToggleDrink: { drink in
                didManuallyChooseDrink = true
                suggestedDrinkID = drink.id
                store.toggleDrink(drink)
            },
            onApplySuggestedLocation: applySuggestedLocation,
            onCommitCustomDrink: commitCustomDrink
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
            didManuallyChooseDrink = true
            suggestedDrinkID = drink.id
            store.toggleDrink(drink)
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(.subheadline, weight: .bold))
                Text(drink.name)
                    .lineLimit(1)
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Capsule().fill(isSelected ? accent : .clear))
            .overlay(Capsule().strokeBorder(isSelected ? accent : .white.opacity(0.25), lineWidth: 1.5))
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private var captureSurface: some View {
        Group {
            if case .ready = camera.setupState {
                CameraPreviewView(session: camera.session, isMirrored: camera.lensMode == .front)
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

    private func previewCard(height: CGFloat) -> some View {
        ZStack {
            if let data = pendingCapturedPhotoData ?? store.postDraft.capturedPhotoData,
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
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
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 30))
    }

    private func commitCustomDrink() {
        guard let drink = store.addCustomDrink(named: customDrinkDraft) else { return }
        didManuallyChooseDrink = true
        suggestedDrinkID = drink.id
        pinnedCustomDrinkID = drink.id   // pin it to the front of the grid
        isEnteringCustomDrink = false
        customDrinkDraft = ""
        focusedField = nil
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .tracking(1.8)
    }

    private func iconButton(symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.22), in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func captureMoment() {
        permissions.requestLocation()
        applySuggestedLocation()

        if case .ready = camera.setupState {
            camera.capturePhoto()
        } else {
            tagSearch = ""
            didManuallyChooseDrink = false
            suggestedDrinkID = nil
            store.useSampleCapture()
            applySuggestedLocation()
        }
    }

    private func closeFlow() {
        focusedField = nil
        camera.stopSession()
        store.closePostFlow()
        dismiss()
    }

    private func returnToCamera() {
        focusedField = nil
        camera.clearCapture()
        pendingCapturedPhotoData = nil
        tagSearch = ""
        suggestedDrinkID = nil
        didManuallyChooseDrink = false
        store.clearDraftCapture()
    }

    private func retakePhoto() {
        focusedField = nil
        pendingCapturedPhotoData = nil
        camera.clearCapture()
    }

    private func confirmCapturedPhoto() {
        guard let pendingCapturedPhotoData else { return }

        // Only reset drink choice state if the user hasn't pinned a
        // custom drink. If they've already typed and committed a custom
        // drink, taking another photo should not clear that selection —
        // the Vision engine would otherwise race back in and overwrite
        // their explicit choice with Beer/Wine after ~5 seconds.
        if pinnedCustomDrinkID == nil {
            didManuallyChooseDrink = false
            suggestedDrinkID = nil
        }

        store.applyCapturedPhoto(pendingCapturedPhotoData, lensMode: camera.lensMode)
        applySuggestedLocation()
        suggestDrink(from: pendingCapturedPhotoData)
        self.pendingCapturedPhotoData = nil
    }

    private func applySuggestedLocation() {
        let match = nearestVenueMatch
        let matchDistance = match?.distance ?? .greatestFiniteMagnitude
        let suggestedVenue = matchDistance <= venueMatchRadius ? match?.venue : nil
        store.applyDraftLocation(activeLocationSnapshot, suggestedVenue: suggestedVenue)
    }

    private func suggestDrink(from data: Data) {
        Task {
            guard let category = await DrinkVisionSuggestionEngine.suggestCategory(from: data),
                  let suggestedDrink = suggestedDrink(for: category)
            else {
                return
            }

            suggestedDrinkID = suggestedDrink.id

            // Never let Vision override a drink the user chose explicitly,
            // whether by tapping a pill or by typing a custom drink name.
            // A pinned custom drink is the strongest signal — Vision should
            // never touch it regardless of `didManuallyChooseDrink`.
            if !didManuallyChooseDrink && pinnedCustomDrinkID == nil {
                store.selectDrink(suggestedDrink)
            }
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
                        title: "Continue",
                        systemImage: "arrow.right",
                        prominence: .primary,
                        action: confirmCapturedPhoto
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
                    title: "Continue",
                    systemImage: "arrow.right",
                    prominence: .primary,
                    action: confirmCapturedPhoto
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
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
        .buttonStyle(.plain)
        .modifier(ReviewActionButtonStyleModifier(accentColor: accent, prominence: prominence))
    }
}

private enum ReviewActionProminence {
    case primary
    case secondary
}

private struct ReviewActionButtonStyleModifier: ViewModifier {
    let accentColor: Color
    let prominence: ReviewActionProminence

    func body(content: Content) -> some View {
        switch prominence {
        case .primary:
            content
                .foregroundStyle(.white)
                .background(accentColor.opacity(0.9), in: Capsule())
                .overlay(Capsule().strokeBorder(accentColor, lineWidth: 1.5))
                .glassCapsule(interactive: true, tint: accentColor.opacity(0.22))
        case .secondary:
            content
                .foregroundStyle(.white)
                .background(.white.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                .glassCapsule(interactive: true)
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

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(friends) { friend in
                    let isSelected = store.postDraft.taggedFriendIDs.contains(friend.id)
                    Button {
                        store.toggleTaggedFriend(friend)
                    } label: {
                        HStack(spacing: 8) {
                            AvatarView(avatar: friend.avatar, size: 28)
                            Text(friend.displayName)
                                .lineLimit(1)
                        }
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            Capsule()
                                .fill(isSelected ? .white.opacity(0.11) : .white.opacity(0.05))
                        )
                        .overlay(
                            Capsule()
                                .strokeBorder(isSelected ? accent.opacity(0.65) : AppTheme.line, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}

/// Composer scroll view, extracted into its own View so `@Bindable store`
/// can be a real stored property wrapper rather than a local annotation
/// (local `@Bindable` in a plain function body is not supported by the
/// Swift compiler).
private struct CaptureComposerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @Environment(\.dismiss) private var dismiss

    let orderedDrinksExcludingLast: [DrinkTag]
    let lastPostedDrink: DrinkTag?
    let filteredFriends: [UserProfile]
    @Binding var isEnteringCustomDrink: Bool
    @Binding var customDrinkDraft: String
    @Binding var tagSearch: String
    @Binding var caption: String
    @FocusState.Binding var focusedField: CaptureComposerField?
    let onReturnToCamera: () -> Void
    let onToggleDrink: (DrinkTag) -> Void
    let onApplySuggestedLocation: () -> Void
    let onCommitCustomDrink: () -> Void

    init(
        orderedDrinksExcludingLast: [DrinkTag],
        lastPostedDrink: DrinkTag?,
        filteredFriends: [UserProfile],
        isEnteringCustomDrink: Binding<Bool>,
        customDrinkDraft: Binding<String>,
        tagSearch: Binding<String>,
        caption: Binding<String>,
        focusedField: FocusState<CaptureComposerField?>.Binding,
        onReturnToCamera: @escaping () -> Void,
        onToggleDrink: @escaping (DrinkTag) -> Void,
        onApplySuggestedLocation: @escaping () -> Void,
        onCommitCustomDrink: @escaping () -> Void
    ) {
        self.orderedDrinksExcludingLast = orderedDrinksExcludingLast
        self.lastPostedDrink = lastPostedDrink
        self.filteredFriends = filteredFriends
        self._isEnteringCustomDrink = isEnteringCustomDrink
        self._customDrinkDraft = customDrinkDraft
        self._tagSearch = tagSearch
        self._caption = caption
        self._focusedField = focusedField
        self.onReturnToCamera = onReturnToCamera
        self.onToggleDrink = onToggleDrink
        self.onApplySuggestedLocation = onApplySuggestedLocation
        self.onCommitCustomDrink = onCommitCustomDrink
    }

    @State private var isEditingDrinks = false

    var body: some View {
        GeometryReader { proxy in
            // Two lines of body text (~22pt each) + 8pt top + 8pt bottom padding
            let captionHeight: CGFloat = 60

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    backButtonRow
                    drinkSection
                    tagFriendsSection
                    captionSection(captionHeight: captionHeight)
                    postButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, max(proxy.safeAreaInsets.bottom, 18))
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .top)
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - Sections (split out to keep the type-checker happy)

    @ViewBuilder
    private var backButtonRow: some View {
        HStack {
            Button {
                onReturnToCamera()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.22), in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    @ViewBuilder
    private var drinkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Drink")
                .font(.system(size: 32, weight: .bold, design: .serif))
                .foregroundStyle(.white)

            DrinkPillGrid(
                drinks: orderedDrinksExcludingLast,
                lastDrink: lastPostedDrink,
                selectedDrinkIDs: Set(store.postDraft.selectedDrinkIDs),
                onToggle: onToggleDrink,
                customPill: {
                    customDrinkPillView
                    editListPillView
                }
            )

            if isEnteringCustomDrink {
                customDrinkFieldView
            }
        }
        .sheet(isPresented: $isEditingDrinks) {
            DrinkListEditView()
                .environment(store)
                .environment(\.appAccent, accent)
        }
    }

    private var editListPillView: some View {
        Button {
            isEditingDrinks = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(.subheadline, weight: .semibold))
                Text("Edit")
                    .lineLimit(1)
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(AppTheme.softText)
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Capsule().fill(.clear))
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.20), lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // Custom drink pill — built here so the button action can directly
    // mutate @Binding state and set @FocusState, both of which require
    // living in the same view context as the binding owners.
    private var customDrinkPillView: some View {
        Button {
            isEnteringCustomDrink = true
            customDrinkDraft = ""
            focusedField = .customDrink
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(.subheadline, weight: .semibold))
                Text("Custom")
                    .lineLimit(1)
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(AppTheme.softText)
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Capsule().fill(.clear))
            .overlay(
                Capsule()
                    .strokeBorder(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            )
        }
        .buttonStyle(.plain)
    }

    private var customDrinkFieldView: some View {
        HStack(spacing: 10) {
            // Tapping the + commits the draft immediately — the user typed
            // a name to use it, so committing on tap is the expected action.
            Button(action: onCommitCustomDrink) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(.subheadline, weight: .semibold))
                    .foregroundStyle(customDrinkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? accent.opacity(0.35) : accent)
            }
            .buttonStyle(.plain)
            .disabled(customDrinkDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            TextField("Diet Coke, Ranch Water, …", text: $customDrinkDraft)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .focused($focusedField, equals: .customDrink)
                .submitLabel(.done)
                .onSubmit(onCommitCustomDrink)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(.white)
                .tint(accent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var tagFriendsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Tag Friends")
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .frame(minWidth: 88, alignment: .leading)

                TextField("Search", text: $tagSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .tagSearch)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                    )
                    .glassEffect(.regular, in: .rect(cornerRadius: 16))
            }

            if !filteredFriends.isEmpty {
                FriendTagRow(friends: filteredFriends)
            }
        }
    }

    @ViewBuilder
    private func captionSection(captionHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Caption")
                    .font(.system(size: 32, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                Spacer()
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

            TextEditor(text: $caption)
                .focused($focusedField, equals: .caption)
                .font(.system(.body, design: .rounded))
                .foregroundStyle(.white)
                .tint(accent)
                .scrollContentBackground(.hidden)
                .frame(height: captionHeight)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
    }

    @ViewBuilder
    private var postButton: some View {
        Button {
            focusedField = nil
            onApplySuggestedLocation()

            let isMaddox = store.selectedDrinksForDraft.contains {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    .localizedCaseInsensitiveCompare("Maddox") == .orderedSame
            }

            // Queue the Maddox player BEFORE dismissing. AppRootView watches
            // isPostFlowPresented — once the cover animates out it checks
            // pendingMaddoxPlayer and presents the sheet cleanly with no
            // camera visible behind it.
            if isMaddox {
                store.pendingMaddoxPlayer = true
                store.selectedTab = .home
            }

            store.publishDraft()
            dismiss()
        } label: {
            Text("Post")
                .font(.system(.headline, design: .rounded, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(accent.opacity(0.85), in: Capsule())
                .overlay(Capsule().strokeBorder(accent, lineWidth: 1.5))
        }
        .disabled(!store.canPublishDraft)
        .glassEffect(.regular.interactive(), in: .capsule)
        .buttonStyle(.plain)
        .padding(.top, 4)
    }
}

/// Wrapping pill grid for drink selection. Supports multi-select — any number
/// of drinks can be toggled on simultaneously. Uses a flow layout so all
/// options are visible with no horizontal scrolling. The custom pill slot is
/// type-erased to AnyView so the compiler can always infer the concrete type.
private struct DrinkPillGrid: View {
    @Environment(\.appAccent) private var accent

    let drinks: [DrinkTag]
    let lastDrink: DrinkTag?
    /// Full set of currently selected drink IDs — drives pill highlight state.
    let selectedDrinkIDs: Set<UUID>
    /// Tapping any pill calls this; the store decides whether to add or remove.
    let onToggle: (DrinkTag) -> Void
    let customPill: AnyView

    init(
        drinks: [DrinkTag],
        lastDrink: DrinkTag?,
        selectedDrinkIDs: Set<UUID>,
        onToggle: @escaping (DrinkTag) -> Void,
        @ViewBuilder customPill: () -> some View
    ) {
        self.drinks = drinks
        self.lastDrink = lastDrink
        self.selectedDrinkIDs = selectedDrinkIDs
        self.onToggle = onToggle
        self.customPill = AnyView(customPill())
    }

    var body: some View {
        FlowLayout(spacing: 8) {
            // Repeat-last pill at the front when there's post history.
            if let lastDrink {
                let isSelected = selectedDrinkIDs.contains(lastDrink.id)
                drinkButton(drink: lastDrink, isSelected: isSelected)
            }

            // All catalog drinks
            ForEach(drinks) { drink in
                let isSelected = selectedDrinkIDs.contains(drink.id)
                drinkButton(drink: drink, isSelected: isSelected)
            }

            // Custom pill always last
            customPill
        }
    }

    @ViewBuilder
    private func drinkButton(drink: DrinkTag, isSelected: Bool) -> some View {
        // Single button — tapping toggles selection on or off.
        // The × is retained as a visual affordance on selected pills so
        // the user has a clear deselect target, but the whole pill is
        // tappable and routes to the same toggle action.
        Button {
            onToggle(drink)
        } label: {
            HStack(spacing: 7) {
                DrinkIconView(drink: drink, size: 26)
                Text(drink.name)
                    .lineLimit(1)

                if isSelected {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(4)
                        .background(.white.opacity(0.20), in: Circle())
                }
            }
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.leading, 14)
            .padding(.trailing, isSelected ? 8 : 14)
            .padding(.vertical, 12)
            .background(Capsule().fill(isSelected ? accent : Color.clear))
            .overlay(Capsule().strokeBorder(isSelected ? accent : .white.opacity(0.25), lineWidth: 1.5))
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(.plain)
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
    case customDrink
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
