import AuthenticationServices
import PhotosUI
import SwiftUI

struct OnboardingFlowView: View {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions
    @State private var selectedPhotoItem: PhotosPickerItem?

    var body: some View {
        @Bindable var store = store

        Group {
            if store.onboardingStep == .welcome {
                welcomeStep
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        header

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
                if let data = try? await newValue.loadTransferable(type: Data.self) {
                    store.onboardingDraft.profileImageData = data
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Out Again")
                .font(.system(size: 44, weight: .bold, design: .serif))
                .foregroundStyle(.white)
        }
        .padding(.top, 12)
    }

    private var welcomeStep: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            VStack(spacing: 14) {
                Text("Welcome to Out Again")
                    .font(.system(size: 44, weight: .bold, design: .serif))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("Private nightlife with your people.")
                    .font(.system(.title3, design: .rounded, weight: .medium))
                    .foregroundStyle(AppTheme.softText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)

            SignInWithAppleButton(.continue) { request in
                request.requestedScopes = [.fullName]
            } onCompletion: { result in
                store.handleAppleSignIn(result)
            }
            .signInWithAppleButtonStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

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
                    SectionEyebrow(title: "Your Profile", detail: "Set a profile picture, display name, and username.")

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
                                    .foregroundStyle(.white, AppTheme.amber)
                                    .background(.black, in: Circle())
                            }
                        }
                        .buttonStyle(.plain)

                        Text("Profile Picture")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)

                        Spacer()
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        fieldLabel("Display Name")
                        TextField("Cristian", text: $store.onboardingDraft.displayName)
                            .textInputAutocapitalization(.words)
                            .padding(16)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(AppTheme.line, lineWidth: 1)
                            )

                        fieldLabel("Username")
                        TextField("afterhours", text: $store.onboardingDraft.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(16)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(AppTheme.line, lineWidth: 1)
                            )
                    }
                }
            }

            Button("Continue") {
                store.continueFromProfile()
            }
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .buttonStyle(.glassProminent)
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            NightPanel(cornerRadius: 34, padding: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    SectionEyebrow(title: "Permissions", detail: "We ask for contacts, notifications, and location so you can find friends and know when they post, react, or comment.")
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
        VStack(alignment: .leading, spacing: 18) {
            NightPanel(cornerRadius: 34, padding: 22) {
                VStack(alignment: .leading, spacing: 18) {
                    SectionEyebrow(title: "Invite Friends", detail: "Share your invite and add suggested friends so your feed starts with people you actually know.")

                    if let url = URL(string: store.onboardingDraft.inviteLink) {
                        ShareLink(item: url) {
                            HStack(spacing: 12) {
                                Image(systemName: "link")
                                    .font(.system(size: 20, weight: .bold))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Share Invite")
                                        .font(.system(.headline, design: .rounded, weight: .semibold))
                                    Text(url.absoluteString)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(AppTheme.softText)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        fieldLabel("Suggested First Adds")
                        ForEach(store.suggestedFriends) { friend in
                            HStack(spacing: 12) {
                                AvatarView(avatar: friend.avatar, size: 46)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(friend.displayName)
                                        .font(.system(.headline, design: .rounded, weight: .semibold))
                                    Text("@\(friend.username) • friends-of-friends")
                                        .font(.system(.subheadline, design: .rounded))
                                        .foregroundStyle(AppTheme.softText)
                                }
                                Spacer()
                                GlassPill(title: "Suggested")
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
    private func fieldLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(.caption2, design: .rounded, weight: .semibold))
            .foregroundStyle(AppTheme.warmGold.opacity(0.8))
            .tracking(1.4)
    }
}

private struct PermissionPromptCard: View {
    let title: String
    let symbol: String
    let state: PermissionState
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(AppTheme.warmGold)
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
