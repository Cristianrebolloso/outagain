import SwiftUI
import UIKit
import UserNotifications

struct AppRootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var store = store

        ZStack {
            // Three-way routing so the first cold-launch window shows a
            // neutral splash instead of flashing the onboarding UI before
            // bootstrap completes. Once bootstrap resolves, we route to
            // either the live shell or onboarding based on real state.
            switch (store.bootstrapPhase, store.isLive) {
            case (.pending, _):
                LaunchSplashView()
                    .transition(.opacity)
            case (.ready, true):
                MainShellView()
                    .transition(.opacity)
            case (.ready, false):
                OnboardingFlowView()
                    .background(AmbientBackground())
                    .transition(.opacity)
            }

            // In-app notification banner — floats above all content
            InAppNotificationOverlay()
        }
        .animation(.easeInOut(duration: 0.22), value: store.bootstrapPhase)
        .animation(.easeInOut(duration: 0.22), value: store.isLive)
        .fullScreenCover(isPresented: $store.isPostFlowPresented) {
            PostCaptureFlowView()
                .environment(\.appAccent, store.accentColorChoice.color)
                .tint(store.accentColorChoice.color)
        }
        // Maddox player is presented from the root AFTER the post flow cover
        // has fully dismissed. The post button sets pendingMaddoxPlayer = true
        // and calls dismiss() — once isPostFlowPresented flips to false the
        // onChange below fires and presents the player cleanly with no camera
        // visible behind it.
        .onChange(of: store.isPostFlowPresented) { _, isPresented in
            if !isPresented && store.pendingMaddoxPlayer {
                store.pendingMaddoxPlayer = false
                // Small delay so the cover dismissal animation finishes
                // before the sheet animates in.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    store.isMaddoxPlayerPresented = true
                }
            }
        }
        .sheet(isPresented: $store.isMaddoxPlayerPresented) {
            MaddoxPlayerView()
                .environment(\.appAccent, store.accentColorChoice.color)
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
                .presentationBackground(.black)
        }
        .sheet(isPresented: $store.isLiveActivityPromptPresented) {
            LiveActivityPromptSheet()
                .environment(\.appAccent, store.accentColorChoice.color)
                .tint(store.accentColorChoice.color)
        }
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
            if tab == .activity {
                UNUserNotificationCenter.current().setBadgeCount(0)
            }
        }
    }
}

/// Shown during the first bootstrap, before we know whether the viewer is
/// signed in. Deliberately minimal so this reads like the app background
/// itself while bootstrap resolves, not a separate branded screen.
private struct LaunchSplashView: View {
    var body: some View {
        AmbientBackground()
            .ignoresSafeArea()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct MainShellView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        ZStack {
            // AmbientBackground lives here at the root, outside every
            // NavigationStack and tab view. It is never re-created when
            // the user switches tabs — the orbs keep animating continuously
            // across the whole session.
            AmbientBackground()
                .ignoresSafeArea()

            // Each tab gets its own NavigationStack so push state is
            // preserved independently. We keep all four in the hierarchy
            // simultaneously (opacity 0 when not selected) rather than
            // using a switch, which destroys and recreates the view —
            // and would restart the ambient background if it lived here.
            ZStack {
                HomeFeedView()
                    .opacity(store.selectedTab == .home ? 1 : 0)
                    .allowsHitTesting(store.selectedTab == .home)

                AddFriendsSheet()
                    .opacity(store.selectedTab == .friends ? 1 : 0)
                    .allowsHitTesting(store.selectedTab == .friends)

                ActivityView()
                    .opacity(store.selectedTab == .activity ? 1 : 0)
                    .allowsHitTesting(store.selectedTab == .activity)

                ProfileView()
                    .opacity(store.selectedTab == .profile ? 1 : 0)
                    .allowsHitTesting(store.selectedTab == .profile)
            }
        }
        .environment(\.appAccent, store.accentColorChoice.color)
        .tint(store.accentColorChoice.color)
        .safeAreaInset(edge: .bottom) {
            LiquidTabBar()
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 8)
        }
    }
}

private struct LiquidTabBar: View {
    @Environment(AppStore.self) private var store
    @Namespace private var tabSelectionNamespace

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            navigationCluster
        }
    }

    private var navigationCluster: some View {
        HStack(spacing: 4) {
            tabButton(
                title: AppTab.home.title,
                symbol: AppTab.home.symbol,
                badgeCount: nil,
                isSelected: store.selectedTab == .home,
                action: { store.handleHomeTabTap() }
            )

            tabButton(
                title: AppTab.friends.title,
                symbol: AppTab.friends.symbol,
                badgeCount: store.pendingIncomingRequestCount,
                isSelected: store.selectedTab == .friends,
                action: { store.selectedTab = .friends }
            )

            // Post sits mid-bar and intentionally reads as an action
            // rather than a tab. Two greyed circles — one for the active
            // tab's selection capsule and one around the Post glyph — was
            // muddying the hierarchy. Dropped the surrounding capsule;
            // differentiation now comes purely from the warm-gold color
            // on the icon and label. The user's eye goes to gold before
            // it reads the selection ring on whichever nav tab is active,
            // preserving Post as the single call-to-action.
            postTabButton

            tabButton(
                title: AppTab.activity.title,
                symbol: AppTab.activity.symbol,
                badgeCount: store.unreadNotificationCount,
                isSelected: store.selectedTab == .activity,
                action: { store.openNotifications() }
            )

            tabButton(
                title: AppTab.profile.title,
                symbol: AppTab.profile.symbol,
                badgeCount: nil,
                isSelected: store.selectedTab == .profile,
                action: { store.selectedTab = .profile }
            )
        }
        .frame(height: 62)
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(.white.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(AppTheme.line, lineWidth: 1))
        .glassEffect(.regular, in: .capsule)
    }

    private func tabButton(
        title: String,
        symbol: String,
        badgeCount: Int?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let foregroundColor: Color = isSelected ? .white : AppTheme.softText

        return Button(action: action) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    if isSelected {
                        Capsule()
                            .fill(.white.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                            )
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .matchedGeometryEffect(id: "tab_selection", in: tabSelectionNamespace)
                            .frame(maxWidth: .infinity)
                            .frame(height: 62)
                    }

                    VStack(spacing: 5) {
                        Image(systemName: symbol)
                            .font(.system(size: 18, weight: .semibold))

                        Text(title)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.88)
                    }
                    .foregroundStyle(foregroundColor)
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .contentShape(Capsule())

                if let badgeCount, badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(store.accentColorChoice.color, in: Capsule())
                        .offset(x: -2, y: 4)
                }
            }
        }
        .buttonStyle(.plain)
        .animation(.snappy(duration: 0.22), value: isSelected)
    }

    /// Post is an *action*, not a navigation destination, so it renders
    /// differently from `tabButton`: no selection capsule (which caused
    /// the "two greyed circles" read when another tab was active),
    /// no hit-area background fill, and warm-gold color applied to both
    /// glyph and label. The icon sits slightly larger than sibling tabs
    /// (20 vs 18) to reinforce that it's the primary CTA in the cluster
    /// without requiring a separate container.
    private var postTabButton: some View {
        Button(action: { store.openPostFlow() }) {
            VStack(spacing: 5) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 20, weight: .bold))

                Text("Post")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
            }
            .foregroundStyle(store.accentColorChoice.color)
            .frame(maxWidth: .infinity)
            .frame(height: 62)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

}
