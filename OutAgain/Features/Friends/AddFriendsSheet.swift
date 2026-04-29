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
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
                Text("@\(profile.username)")
                    .font(.system(.footnote, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
            }
            .layoutPriority(1)

            Spacer(minLength: 0)

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.softText.opacity(0.8))
            }
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
                .font(.system(.footnote, design: .rounded, weight: .semibold))
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

/// Models the three "discovery" states that materially change this screen's
/// intent. Each case dictates which module earns the hero slot: contacts
/// permission sell, invite-forward push, or the default "contacts yielded
/// people" layout. Keeping this explicit rather than scattered through a
/// dozen `if` branches means the layout is easier to reason about and the
/// copywriting per state lives in one place.
private enum FriendDiscoveryState {
    /// Contacts permission has never been asked — highest value moment,
    /// push hard for the grant.
    case contactsPromptAvailable
    /// User denied contacts — respect it, collapse the dead surface,
    /// elevate invite as the alternative path forward.
    case contactsBlocked
    /// Contacts granted, backend still matching.
    case contactsResolving
    /// Contacts granted but zero matches — pivot the screen into an
    /// invite-forward stance since the user's people aren't here yet.
    case contactsEmptyMatchingInvite
    /// Contacts granted, matches exist — the screen does its default thing.
    case contactsYieldedMatches
}

struct AddFriendsSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(PermissionCenter.self) private var permissions
    @Environment(\.appAccent) private var accent
    @State private var selectedProfile: UserProfile?
    @State private var isShowingRefreshConfirmation = false

    var body: some View {
        @Bindable var store = store

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                modeToggle(store: store)

                switch store.friendsPageMode {
                case .people:
                    peopleSection(store: store)
                case .discover:
                    discoverSection(store: store)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 120)
        }
        .refreshable {
            await performManualRefresh()
        }
        .scrollIndicators(.hidden)
        // Keep the warm ambient present on the Friends tab. Despite the
        // name `AddFriendsSheet`, this view is mounted as a top-level
        // tab (not a sheet) via MainShellView's switch, so the shell's
        // NavigationStack imposes the same opaque-scroll issue we see
        // on Home and Profile.
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .overlay(alignment: .top) {
            if isShowingRefreshConfirmation {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                    Text("Refreshed")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.72), in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(AppTheme.line, lineWidth: 1)
                )
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(item: $selectedProfile) { profile in
            FriendProfileView(profile: profile)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: store.friendsTabPendingProfile) { _, pending in
            guard let pending else { return }
            store.friendsTabPendingProfile = nil
            withAnimation(.snappy(duration: 0.22)) {
                store.friendsPageMode = .people
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                selectedProfile = pending
            }
        }
        .task(id: permissions.contactsStatus) {
            guard permissions.contactsStatus == .granted else { return }
            guard store.contactMatches.isEmpty, !store.isSearchingContactMatches else { return }
            let contacts = await permissions.contactLookupSeeds()
            store.searchContacts(using: contacts)
        }
    }

    private func performManualRefresh() async {
        await store.refreshAppData(silenceErrors: true)

        await MainActor.run {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                isShowingRefreshConfirmation = true
            }
        }

        try? await Task.sleep(for: .seconds(1.1))

        await MainActor.run {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.9)) {
                isShowingRefreshConfirmation = false
            }
        }
    }

    private var discoveryState: FriendDiscoveryState {
        switch permissions.contactsStatus {
        case .notDetermined:
            return .contactsPromptAvailable
        case .granted:
            if store.isSearchingContactMatches {
                return .contactsResolving
            }
            return store.contactMatches.isEmpty
                ? .contactsEmptyMatchingInvite
                : .contactsYieldedMatches
        default:
            return .contactsBlocked
        }
    }

    /// Renders the contacts + invite modules in the correct order and
    /// prominence for the given state. `compact` is true when an active
    /// search query already owns the hero slot — in that mode both modules
    /// render in a quieter form below the results.
    @ViewBuilder
    private func discoverySections(state: FriendDiscoveryState, compact: Bool) -> some View {
        switch state {
        case .contactsPromptAvailable:
            // Highest-value CTA on the screen. Lead with it.
            if !compact { contactsPermissionPitch }
            inviteSection(tone: .secondary)
            if compact { contactsPermissionPitch }

        case .contactsBlocked:
            // Contacts are dead. Invite becomes the primary path.
            inviteSection(tone: .primary)

        case .contactsResolving:
            contactsResolvingPlaceholder
            inviteSection(tone: .secondary)

        case .contactsEmptyMatchingInvite:
            // User opted in, no matches — pivot to invite-forward. The
            // headline itself carries the acknowledgement; no need for a
            // second line repeating "we checked."
            inviteSection(tone: .primary, headline: "None of your people are here yet")

        case .contactsYieldedMatches:
            contactsMatchesSection
            inviteSection(tone: .secondary)
        }
    }

    private var header: some View {
        Text(store.friendsPageMode.title)
            .font(.system(size: 32, weight: .bold, design: .serif))
            .foregroundStyle(.white)
    }

    @Namespace private var modeNamespace

    private func modeToggle(store: AppStore) -> some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 6) {
                modeButton(title: "Add Friends", mode: .discover, store: store)
                modeButton(title: "Friends", mode: .people, store: store)
            }
            .padding(6)
            .background(.white.opacity(0.05), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .glassEffect(.regular, in: .capsule)
        }
    }

    private func modeButton(title: String, mode: FriendsPageMode, store: AppStore) -> some View {
        let isSelected = store.friendsPageMode == mode

        return Button {
            withAnimation(.snappy(duration: 0.22)) {
                store.friendsPageMode = mode
            }
        } label: {
            ZStack {
                if isSelected {
                    Capsule()
                        .fill(.white.opacity(0.11))
                        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                        .glassEffect(.regular.interactive(), in: .capsule)
                        .matchedGeometryEffect(id: "friends_mode_selection", in: modeNamespace)
                }
                Text(title)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : AppTheme.softText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func peopleSection(store: AppStore) -> some View {
        searchCard(store: store)

        if store.friends.isEmpty {
            emptyFriendsState(store: store)
        } else {
            let query = store.friendSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let filtered = query.isEmpty ? store.friends : store.friends.filter {
                $0.displayName.lowercased().contains(query) || $0.username.lowercased().contains(query)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("\(store.friends.count) friends")
                    .font(.system(size: 28, weight: .bold, design: .serif))
                    .foregroundStyle(.white)

                NightPanel(cornerRadius: 28, padding: 12) {
                    VStack(spacing: 8) {
                        if filtered.isEmpty {
                            Text("No friends match \"\(store.friendSearchQuery)\"")
                                .font(.system(.subheadline, design: .rounded))
                                .foregroundStyle(AppTheme.softText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 12)
                        } else {
                            ForEach(filtered) { friend in
                                ExistingFriendRow(profile: friend) {
                                    selectedProfile = friend
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func emptyFriendsState(store: AppStore) -> some View {
        NightPanel(cornerRadius: 28, padding: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Text("No friends here yet")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)

                Text("Add the people you actually go out with, and they'll show up here as their own profiles.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(AppTheme.softText)

                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        store.friendsPageMode = .discover
                    }
                } label: {
                    Label("Add friends", systemImage: "person.badge.plus")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func discoverSection(store: AppStore) -> some View {
        if !store.incomingFriendRequests.isEmpty {
            incomingRequestsSection
        }

        searchCard(store: store)

        if hasActiveQuery {
            searchResultsSection
            discoverySections(state: discoveryState, compact: true)
        } else {
            discoverySections(state: discoveryState, compact: false)
        }

        if !store.outgoingFriendRequests.isEmpty {
            outgoingRequestsSection
        }
    }

    private func searchCard(store: AppStore) -> some View {
        @Bindable var store = store

        return NightPanel(cornerRadius: 28, padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AppTheme.softText)

                    TextField("Search by @username", text: $store.friendSearchQuery)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
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
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                )
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
    }

    private var hasActiveQuery: Bool {
        !store.friendSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionEyebrow(title: "Results")

            NightPanel(cornerRadius: 28, padding: 12) {
                if store.friendSearchResults.isEmpty {
                    sectionMessage(
                        title: "No matches yet",
                        detail: "Nobody matching that username is on Out Again yet. Send them an invite below."
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(store.friendSearchResults) { candidate in
                            FriendRow(
                                profile: candidate,
                                onOpen: {
                                    selectedProfile = candidate
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

    // MARK: - Contacts discovery modules
    //
    // Each of these renders a focused slice of the contacts-discovery surface.
    // The state machine in `discoverySections(state:compact:)` decides which
    // ones appear, in what order, and whether the invite card plays primary
    // or secondary. None of them knows about the others — that separation is
    // what keeps the layout legible as we add more states.

    /// Full-strength pitch for granting contacts permission. Used only when
    /// the user hasn't been asked yet — the highest-leverage moment on the
    /// whole screen. Don't let it live in a tiny row; the prompt itself is
    /// the hero until it's answered.
    private var contactsPermissionPitch: some View {
        NightPanel(cornerRadius: 28, padding: 18, tint: accent.opacity(0.12), interactive: true) {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("Find friends you already know")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                } icon: {
                    Image(systemName: "person.2.fill")
                        .foregroundStyle(accent)
                }

                Button {
                    Task { await permissions.requestContacts() }
                } label: {
                    Label("Turn on contacts", systemImage: "checkmark.circle.fill")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(.white.opacity(0.10), in: Capsule())
                        .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Resolving state while the backend matches contacts. Minimal chrome —
    /// a progress affordance so the user knows we're working, nothing more.
    private var contactsResolvingPlaceholder: some View {
        NightPanel(cornerRadius: 28, padding: 12) {
            HStack(spacing: 12) {
                ProgressView().tint(accent)
                Text("Checking your contacts against Out Again…")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(AppTheme.softText)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
    }

    /// The happy path: contacts resolved to actual friend candidates.
    private var contactsMatchesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionEyebrow(title: "Suggested", detail: "From your contacts")

            NightPanel(cornerRadius: 28, padding: 12) {
                VStack(spacing: 10) {
                    ForEach(store.contactMatches) { candidate in
                        FriendRow(
                            profile: candidate,
                            onOpen: {
                                selectedProfile = candidate
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

    private var incomingRequestsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionEyebrow(
                title: "Requests",
                detail: "\(store.incomingFriendRequests.count) waiting on you"
            )

            NightPanel(cornerRadius: 28, padding: 12) {
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
                                selectedProfile = request.counterpart
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

            NightPanel(cornerRadius: 28, padding: 12) {
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
                                selectedProfile = request.counterpart
                            }
                        )
                    }
                }
            }
        }
    }

    /// Visual weight for the invite card. `primary` makes invite the hero of
    /// the screen (used when contacts can't carry their weight — blocked or
    /// yielded zero matches). `secondary` is the quieter default: still
    /// prominent enough to matter, but it doesn't compete with a section
    /// above it that already owns the user's attention.
    private enum InviteTone {
        case primary
        case secondary

        var tint: Color {
            switch self {
            case .primary: return .clear
            case .secondary: return .clear
            }
        }

        var headlineFont: Font {
            switch self {
            case .primary: return .system(.title3, design: .rounded, weight: .bold)
            case .secondary: return .system(.headline, design: .rounded, weight: .semibold)
            }
        }

        var buttonHeight: CGFloat {
            switch self {
            case .primary: return 54
            case .secondary: return 48
            }
        }

        var buttonTitle: String {
            switch self {
            case .primary: return "Share invite link"
            case .secondary: return "Share invite link"
            }
        }

        var padding: CGFloat {
            switch self {
            case .primary: return 20
            case .secondary: return 16
            }
        }

        var detailText: String {
            switch self {
            case .primary:
                return "Share your link and when they join, you'll both see each other's nights out."
            case .secondary:
                return "Share your link and when they join, you'll both see each other's nights out."
            }
        }
    }

    private func inviteSection(
        tone: InviteTone,
        headline: String = "Send an invite"
    ) -> some View {
        NightPanel(
            cornerRadius: 28,
            padding: tone.padding,
            tint: tone.tint,
            interactive: true
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(headline)
                    .font(tone.headlineFont)
                    .foregroundStyle(.white)

                Text(tone.detailText)
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(AppTheme.softText)

                if let url = URL(string: store.onboardingDraft.inviteLink) {
                    ShareLink(item: url) {
                        Label(tone.buttonTitle, systemImage: "square.and.arrow.up")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: tone.buttonHeight)
                            .background(.white.opacity(0.10), in: Capsule())
                            .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                            .glassEffect(.regular.interactive(), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sectionMessage(
        title: String,
        detail: String,
        buttonTitle: String? = nil,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(.white)

            Text(detail)
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(AppTheme.softText)

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

private struct ExistingFriendRow: View {
    let profile: UserProfile
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 14) {
                TonightAvatarView(avatar: profile.avatar, userID: profile.id, size: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.displayName)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("@\(profile.username)")
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(AppTheme.softText)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.softText.opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("@\(profile.username)")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(AppTheme.softText)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.softText.opacity(0.8))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onAdd) {
                Label("Add", systemImage: "person.badge.plus")
                    .font(.system(.footnote, design: .rounded, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
