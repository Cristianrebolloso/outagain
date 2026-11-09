import SwiftUI

struct HomeFeedScopeControl: View {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 12) {
            if store.hasLocalFeedPosts {
                Picker("Home feed", selection: $store.feedScope) {
                    Text("Friends").tag(FeedScope.friends)
                    Text("Local").tag(FeedScope.local)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("home.feedScope")
            }

            if store.feedScope == .local && store.hasLocalFeedPosts {
                Label(permissions.currentLocality.map { "\($0) · Within 35 miles - Last 48 hours" } ?? "Within 35 miles - Last 48 hours",
                      systemImage: "location")
                    .font(AppTypography.caption)
                    .foregroundStyle(AppTheme.softText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else if let recap = store.latestNightRecapRoute {
                Button {
                    store.notificationDestination = .recap(recap)
                } label: {
                    Label("Last night's photos", systemImage: "photo.stack.fill")
                        .font(AppTypography.buttonFootnote)
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("home.nightRecap")
            }
        }
    }
}

/// Discovery must keep working while the picker is hidden and Friends is selected.
/// Attach to Home itself, not to its conditional header.
struct HomeLocalDiscoveryRefresh: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions
    @Environment(\.scenePhase) private var scenePhase

    private var shouldRefresh: Bool {
        scenePhase == .active && store.isLive && store.selectedTab == .home && !store.isLayoutPreview
    }

    func body(content: Content) -> some View {
        content
        .onChange(of: store.hasLocalFeedPosts, initial: true) { _, _ in
            store.reconcileLocalFeedAvailability()
        }
        .onChange(of: store.feedScope) { _, scope in
            guard scope == .local, shouldRefresh else { return }
            permissions.requestLocation()
            Task { await store.refreshLocalFeed(at: permissions.currentLocationSnapshot, force: true) }
        }
        .onChange(of: permissions.currentLocationSnapshot) { _, location in
            guard shouldRefresh, permissions.locationStatus == .granted else { return }
            // GPS updates must not cancel an in-flight network request.
            Task { await store.refreshLocalFeed(at: location) }
        }
        .task(id: shouldRefresh) {
            guard shouldRefresh else { return }
            permissions.requestLocation()
            if permissions.locationStatus == .granted {
                await store.refreshLocalFeed(at: permissions.currentLocationSnapshot)
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                store.reconcileLocalFeedAvailability()
                guard permissions.locationStatus == .granted else { continue }
                permissions.requestLocation()
                await store.refreshLocalFeed(at: permissions.currentLocationSnapshot)
            }
        }
        .onChange(of: permissions.locationStatus, initial: true) { _, status in
            if status == .denied && !store.isLayoutPreview {
                store.clearLocalFeed()
            }
        }
    }
}

struct LocalFeedEmptyState: View {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions

    var body: some View {
        NightPanel(cornerRadius: 24, padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                if store.isLoadingLocalFeed {
                    ProgressView("Finding nearby photos…")
                        .tint(.white)
                } else if permissions.locationStatus == .denied {
                    Label("See what's happening nearby", systemImage: "location.slash")
                        .font(AppTypography.rowTitle)
                    Text("Allow location to see posts shared within 35 miles.")
                        .font(AppTypography.rowSubtitle)
                    Button("Open Settings") { permissions.openSettings() }.buttonStyle(.glass)
                } else if let error = store.localFeedError {
                    Text(error).font(AppTypography.rowSubtitle)
                    Button("Try Again") {
                        permissions.requestLocation()
                        Task { await store.refreshLocalFeed(at: permissions.currentLocationSnapshot, force: true) }
                    }.buttonStyle(.glass)
                } else if permissions.currentLocationSnapshot == nil && !store.isLayoutPreview {
                    Label("Find your local feed", systemImage: "location")
                        .font(AppTypography.rowTitle)
                    Text("Use your location to see recent photos around you.").font(AppTypography.rowSubtitle)
                    Button("Use My Location") { permissions.requestLocation() }.buttonStyle(.glass)
                } else {
                    Label("No nearby posts yet", systemImage: "moon.stars")
                        .font(AppTypography.rowTitle)
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, AppLayout.screenPadding)
    }
}


/// Inserts labels at night boundaries without sorting, regrouping, or changing
/// post identities. Ad positions and Duo's tracked post frames stay unchanged.
struct HomeFeedPeriodHeading: View {
    let date: Date
    let previousDate: Date?

    var body: some View {
        let window = AppStore.tonightWindow(reference: .now)
        let isTonight = window.contains(date)
        if previousDate == nil || previousDate.map({ window.contains($0) }) != isTonight {
            HStack(spacing: 12) {
                Text(isTonight ? "Tonight" : "Earlier")
                    .font(AppTypography.metadataEmphasis)
                    .foregroundStyle(AppTheme.softText)
                    .textCase(.uppercase)
                    .tracking(1.2)
                Rectangle()
                    .fill(AppTheme.line)
                    .frame(height: 1)
            }
            .padding(.horizontal, AppLayout.screenPadding)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
        }
    }
}

struct FriendsFeedEmptyState: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    var body: some View {
        NightPanel(cornerRadius: 28, padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(accent)
                Text("No posts yet")
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(.white)
                Button { store.selectedTab = .friends } label: {
                    Text("Find Friends")
                        .font(AppTypography.button)
                        .frame(minHeight: 36)
                }
                .buttonStyle(.glass)
                .tint(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
