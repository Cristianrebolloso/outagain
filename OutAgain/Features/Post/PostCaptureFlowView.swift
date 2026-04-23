import CoreLocation
import SwiftUI
import UIKit
import Vision

struct PostCaptureFlowView: View {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions
    @Environment(\.dismiss) private var dismiss

    @State private var camera = CameraPipeline()
    @State private var tagSearch = ""
    @State private var suggestedDrinkID: UUID?
    @State private var didManuallyChooseDrink = false

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            ZStack {
                AmbientBackground()

                if isComposing {
                    composerView(store: $store)
                } else {
                    captureView
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await camera.prepare()
                permissions.requestLocation()
                applySuggestedVenue()
            }
            .onChange(of: camera.capturedPhotoData) { _, newValue in
                guard let newValue else { return }

                didManuallyChooseDrink = false
                suggestedDrinkID = nil
                store.applyCapturedPhoto(newValue, lensMode: camera.lensMode)
                applySuggestedVenue()
                suggestDrink(from: newValue)
            }
            .onChange(of: permissions.currentLocation?.timestamp) { _, _ in
                applySuggestedVenue()
            }
            .onDisappear {
                camera.stopSession()
            }
        }
    }

    private var isComposing: Bool {
        store.postDraft.capturedPhotoData != nil || store.postDraft.isUsingSampleCapture
    }

    private var orderedDrinks: [DrinkTag] {
        var drinks = store.drinks

        guard let suggestedDrinkID,
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

    private var resolvedVenue: Venue? {
        if let selected = store.selectedVenueForDraft {
            return selected
        }

        guard let currentLocation = permissions.currentLocation else { return nil }

        return store.venues.min { lhs, rhs in
            distance(from: currentLocation, to: lhs) < distance(from: currentLocation, to: rhs)
        }
    }

    private var captureView: some View {
        ZStack(alignment: .bottom) {
            captureSurface

            VStack(spacing: 0) {
                HStack {
                    Button("Back") {
                        store.closePostFlow()
                        dismiss()
                    }
                    .buttonStyle(.glass)

                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                Spacer()

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
                .padding(.bottom, 34)
            }
        }
    }

    private func composerView(store: Bindable<AppStore>) -> some View {
        GeometryReader { proxy in
            let previewHeight = min(max(proxy.size.height * 0.24, 170), 220)
            let captionHeight = min(max(proxy.size.height * 0.11, 74), 94)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button("Back") {
                        camera.clearCapture()
                        tagSearch = ""
                        suggestedDrinkID = nil
                        didManuallyChooseDrink = false
                        self.store.postDraft.capturedPhotoData = nil
                        self.store.postDraft.isUsingSampleCapture = false
                    }
                    .buttonStyle(.glass)

                    Spacer()
                }

                postPreview(height: previewHeight)

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Drink")

                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(orderedDrinks) { drink in
                                let isSelected = self.store.selectedDrinkForDraft?.id == drink.id

                                Button {
                                    didManuallyChooseDrink = true
                                    suggestedDrinkID = drink.id
                                    self.store.selectDrink(drink)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: drink.symbol)
                                            .font(.system(.subheadline, weight: .semibold))
                                        Text(drink.name)
                                            .lineLimit(1)
                                    }
                                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 12)
                                    .background(
                                        Capsule()
                                            .fill(isSelected ? Color(hex: drink.primaryHex).opacity(0.28) : .white.opacity(0.05))
                                    )
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(isSelected ? Color(hex: drink.primaryHex).opacity(0.7) : AppTheme.line, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Place")

                    HStack(spacing: 12) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(AppTheme.warmGold)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(resolvedVenue?.name ?? "Finding place")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)

                            if let resolvedVenue {
                                Text("\(resolvedVenue.neighborhood), \(resolvedVenue.city)")
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(AppTheme.softText)
                            }
                        }

                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 14)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(AppTheme.line, lineWidth: 1)
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        sectionLabel("Tag Friends")
                            .frame(minWidth: 88, alignment: .leading)

                        TextField("Search", text: $tagSearch)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(AppTheme.line, lineWidth: 1)
                            )
                    }

                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(filteredFriends) { friend in
                                let isSelected = self.store.postDraft.taggedFriendIDs.contains(friend.id)

                                Button {
                                    self.store.toggleTaggedFriend(friend)
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
                                            .strokeBorder(isSelected ? AppTheme.warmGold.opacity(0.65) : AppTheme.line, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("Caption")

                    TextEditor(text: store.postDraft.caption)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.white)
                        .scrollContentBackground(.hidden)
                        .frame(height: captionHeight)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(AppTheme.line, lineWidth: 1)
                        )
                }

                Spacer(minLength: 0)

                Button {
                    self.store.publishDraft()
                    dismiss()
                } label: {
                    Text("Post")
                        .font(.system(.headline, design: .rounded, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .disabled(!self.store.canPublishDraft)
                .background(
                    Capsule()
                        .fill(self.store.canPublishDraft ? AppTheme.amber.opacity(0.95) : .white.opacity(0.08))
                )
                .overlay(
                    Capsule()
                        .strokeBorder(self.store.canPublishDraft ? AppTheme.warmGold.opacity(0.55) : AppTheme.line, lineWidth: 1)
                )
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, max(proxy.safeAreaInsets.bottom, 18))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var captureSurface: some View {
        Group {
            if case .ready = camera.setupState {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()
            } else {
                Color.black
                    .ignoresSafeArea()
            }
        }
    }

    private func postPreview(height: CGFloat) -> some View {
        ZStack {
            if let data = store.postDraft.capturedPhotoData, let image = UIImage(data: data) {
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
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(.caption, design: .rounded, weight: .semibold))
            .foregroundStyle(AppTheme.warmGold.opacity(0.88))
            .tracking(1.2)
    }

    private func captureMoment() {
        if case .ready = camera.setupState {
            camera.capturePhoto()
        } else {
            tagSearch = ""
            didManuallyChooseDrink = false
            suggestedDrinkID = nil
            store.useSampleCapture()
            applySuggestedVenue()
        }
    }

    private func applySuggestedVenue() {
        guard let resolvedVenue else { return }
        guard store.selectedVenueForDraft?.id != resolvedVenue.id else { return }
        store.selectVenue(resolvedVenue)
    }

    private func suggestDrink(from data: Data) {
        Task {
            guard let category = await DrinkVisionSuggestionEngine.suggestCategory(from: data),
                  let suggestedDrink = suggestedDrink(for: category)
            else {
                return
            }

            suggestedDrinkID = suggestedDrink.id

            if !didManuallyChooseDrink {
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
