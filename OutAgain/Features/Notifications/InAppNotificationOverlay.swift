import SwiftUI

/// Liquid-glass toast banner that slides in from the top of the screen
/// whenever a social event arrives while the app is foregrounded.
///
/// One source feeds this overlay:
///   - `store.notifications` — server-pushed events (friend liked your post,
///     friend commented, incoming friend request, etc.)
///
/// Only events that arrive AFTER this view appears (i.e. during the current
/// session) trigger a banner. All IDs already in the store at first appear
/// are pre-seeded into `seenIDs` so old bootstrap notifications never fire.
///
/// Each banner auto-dismisses after 3.5 seconds. Swipe up to dismiss immediately.
/// If multiple new events arrive close together, only the latest pending item
/// is kept so the viewer never gets spammed by a backlog of banners.
struct InAppNotificationOverlay: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    /// The banner currently on screen (nil = nothing showing).
    @State private var current: BannerItem?
    /// Pending events waiting to show. We intentionally keep at most one:
    /// the latest item that arrived while another banner was visible.
    @State private var queue: [BannerItem] = []
    /// Tracks IDs we've already shown so refreshes don't re-fire old events.
    /// Pre-seeded on first appear with all bootstrap IDs.
    @State private var seenIDs: Set<UUID> = []
    /// True after the initial seed pass — gates onChange from firing before seeding.
    @State private var didSeedInitialIDs = false
    /// Swipe-up drag offset for the current banner.
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack {
            if let item = current {
                banner(for: item)
                    .onTapGesture {
                        if let notification = store.notifications.first(where: { $0.id == item.id }) {
                            if notification.kind == .nightRecap {
                                store.openNightRecap(notification)
                            } else if let postID = notification.postID {
                                store.notificationDestination = .post(postID, commentID: notification.commentID)
                            } else { store.openNotifications() }
                        }
                        dismissCurrent()
                    }
                    .offset(y: min(0, dragOffset))
                    .opacity(dragOffset < -20 ? max(0, 1 + dragOffset / 80) : 1)
                    .gesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                if value.translation.height < 0 {
                                    dragOffset = value.translation.height
                                }
                            }
                            .onEnded { value in
                                if value.translation.height < -40 {
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                                        dragOffset = -160
                                    }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        dismissCurrent()
                                    }
                                } else {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        dragOffset = 0
                                    }
                                }
                            }
                    )
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .move(edge: .top).combined(with: .opacity)
                        )
                    )
                    .zIndex(1)
            }
            Spacer()
        }
        .padding(.top, 8)
        .allowsHitTesting(current != nil)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: current?.id)
        .onAppear {
            // Seed all IDs currently in memory so bootstrap notifications
            // never fire as banners. If bootstrap hasn't resolved yet, this
            // seeds an empty set — the onChange handlers below handle that
            // case by seeding on the first call when not yet seeded.
            guard !didSeedInitialIDs else { return }
            didSeedInitialIDs = true
            for n in store.notifications { seenIDs.insert(n.id) }
        }
        .onChange(of: store.notifications) { oldValue, newValue in
            guard didSeedInitialIDs else { return }
            // If the store just went from empty → populated (bootstrap landed
            // after onAppear), the new IDs are all old — seed them silently.
            if oldValue.isEmpty && !newValue.isEmpty && seenIDs.isEmpty {
                for n in newValue { seenIDs.insert(n.id) }
                return
            }
            let fresh = newValue.filter { !seenIDs.contains($0.id) }
            for n in fresh {
                seenIDs.insert(n.id)
            }

            // Skip anything the server already marked read — that means the
            // user has seen it on another device or in a prior session, so
            // re-banner'ing it on login would be spam.
            let unreadFresh = fresh.filter { !$0.isRead }
            guard let latest = unreadFresh.max(by: { $0.createdAt < $1.createdAt }) else { return }

            // Showing the banner counts as "seen" — mark it read so a
            // subsequent login/poll doesn't surface the same event again.
            store.markNotificationRead(latest.id)

            enqueue(BannerItem(
                id: latest.id,
                icon: latest.kind.symbol,
                title: latest.headline,
                actor: latest.actor
            ))
        }
    }

    // MARK: - Banner view

    @ViewBuilder
    private func banner(for item: BannerItem) -> some View {
        HStack(spacing: 12) {
            // Actor avatar or a generic icon
            if let actor = item.actor {
                AvatarView(avatar: actor.avatar, size: 40)
            } else {
                Image(systemName: item.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 40, height: 40)
                    .background(accent.opacity(0.15), in: Circle())
            }

            Text(item.title)
                .font(AppTypography.button)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
        )
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .padding(.horizontal, 16)
    }

    // MARK: - Queue management

    private func enqueue(_ item: BannerItem) {
        if current == nil {
            show(item)
        } else {
            queue = [item]
        }
    }

    private func show(_ item: BannerItem) {
        dragOffset = 0
        current = item
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            dismissCurrent()
        }
    }

    private func dismissCurrent() {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            current = nil
            dragOffset = 0
        }
        // Small delay so the exit animation finishes before next banner
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if let next = queue.last {
                queue.removeAll()
                show(next)
            }
        }
    }

    // MARK: - Model

    struct BannerItem: Identifiable {
        let id: UUID
        let icon: String
        let title: String
        let actor: UserProfile?
    }
}

/// Dismissible, in-app recap for the just-finished 7am-to-7am cycle.
/// It stays local to the app like the foreground notification banner:
/// no push, no Activity tab row, and one dismissal per user per cycle.
struct NightActivitySummaryOverlay: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent

    @State private var current: NightSummaryOverlayItem?
    @State private var dragOffset: CGFloat = 0

    private enum NightSummaryOverlayItem: Identifiable, Hashable {
        case personal(AppStore.NightActivitySummary)
        case group(AppStore.NightGroupActivitySummary)

        var id: String {
            switch self {
            case .personal(let summary):
                return "personal-\(summary.id)"
            case .group(let summary):
                return summary.id
            }
        }
    }

    private var candidate: NightSummaryOverlayItem? {
        guard store.isLive,
              store.notificationDestination == nil,
              store.appAnnouncements.isEmpty,
              !store.isPostFlowPresented,
              !store.isMaddoxPlayerPresented
        else { return nil }

        if let groupSummary = store.lastNightGroupActivitySummary {
            return .group(groupSummary)
        }

        guard let summary = store.lastNightActivitySummary,
              !store.isNightActivitySummaryDismissed(summary)
        else { return nil }

        return .personal(summary)
    }

    var body: some View {
        ZStack {
            if let current {
                NightSummaryFocusBackdrop()
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture {
                        dismiss(current)
                    }

                GeometryReader { geometry in
                    let availableHeight = max(320, geometry.size.height - 32)

                    VStack {
                        Spacer(minLength: 16)

                        summaryCard(for: current, maxHeight: availableHeight)
                            .offset(y: max(0, dragOffset))
                            .opacity(dragOffset > 20 ? max(0.72, 1 - dragOffset / 280) : 1)
                            .gesture(dismissDragGesture(for: current))

                        Spacer(minLength: 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .allowsHitTesting(current != nil)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: current?.id)
        .task(id: candidate?.id) {
            await presentCandidateIfNeeded()
        }
        .onChange(of: store.isLive) { _, isLive in
            if !isLive {
                current = nil
            }
        }
    }

    private func summaryCard(
        for summary: NightSummaryOverlayItem,
        maxHeight: CGFloat
    ) -> some View {
        ViewThatFits(in: .vertical) {
            summaryCardSurface(for: summary, compact: false)
            summaryCardSurface(for: summary, compact: true)
        }
        .frame(maxWidth: 470)
        .frame(maxHeight: maxHeight)
        .padding(.horizontal, 16)
        .shadow(color: .black.opacity(0.34), radius: 30, y: 18)
    }

    private func summaryCardSurface(for summary: NightSummaryOverlayItem, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryPhotoHeader(for: summary, compact: compact)

            VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                VStack(alignment: .leading, spacing: compact ? 5 : 7) {
                    Text(headline(for: summary))
                        .font(compact ? .system(.title3, design: .rounded, weight: .bold) : AppTypography.sheetTitle)
                        .foregroundStyle(.white)
                        .lineLimit(compact ? 2 : nil)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(detailLine(for: summary))
                        .font(AppTypography.rowSubtitle)
                        .foregroundStyle(AppTheme.softText)
                        .lineSpacing(2)
                        .lineLimit(compact ? 1 : nil)
                        .minimumScaleFactor(0.78)
                        .fixedSize(horizontal: false, vertical: true)
                }

                summaryOverviewCard(for: summary, compact: compact)

                let groupDrinks = groupDrinkItems(for: summary, limit: compact ? 2 : 3)
                if !groupDrinks.isEmpty {
                    ActivityDrinkListCard(
                        title: "Group drinks",
                        items: groupDrinks,
                        tint: AppTheme.barLightGreen
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    if let context = peopleContextLine(for: summary) {
                        ActivityContextPill(symbol: "person.2.fill", text: context)
                    }

                    if let drinkLine = topDrinkLine(for: summary) {
                        ActivityContextPill(symbol: "wineglass.fill", text: drinkLine)
                    }
                }

                summaryActions(for: summary, compact: compact)
            }
            .padding(compact ? 12 : 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .primaryGlass(in: .roundedRect(cornerRadius: 30), interactive: true)
    }

    private func summaryPhotoHeader(for summary: NightSummaryOverlayItem, compact: Bool) -> some View {
        NightSummaryPhotoCollage(
            posts: featuredPosts(for: summary),
            viewerID: viewerID(for: summary)
        )
        .frame(height: compact ? 96 : 132)
        .overlay {
            LinearGradient(
                colors: [
                    .black.opacity(0.62),
                    .clear,
                    .black.opacity(0.32)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LAST NIGHT")
                    .font(AppTypography.badgeStrong)
                    .foregroundStyle(accent)

                Text(windowLabel(for: summary))
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(.white.opacity(0.82))
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func summaryOverviewCard(for summary: NightSummaryOverlayItem, compact: Bool) -> some View {
        let stats = summaryOverviewStats(for: summary)
        let count = momentCount(for: summary)
        if compact {
            NightSummaryCompactOverviewCard(
                title: overviewTitle(for: summary),
                subtitle: windowLabel(for: summary),
                value: "\(count)",
                unit: count == 1 ? "moment" : "moments",
                stats: stats,
                tint: accent
            )
        } else {
            ActivityNightOverviewCard(
                title: overviewTitle(for: summary),
                subtitle: windowLabel(for: summary),
                value: "\(count)",
                unit: count == 1 ? "moment" : "moments",
                stats: stats,
                tint: accent
            )
        }
    }

    private func summaryOverviewStats(for summary: NightSummaryOverlayItem) -> [ActivityNightOverviewStat] {
        return [
            ActivityNightOverviewStat(
                symbol: "play.fill",
                title: "Started",
                value: ActivityNightText.startedTimeLabel(for: postsForTimeline(summary)),
                tint: AppTheme.barLightGreen
            ),
            ActivityNightOverviewStat(
                symbol: "sparkles",
                title: "Most active",
                value: mostActiveHourLabel(for: postsForTimeline(summary)) ?? "Last night",
                tint: AppTheme.barLightBlue
            )
        ]
    }

    private func topDrinkLine(for summary: NightSummaryOverlayItem) -> String? {
        guard case .personal = summary else { return nil }
        var aggregates: [String: NightSummaryDrinkAggregate] = [:]

        for post in postsForTimeline(summary) {
            guard let drink = post.drink else { continue }
            let key = AppStore.normalizedDrinkName(drink.name)

            if var aggregate = aggregates[key] {
                aggregate.count += 1
                aggregate.latestPostDate = max(aggregate.latestPostDate, post.createdAt)
                aggregates[key] = aggregate
            } else {
                aggregates[key] = NightSummaryDrinkAggregate(
                    id: key,
                    drink: drink,
                    count: 1,
                    latestPostDate: post.createdAt
                )
            }
        }

        let sortedDrinks = aggregates.values.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.latestPostDate > $1.latestPostDate
        }
        guard let topDrink = sortedDrinks.first else { return nil }

        if topDrink.count > 1 {
            return "Top drink \(topDrink.drink.name) x\(topDrink.count)"
        }

        return "Top drink \(topDrink.drink.name)"
    }

    private func groupDrinkItems(for summary: NightSummaryOverlayItem, limit: Int) -> [ActivityDrinkListItem] {
        guard case .group(let groupSummary) = summary else { return [] }

        var aggregates: [String: NightSummaryDrinkAggregate] = [:]

        for post in groupSummary.allPosts {
            guard let drink = post.drink else { continue }
            let key = AppStore.normalizedDrinkName(drink.name)

            if var aggregate = aggregates[key] {
                aggregate.count += 1
                aggregate.latestPostDate = max(aggregate.latestPostDate, post.createdAt)
                aggregates[key] = aggregate
            } else {
                aggregates[key] = NightSummaryDrinkAggregate(
                    id: key,
                    drink: drink,
                    count: 1,
                    latestPostDate: post.createdAt
                )
            }
        }

        return aggregates.values
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.latestPostDate > $1.latestPostDate
            }
            .prefix(limit)
            .map { aggregate in
                ActivityDrinkListItem(
                    id: aggregate.id,
                    drink: aggregate.drink,
                    count: aggregate.count,
                    detail: "Latest \(aggregate.latestPostDate.postClockTimeLabel)"
                )
            }
    }

    private func mostActiveHourLabel(for posts: [MomentPost]) -> String? {
        guard !posts.isEmpty else { return nil }

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: posts) { post in
            calendar.dateInterval(of: .hour, for: post.createdAt)?.start ?? post.createdAt
        }

        guard let bestHour = grouped
            .map({ hour, posts in
                (
                    hour: hour,
                    count: posts.count,
                    latest: posts.map(\.createdAt).max() ?? hour
                )
            })
            .sorted(by: { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.latest > rhs.latest
            })
            .first?
            .hour
        else { return nil }

        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "h a"
        return formatter.string(from: bestHour)
    }

    private func peopleContextLine(for summary: NightSummaryOverlayItem) -> String? {
        guard !featuredPeople(for: summary).isEmpty else { return nil }
        return "With \(peopleLine(for: summary))"
    }

    private func summaryActions(for summary: NightSummaryOverlayItem, compact: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                dismiss(summary)
            } label: {
                Label("Close", systemImage: "xmark")
                    .font(AppTypography.button)
                    .foregroundStyle(.white.opacity(0.86))
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 44 : 48)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .contentShape(Capsule())
            .primaryGlass(in: .capsule, interactive: true)

            Button {
                dismiss(summary, routeToProfile: true)
            } label: {
                Label(viewActionTitle(for: summary), systemImage: viewActionSymbol(for: summary))
                    .font(AppTypography.button)
                    .foregroundStyle(AppTheme.foregroundOnAccent(accent))
                    .frame(maxWidth: .infinity)
                    .frame(height: compact ? 44 : 48)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .background(accent.opacity(0.88), in: Capsule())
            .overlay(Capsule().strokeBorder(accent.opacity(0.95), lineWidth: 1))
            .glassEffect(.regular.tint(accent.opacity(0.18)).interactive(), in: .capsule)
            .contentShape(Capsule())
        }
    }

    private struct NightSummaryDrinkAggregate {
        let id: String
        let drink: DrinkTag
        var count: Int
        var latestPostDate: Date
    }

    private struct NightSummaryCompactOverviewCard: View {
        let title: String
        let subtitle: String
        let value: String
        let unit: String
        let stats: [ActivityNightOverviewStat]
        let tint: Color

        var body: some View {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "moon.stars.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(tint.opacity(0.24), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.14), lineWidth: 1))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(AppTypography.metadataEmphasis)
                            .foregroundStyle(.white.opacity(0.72))
                            .textCase(.uppercase)
                            .tracking(1.1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        Text(subtitle)
                            .font(AppTypography.captionMedium)
                            .foregroundStyle(AppTheme.softText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                    }

                    Spacer(minLength: 8)

                    HStack(alignment: .lastTextBaseline, spacing: 5) {
                        Text(value)
                            .font(AppTypography.statCompact)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        Text(unit)
                            .font(AppTypography.rowSubtitleMedium)
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                    }
                }

                HStack(spacing: 8) {
                    ForEach(stats) { stat in
                        NightSummaryCompactStatPill(stat: stat)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [
                        tint.opacity(0.18),
                        Color.white.opacity(0.06),
                        Color.black.opacity(0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 24, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            )
            .glassEffect(.regular.tint(tint.opacity(0.10)), in: .rect(cornerRadius: 24))
        }
    }

    private struct NightSummaryCompactStatPill: View {
        let stat: ActivityNightOverviewStat

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Image(systemName: stat.symbol)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.88))

                    Text(stat.title)
                        .font(AppTypography.caption2Emphasis)
                        .foregroundStyle(.white.opacity(0.62))
                        .textCase(.uppercase)
                        .tracking(0.7)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                }

                Text(stat.value)
                    .font(AppTypography.controlLabel)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(stat.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            )
        }
    }

    private struct NightSummaryFocusBackdrop: View {
        @Environment(\.appAccent) private var accent

        var body: some View {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)

                Color.black.opacity(0.24)

                LinearGradient(
                    colors: [
                        accent.opacity(0.12),
                        .clear,
                        .black.opacity(0.22)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .ignoresSafeArea()
        }
    }

    private func detailLine(for summary: NightSummaryOverlayItem) -> String {
        var details: [String] = []

        if let activeHour = mostActiveHourLabel(for: postsForTimeline(summary)) {
            details.append("Most active \(activeHour)")
        }

        let photos = photoCount(for: summary)
        if photos > 0 {
            details.append("\(photos) \(photos == 1 ? "photo" : "photos")")
        }

        return details.isEmpty ? "Your recap is ready." : details.joined(separator: " · ")
    }

    private func peopleLine(for summary: NightSummaryOverlayItem) -> String {
        let names = featuredPeople(for: summary).map { $0.displayName.summaryFirstName }
        guard let first = names.first else { return "" }
        if names.count == 1 { return first }
        if names.count == 2 { return "\(first) and \(names[1])" }
        return "\(first), \(names[1]) + \(names.count - 2)"
    }

    private func windowLabel(for summary: NightSummaryOverlayItem) -> String {
        let window = window(for: summary)
        let start = window.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        let end = window.end.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(start) to \(end)"
    }

    private func presentCandidateIfNeeded() async {
        guard current == nil, let initial = candidate else { return }
        try? await Task.sleep(for: .milliseconds(850))
        guard !Task.isCancelled,
              current == nil,
              let latest = candidate,
              latest.id == initial.id
        else { return }

        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            current = latest
            dragOffset = 0
        }
    }

    private func dismiss(_ summary: NightSummaryOverlayItem, routeToProfile: Bool = false) {
        switch summary {
        case .personal(let personalSummary):
            store.dismissNightActivitySummary(personalSummary)
        case .group(let groupSummary):
            store.dismissNightGroupActivitySummary(groupSummary)
        }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.88)) {
            current = nil
            dragOffset = 0
        }

        if routeToProfile {
            switch summary {
            case .personal(let personal):
                store.notificationDestination = .recap(NightRecapRoute(start: personal.window.start, end: personal.window.end))
            case .group(let group):
                store.notificationDestination = .recap(NightRecapRoute(start: group.window.start, end: group.window.end, groupID: group.group.id))
            }
        }
    }

    private func dismissDragGesture(for summary: NightSummaryOverlayItem) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if value.translation.height > 0 {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                if value.translation.height > 70 {
                    dismiss(summary)
                } else {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func headline(for summary: NightSummaryOverlayItem) -> String {
        switch summary {
        case .group(let groupSummary):
            let name = groupSummary.group.displayName
            return name == "Group"
                ? "Your group made it out"
                : "\(name) made it out"
        case .personal(let personalSummary):
            if personalSummary.ownMomentCount == 0 {
                return personalSummary.taggedViewerPosts.isEmpty ? "Your friends last night" : "Photos with you from last night"
            }
            guard let firstFriend = personalSummary.featuredPeople.first else {
                if personalSummary.ownMomentCount == 1 {
                    return "You posted a night worth keeping"
                }
                return "You posted \(personalSummary.ownMomentCount) moments last night"
            }

            let firstName = firstFriend.displayName.summaryFirstName
            let extra = max(personalSummary.featuredPeople.count - 1, 0)
            let friendText = extra == 0 ? firstName : "\(firstName) + \(extra)"

            if personalSummary.ownMomentCount == 0 {
                return "You showed up with \(friendText)"
            }

            return "You and \(friendText) made it out"
        }
    }

    private func overviewTitle(for summary: NightSummaryOverlayItem) -> String {
        switch summary {
        case .personal:
            return "Last night's recap"
        case .group(let groupSummary):
            return "\(groupSummary.group.displayName) recap"
        }
    }

    private func viewActionTitle(for summary: NightSummaryOverlayItem) -> String { "Photos" }
    private func viewActionSymbol(for summary: NightSummaryOverlayItem) -> String { "photo.stack" }

    private func window(for summary: NightSummaryOverlayItem) -> AppStore.NightSummaryWindow {
        switch summary {
        case .personal(let personalSummary):
            return personalSummary.window
        case .group(let groupSummary):
            return groupSummary.window
        }
    }

    private func viewerID(for summary: NightSummaryOverlayItem) -> UUID {
        switch summary {
        case .personal(let personalSummary):
            return personalSummary.viewer.id
        case .group(let groupSummary):
            return groupSummary.viewer.id
        }
    }

    private func featuredPosts(for summary: NightSummaryOverlayItem) -> [MomentPost] {
        switch summary {
        case .personal(let personalSummary):
            return personalSummary.featuredPosts
        case .group(let groupSummary):
            return groupSummary.featuredPosts
        }
    }

    private func featuredPeople(for summary: NightSummaryOverlayItem) -> [UserProfile] {
        switch summary {
        case .personal(let personalSummary):
            return personalSummary.featuredPeople
        case .group(let groupSummary):
            return groupSummary.featuredPeople
        }
    }

    private func postsForTimeline(_ summary: NightSummaryOverlayItem) -> [MomentPost] {
        switch summary {
        case .personal(let personalSummary):
            return personalSummary.personalPosts
        case .group(let groupSummary):
            return groupSummary.allPosts
        }
    }

    private func momentCount(for summary: NightSummaryOverlayItem) -> Int {
        switch summary {
        case .personal(let personalSummary):
            return personalSummary.momentCount
        case .group(let groupSummary):
            return groupSummary.momentCount
        }
    }

    private func photoCount(for summary: NightSummaryOverlayItem) -> Int {
        switch summary {
        case .personal(let personalSummary):
            return personalSummary.photoCount
        case .group(let groupSummary):
            return groupSummary.photoCount
        }
    }
}

private struct NightSummaryPhotoCollage: View {
    let posts: [MomentPost]
    let viewerID: UUID

    @Environment(\.appAccent) private var accent

    var body: some View {
        GeometryReader { geometry in
            let visible = Array(posts.prefix(3))

            ZStack {
                LinearGradient(
                    colors: [
                        Color(hex: "#09090D"),
                        accent.opacity(0.28),
                        Color(hex: "#050506")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                if visible.isEmpty {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.22))
                } else {
                    collageLayout(visible, size: geometry.size)
                }
            }
        }
    }

    @ViewBuilder
    private func collageLayout(_ visible: [MomentPost], size: CGSize) -> some View {
        switch visible.count {
        case 1:
            NightSummaryPhotoTile(post: visible[0], viewerID: viewerID)
        case 2:
            HStack(spacing: 4) {
                NightSummaryPhotoTile(post: visible[0], viewerID: viewerID)
                    .frame(width: (size.width - 4) / 2)
                NightSummaryPhotoTile(post: visible[1], viewerID: viewerID)
                    .frame(width: (size.width - 4) / 2)
            }
        default:
            HStack(spacing: 4) {
                NightSummaryPhotoTile(post: visible[0], viewerID: viewerID)
                    .frame(width: size.width * 0.60)

                VStack(spacing: 4) {
                    NightSummaryPhotoTile(post: visible[1], viewerID: viewerID)
                    NightSummaryPhotoTile(post: visible[2], viewerID: viewerID)
                        .overlay {
                            if posts.count > 3 {
                                ZStack {
                                    Color.black.opacity(0.42)
                                    Text("+\(posts.count - 3)")
                                        .font(AppTypography.sheetTitle)
                                        .foregroundStyle(.white)
                                }
                            }
                        }
                }
                .frame(width: max(0, size.width * 0.40 - 4))
            }
        }
    }
}

private struct NightSummaryPhotoTile: View {
    let post: MomentPost
    let viewerID: UUID

    var body: some View {
        GeometryReader { geometry in
            MomentMediaView(media: post.media, height: geometry.size.height)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .overlay(alignment: .bottomLeading) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.58)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: min(84, geometry.size.height))
                }
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 7) {
                        AvatarView(avatar: post.author.avatar, size: 24)

                        Text(post.author.id == viewerID ? "You" : post.author.displayName.summaryFirstName)
                            .font(AppTypography.badgeStrong)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.34), in: Capsule())
                    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                    .padding(8)
                }
        }
    }
}

private extension String {
    var summaryFirstName: String {
        split(separator: " ").first.map(String.init) ?? self
    }
}
