import SwiftUI

/// Friends vs. Friends-of-Friends feed scope selector.
///
/// Position rationale:
/// This used to sit at the very top of Home, immediately under the
/// logo. That gave it the prime slot on the screen, which made
/// sense when the scope toggle was the primary lever the viewer
/// pulled on open. With the Tonight strip in place, the anchor of
/// attention should be *who's out right now* — that's the object
/// that earns re-opens. The scope slider still matters (it filters
/// the feed below), but it's a control that belongs adjacent to
/// the feed it modifies, not at the top of the screen competing
/// with the social pulse. Placing it between the Tonight strip
/// and `feedPosts` also reads correctly visually: Tonight is its
/// own object (stories-style strip), and the slider then acts as
/// the feed's header control, which is conventional.
struct HomeFeedScopeControl: View {
    @Environment(AppStore.self) private var store
    @Namespace private var scopeNamespace

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(FeedScope.allCases) { scope in
                    Button {
                        withAnimation(.snappy(duration: 0.24)) {
                            store.feedScope = scope
                            store.selectedPresenceClusterID = nil
                        }
                    } label: {
                        ZStack {
                            if store.feedScope == scope {
                                Capsule()
                                    .fill(.white.opacity(0.11))
                                    .overlay(
                                        Capsule()
                                            .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                                    )
                                    .glassEffect(.regular.interactive(), in: .capsule)
                                    .matchedGeometryEffect(id: "feed_scope_selection", in: scopeNamespace)
                            }

                            Text(scope.title)
                                .font(.system(.footnote, design: .rounded, weight: .semibold))
                                .foregroundStyle(store.feedScope == scope ? .white : AppTheme.softText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.9)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(.white.opacity(0.05), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(AppTheme.line, lineWidth: 1)
            )
            .glassEffect(.regular, in: .capsule)
        }
    }
}
