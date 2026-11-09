import SwiftUI
import UIKit
import UserNotifications

struct AppRootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasLoadedAppContent: Bool {
        store.bootstrapPhase == .ready && store.isLive && !store.shouldPresentMaintenanceScreen
    }

    private var defaultBackgroundPhase: DefaultBackgroundPhase {
        hasLoadedAppContent ? .default2 : .default1
    }

    private var launchHandoffAnimation: Animation {
        .easeOut(duration: reduceMotion ? 0.12 : 0.24)
    }

    var body: some View {
        @Bindable var store = store

        ZStack {
            if store.shouldPresentMaintenanceScreen {
                MaintenanceUnavailableView(
                    title: store.maintenanceTitle,
                    message: store.maintenanceMessage
                )
                    .transition(.opacity)
            } else {
                // Three-way routing so the first cold-launch window shows a
                // neutral splash instead of flashing the onboarding UI before
                // bootstrap completes. Once bootstrap resolves, we route to
                // either the live shell or onboarding based on real state.
                switch (store.bootstrapPhase, store.isLive) {
                case (.pending, _):
                    Color.clear
                case (.ready, true):
                    MainShellView()
                        // Mount the ready feed at full opacity beneath the splash.
                        // Only the outgoing cover fades, avoiding a dark dip.
                        .transition(.asymmetric(insertion: .identity, removal: .opacity))
                case (.ready, false):
                    OnboardingFlowView()
                        .transition(.opacity)
                }

                // In-app notification banner — floats above all content
                InAppNotificationOverlay()
                    .zIndex(1)

                NightActivitySummaryOverlay()
                    .zIndex(2.5)

                AppAnnouncementOverlay()
                    .zIndex(3)

                if store.bootstrapPhase == .pending {
                    // Resolve the full viewport before placing the logo. Letting
                    // the logo itself expand beyond a safe-area-sized parent
                    // briefly centers its first glass frame inside Duo's rail.
                    GeometryReader { viewport in
                        LaunchSplashView()
                            .frame(width: viewport.size.width, height: viewport.size.height)
                    }
                        .ignoresSafeArea(.container)
                        .background(AmbientBackground())
                        .environment(\.defaultBackgroundPhase, .default1)
                        .transition(.asymmetric(
                            insertion: .identity,
                            removal: .opacity.animation(launchHandoffAnimation)
                        ))
                        // Keep the outgoing splash above the shell's opaque
                        // surfaces until its dissolve finishes.
                        .zIndex(4)
                        .allowsHitTesting(false)
                }
            }
        }
        // Keep the light field alive beneath route fades. Fading two opaque
        // page backgrounds over black briefly darkens the handoff twice.
        .background(AmbientBackground())
        // Propagate theme to ALL children including LaunchSplashView so the
        // splash background matches the user's chosen theme.
        .environment(\.appAccent, store.accentColorChoice.color)
        .environment(\.appBackgroundTheme, store.backgroundTheme)
        .tint(store.accentColorChoice.color)
        .background(DuoOrientationPolicyView())
        .animation(launchHandoffAnimation, value: store.bootstrapPhase)
        .animation(.easeInOut(duration: 0.22), value: store.isLive)
        .animation(.easeInOut(duration: 0.22), value: store.shouldPresentMaintenanceScreen)
        .fullScreenCover(isPresented: $store.isPostFlowPresented, onDismiss: {
            store.finishPostFlowDismissal()
        }) {
            PostCaptureFlowView(
                camera: store.sharedCamera,
                presentationID: store.postFlowCameraPresentationID ?? UUID()
            )
                .environment(\.appAccent, store.accentColorChoice.color)
                .environment(\.appBackgroundTheme, store.backgroundTheme)
                .environment(\.defaultBackgroundPhase, defaultBackgroundPhase)
                .tint(store.accentColorChoice.color)
        }
        // Maddox player is presented from the root AFTER the post flow cover
        // has fully dismissed. The post button sets pendingMaddoxPlayer = true
        // and calls dismiss() — once isPostFlowPresented flips to false the
        // onChange below fires and presents the player cleanly with no camera
        // visible behind it.
        .onChange(of: store.isPostFlowPresented) { _, isPresented in
            guard !isPresented else { return }

            store.finishPostFlowDismissal()

            if store.pendingMaddoxPlayer {
                store.pendingMaddoxPlayer = false
                // Small delay so the cover dismissal animation finishes
                // before the sheet animates in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    store.isMaddoxPlayerPresented = true
                }
            }
        }
        .onChange(of: store.shouldPresentMaintenanceScreen) { _, isActive in
            guard isActive else { return }
            store.isPostFlowPresented = false
            store.isMaddoxPlayerPresented = false
            store.pendingMaddoxPlayer = false
            store.isSocialInvitePresented = false
        }
        .sheet(isPresented: $store.isMaddoxPlayerPresented) {
            MaddoxPlayerView()
                .environment(\.appAccent, store.accentColorChoice.color)
                .presentationDetents([.large])
                .presentationBackground(.black)
                .appSheetDragHandle()
        }
        .sheet(item: $store.notificationDestination) { destination in
            switch destination {
            case .post(let postID, let commentID):
                ActivityPostDetailSheet(postID: postID, highlightedCommentID: commentID) { profile in
                    store.notificationDestination = nil
                    store.selectedTab = .home
                    store.homeProfile = profile
                }
            case .recap(let recap):
                NightRecapView(route: recap)
            }
        }
        .sheet(isPresented: $store.isSocialInvitePresented) {
            RedeemSocialInviteView()
                .presentationDetents([.large])
                .appSheetDragHandle()
        }
        .onChange(of: store.isLive) { _, isLive in
            if isLive { store.presentPendingSocialInvite() }
        }
        .onChange(of: store.isPostFlowPresented) { _, isPresented in
            if !isPresented { store.presentPendingSocialInvite() }
        }
        .onChange(of: store.notificationDestination) { _, destination in
            if destination == nil { store.presentPendingSocialInvite() }
        }
        .onChange(of: store.isMaddoxPlayerPresented) { _, isPresented in
            if !isPresented { store.presentPendingSocialInvite() }
        }
        .onChange(of: store.shouldPresentMaintenanceScreen) { _, isActive in
            if !isActive { store.presentPendingSocialInvite() }
        }
        // Apply outside presentation modifiers so sheets inherit the same phase.
        .environment(\.defaultBackgroundPhase, defaultBackgroundPhase)
        .task {
            store.bootstrapFromBackendIfNeeded()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // Foregrounding pulls fresh server state so notifications and
            // friend requests inserted while backgrounded land without a
            // cold relaunch. Also restarts the lightweight foreground delta
            // loop so state stays live while the user is in-app.
            switch newPhase {
            case .active:
                store.refreshOnForeground()
            case .background, .inactive:
                store.stopForegroundPolling()
                store.stopMaintenanceConfigPolling()
            @unknown default:
                break
            }
        }
        // Mirror the in-app unread count to the iOS app badge so the user
        // sees the same number on the home screen icon as on the Activity tab.
        .onChange(of: store.unreadNotificationCount) { _, count in
            UNUserNotificationCenter.current().setBadgeCount(count)
        }
        // Clear the badge immediately when the user opens the Activity tab —
        // markActivityAsSeen() will mark rows read, which drives count to 0
        // via the onChange above, but this fires synchronously for zero lag.
        .onChange(of: store.selectedTab) { _, tab in
            if tab == .activity, !store.isViewerAdmin {
                UNUserNotificationCenter.current().setBadgeCount(0)
            }
        }
    }
}

private struct MaintenanceUnavailableView: View {
    @Environment(AppStore.self) private var store
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text(title)
                .font(AppTypography.sheetTitle)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(message)
                .font(AppTypography.rowSubtitle)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
        }
        .padding(.horizontal, AppLayout.screenPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: store.isDuoDevice ? .all : [])
        .accessibilityElement(children: .combine)
    }
}

/// Shown during the first bootstrap, before we know whether the viewer is
/// signed in. The frosted glass logo adapts to the user's themed background.
private struct LaunchSplashView: View {
    var body: some View {
        LiquidGlassClinkLogo()
            .frame(maxWidth: 220)
            .accessibilityIdentifier("launch.logo")
            .padding(.horizontal, AppLayout.screenPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MainShellView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Group {
            if store.isDuoDevice { DuoShellView() }
            else { PhoneMainShellView() }
        }
        .modifier(ProfileSceneThemeScope())
    }
}

private struct DuoShellView: View {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions
    @State private var layoutContinuity = DuoLayoutContinuity()

    var body: some View {
        @Bindable var store = store

        ZStack {
            // Each tab owns one full-window background behind both panes.
            TabView(selection: nativeTabSelection) {
                Tab(
                    store.isViewerAdmin ? "Posts" : AppTab.home.title,
                    systemImage: AppTab.home.symbol,
                    value: AppTab.home
                ) {
                    HomeFeedView()
                        .environment(\.profileSceneTab, .home)
                        .tint(store.accentColorChoice.color)
                }

                Tab(
                    store.isViewerAdmin ? "Admin" : AppTab.activity.title,
                    systemImage: store.isViewerAdmin ? "shield.lefthalf.filled" : AppTab.activity.symbol,
                    value: AppTab.activity
                ) {
                    Group {
                        if store.isViewerAdmin {
                            AdminHomeView()
                        } else {
                            ActivityView()
                        }
                    }
                    .environment(\.profileSceneTab, .activity)
                    .tint(store.accentColorChoice.color)
                }
                .badge(activityBadge)

                Tab(AppTab.friends.title, systemImage: AppTab.friends.symbol, value: AppTab.friends) {
                    AddFriendsSheet()
                        .environment(\.profileSceneTab, .friends)
                        .tint(store.accentColorChoice.color)
                }
                .badge(store.pendingIncomingRequestCount > 0 ? Text("\(store.pendingIncomingRequestCount)") : nil)

                Tab(AppTab.profile.title, systemImage: AppTab.profile.symbol, value: AppTab.profile) {
                    ProfileView()
                        .environment(\.profileSceneTab, .profile)
                        .tint(store.accentColorChoice.color)
                }

                Tab(value: AppTab.post, role: postTabRole) {
                    PostTabPlaceholderView()
                } label: {
                    Label {
                        Text(AppTab.post.title)
                    } icon: {
                        Image(uiImage: (UIImage(systemName: AppTab.post.symbol) ?? UIImage())
                            .withTintColor(UIColor(store.accentColorChoice.color), renderingMode: .alwaysOriginal))
                    }
                }
            }
            .tint(.white)
            .background(DuoTabBarLayoutRecovery())
        }
        .environment(\.duoLayoutContinuity, layoutContinuity)
        .background(DuoSceneLayoutObserver(continuity: layoutContinuity))
        .environment(\.appAccent, store.accentColorChoice.color)
        .tint(store.accentColorChoice.color)
        .task {
            guard !store.isLayoutPreview else { return }
            // If the user skipped the onboarding permissions screen or
            // notifications are still undecided, prompt now — right as they
            // land on the home screen for the first time. This covers both
            // new sign-ups who tapped past the permissions step and returning
            // users whose prior install never surfaced the prompt.
            // reregisterRemoteNotificationsIfAuthorized() is a no-op if
            // already granted, so this is safe to call on every cold launch.
            if permissions.notificationsStatus == .notDetermined {
                await permissions.requestNotifications()
            } else {
                await permissions.reregisterRemoteNotificationsIfAuthorized()
            }
        }
    }

    private var nativeTabSelection: Binding<AppTab> {
        Binding {
            store.selectedTab
        } set: { newTab in
            let previousTab = store.selectedTab

            switch newTab {
            case .home:
                store.handleHomeTabTap()
            case .activity:
                if store.isViewerAdmin {
                    store.handleActivityTabTap()
                    if store.adminReports.isEmpty {
                        store.loadAdminReportsNextPage(reset: true)
                    }
                } else {
                    store.handleActivityTabTap()
                }
            case .post:
                store.openPostFlow()
            case .friends:
                store.handleFriendsTabTap()
            case .admin:
                store.handleAdminTabTap()
            case .profile:
                if previousTab == .profile {
                    store.handleProfileTabTap()
                } else {
                    store.selectedTab = .profile
                }
            }
        }
    }

    private var postTabRole: TabRole {
        if #available(iOS 27.0, *) { .prominent } else { .search }
    }

    private var activityBadge: Text? {
        if store.isViewerAdmin {
            return store.openAdminReportCount > 0 ? Text("\(store.openAdminReportCount)") : nil
        }
        return store.unreadNotificationCount > 0 ? Text("\(store.unreadNotificationCount)") : nil
    }
}

private struct PostTabPlaceholderView: View {
    var body: some View {
        Color.clear
    }
}
