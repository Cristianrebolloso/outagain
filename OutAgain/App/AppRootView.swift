import SwiftUI

struct AppRootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        ZStack {
            AmbientBackground()

            if store.isLive {
                MainShellView()
                    .transition(.opacity)
            } else {
                OnboardingFlowView()
                    .transition(.opacity)
            }
        }
        .sheet(isPresented: $store.isNotificationsPresented) {
            NotificationsCenterView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $store.isPostFlowPresented) {
            PostCaptureFlowView()
        }
    }
}

private struct MainShellView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store

        TabView(selection: $store.selectedTab) {
            NavigationStack {
                HomeFeedView()
            }
            .tag(AppTab.home)
            .tabItem {
                Label(AppTab.home.title, systemImage: AppTab.home.symbol)
            }

            NavigationStack {
                ProfileView()
            }
            .tag(AppTab.profile)
            .tabItem {
                Label(AppTab.profile.title, systemImage: AppTab.profile.symbol)
            }
        }
        .tint(AppTheme.warmGold)
        .tabBarMinimizeBehavior(.onScrollDown)
        .tabViewBottomAccessory {
            CaptureBottomAccessory()
        }
    }
}

private struct CaptureBottomAccessory: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        HStack {
            Spacer()
            Button {
                store.openPostFlow()
            } label: {
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.08))
                        .frame(width: 62, height: 62)
                        .overlay(
                            Circle()
                                .strokeBorder(tint.opacity(0.56), lineWidth: 1)
                        )
                        .glassEffect(.regular.tint(tint.opacity(0.22)).interactive(), in: .circle)

                    Image(systemName: "camera.fill")
                        .font(.system(size: 21, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var tint: Color {
        switch store.selectedTab {
        case .home:
            Color(hex: store.chromeTintHex)
        case .profile:
            Color(hex: store.viewerIdentity.avatar.primaryHex)
        }
    }
}
