import SwiftUI

struct AdminHomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @State private var isDuoExpanded = false

    var body: some View {
        DuoPageLayout(isExpanded: $isDuoExpanded) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if !store.isDuoDevice { header }

                        VStack(spacing: 12) {
                            adminToolLink(
                                title: "Reports",
                                subtitle: reportsSubtitle,
                                symbol: "flag.fill",
                                tint: Color(hex: "#FF6B6B")
                            ) {
                                AdminReportsView(embedsNavigationStack: false)
                            }

                            adminToolLink(
                                title: "Maintenance Mode",
                                subtitle: maintenanceSubtitle,
                                symbol: "wrench.and.screwdriver.fill",
                                tint: store.isMaintenanceModeActive ? Color(hex: "#FFD166") : accent
                            ) {
                                AdminBroadcastsView(section: .maintenance)
                            }

                            adminToolLink(
                                title: "Feed Ads",
                                subtitle: store.areFeedAdsEnabled ? "On · live ads with promo fallback" : "Off · all ad cards hidden",
                                symbol: "rectangle.stack.badge.play",
                                tint: accent
                            ) {
                                AdminFeedAdsView()
                            }

                            adminToolLink(
                                title: "Notifications",
                                subtitle: notificationsSubtitle,
                                symbol: "bell.badge.fill",
                                tint: accent
                            ) {
                                AdminBroadcastsView(section: .notifications)
                            }
                        }
                    }
                    .padding(.horizontal, AppLayout.screenPadding)
                    .padding(.top, store.isDuoDevice ? AppLayout.secondaryPageTopPadding : 12)
                    .padding(.bottom, AppLayout.tabBarClearance)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.always, axes: .vertical)
                .scrollContentBackground(.hidden)
                .modifier(MainPageSurface())
                .modifier(DuoPageHeader(title: "Admin"))
                .glassPullToRefresh {
                    await refreshAdminOverview(forceReports: true)
                }
                .task {
                    await refreshAdminOverview(forceReports: false)
                }
            }
        } companion: {
            DuoCompanionPlaceholder(
                title: "Admin tools", subtitle: "Manage reports, ads, maintenance and notifications.",
                symbol: "shield.lefthalf.filled")
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Admin")
                .font(AppTypography.pageTitle)
                .foregroundStyle(.white)

            Spacer()

            Label("@admin", systemImage: "shield.lefthalf.filled")
                .font(AppTypography.caption2Emphasis)
                .foregroundStyle(AppTheme.softText)
                .labelStyle(.titleAndIcon)
        }
    }

    private var reportsSubtitle: String {
        if store.isLoadingAdminReports && store.adminReports.isEmpty {
            return "Loading"
        }

        let openCount = store.openAdminReportCount
        return openCount == 1 ? "1 open report" : "\(openCount) open reports"
    }

    private var maintenanceSubtitle: String {
        store.isMaintenanceModeActive ? "On for non-admin users" : "Off"
    }

    private var notificationsSubtitle: String {
        if store.isLoadingAdminAppAnnouncements && store.adminAppAnnouncements.isEmpty {
            return "Loading"
        }

        return "Custom pushes and in-app pop-ups"
    }

    private func adminToolLink<Destination: View>(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            NightPanel(cornerRadius: AppLayout.panelRadius, padding: 16) {
                HStack(spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 42, height: 42)
                        .primaryGlass(in: .circle)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(subtitle)
                            .font(AppTypography.rowSubtitle)
                            .foregroundStyle(AppTheme.softText)
                            .lineLimit(1)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.softText)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: AppLayout.panelRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func refreshAdminOverview(forceReports: Bool) async {
        await store.refreshAppConfigOnly()
        await store.loadAdminAppAnnouncements()

        if forceReports || store.adminReports.isEmpty {
            store.loadAdminReportsNextPage(reset: true)
        }
    }
}

private struct AdminFeedAdsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isTitleScrolled = false

    var body: some View {
        ScrollView {
            if store.isViewerAdmin {
                NightPanel(cornerRadius: AppLayout.panelRadius, padding: 20) {
                    VStack(alignment: .leading, spacing: 18) {
                        Toggle("Show feed ads", isOn: Binding(
                            get: { store.areFeedAdsEnabled },
                            set: { enabled in
                                guard !isSaving else { return }
                                isSaving = true
                                Task {
                                    defer { isSaving = false }
                                    do { try await store.saveFeedAdsEnabled(enabled) }
                                    catch { errorMessage = error.localizedDescription }
                                }
                            }
                        ))
                        .font(AppTypography.rowTitle)
                        .toggleStyle(AppAccentToggleStyle(accent: accent))
                        .disabled(isSaving)
                        .accessibilityIdentifier("admin.feedAds.enabled")

                        Text(store.areFeedAdsEnabled
                             ? "On: live ads appear when available. Otherwise, an Out Again promo fills the spot."
                             : "Off: all sponsored and promo cards are hidden.")
                            .font(AppTypography.body)
                        Text("Applies to everyone using this update. Cards appear at positions 7, 14, 21, and so on. Changes reach open apps on their next settings refresh, usually within 10 seconds.")
                            .font(AppTypography.rowSubtitle)
                            .foregroundStyle(AppTheme.softText)
                        if isSaving { ProgressView("Saving…") }
                    }
                    .foregroundStyle(.white)
                }
                .padding(.horizontal, AppLayout.screenPadding)
                .padding(.top, AppLayout.secondaryPageTopPadding)
            }
        }
        .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 8 }
        action: { _, value in isTitleScrolled = value }
        .modifier(MainPageSurface())
        .appSecondaryPageNavigation(title: "Feed Ads", isScrolled: isTitleScrolled)
        .task { await store.refreshAppConfigOnly() }
        .alert("Couldn’t save ad setting", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) { Button("OK", role: .cancel) { errorMessage = nil } }
        message: { Text(errorMessage ?? "") }
    }
}
