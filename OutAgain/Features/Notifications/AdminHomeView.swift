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
                .refreshable {
                    await refreshAdminOverview(forceReports: true)
                }
                .task {
                    await refreshAdminOverview(forceReports: false)
                }
            }
        } companion: {
            DuoCompanionPlaceholder(
                title: "Admin tools", subtitle: "Manage reports, maintenance and notifications.",
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
