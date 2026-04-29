import PhotosUI
import SwiftUI
import UIKit

struct OnboardingFlowView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @Environment(PermissionCenter.self) private var permissions
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var pendingCropImage: UIImage?

    var body: some View {
        @Bindable var store = store

        Group {
            if store.onboardingStep == .welcome {
                welcomeStep
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header

                        if let socialErrorMessage = store.socialErrorMessage {
                            statusRow(symbol: "exclamationmark.triangle.fill", tint: Color(hex: "#E16B5C"), text: socialErrorMessage)
                        }

                        switch store.onboardingStep {
                        case .welcome:
                            EmptyView()
                        case .profile:
                            profileStep
                        case .permissions:
                            permissionsStep
                        case .invite:
                            inviteStep
                        case .done:
                            EmptyView()
                        }
                    }
                    .padding(20)
                    .padding(.bottom, 40)
                }
                .scrollIndicators(.hidden)
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
                store.onboardingDraft.profileImageData = croppedData
                pendingCropImage = nil
            } onCancel: {
                pendingCropImage = nil
            }
        }
        .task(id: store.onboardingStep == .profile ? store.normalizedOnboardingUsername : "") {
            guard store.onboardingStep == .profile else { return }
            await store.refreshUsernameAvailability()
        }
    }

    @ViewBuilder
    private var header: some View {
        if !headerTitle.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    store.onboardingStep = .welcome
                    store.authState = .signedOut
                    store.socialErrorMessage = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Back")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    }
                    .foregroundStyle(AppTheme.softText)
                }
                .buttonStyle(.plain)

                Text(headerTitle)
                    .font(.system(size: 44, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
            }
            .padding(.top, 12)
        }
    }

    private var headerTitle: String {
        switch store.onboardingStep {
        case .profile: return "Make your Profile"
        case .permissions: return "Permissions"
        case .invite: return "Invite Friends"
        default: return ""
        }
    }

    private var welcomeStep: some View {
        @Bindable var store = store

        return VStack(spacing: 28) {
            Spacer(minLength: 0)

            VStack(spacing: 14) {
                Text("Welcome to Out Again")
                    .font(.system(size: 44, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Nightlife with your friends.")
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .foregroundStyle(AppTheme.softText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            NightPanel(cornerRadius: 34, padding: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    SectionEyebrow(
                        title: store.authDraft.mode.eyebrowTitle
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        fieldLabel("Email Address")
                        TextField("", text: $store.authDraft.email)
                            .keyboardType(.emailAddress)
                            .textContentType(.emailAddress)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Email Address")
                            .padding(16)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(AppTheme.line, lineWidth: 1)
                            )

                        fieldLabel("Password")
                        SecureField(
                            store.isSignInMode ? "Enter your password" : "At least 8 characters",
                            text: $store.authDraft.password
                        )
                        .textContentType(store.isSignInMode ? .password : .newPassword)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(16)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .strokeBorder(AppTheme.line, lineWidth: 1)
                        )
                    }

                    Button(store.authDraft.mode.primaryActionTitle) {
                        store.submitAuth()
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .buttonStyle(.glassProminent)
                    .disabled(!store.canSubmitAuth)
                    .opacity(store.canSubmitAuth ? 1 : 0.65)

                    if let socialErrorMessage = store.socialErrorMessage {
                        statusRow(
                            symbol: "exclamationmark.triangle.fill",
                            tint: Color(hex: "#E16B5C"),
                            text: socialErrorMessage
                        )
                    }

                    HStack(spacing: 8) {
                        Text(store.authDraft.mode.alternatePrompt)
                            .foregroundStyle(AppTheme.softText)

                        Button(store.authDraft.mode.alternateActionTitle) {
                            store.toggleAuthMode()
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                    }
                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(maxWidth: 420)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 36)
    }

    private var profileStep: some View {
        @Bindable var store = store
        let profileImageData = store.onboardingDraft.profileImageData

        return VStack(alignment: .leading, spacing: 18) {
            NightPanel(cornerRadius: 34, padding: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 18) {
                        PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                            AvatarView(
                                avatar: AvatarStyle(
                                    symbol: "moon.stars.fill",
                                    primaryHex: "#D98B3D",
                                    secondaryHex: "#281916",
                                    imageData: profileImageData
                                ),
                                size: 88
                            )
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white, accent)
                                    .background(.black, in: Circle())
                            }
                        }
                        .buttonStyle(.plain)

                        Text("Add a Profile Picture")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)

                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        fieldLabel("Display Name")
                        TextField("Your name", text: $store.onboardingDraft.displayName)
                            .textInputAutocapitalization(.words)
                            .padding(16)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(AppTheme.line, lineWidth: 1)
                            )

                        fieldLabel("Username")
                        TextField("username", text: $store.onboardingDraft.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(16)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(AppTheme.line, lineWidth: 1)
                            )

                        usernameAvailabilityView
                    }
                }
            }

            Button("Continue") {
                store.continueFromProfile()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .buttonStyle(.glassProminent)
            .disabled(!store.canContinueFromProfile)
            .opacity(store.canContinueFromProfile ? 1 : 0.65)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            NightPanel(cornerRadius: 34, padding: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("We ask for contacts, notifications, and location so you can find friends and know when they post, react, or comment.")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                    PermissionPromptCard(
                        title: "Contacts",
                        symbol: "person.2.fill",
                        state: permissions.contactsStatus
                    ) {
                        Task {
                            await permissions.requestContacts()
                        }
                    }
                    PermissionPromptCard(
                        title: "Notifications",
                        symbol: "bell.badge.fill",
                        state: permissions.notificationsStatus
                    ) {
                        Task {
                            await permissions.requestNotifications()
                        }
                    }
                    PermissionPromptCard(
                        title: "Location",
                        symbol: "location.fill",
                        state: permissions.locationStatus
                    ) {
                        permissions.requestLocation()
                    }

                    if let locationErrorMessage = permissions.locationErrorMessage {
                        statusRow(
                            symbol: "location.slash.fill",
                            tint: Color(hex: "#E16B5C"),
                            text: locationErrorMessage
                        )
                    }
                }
            }

            Button("Next") {
                store.continueFromPermissions()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .buttonStyle(.glassProminent)
        }
    }

    private var inviteStep: some View {
        @Bindable var store = store

        return VStack(alignment: .leading, spacing: 18) {
            NightPanel(cornerRadius: 34, padding: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Search by username to find and add friends before you start.")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(.white)

                    VStack(alignment: .leading, spacing: 12) {
                        fieldLabel("Find Friends")
                        TextField("Search by username", text: $store.friendSearchQuery)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(16)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(AppTheme.line, lineWidth: 1)
                            )
                            .onChange(of: store.friendSearchQuery) { _, _ in
                                store.searchForFriends()
                            }

                        if !store.friendSearchResults.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(store.friendSearchResults) { friend in
                                    HStack(spacing: 12) {
                                        AvatarView(avatar: friend.avatar, size: 46)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(friend.displayName)
                                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                            Text("@\(friend.username)")
                                                .font(.system(.subheadline, design: .rounded))
                                                .foregroundStyle(AppTheme.softText)
                                        }
                                        Spacer()
                                        Button("Add") {
                                            store.sendFriendRequest(to: friend)
                                        }
                                        .buttonStyle(.glass)
                                    }
                                }
                            }
                        }
                    }

                    // Only show contacts-based suggestions if the user granted access
                    if permissions.contactsStatus == .granted && !store.suggestedFriends.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            fieldLabel("From Your Contacts")
                            ForEach(store.suggestedFriends) { friend in
                                HStack(spacing: 12) {
                                    AvatarView(avatar: friend.avatar, size: 46)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(friend.displayName)
                                            .font(.system(.headline, design: .rounded, weight: .semibold))
                                        Text("@\(friend.username)")
                                            .font(.system(.subheadline, design: .rounded))
                                            .foregroundStyle(AppTheme.softText)
                                    }
                                    Spacer()
                                    Button("Add") {
                                        store.sendFriendRequest(to: friend)
                                    }
                                    .buttonStyle(.glass)
                                }
                            }
                        }
                    }
                }
            }

            Button("Done") {
                store.enterApp()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .buttonStyle(.glassProminent)
        }
    }
    @ViewBuilder
    private var usernameAvailabilityView: some View {
        switch store.usernameAvailability {
        case .unchecked:
            EmptyView()
        case .checking:
            statusRow(symbol: "hourglass", tint: AppTheme.softText, text: "Checking @\(store.normalizedOnboardingUsername)...")
        case .available(let username, let jokeSuggestion):
            VStack(alignment: .leading, spacing: 8) {
                statusRow(symbol: "checkmark.circle.fill", tint: AppTheme.activeGreen, text: "@\(username) is available")

                if let joke = jokeSuggestion {
                    Button("Try @\(joke)") {
                        store.onboardingDraft.username = joke
                    }
                    .buttonStyle(.glass)
                }
            }
        case .unavailable(let username, let suggestion):
            VStack(alignment: .leading, spacing: 8) {
                statusRow(symbol: "xmark.circle.fill", tint: Color(hex: "#E16B5C"), text: "@\(username) is taken")

                if let suggestion {
                    Button("Try @\(suggestion)") {
                        store.onboardingDraft.username = suggestion
                    }
                    .buttonStyle(.glass)
                }
            }
        case .invalid(let message), .failed(let message):
            statusRow(symbol: "exclamationmark.triangle.fill", tint: Color(hex: "#E16B5C"), text: message)
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

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 22, weight: .bold, design: .serif))
            .foregroundStyle(.white)
    }
}

private struct PermissionPromptCard: View {
    @Environment(\.appAccent) private var accent
    let title: String
    let symbol: String
    let state: PermissionState
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.06), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Spacer()
            Button(action: action) {
                Text(state.rawValue)
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
            }
            .buttonStyle(.glass)
        }
        .padding(18)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(AppTheme.line, lineWidth: 1)
        )
    }
}
