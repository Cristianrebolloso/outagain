import SwiftUI

/// Your existing friends stay separate from discovery and its search query.
struct FriendsCompanionView: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedProfile: UserProfile?
    @State private var isTitleScrolled = false

    private var friends: [UserProfile] {
        store.friends.sorted {
            let order = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if friends.isEmpty {
                        ContentUnavailableView(
                            "No friends yet", systemImage: "person.2"
                        )
                    } else {
                        NightPanel(cornerRadius: AppLayout.panelRadius, padding: 12) {
                            LazyVStack(spacing: 8) {
                                ForEach(friends) { friend in
                                    ExistingFriendRow(profile: friend) { selectedProfile = friend }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, AppLayout.screenPadding)
                .padding(.top, AppLayout.secondaryPageTopPadding)
                .padding(.bottom, 20)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > 8
            } action: { _, isScrolled in
                isTitleScrolled = isScrolled
            }
            #if DEBUG
            .modifier(DuoScrollPreviewControls())
            #endif
            .modifier(DuoPageHeader(title: "\(friends.count) \(friends.count == 1 ? "Friend" : "Friends")", isScrolled: isTitleScrolled))
            .scrollIndicators(.hidden)
            .containerBackground(.clear, for: .navigation)
            .ignoresSafeArea(.container, edges: .horizontal)
            .navigationDestination(item: $selectedProfile) { profile in
                FriendProfileView(profile: profile, presentationStyle: .embedded)
                    .ignoresSafeArea(.container, edges: .horizontal)
            }
        }
        .accessibilityIdentifier("friends.companion")
    }
}
