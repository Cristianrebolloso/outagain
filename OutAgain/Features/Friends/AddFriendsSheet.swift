import SwiftUI

private struct FriendRequestRow: View {
    @Environment(\.appAccent) private var accent
    let profile: UserProfile
    let primaryTitle: String
    let primarySymbol: String
    let primaryAction: () -> Void
    let secondaryTitle: String?
    let secondaryAction: (() -> Void)?
    var onOpen: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            profileIdentity

            HStack(spacing: 8) {
                if let secondaryTitle, let secondaryAction {
                    actionButton(
                        title: secondaryTitle,
                        systemImage: "xmark",
                        prominence: .secondary,
                        action: secondaryAction
                    )
                }

                Spacer(minLength: 0)

                actionButton(
                    title: primaryTitle,
                    systemImage: primarySymbol,
                    prominence: .primary,
                    action: primaryAction
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var profileIdentity: some View {
        if let onOpen {
            Button(action: onOpen) {
                identityContent(showsChevron: true)
            }
            .buttonStyle(.plain)
        } else {
            identityContent(showsChevron: false)
        }
    }

    private func identityContent(showsChevron: Bool) -> some View {
        HStack(spacing: 14) {
            AvatarView(avatar: profile.avatar, size: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayName)
                    .font(AppTypography.rowTitle)
                    .foregroundStyle(.white)
                VerifiedUsernameLabel(profile: profile, font: AppTypography.footnote, badgeSize: 11)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private enum ActionProminence {
        case primary
        case secondary
    }

    private func actionButton(
        title: String,
        systemImage: String,
        prominence: ActionProminence,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(AppTypography.buttonFootnote)
                .foregroundStyle(prominence == .primary ? AppTheme.charcoal : .white)
                .frame(minWidth: 104)
                .frame(height: 42)
                .padding(.horizontal, 14)
                .background(background(for: prominence))
                .overlay(border(for: prominence))
        }
        .buttonStyle(.plain)
    }

    private func background(for prominence: ActionProminence) -> some View {
        Capsule(style: .continuous)
            .fill(prominence == .primary ? accent : Color.white.opacity(0.06))
    }

    private func border(for prominence: ActionProminence) -> some View {
        Capsule(style: .continuous)
            .strokeBorder(
                prominence == .primary ? accent.opacity(0.42) : AppTheme.line,
                lineWidth: 1
            )
    }
}

struct AddFriendsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.appAccent) private var accent
    @State private var selectedProfile: UserProfile?
    @State private var inlineProfile: UserProfile?
    @State private var isDuoExpanded = false
    @State private var isTabRefreshing = false
    @State private var friendsScrollOffset: CGFloat = 0
    @State private var isTitleScrolled = false
    @FocusState private var isSearchFocused: Bool

    @ViewBuilder
    var body: some View {
        if store.isDuoDevice {
            duoFriends
        } else {
            phoneFriends
        }
    }

    @ViewBuilder
    private var phoneFriends: some View {
        @Bindable var store = store

        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    GeometryReader { geo in
                        Color.clear
                            .preference(
                                key: FriendsScrollOffsetKey.self,
                                value: geo.frame(in: .named("friendsScroll")).minY
                            )
                    }
                    .frame(height: 0)
                    .id(FriendsScrollAnchor.top)

                    VStack(alignment: .leading, spacing: 24) {
                        if store.isViewerAdmin {
                            adminSection(store: store)
                        } else {
                            discoverSection(store: store)
                        }
                    }
                    .padding(.horizontal, AppLayout.screenPadding)
                    .padding(.top, 12)
                    .padding(.bottom, AppLayout.tabBarClearance)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 8
                } action: { _, isScrolled in
                    isTitleScrolled = isScrolled
                }
                #if DEBUG
                .modifier(DuoScrollPreviewControls())
                #endif
                .safeAreaInset(edge: .top, spacing: 0) {
                    ScrollingPageTitle(
                        title: store.isViewerAdmin ? "All Users" : "Add Friends",
                        isScrolled: isTitleScrolled
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppLayout.screenPadding)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
                }
                .coordinateSpace(name: "friendsScroll")
                .onPreferenceChange(FriendsScrollOffsetKey.self) { offset in
                    friendsScrollOffset = offset
                }
                .glassPullToRefresh(isRefreshing: isTabRefreshing) { await runManualRefresh() }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.always, axes: .vertical)
                // Keep the warm ambient present on the People tab. Despite the
                // name `AddFriendsSheet`, this view is mounted as a top-level tab
                // and needs to paint its own surface like Profile does.
                .scrollContentBackground(.hidden)
                .modifier(MainPageSurface())
                // Tapping anywhere outside the search field dismisses the keyboard.
                .onTapGesture { isSearchFocused = false }
                // Prevent keyboard from pushing this view (and the tab bar) upward.
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .navigationDestination(item: $selectedProfile) { profile in
                    FriendProfileView(profile: profile, presentationStyle: .embedded)
                }
                .onChange(of: store.selectedTab) { oldTab, newTab in
                    if oldTab == .friends, newTab != .friends {
                        isSearchFocused = false
                    }
                    guard newTab == .friends, oldTab != .friends else { return }
                    scrollToTop(proxy)
                }
                .onChange(of: store.friendsTabSelectionTrigger) { _, _ in
                    guard store.selectedTab == .friends else { return }
                    scrollToTop(proxy)
                }
                .task(id: store.friendsTabSelectionTrigger) {
                    guard store.selectedTab == .friends,
                          store.friendsTabSelectionTrigger > 0
                    else { return }

                    scrollToTop(proxy)
                    await refreshFriendsData()
                }
                .onChange(of: store.friendsTabPendingProfile) { _, pending in
                    guard let pending else { return }
                    store.friendsTabPendingProfile = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        selectedProfile = pending
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var duoFriends: some View {
        @Bindable var store = store

        DuoPageLayout(isExpanded: $isDuoExpanded) {
            NavigationStack {
                ScrollViewReader { proxy in
                    ScrollView {
                        GeometryReader { geo in
                            Color.clear
                                .preference(
                                    key: FriendsScrollOffsetKey.self,
                                    value: geo.frame(in: .named("friendsScroll")).minY
                                )
                        }
                        .frame(height: 0)
                        .id(FriendsScrollAnchor.top)

                        VStack(alignment: .leading, spacing: 24) {
                            if store.isViewerAdmin {
                                adminSection(store: store)
                            } else {
                                discoverSection(store: store)
                            }
                        }
                        .frame(maxWidth: isDuoExpanded ? .infinity : AppLayout.phoneColumnMaximumWidth)
                        .padding(.horizontal, AppLayout.screenPadding)
                        .padding(.top, AppLayout.secondaryPageTopPadding)
                        .padding(.bottom, AppLayout.tabBarClearance)
                        .frame(maxWidth: .infinity)
                    }
                    .onScrollGeometryChange(for: Bool.self) { geometry in
                        geometry.contentOffset.y + geometry.contentInsets.top > 8
                    } action: { _, isScrolled in
                        isTitleScrolled = isScrolled
                    }
                    #if DEBUG
                    .modifier(DuoScrollPreviewControls())
                    #endif
                    .coordinateSpace(name: "friendsScroll")
                    .onPreferenceChange(FriendsScrollOffsetKey.self) { offset in
                        friendsScrollOffset = offset
                    }
                    .glassPullToRefresh(isRefreshing: isTabRefreshing) { await runManualRefresh() }
                    .modifier(DuoPageViewport())
                    .toolbarBackground(.hidden, for: .navigationBar)
                    .navigationBarTitleDisplayMode(.inline)
                    .modifier(DuoPageHeader(title: store.isViewerAdmin ? "All Users" : "Add Friends", isScrolled: isTitleScrolled))
                    .scrollIndicators(.hidden)
                    .defaultScrollAnchor(.top, for: .sizeChanges)
                    .scrollBounceBehavior(.always, axes: .vertical)
                    // Keep the warm ambient present on the People tab. Despite the
                    // name `AddFriendsSheet`, this view is mounted as a top-level tab
                    // and needs to paint its own surface like Profile does.
                    .scrollContentBackground(.hidden)
                    .modifier(MainPageSurface())
                    // Tapping anywhere outside the search field dismisses the keyboard.
                    .onTapGesture { isSearchFocused = false }
                    // Prevent keyboard from pushing this view (and the tab bar) upward.
                    .ignoresSafeArea(.keyboard, edges: .bottom)
                    .navigationDestination(item: $selectedProfile) { profile in
                        FriendProfileView(profile: profile, presentationStyle: .embedded)
                    }
                    .onChange(of: store.selectedTab) { oldTab, newTab in
                        if oldTab == .friends, newTab != .friends {
                            isSearchFocused = false
                        }
                        guard newTab == .friends, oldTab != .friends else { return }
                        scrollToTop(proxy)
                    }
                    .onChange(of: store.friendsTabSelectionTrigger) { _, _ in
                        guard store.selectedTab == .friends else { return }
                        scrollToTop(proxy)
                    }
                    .task(id: store.friendsTabSelectionTrigger) {
                        guard store.selectedTab == .friends,
                            store.friendsTabSelectionTrigger > 0
                        else { return }

                        scrollToTop(proxy)
                        await refreshFriendsData()
                    }
                    .onChange(of: store.friendsTabPendingProfile) { _, pending in
                        guard let pending else { return }
                        store.friendsTabPendingProfile = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            openProfile(pending)
                        }
                    }
                }
            }
        } companion: {
            FriendsCompanionView(selectedProfile: $inlineProfile)
        }
    }

    private func openProfile(_ profile: UserProfile) {
        if store.isDuoDevice {
            isSearchFocused = false
            if isDuoExpanded { inlineProfile = profile }
            else { selectedProfile = profile }
        } else {
            selectedProfile = profile
        }
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        isSearchFocused = false
        DispatchQueue.main.async {
            proxy.scrollTo(FriendsScrollAnchor.top, anchor: .top)
        }
    }

    private func runManualRefresh() async {
        guard !isTabRefreshing else { return }
        let refreshStartedAt = Date()
        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.18)) {
                isTabRefreshing = true
            }
        }

        await refreshFriendsData()
        await MainTabRefreshFeedback.waitForMinimumVisibleDuration(since: refreshStartedAt)

        await MainActor.run {
            withAnimation(.easeInOut(duration: 0.18)) {
                isTabRefreshing = false
            }
        }

    }

    private func refreshFriendsData() async {
        await store.refreshAppData(silenceErrors: true)
    }


    @ViewBuilder
    private func peopleSection(store: AppStore) -> some View {
        searchCard(store: store)

        if store.friends.isEmpty {
            emptyFriendsState(store: store)
        } else {
            let query = PeopleSearchRules.normalized(store.friendSearchQuery)
            let filtered = query.isEmpty ? store.friends : store.friends.filter {
                $0.displayName.lowercased().contains(query) || $0.username.lowercased().contains(query)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("\(store.friends.count) friends")
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(.white)

                NightPanel(cornerRadius: AppLayout.panelRadius, padding: 12) {
                    VStack(spacing: 8) {
                        if filtered.isEmpty {
                            Text("No friends match \"\(store.friendSearchQuery)\"")
                                .font(AppTypography.rowSubtitle)
                                .foregroundStyle(AppTheme.softText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(filtered) { friend in
                                ExistingFriendRow(profile: friend) {
                                    openProfile(friend)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func emptyFriendsState(store: AppStore) -> some View {
        NightPanel(cornerRadius: AppLayout.panelRadius, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Text("No friends yet")
                    .font(AppTypography.sectionTitle)
                    .foregroundStyle(.white)

                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        store.friendsPageMode = .discover
                    }
                } label: {
                    Label("Add friends", systemImage: "person.badge.plus")
                        .font(AppTypography.button)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(.white.opacity(0.04), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.10), lineWidth: 1))
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .contentShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private func adminSection(store: AppStore) -> some View {
        // Search — read-only, no Add button
        searchCard(store: store)

        if hasActiveQuery {
            searchResultsSection
        } else {
            // All users list, batched 10 at a time
            VStack(alignment: .leading, spacing: 12) {
                NightPanel(cornerRadius: AppLayout.panelRadius, padding: 12) {
                    VStack(spacing: 8) {
                        if store.adminAllUsers.isEmpty && !store.isLoadingAdminUsers {
                            Text("No users loaded yet")
                                .font(AppTypography.rowSubtitle)
                                .foregroundStyle(AppTheme.softText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(store.adminAllUsers) { user in
                                AdminUserRow(
                                    profile: user,
                                    isBusy: store.adminBusyUserIDs.contains(user.id),
                                    onOpen: {
                                        openProfile(user)
                                    }
                                )
                            }

                            if store.isLoadingAdminUsers {
                                HStack {
                                    Spacer()
                                    ProgressView()
                                        .tint(accent)
                                        .padding(.vertical, 10)
                                    Spacer()
                                }
                            } else if store.hasMoreAdminUsers {
                                Button {
                                    store.loadAdminUsersNextPage()
                                } label: {
                                    Text("Load more")
                                        .font(AppTypography.button)
                                        .foregroundStyle(accent)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if let message = store.adminStatusMessage {
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(AppTypography.buttonFootnote)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .task {
                if store.adminAllUsers.isEmpty {
                    store.loadAdminUsersNextPage()
                }
            }
        }
    }

    @ViewBuilder
    private func discoverSection(store: AppStore) -> some View {
        SocialInviteActions()
        // Order is fixed regardless of state: search first, requests
        // second, suggested third. Putting search at the top means the
        // primary action (find a specific person by handle) is always one
        // tap away, even when the requests/suggestions sections are tall
        // enough to push it off-screen. Requests above suggestions because
        // an inbound request is a higher-intent signal than a suggestion.
        searchCard(store: store)

        if hasActiveQuery {
            searchResultsSection
        } else {
            if !store.incomingFriendRequests.isEmpty {
                incomingRequestsSection
            }

            let suggestedWithMutuals = store.suggestedFriends.filter {
                (store.mutualCounts[$0.id] ?? 0) > 0
            }
            if !suggestedWithMutuals.isEmpty {
                suggestedFriendsSection(candidates: suggestedWithMutuals, store: store)
            }
        }

        if !store.outgoingFriendRequests.isEmpty {
            outgoingRequestsSection
        }
    }

    private func suggestedFriendsSection(candidates: [UserProfile], store: AppStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NightPanel(cornerRadius: AppLayout.panelRadius, padding: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Suggestions")
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)

                    VStack(spacing: 10) {
                        ForEach(candidates) { candidate in
                            SuggestedFriendRow(
                                profile: candidate,
                                mutualCount: store.mutualCounts[candidate.id] ?? 0,
                                onOpen: { openProfile(candidate) },
                                onAdd: {
                                    withAnimation(.snappy(duration: 0.24)) {
                                        store.sendFriendRequest(to: candidate)
                                    }
                                }
                            )
                        }
                    }
                }
            }
        }
    }

    private func searchCard(store: AppStore) -> some View {
        @Bindable var store = store

        return NightPanel(cornerRadius: AppLayout.panelRadius, padding: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.softText)

                    TextField(
                        "Search friends or @username",
                        text: $store.friendSearchQuery
                    )
                        .font(AppTypography.searchInput)
                        .foregroundStyle(.white)
                        .tint(.white)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($isSearchFocused)
                        .onChange(of: store.friendSearchQuery) { _, _ in
                            store.searchForFriends()
                        }

                    if !store.friendSearchQuery.isEmpty {
                        Button {
                            store.friendSearchQuery = ""
                            store.friendSearchResults = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppTheme.softText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                )
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
    }

    private var hasActiveQuery: Bool {
        !store.friendSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var matchingFriendsForSearch: [UserProfile] {
        let rawQuery = store.friendSearchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let usernameQuery = UsernameRules.searchFragment(store.friendSearchQuery)

        guard !rawQuery.isEmpty else { return [] }

        return store.friends.filter { friend in
            friend.displayName.lowercased().contains(rawQuery)
                || (!usernameQuery.isEmpty && friend.username.lowercased().contains(usernameQuery))
        }
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        let matchingFriends = store.isViewerAdmin ? [] : matchingFriendsForSearch
        let addableResults = store.friendSearchResults

        VStack(alignment: .leading, spacing: 12) {
            SectionEyebrow(title: "Results")

            NightPanel(cornerRadius: AppLayout.panelRadius, padding: 12) {
                if matchingFriends.isEmpty && addableResults.isEmpty && store.isSearchingFriends {
                    ProgressView("Searching…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                } else if let message = store.friendSearchError, matchingFriends.isEmpty && addableResults.isEmpty {
                    Text(message)
                        .font(AppTypography.rowSubtitle)
                        .foregroundStyle(AppTheme.softText)
                        .padding(10)
                } else if matchingFriends.isEmpty && addableResults.isEmpty {
                    sectionMessage(
                        title: "No results found",
                        detail: "Try their name or @username, or send them an invite link."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        if !matchingFriends.isEmpty {
                            resultGroupTitle("Friends")

                            VStack(spacing: 8) {
                                ForEach(matchingFriends) { friend in
                                    ExistingFriendRow(profile: friend) {
                                        openProfile(friend)
                                    }
                                }
                            }
                        }

                        if !matchingFriends.isEmpty && !addableResults.isEmpty {
                            Divider()
                                .overlay(AppTheme.line)
                                .padding(.horizontal, 4)
                        }

                        if !addableResults.isEmpty {
                            if !store.isViewerAdmin {
                                resultGroupTitle("Add Friends")
                            }

                            VStack(spacing: 10) {
                                ForEach(addableResults) { candidate in
                                    if store.isViewerAdmin {
                                        AdminUserRow(
                                            profile: candidate,
                                            isBusy: store.adminBusyUserIDs.contains(candidate.id),
                                            onOpen: {
                                                openProfile(candidate)
                                            }
                                        )
                                    } else {
                                        FriendRow(
                                            profile: candidate,
                                            onOpen: {
                                                openProfile(candidate)
                                            }
                                        ) {
                                            withAnimation(.snappy(duration: 0.24)) {
                                                store.sendFriendRequest(to: candidate)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func resultGroupTitle(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.buttonFootnote)
            .foregroundStyle(AppTheme.softText)
            .textCase(.uppercase)
            .tracking(0.8)
            .padding(.horizontal, 4)
    }

    private var incomingRequestsSection: some View {
        // No eyebrow — the Accept/Ignore buttons in the row tell the user
        // exactly what these are without a header.
        VStack(alignment: .leading, spacing: 12) {
            NightPanel(cornerRadius: AppLayout.panelRadius, padding: 12) {
                VStack(spacing: 10) {
                    ForEach(store.incomingFriendRequests) { request in
                        FriendRequestRow(
                            profile: request.counterpart,
                            primaryTitle: "Accept",
                            primarySymbol: "checkmark.seal.fill",
                            primaryAction: {
                                withAnimation(.snappy(duration: 0.24)) {
                                    store.acceptIncomingRequest(request)
                                }
                            },
                            secondaryTitle: "Ignore",
                            secondaryAction: {
                                withAnimation(.snappy(duration: 0.24)) {
                                    store.rejectIncomingRequest(request)
                                }
                            },
                            onOpen: {
                                openProfile(request.counterpart)
                            }
                        )
                    }
                }
            }
        }
    }

    private var outgoingRequestsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionEyebrow(
                title: "Sent",
                detail: "Waiting for them"
            )

            NightPanel(cornerRadius: AppLayout.panelRadius, padding: 12) {
                VStack(spacing: 10) {
                    ForEach(store.outgoingFriendRequests) { request in
                        FriendRequestRow(
                            profile: request.counterpart,
                            primaryTitle: "Cancel",
                            primarySymbol: "xmark.circle.fill",
                            primaryAction: {
                                withAnimation(.snappy(duration: 0.24)) {
                                    store.cancelOutgoingRequest(request)
                                }
                            },
                            secondaryTitle: nil,
                            secondaryAction: nil,
                            onOpen: {
                                openProfile(request.counterpart)
                            }
                        )
                    }
                }
            }
        }
    }

    private func sectionMessage(
        title: String,
        detail: String? = nil,
        buttonTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(AppTypography.rowTitle)
                .foregroundStyle(.white)

            if let detail {
                Text(detail)
                    .font(AppTypography.rowSubtitle)
                    .foregroundStyle(AppTheme.softText)
            }

            if let buttonTitle, let action {
                Button(buttonTitle, action: action)
                    .buttonStyle(.glass)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
    }

}

struct ExistingFriendRow: View {
    let profile: UserProfile
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                TonightAvatarView(avatar: profile.avatar, userID: profile.id, size: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(.white)
                    VerifiedUsernameLabel(profile: profile, font: AppTypography.footnote, badgeSize: 11)
                }

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct AdminUserRow: View {
    @Environment(\.appAccent) private var accent
    let profile: UserProfile
    let isBusy: Bool
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                TonightAvatarView(avatar: profile.avatar, userID: profile.id, size: 48)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(profile.displayName)
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if profile.isBanned {
                            Label("Banned", systemImage: "nosign")
                                .font(AppTypography.badgeStrong)
                                .foregroundStyle(.red.opacity(0.95))
                                .labelStyle(.titleAndIcon)
                        }
                    }

                    VerifiedUsernameLabel(profile: profile, font: AppTypography.footnote, badgeSize: 11)
                }

                Spacer(minLength: 0)

                if isBusy {
                    ProgressView()
                        .tint(accent)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

private struct FriendRow: View {
    let profile: UserProfile
    let onOpen: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    TonightAvatarView(avatar: profile.avatar, userID: profile.id, size: 48)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.displayName)
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(.white)
                        VerifiedUsernameLabel(profile: profile, font: AppTypography.footnote, badgeSize: 11)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onAdd) {
                Label("Add", systemImage: "person.badge.plus")
                    .font(AppTypography.buttonFootnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .primaryGlass(in: .capsule, interactive: true)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// A friend suggestion row that shows the candidate's name/handle alongside
/// an "N mutual" badge and an Add button. The mutual count is always ≥ 1
/// (rows with zero mutuals are filtered out before reaching this view).
private struct SuggestedFriendRow: View {
    @Environment(AppStore.self) private var store
    let profile: UserProfile
    let mutualCount: Int
    let onOpen: () -> Void
    let onAdd: () -> Void

    @ViewBuilder
    var body: some View {
        if store.isDuoDevice { duoRow }
        else { phoneRow }
    }

    // Preserve the regular iPhone row independently of Duo pane adaptations.
    private var phoneRow: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    TonightAvatarView(avatar: profile.avatar, userID: profile.id, size: 48)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.displayName)
                            .font(AppTypography.rowTitle)
                            .foregroundStyle(.white)

                        HStack(spacing: 4) {
                            VerifiedUsernameLabel(
                                profile: profile,
                                font: AppTypography.footnote,
                                badgeSize: 11
                            )
                        }

                        // Mutual count badge — sits below the username so the
                        // identity row stays clean and the social signal reads
                        // as supplementary rather than competing with the name.
                        Label(mutualCount == 1 ? "1 mutual" : "\(mutualCount) mutuals",
                              systemImage: "person.2.fill")
                            .font(AppTypography.badge)
                            .foregroundStyle(AppTheme.softText)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onAdd) {
                Label("Add", systemImage: "person.badge.plus")
                    .font(AppTypography.buttonFootnote)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .primaryGlass(in: .capsule, interactive: true)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var duoRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                identityButton
                    .layoutPriority(1)
                addButton
            }

            // Preserve readable metadata when a narrow pane or larger text
            // cannot fit the identity and action on the same line.
            VStack(alignment: .leading, spacing: 10) {
                identityButton
                addButton.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }

    private var identityButton: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                TonightAvatarView(avatar: profile.avatar, userID: profile.id, size: 48)

                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.displayName)
                        .font(AppTypography.rowTitle)
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    VerifiedUsernameLabel(
                        profile: profile,
                        font: AppTypography.footnote,
                        badgeSize: 11
                    )
                    .lineLimit(1)

                    Label(mutualCount == 1 ? "1 mutual" : "\(mutualCount) mutuals",
                          systemImage: "person.2.fill")
                        .font(AppTypography.badge)
                        .foregroundStyle(AppTheme.softText)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addButton: some View {
        Button(action: onAdd) {
            Label("Add", systemImage: "person.badge.plus")
                .font(AppTypography.buttonFootnote)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .primaryGlass(in: .capsule, interactive: true)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: true, vertical: false)
    }

}

private struct FriendsScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private enum FriendsScrollAnchor: Hashable {
    case top
}
