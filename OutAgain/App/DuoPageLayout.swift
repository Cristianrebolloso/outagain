import SwiftUI

/// Wide windows place the continuing page beside its companion. Portrait and
/// compact windows give the page the full width without replacing its identity.
struct DuoPageLayout<Page: View, Companion: View>: View {
    @Environment(AppStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.duoLayoutContinuity) private var layoutContinuity
    @State private var visiblePageWidth: CGFloat?
    @Binding var isExpanded: Bool
    @ViewBuilder let page: () -> Page
    @ViewBuilder let companion: () -> Companion

    @ViewBuilder
    var body: some View {
        if store.isDuoDevice { duoLayout }
        else { page() }
    }

    private var duoLayout: some View {
        GeometryReader { safeArea in
            GeometryReader { geometry in
                let isWide = geometry.size.width > safeArea.size.height
                    + safeArea.safeAreaInsets.top + safeArea.safeAreaInsets.bottom
                let expanded =
                    isWide && horizontalSizeClass == .regular
                    && geometry.size.width >= AppLayout.inlineCommentsMinimumWidth
                    && (!dynamicTypeSize.isAccessibilitySize || geometry.size.width >= 1_000)
                let paneWidth = expanded
                    ? (layoutContinuity?.pageWidth(in: geometry.size.width) ?? geometry.size.width / 2)
                    : geometry.size.width
                let companionWidth = expanded ? geometry.size.width - paneWidth : 0
                let leading = geometry.safeAreaInsets.leading
                let trailing = geometry.safeAreaInsets.trailing
                let availableWidth = max(1, paneWidth - trailing)
                // Keep the content inside the continuing window's native
                // safe area, using scene measurements rather than card widths.
                let pageWidth: CGFloat? = expanded
                    ? min(availableWidth, AppLayout.phoneColumnMaximumWidth) : nil
                let companionContentWidth = min(pageWidth ?? availableWidth, visiblePageWidth ?? availableWidth)

                HStack(spacing: 0) {
                    Group {
                        if expanded { companion() }
                    }
                    .environment(\.duoPresentationPane, expanded ? .leading : nil)
                    .environment(\.duoPresentationWidth, expanded ? paneWidth : nil)
                    .environment(\.duoPageContentWidth, expanded ? companionContentWidth : nil)
                    .padding(.bottom, expanded ? safeArea.safeAreaInsets.bottom : 0)
                    .frame(width: expanded ? max(0, companionWidth - leading) : 0)
                    .padding(.leading, expanded ? leading : 0)
                    .frame(width: companionWidth)
                    .clipped()

                    page()
                        .environment(\.duoPageContentWidth, pageWidth)
                        .environment(\.duoPresentationPane, expanded ? .trailing : nil)
                        .environment(\.duoPresentationWidth, expanded ? paneWidth : nil)
                        .frame(width: paneWidth, alignment: .leading)
                        // Native navigation controls extend outside the content
                        // safe area, so this container must not clip them.
                        .geometryGroup()
                        .onPreferenceChange(DuoPageViewportWidthKey.self) { width in
                            if let width, width.isFinite, width > 0 { visiblePageWidth = width }
                        }
                }
                .onChange(of: expanded, initial: true) { _, value in isExpanded = value }
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .ignoresSafeArea(.container, edges: .horizontal)
        .background(AmbientBackground())
    }
}

struct DuoCompanionPlaceholder: View {
    let title: String
    var subtitle: String? = nil
    let symbol: String

    var body: some View {
        ContentUnavailableView(title, systemImage: symbol, description: subtitle.map { Text($0) })
            .foregroundStyle(AppTheme.softText)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DuoPageContentWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private struct DuoPageViewportWidthKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

extension EnvironmentValues {
    var duoPageContentWidth: CGFloat? {
        get { self[DuoPageContentWidthKey.self] }
        set { self[DuoPageContentWidthKey.self] = newValue }
    }
}

/// Constrain the scrolling page, while its navigation container fills the
/// physical half and owns the native toolbar's safe area exactly once.
struct DuoPageViewport: ViewModifier {
    @Environment(AppStore.self) private var store
    @Environment(\.duoPageContentWidth) private var width
    var extendsUnderBottomBar = true

    @ViewBuilder
    func body(content: Content) -> some View {
        if store.isDuoDevice {
            content
                .frame(maxWidth: width, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: DuoPageViewportWidthKey.self, value: geometry.size.width)
                    }
                }
                .ignoresSafeArea(.container, edges: extendsUnderBottomBar ? .bottom : [])
        } else {
            content
        }
    }
}

/// Read the axis from the page's own native navigation container, so header
/// actions can return to their regular iPhone position in open portrait.
struct DuoToolbarAxisReader: View {
    @Binding var isVertical: Bool

    @ViewBuilder
    var body: some View {
        #if canImport(SwiftUICore, _version: 8.1)
        if #available(iOS 27.1, *) {
            NativeToolbarAxisReader(isVertical: $isVertical)
        } else {
            Color.clear
        }
        #else
        Color.clear
        #endif
    }
}

#if canImport(SwiftUICore, _version: 8.1)
@available(iOS 27.1, *)
private struct NativeToolbarAxisReader: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    @Binding var isVertical: Bool

    var body: some View {
        Color.clear.onChange(of: edge, initial: true) { _, value in
            isVertical = value != nil
        }
    }
}
#endif
