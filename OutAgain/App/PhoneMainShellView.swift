import SwiftUI

struct PhoneMainShellView: View {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions

    var body: some View {
        @Bindable var store = store

        NavigationStack {
            ZStack {
                // AmbientBackground lives here at the root, outside every
                // per-tab NavigationStack. It is never re-created when
                // the user switches tabs, keeping the static orb layer stable
                // across the whole session.
                AmbientBackground()
                    .ignoresSafeArea()

                TabView(selection: nativeTabSelection) {
                    Tab(
                        store.isViewerAdmin ? "Posts" : AppTab.home.title,
                        systemImage: AppTab.home.symbol,
                        value: AppTab.home
                    ) {
                        PhoneHomeFeedView()
                            .environment(\.profileSceneTab, .home)
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
                    }
                    .badge(activityBadge)

                    Tab(AppTab.friends.title, systemImage: AppTab.friends.symbol, value: AppTab.friends) {
                        AddFriendsSheet()
                            .environment(\.profileSceneTab, .friends)
                    }
                    .badge(store.pendingIncomingRequestCount > 0 ? Text("\(store.pendingIncomingRequestCount)") : nil)

                    Tab(AppTab.profile.title, systemImage: AppTab.profile.symbol, value: AppTab.profile) {
                        ProfileView()
                            .environment(\.profileSceneTab, .profile)
                    }

                    Tab(AppTab.post.title, systemImage: AppTab.post.symbol, value: AppTab.post, role: postTabRole) {
                        PostTabPlaceholderView()
                    }
                }
                .ignoresSafeArea(.keyboard, edges: .bottom)
            }
            .navigationDestination(item: $store.profileOverlayRoute) { route in
                ProfileOverlayDestination(route: route)
            }
        }
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
        // iOS 27 separates prominent tabs into their own Liquid Glass control.
        // Retain the previous placement on iOS 26.
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
