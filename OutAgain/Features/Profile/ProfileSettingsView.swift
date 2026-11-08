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
    private let privacyPolicyURL = URL(string: "https://cristianrebolloso.github.io/outagain/privacy/")!

    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var isTitleScrolled = false
    @State private var isBlockedUsersSheetPresented = false
    @State private var isChangePasswordPresented = false
    @State private var isPasskeysPresented = false
    @State private var isDeleteAccountSheetPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                accentColorPanel
                notificationsPanel
                permissionsPanel
                safetyPanel
                accountPanel
            }
            .padding(.horizontal, AppLayout.screenPadding)
            .padding(.top, AppLayout.secondaryPageTopPadding)
            .padding(.bottom, AppLayout.secondaryPageBottomPadding)
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > 8
        } action: { _, isScrolled in
            isTitleScrolled = isScrolled
        }
        #if DEBUG
        .modifier(DuoScrollPreviewControls())
        #endif
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .modifier(MainPageSurface())
        .appSecondaryPageNavigation(title: "Settings", isScrolled: isTitleScrolled)
        .task(id: store.viewer?.id) {
            await permissions.refreshNotificationStatus()
            await store.refreshNotificationPreferences()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await permissions.refreshNotificationStatus() }
            }
        }
        .navigationDestination(isPresented: $isChangePasswordPresented) {
            ChangePasswordView()
        }
        .navigationDestination(isPresented: $isPasskeysPresented) {
            PasskeySettingsView()
        }
        .sheet(isPresented: $isDeleteAccountSheetPresented) {
            DeleteAccountConfirmationSheet {
                dismiss()
            }
            .presentationDetents([.height(360)])
            .appSheetDragHandle()
            .presentationBackground(Color(hex: "#0A0A0F"))
        }
        .sheet(isPresented: $isBlockedUsersSheetPresented) {
            BlockedUsersSheet()
                .presentationDetents([.medium, .large])
                .appSheetDragHandle()
                .presentationBackground(Color(hex: "#0A0A0F"))
        }
    }

    // MARK: - Accent Color

    private var accentColorPanel: some View {
        // Build the accent panel with `padding: 0` so the horizontal scroll
        // rows can extend edge-to-edge inside the panel. The text rows are
        // re-inset to the original 18pt manually below; the scroll views
        // use `.contentMargins(.horizontal, 18)` so they look inset at rest
        // but let content travel right to the panel edge when scrolled.
        // This eliminates the visual "blocker" where scrolling stopped 18pt
        // shy of the panel's border. The scroll views also get extra
        // vertical content padding so the selected-item glow shadow has
        // room to render without being clipped by the scroll view's bounds.
        NightPanel(cornerRadius: AppLayout.panelRadius, padding: 0) {
            VStack(alignment: .leading, spacing: 14) {
                settingsSectionTitle("Appearance")
                    .padding(.horizontal, 18)

                Text("Accent Color")
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)

                ScrollView(.horizontal, showsIndicators: false) {
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
                // 18pt vertical padding gives the selected-item glow shadow
                // (8pt blur radius, scaled 1.12x) room to render fully
                // without being clipped by the scroll view's bounds.
                .padding(.vertical, 18)
                .padding(.horizontal, 2)
                }
                .contentMargins(.horizontal, 18, for: .scrollContent)

                Text(store.accentColorChoice.label)
                    .font(AppTypography.metadataEmphasis)
                    .foregroundStyle(store.accentColorChoice.color.opacity(0.9))
                    .animation(.snappy(duration: 0.22), value: store.accentColorChoice)
                    .padding(.horizontal, 18)

                Divider()
                    .overlay(AppTheme.line)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 18)

                Text("Background")
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)

                ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(BackgroundTheme.allCases) { theme in
                        let isSelected = store.backgroundTheme == theme
                        Button {
                            store.backgroundTheme = theme
                            // Auto-pair a matching accent when the user picks
                            // certain backgrounds — a sensible default they can
                            // still override by tapping a different accent color.
                            switch theme {
                            case .night:   store.accentColorChoice = .white
                            case .original: store.accentColorChoice = .orange
                            case .orange:  store.accentColorChoice = .orange
default: break
                            }
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill({
                                        switch theme {
                                        case .night:
                                            return LinearGradient(colors: [Color(hex: "#00000F"), Color(hex: "#000000")], startPoint: .top, endPoint: .bottom)
                                        case .original:
                                            return LinearGradient(colors: [Color(hex: "#000000"), Color(hex: "#110703"), Color(hex: "#000000")], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        case .speakeasy:
                                            return LinearGradient(colors: [Color(hex: "#030102"), Color(hex: "#23060C"), Color(hex: "#071014")], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        case .orange:
                                            return LinearGradient(colors: [Color(hex: "#0A0402"), Color(hex: "#070200")], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        case .green:
                                            return LinearGradient(colors: [Color(hex: "#030A04"), Color(hex: "#030803")], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        case .pink:
                                            return LinearGradient(colors: [Color(hex: "#0A0307"), Color(hex: "#080206")], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        case .blue:
                                            return LinearGradient(colors: [Color(hex: "#000205"), Color(hex: "#000103")], startPoint: .topLeading, endPoint: .bottomTrailing)
                                        case .standard:
                                            return LinearGradient(colors: [Color(hex: "#050508"), Color(hex: "#000000")], startPoint: .topLeading, endPoint: .bottomTrailing)
}
                                    }())
                                    .frame(width: 56, height: 40)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(
                                                isSelected ? .white : .white.opacity(0.18),
                                                lineWidth: isSelected ? 2.5 : 1
                                            )
                                    )
                                    .shadow(color: {
                                    switch theme {
                                        case .night:    return Color(hex: "#D0E8FF")
                                        case .original: return Color(hex: "#E0A35D")
                                        case .speakeasy: return Color(hex: "#C8A45D")
                                        case .orange:   return Color(hex: "#FF6B35")
                                        case .green:    return Color(hex: "#4ADE80")
                                        case .pink:     return Color(hex: "#EC4899")
                                        case .blue:     return Color(hex: "#0EA5E9")
                                        case .standard: return store.accentColorChoice.color
}
                                    }().opacity(isSelected ? 0.5 : 0), radius: 8)

                                switch theme {
                                case .night:
                                    // Star cluster preview — white and icy-blue dots of varying sizes
                                    ZStack {
                                        Circle()
                                            .fill(Color.white.opacity(0.95))
                                            .frame(width: 3.5, height: 3.5)
                                            .offset(x: -14, y: -8)
                                        Circle()
                                            .fill(Color(hex: "#D0E8FF").opacity(0.85))
                                            .frame(width: 2.5, height: 2.5)
                                            .offset(x: 10, y: -10)
                                        Circle()
                                            .fill(Color.white.opacity(0.90))
                                            .frame(width: 3.0, height: 3.0)
                                            .offset(x: 2, y: 2)
                                        Circle()
                                            .fill(Color(hex: "#E8F4FF").opacity(0.80))
                                            .frame(width: 2.0, height: 2.0)
                                            .offset(x: -6, y: 8)
                                        Circle()
                                            .fill(Color.white.opacity(0.70))
                                            .frame(width: 2.5, height: 2.5)
                                            .offset(x: 14, y: 4)
                                        Circle()
                                            .fill(Color(hex: "#D0E8FF").opacity(0.60))
                                            .frame(width: 2.0, height: 2.0)
                                            .offset(x: -12, y: 2)
                                        Circle()
                                            .fill(Color.white.opacity(0.85))
                                            .frame(width: 1.5, height: 1.5)
                                            .offset(x: 6, y: -4)
                                    }
                                case .original:
                                    ZStack {
                                        Rectangle()
                                            .fill(
                                                LinearGradient(
                                                    colors: [
                                                        .clear,
                                                        Color(hex: "#B56B35").opacity(0.58),
                                                        .clear,
                                                    ],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .frame(width: 52, height: 18)
                                            .rotationEffect(.degrees(-8))
                                            .blur(radius: 5)
                                            .offset(y: 4)
                                        Rectangle()
                                            .fill(Color(hex: "#E0A35D").opacity(0.35))
                                            .frame(width: 4, height: 40)
                                            .rotationEffect(.degrees(9))
                                            .offset(x: 12)
                                    }
                                case .speakeasy:
                                    ZStack {
                                        Rectangle()
                                            .fill(Color(hex: "#7A1A2A").opacity(0.42))
                                            .frame(width: 7, height: 40)
                                            .blur(radius: 3)
                                            .offset(x: -14)
                                        Rectangle()
                                            .fill(Color(hex: "#C8A45D").opacity(0.22))
                                            .frame(width: 3, height: 44)
                                            .rotationEffect(.degrees(12))
                                            .offset(x: 9)
                                        Rectangle()
                                            .fill(Color(hex: "#4C0C18").opacity(0.32))
                                            .frame(width: 8, height: 40)
                                            .blur(radius: 4)
                                            .offset(x: 18)
                                    }
                                case .orange:
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: "#FF6B35").opacity(0.70))
                                            .frame(width: 24, height: 24)
                                            .blur(radius: 8)
                                            .offset(x: -10, y: -5)
                                        Circle()
                                            .fill(Color(hex: "#FF3D6B").opacity(0.55))
                                            .frame(width: 18, height: 18)
                                            .blur(radius: 7)
                                            .offset(x: 11, y: 6)
                                        Circle()
                                            .fill(Color(hex: "#FFD4A8").opacity(0.88))
                                            .frame(width: 3.5, height: 3.5)
                                            .offset(x: -8, y: 8)
                                        Circle()
                                            .fill(Color(hex: "#FFE8CC").opacity(0.80))
                                            .frame(width: 3.0, height: 3.0)
                                            .offset(x: 13, y: -5)
                                    }
                                case .green:
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: "#16A34A").opacity(0.65))
                                            .frame(width: 22, height: 22)
                                            .blur(radius: 8)
                                            .offset(x: -10, y: -5)
                                        Circle()
                                            .fill(Color(hex: "#4ADE80").opacity(0.50))
                                            .frame(width: 18, height: 18)
                                            .blur(radius: 7)
                                            .offset(x: 10, y: 6)
                                        Circle()
                                            .fill(Color(hex: "#86EFAC").opacity(0.80))
                                            .frame(width: 3.5, height: 3.5)
                                            .offset(x: -6, y: 8)
                                        Circle()
                                            .fill(Color(hex: "#4ADE80").opacity(0.70))
                                            .frame(width: 3.0, height: 3.0)
                                            .offset(x: 12, y: -4)
                                    }
                                case .pink:
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: "#EC4899").opacity(0.65))
                                            .frame(width: 22, height: 22)
                                            .blur(radius: 8)
                                            .offset(x: -10, y: -5)
                                        Circle()
                                            .fill(Color(hex: "#BE185D").opacity(0.58))
                                            .frame(width: 18, height: 18)
                                            .blur(radius: 7)
                                            .offset(x: 10, y: 6)
                                        Circle()
                                            .fill(Color(hex: "#E879F9").opacity(0.50))
                                            .frame(width: 14, height: 14)
                                            .blur(radius: 6)
                                            .offset(x: 0, y: -2)
                                    }
                                case .blue:
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: "#1D4ED8").opacity(0.52))
                                            .frame(width: 22, height: 22)
                                            .blur(radius: 8)
                                            .offset(x: -10, y: -5)
                                        Circle()
                                            .fill(Color(hex: "#0369A1").opacity(0.46))
                                            .frame(width: 18, height: 18)
                                            .blur(radius: 7)
                                            .offset(x: 10, y: 6)
                                        Circle()
                                            .fill(Color(hex: "#22D3EE").opacity(0.30))
                                            .frame(width: 14, height: 14)
                                            .blur(radius: 6)
                                            .offset(x: 0, y: -2)
                                    }
                                case .standard:
                                    ZStack {
                                        Circle()
                                            .fill(Color(hex: "#1A6EFF").opacity(0.45))
                                            .frame(width: 20, height: 20)
                                            .blur(radius: 8)
                                            .offset(x: -10, y: -5)
                                        Circle()
                                            .fill(Color(hex: "#E8009A").opacity(0.40))
                                            .frame(width: 18, height: 18)
                                            .blur(radius: 7)
                                            .offset(x: 10, y: 5)
                                    }
}
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                // Same vertical-padding rationale as the accent row above:
                // give the selected-item glow shadow room to render without
                // being clipped by the scroll view's bounds.
                .padding(.vertical, 18)
                .padding(.horizontal, 2)
                }
                .contentMargins(.horizontal, 18, for: .scrollContent)

                Text(store.backgroundTheme.label)
                    .font(AppTypography.metadataEmphasis)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)

                Spacer()
                    .frame(height: 4)
            }
            .padding(.top, 18)
        }
    }

    // MARK: - Notifications

    private var notificationsPanel: some View {
        NightPanel(cornerRadius: AppLayout.panelRadius, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                settingsSectionTitle("Notifications")

                permissionRow(
                    icon: "bell.badge.fill",
                    title: "Push notifications",
                    state: permissions.notificationsStatus,
                    actionTitle: permissionActionTitle(for: permissions.notificationsStatus),
                    action: requestNotifications
                )

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(PushNotificationCategory.allCases, id: \.self) { category in
                        if category != .friendRequests { Divider().overlay(AppTheme.line) }
                        preferenceToggle(
                            title: category.title,
                            isOn: Binding(
                                get: { store.notificationPreferences[category] },
                                set: { store.setNotificationPreference(category, enabled: $0) }
                            )
                        )
                        .accessibilityIdentifier("settings.\(category == .announcements ? "announcements" : category.rawValue)")
                    }
                }
                .disabled(store.isLoadingNotificationPreferences || store.isSavingNotificationPreferences)

                if store.isSavingNotificationPreferences {
                    ProgressView("Saving…")
                        .font(AppTypography.caption)
                }
                if let error = store.notificationPreferenceError {
                    Text(error)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color(hex: "#FF6B6B"))
                    Button("Retry") { Task { await store.refreshNotificationPreferences() } }
                        .font(AppTypography.caption)
                }

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
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(.white)

                    Text("Post from your Lock Screen")
                        .font(AppTypography.metadata)
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
        NightPanel(cornerRadius: AppLayout.panelRadius, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                settingsSectionTitle("Access")

                permissionRow(
                    icon: "location.fill",
                    title: "Location",
                    state: permissions.locationStatus,
                    actionTitle: permissionActionTitle(for: permissions.locationStatus),
                    action: requestLocation
                )

            }
        }
    }

    // MARK: - Account

    private var safetyPanel: some View {
        NightPanel(cornerRadius: AppLayout.panelRadius, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                settingsSectionTitle("Safety")

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
                                .font(AppTypography.rowTitle)
                                .foregroundStyle(.white)

                        }

                        Spacer(minLength: 12)

                        Text("\(store.blockedUserIDs.count)")
                            .font(AppTypography.button)
                            .foregroundStyle(store.blockedUserIDs.isEmpty ? AppTheme.softText : .white)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(AppTheme.softText.opacity(0.8))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                    )
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
                    .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var accountPanel: some View {
        NightPanel(cornerRadius: AppLayout.panelRadius, padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                if store.arePasskeysEnabled {
                    Button {
                        isPasskeysPresented = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "person.badge.key.fill")
                            Text("Passkeys").font(AppTypography.rowTitle)
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, AppLayout.screenPadding)
                        .padding(.vertical, 16)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(AppTheme.line)
                }
                // No eyebrow, no tagline. The Sign Out button's destructive
                // color and pill framing already read as an account action;
                // an "Account" header plus a "step out cleanly" sentence
                // bloats a panel that should be a single decisive tap.
                Button {
                    isChangePasswordPresented = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "key.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("Change Password")
                            .font(AppTypography.rowTitle)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, AppLayout.screenPadding)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Divider().overlay(AppTheme.line)

                Button {
                    store.signOut()
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.system(size: 15, weight: .bold))
                        Text("Sign Out")
                            .font(AppTypography.rowTitle)
                        Spacer()
                    }
                    .foregroundStyle(Color(hex: "#F2B0A7"))
                    .padding(.horizontal, AppLayout.screenPadding)
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
                            .font(AppTypography.rowTitle)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundStyle(.white.opacity(0.92))
                    .padding(.horizontal, AppLayout.screenPadding)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                FeedAdPrivacySettings()

                Divider().overlay(AppTheme.line)

                Button {
                    isDeleteAccountSheetPresented = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 15, weight: .bold))
                        Text("Delete Account")
                            .font(AppTypography.rowTitle)
                        Spacer()
                    }
                    .foregroundStyle(Color(hex: "#FF8C7A"))
                    .padding(.horizontal, AppLayout.screenPadding)
                    .padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
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
        case .granted, .denied:
            guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
            openURL(url)
        case .notDetermined:
            Task {
                await permissions.requestNotifications()
            }
        }
    }

    private func requestLocation() {
        switch permissions.locationStatus {
        case .notDetermined:
            permissions.requestLocation()
        case .granted, .denied:
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

            Text(title)
                .font(AppTypography.rowTitle)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 12)

            Button(action: action) {
                HStack(spacing: 6) {
                    Text(actionTitle)
                    if state != .notDetermined {
                        Image(systemName: "arrow.up.right")
                            .font(AppTypography.caption)
                    }
                }
                .foregroundStyle(.white)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("\(title): \(state.rawValue)")
            .accessibilityHint(state == .notDetermined ? "Request permission" : "Open system settings")
        }
    }

    private func preferenceToggle(title: String, subtitle: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.white)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(AppTypography.metadata)
                        .foregroundStyle(AppTheme.softText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .tint(store.accentColorChoice.color)
        .padding(.vertical, 8)
    }

    private func settingsSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.sectionTitle)
            .foregroundStyle(.white)
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
                            symbol: "hand.raised.slash.fill"
                        )
                    } else {
                        SectionEyebrow(
                            title: "Safety",
                            detail: "\(store.blockedUsers.count) blocked"
                        )

                        NightPanel(cornerRadius: AppLayout.panelRadius, padding: 12) {
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
                .padding(.horizontal, AppLayout.screenPadding)
                .padding(.top, 12)
                .padding(.bottom, 36)
            }
            .scrollIndicators(.hidden)
            .background(AmbientBackground())
            .appSecondaryPageNavigation(title: "Blocked Users")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                    .font(AppTypography.toolbarAction)
                    .foregroundStyle(accent)
                }
            }
            .navigationDestination(item: $selectedProfile) { profile in
                FriendProfileView(profile: profile, presentationStyle: .embedded)
            }
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
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(.white)

                        VerifiedUsernameLabel(profile: profile, font: AppTypography.footnote, badgeSize: 11)
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
                    .font(AppTypography.buttonFootnote)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(accent, in: Capsule())
                    .overlay(Capsule().strokeBorder(accent.opacity(0.42), lineWidth: 1))
                    .glassEffect(.regular.tint(accent.opacity(0.24)).interactive(), in: .capsule)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

private struct ChangePasswordView: View {
    @Environment(AppStore.self) private var store

    @FocusState private var focusedField: PasswordField?
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var status: PasswordChangeStatus?
    @State private var isSaving = false

    var body: some View {
        ScrollView {
            NightPanel(cornerRadius: AppLayout.panelRadius, padding: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    passwordInput(
                        title: "Current Password",
                        placeholder: "Enter current password",
                        text: $currentPassword,
                        textContentType: .password,
                        field: .current
                    )

                    passwordInput(
                        title: "New Password",
                        placeholder: "10+ chars, upper/lower/number",
                        text: $newPassword,
                        textContentType: .newPassword,
                        field: .new
                    )

                    passwordInput(
                        title: "Confirm New Password",
                        placeholder: "Repeat new password",
                        text: $confirmPassword,
                        textContentType: .newPassword,
                        field: .confirm
                    )

                    if let validationMessage {
                        statusRow(
                            symbol: "exclamationmark.triangle.fill",
                            tint: Color(hex: "#E16B5C"),
                            text: validationMessage
                        )
                    } else if let status {
                        statusRow(symbol: status.symbol, tint: status.tint, text: status.message)
                    }

                    Button {
                        submit()
                    } label: {
                        HStack {
                            Spacer()
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text("Update Password")
                                    .font(AppTypography.rowTitle)
                            }
                            Spacer()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .buttonStyle(.glassProminent)
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.62)
                    .padding(.top, 2)
                }
            }
            .padding(.horizontal, AppLayout.screenPadding)
            .padding(.top, AppLayout.secondaryPageTopPadding)
            .padding(.bottom, AppLayout.secondaryPageBottomPadding)
        }
        .scrollIndicators(.hidden)
        .scrollContentBackground(.hidden)
        .background(AmbientBackground())
        .appSecondaryPageNavigation(title: "Change Password")
        .onDisappear {
            currentPassword = ""
            newPassword = ""
            confirmPassword = ""
        }
    }

    private var canSubmit: Bool {
        !isSaving
        && !currentPassword.isEmpty
        && PasswordRules.isValid(newPassword)
        && newPassword == confirmPassword
    }

    private var validationMessage: String? {
        guard !newPassword.isEmpty || !confirmPassword.isEmpty else { return nil }

        if !newPassword.isEmpty && !PasswordRules.isValid(newPassword) {
            return "Use at least \(PasswordRules.minimumLength) characters for your password."
        }

        if !confirmPassword.isEmpty && newPassword != confirmPassword {
            return "New passwords don't match."
        }

        return nil
    }

    private func passwordInput(
        title: String,
        placeholder: String,
        text: Binding<String>,
        textContentType: UITextContentType,
        field: PasswordField
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(AppTypography.rowTitle)
                .foregroundStyle(.white)

            SecureField(placeholder, text: text)
                .font(AppTypography.formInput)
                .textContentType(textContentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focusedField, equals: field)
                .submitLabel(field == .confirm ? .done : .next)
                .onSubmit {
                    switch field {
                    case .current:
                        focusedField = .new
                    case .new:
                        focusedField = .confirm
                    case .confirm:
                        submit()
                    }
                }
                .padding(16)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(AppTheme.line, lineWidth: 1)
                )
        }
    }

    private func statusRow(symbol: String, tint: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(AppTypography.footnoteMedium)
                .foregroundStyle(AppTheme.softText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        focusedField = nil
        status = nil
        isSaving = true

        Task { @MainActor in
            do {
                try await store.changePassword(
                    currentPassword: currentPassword,
                    newPassword: newPassword
                )
                currentPassword = ""
                newPassword = ""
                confirmPassword = ""
                status = .success("Password updated.")
            } catch {
                status = .failure(error.localizedDescription)
            }

            isSaving = false
        }
    }

    private enum PasswordField: Hashable {
        case current
        case new
        case confirm
    }
}

private enum PasswordChangeStatus {
    case success(String)
    case failure(String)

    var message: String {
        switch self {
        case .success(let message), .failure(let message):
            return message
        }
    }

    var symbol: String {
        switch self {
        case .success:
            return "checkmark.circle.fill"
        case .failure:
            return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success:
            return AppTheme.activeGreen
        case .failure:
            return Color(hex: "#E16B5C")
        }
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
                        .font(AppTypography.sheetTitle)
                        .foregroundStyle(.white)

                    Text("Are you sure you want to delete your account? This is permanent.")
                        .font(AppTypography.rowSubtitleMedium)
                        .foregroundStyle(AppTheme.softText)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(timerLabel)
                        .font(AppTypography.metadataEmphasis)
                        .foregroundStyle(secondsRemaining == 0 ? AppTheme.activeGreen : Color(hex: "#FFB86C"))
                }

                if let errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(AppTypography.metadataEmphasis)
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
                                    .font(AppTypography.rowTitle)
                            }
                            Spacer()
                        }
                        .foregroundStyle(.white)
                        .padding(.vertical, 16)
                        .background(
                            Capsule()
                                .fill(proceedButtonEnabled ? Color(hex: "#D94B3D") : Color.white.opacity(0.10))
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .contentShape(Capsule())
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
