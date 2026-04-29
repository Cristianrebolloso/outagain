import SwiftUI
import UIKit

/// Dedicated Settings destination for the Profile tab. Pulled out of
/// ProfileView so the profile surface can read as identity (avatar,
/// counters, moments, stats) while this surface reads as administration
/// (permissions, preferences, sign-out). Mixing the two forced the user
/// to scroll through settings copy to get to their own posts, which is
/// backwards for a profile.
struct ProfileSettingsView: View {
    // Replace this path if your public policy lives somewhere else before
    // submitting. Apple requires a publicly accessible privacy policy URL.
    private let privacyPolicyURL = URL(string: "https://outagain.app/privacy")!

    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var isBlockedUsersSheetPresented = false
    @State private var isDeleteAccountSheetPresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    accentColorPanel
                    notificationsPanel
                    permissionsPanel
                    safetyPanel
                    accountPanel
                    versionFootnote
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 60)
            }
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(store.accentColorChoice.color)
                }
            }
        }
        .sheet(isPresented: $isDeleteAccountSheetPresented) {
            DeleteAccountConfirmationSheet {
                dismiss()
            }
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isBlockedUsersSheetPresented) {
            BlockedUsersSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Accent Color

    private var accentColorPanel: some View {
        NightPanel(cornerRadius: 28, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                SectionEyebrow(title: "Appearance")

                Text("Accent Color")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)

                HStack(spacing: 12) {
                    ForEach(AccentColorChoice.allCases) { choice in
                        let isSelected = store.accentColorChoice == choice
                        Button {
                            withAnimation(.snappy(duration: 0.22)) {
                                store.accentColorChoice = choice
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(choice.color)
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Circle().strokeBorder(
                                            isSelected ? .white : .white.opacity(0.18),
                                            lineWidth: isSelected ? 2.5 : 1
                                        )
                                    )
                                    .shadow(color: choice.color.opacity(isSelected ? 0.6 : 0), radius: 8)

                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(choice == .white ? .black : .white)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .scaleEffect(isSelected ? 1.12 : 1.0)
                        .animation(.snappy(duration: 0.22), value: isSelected)
                    }
                }
                .padding(.vertical, 4)

                Text(store.accentColorChoice.label)
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(store.accentColorChoice.color.opacity(0.9))
                    .animation(.snappy(duration: 0.22), value: store.accentColorChoice)
            }
        }
    }

    // MARK: - Notifications

    private var notificationsPanel: some View {
        NightPanel(cornerRadius: 28, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                SectionEyebrow(title: "Notifications", detail: "Choose what reaches you")

                permissionRow(
                    icon: "bell.badge.fill",
                    title: "Push notifications",
                    state: permissions.notificationsStatus,
                    actionTitle: permissionActionTitle(for: permissions.notificationsStatus),
                    action: requestNotifications
                )

                VStack(spacing: 0) {
                    preferenceToggle(
                        title: "Friend posts",
                        isOn: Binding(
                            get: { store.notificationPreferences.friendPosts },
                            set: { store.notificationPreferences.friendPosts = $0 }
                        )
                    )

                    Divider().overlay(AppTheme.line)

                    preferenceToggle(
                        title: "Friend requests",
                        isOn: Binding(
                            get: { store.notificationPreferences.friendRequests },
                            set: { store.notificationPreferences.friendRequests = $0 }
                        )
                    )

                    Divider().overlay(AppTheme.line)

                    preferenceToggle(
                        title: "Reactions",
                        isOn: Binding(
                            get: { store.notificationPreferences.likesAndReactions },
                            set: { store.notificationPreferences.likesAndReactions = $0 }
                        )
                    )

                    Divider().overlay(AppTheme.line)

                    preferenceToggle(
                        title: "Comments",
                        isOn: Binding(
                            get: { store.notificationPreferences.commentsAndReplies },
                            set: { store.notificationPreferences.commentsAndReplies = $0 }
                        )
                    )
                }
                .disabled(permissions.notificationsStatus != .granted)
                .opacity(permissions.notificationsStatus == .granted ? 1 : 0.45)

                Divider().overlay(AppTheme.line)

                liveActivitiesRow
            }
        }
    }

    // MARK: - Live Activities row

    private var liveActivitiesRow: some View {
        Toggle(
            isOn: Binding(
                get: { store.liveActivityPreferences.isEnabled },
                set: { store.setLiveActivitiesEnabled($0) }
            )
        ) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "lock.iphone")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(store.accentColorChoice.color)
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.05), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Live Activities")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)

                    Text("Shows Out Again on your phone and Lock Screen for quick posting.")
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(AppTheme.softText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(store.accentColorChoice.color)
        .padding(.vertical, 4)
    }

    // MARK: - Permissions

    private var permissionsPanel: some View {
        NightPanel(cornerRadius: 28, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                SectionEyebrow(title: "Access", detail: "What the app can use")

                permissionRow(
                    icon: "location.fill",
                    title: "Location",
                    state: permissions.locationStatus,
                    actionTitle: permissionActionTitle(for: permissions.locationStatus),
                    action: requestLocation
                )

                permissionRow(
                    icon: "person.crop.circle.badge.checkmark",
                    title: "Contacts",
                    state: permissions.contactsStatus,
                    actionTitle: permissionActionTitle(for: permissions.contactsStatus),
                    action: requestContacts
                )
            }
        }
    }

    // MARK: - Account

    private var safetyPanel: some View {
        NightPanel(cornerRadius: 28, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                SectionEyebrow(title: "Safety")

                Button {
                    isBlockedUsersSheetPresented = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "hand.raised.slash.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color(hex: "#F2B0A7"))
                            .frame(width: 36, height: 36)
                            .background(.white.opacity(0.06), in: Circle())

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Blocked Users")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(.white)

                            Text("See everyone you've blocked and unblock them any time.")
                                .font(.system(.caption, design: .rounded, weight: .medium))
                                .foregroundStyle(AppTheme.softText)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        Text("\(store.blockedUserIDs.count)")
                            .font(.system(.subheadline, design: .rounded, weight: .bold))
                            .foregroundStyle(store.blockedUserIDs.isEmpty ? AppTheme.softText : .white)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.softText.opacity(0.8))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    )
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var accountPanel: some View {
        NightPanel(cornerRadius: 28, padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                // No eyebrow, no tagline. The Sign Out button's destructive
                // color and pill framing already read as an account action;
                // an "Account" header plus a "step out cleanly" sentence
                // bloats a panel that should be a single decisive tap.
                Button {
                    Task {
                        await store.signOut()
                        dismiss()
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 15, weight: .bold))
                        Text("Sign Out")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(Color(hex: "#F2B0A7"))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Divider().overlay(AppTheme.line)

                Button {
                    openURL(privacyPolicyURL)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "lock.doc.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("Privacy Policy")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Divider().overlay(AppTheme.line)

                Button {
                    isDeleteAccountSheetPresented = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("Delete Account")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(Color(hex: "#FF8C7A"))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var versionFootnote: some View {
        VStack(spacing: 4) {
            Text("Designed by Cristian and Maddox")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(AppTheme.softText.opacity(0.7))
            Text("v1.0")
                .font(.system(.caption2, design: .rounded, weight: .medium))
                .foregroundStyle(AppTheme.softText.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 4)
    }

    // MARK: - Permission helpers

    private func permissionActionTitle(for state: PermissionState) -> String {
        switch state {
        case .granted:
            return "On"
        case .notDetermined:
            return "Turn On"
        case .denied:
            return "Settings"
        }
    }

    private func requestNotifications() {
        switch permissions.notificationsStatus {
        case .granted:
            break
        case .notDetermined:
            Task {
                await permissions.requestNotifications()
            }
        case .denied:
            openAppSettings()
        }
    }

    private func requestLocation() {
        switch permissions.locationStatus {
        case .granted, .notDetermined:
            permissions.requestLocation()
        case .denied:
            openAppSettings()
        }
    }

    private func requestContacts() {
        switch permissions.contactsStatus {
        case .granted:
            break
        case .notDetermined:
            Task {
                await permissions.requestContacts()
            }
        case .denied:
            openAppSettings()
        }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    // MARK: - Row helpers

    private func permissionRow(
        icon: String,
        title: String,
        state: PermissionState,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(store.accentColorChoice.color)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.05), in: Circle())

            HStack(spacing: 8) {
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)

                Text(state.rawValue)
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(state == .granted ? AppTheme.activeGreen : AppTheme.softText)
            }

            Spacer(minLength: 12)

            Button(actionTitle, action: action)
                .buttonStyle(.glass)
        }
    }

    private func preferenceToggle(title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(.caption, design: .rounded, weight: .medium))
                        .foregroundStyle(AppTheme.softText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(store.accentColorChoice.color)
        .padding(.vertical, 8)
    }

}

private struct BlockedUsersSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appAccent) private var accent
    @State private var selectedProfile: UserProfile?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.blockedUsers.isEmpty {
                        EmptyStateCard(
                            title: "No blocked users",
                            detail: "Anyone you block will show up here so you can undo it later.",
                            symbol: "hand.raised.slash.fill"
                        )
                    } else {
                        SectionEyebrow(
                            title: "Safety",
                            detail: "\(store.blockedUsers.count) blocked"
                        )

                        NightPanel(cornerRadius: 28, padding: 12) {
                            VStack(spacing: 10) {
                                ForEach(store.blockedUsers) { profile in
                                    BlockedUserRow(
                                        profile: profile,
                                        onOpen: {
                                            selectedProfile = profile
                                        },
                                        onUnblock: {
                                            withAnimation(.snappy(duration: 0.22)) {
                                                store.unblockUser(profile)
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Blocked Users")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .foregroundStyle(accent)
                }
            }
        }
        .sheet(item: $selectedProfile) { profile in
            FriendProfileView(profile: profile)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct BlockedUserRow: View {
    @Environment(\.appAccent) private var accent

    let profile: UserProfile
    let onOpen: () -> Void
    let onUnblock: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    AvatarView(avatar: profile.avatar, size: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.displayName)
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)

                        Text("@\(profile.username)")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(AppTheme.softText)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.softText.opacity(0.8))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            Button(action: onUnblock) {
                Text("Unblock")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(accent, in: Capsule())
                    .overlay(Capsule().strokeBorder(accent.opacity(0.42), lineWidth: 1))
                    .glassEffect(.regular.tint(accent.opacity(0.24)).interactive(), in: .capsule)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

private struct DeleteAccountConfirmationSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let onAccountDeleted: () -> Void

    @State private var secondsRemaining = 5
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @State private var countdownTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Delete Account?")
                        .font(.system(.title2, design: .serif, weight: .bold))
                        .foregroundStyle(.white)

                    Text("Are you sure you want to delete your account? This is permanent.")
                        .font(.system(.subheadline, design: .rounded, weight: .medium))
                        .foregroundStyle(AppTheme.softText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(timerLabel)
                        .font(.system(.caption, design: .rounded, weight: .bold))
                        .foregroundStyle(secondsRemaining == 0 ? AppTheme.activeGreen : Color(hex: "#FFB86C"))
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .foregroundStyle(Color(hex: "#FF9D8F"))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                VStack(spacing: 12) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.glass)
                    .disabled(isDeleting)

                    Button {
                        confirmDeleteAccount()
                    } label: {
                        HStack {
                            Spacer()
                            if isDeleting {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text(proceedLabel)
                                    .font(.system(.headline, design: .rounded, weight: .bold))
                            }
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 16)
                        .background(
                            Capsule()
                                .fill(proceedButtonEnabled ? Color(hex: "#D94B3D") : Color.white.opacity(0.10))
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(!proceedButtonEnabled)
                }
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(AmbientBackground())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") {
                        dismiss()
                    }
                    .disabled(isDeleting)
                }
            }
        }
        .task {
            startCountdown()
        }
        .onDisappear {
            countdownTask?.cancel()
            countdownTask = nil
        }
    }

    private var proceedButtonEnabled: Bool {
        secondsRemaining == 0 && !isDeleting
    }

    private var timerLabel: String {
        if isDeleting {
            return "Deleting your account now…"
        }

        if secondsRemaining == 0 {
            return "Proceed is now available."
        }

        if secondsRemaining == 1 {
            return "Proceed unlocks in 1 second."
        }

        return "Proceed unlocks in \(secondsRemaining) seconds."
    }

    private var proceedLabel: String {
        secondsRemaining == 0 ? "Proceed and Delete Permanently" : "Proceed in \(secondsRemaining)s"
    }

    private func startCountdown() {
        countdownTask?.cancel()
        secondsRemaining = 5
        countdownTask = Task { @MainActor in
            while secondsRemaining > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                secondsRemaining -= 1
            }
        }
    }

    private func confirmDeleteAccount() {
        guard proceedButtonEnabled else { return }
        errorMessage = nil
        isDeleting = true

        Task { @MainActor in
            do {
                try await store.deleteCurrentAccount()
                onAccountDeleted()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isDeleting = false
            }
        }
    }
}
