import SwiftUI

#if DEBUG
/// Deterministic scroll positions for local visual previews, with no backend.
struct DuoScrollPreviewControls: ViewModifier {
    @Environment(AppStore.self) private var store
    @State private var position = ScrollPosition(y: 0)

    @ViewBuilder
    func body(content: Content) -> some View {
        if store.isLayoutPreview && ProcessInfo.processInfo.arguments.contains("--scroll-controls-preview") {
            content
                .scrollPosition($position)
                .overlay(alignment: .bottomLeading) {
                    HStack {
                        Button("Preview scroll") { position.scrollTo(y: 380) }
                        Button("Preview top") { position.scrollTo(edge: .top) }
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(12)
                }
        } else {
            content
        }
    }
}
#endif

/// Shared by phone pages and Duo panes so scrolling titles behave identically.
struct ScrollingPageTitle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    var isScrolled = false

    var body: some View {
        Text(title)
            .font(AppTypography.pageTitle)
            .foregroundStyle(.white)
            .background {
                // Protect the title only once scrolling content reaches it.
                // Keep the capsule outside layout so the text never jumps.
                Color.clear
                    .glassEffect(.regular, in: .capsule)
                    .padding(.horizontal, -12)
                    .padding(.vertical, -8)
                    .opacity(isScrolled ? 1 : 0)
            }
            .animation(.easeOut(duration: reduceMotion ? 0.1 : 0.16), value: isScrolled)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One title treatment for full pages and companion panes. Native navigation
/// continues to own the back/actions bar; titles stay with their page content.
struct DuoPageHeading: View {
    let title: String
    var isScrolled = false

    var body: some View {
        ScrollingPageTitle(title: title, isScrolled: isScrolled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, AppLayout.screenPadding)
            // Clear the rounded display corner while keeping the title on
            // the same leading edge as the cards and fields below it.
            .padding(.top, 32)
    }
}

struct AppSecondaryPageNavigation: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.isAppSheet) private var isAppSheet
    let title: String
    var isScrolled = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if store.isDuoDevice && !isAppSheet {
            content
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .modifier(DuoPageHeader(title: title, isScrolled: isScrolled))
        } else {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

/// A vertical native bar reserves a top inset as well as its side rail. Full
/// page headings use the same top origin as the neighboring companion pane.
struct DuoPageHeader: ViewModifier {
    @Environment(AppStore.self) private var store
    let title: String
    var isScrolled = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if store.isDuoDevice {
            duoContent(content)
        } else {
            content
        }
    }

    @ViewBuilder
    private func duoContent(_ content: Content) -> some View {
        #if canImport(SwiftUICore, _version: 8.1)
        if #available(iOS 27.1, *) {
            content.modifier(NativeDuoPageHeader(title: title, isScrolled: isScrolled))
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { DuoPageHeading(title: title, isScrolled: isScrolled) }
        }
        #else
        content.safeAreaInset(edge: .top, spacing: 0) { DuoPageHeading(title: title, isScrolled: isScrolled) }
        #endif
    }
}

#if canImport(SwiftUICore, _version: 8.1)
@available(iOS 27.1, *)
private struct NativeDuoPageHeader: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    let title: String
    var isScrolled = false

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) { DuoPageHeading(title: title, isScrolled: isScrolled) }
            .ignoresSafeArea(.container, edges: verticalEdge == nil ? [] : .top)
    }
}
#endif

/// A native, compact header for a modal destination. Full pages keep their
/// larger heading, while the system reserves space for Duo's side controls.
struct DuoModalNavigation: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let title: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if store.isDuoDevice {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
        } else {
            content
        }
    }
}
