import SwiftUI

/// Only Activity opts in. Feed cards and native phone sheets keep their own
/// presentation. The author element includes the name and verification badge.
struct ActivityPostMorph: ViewModifier {
    enum Element: String { case photo, author }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let namespace: Namespace.ID?
    let postID: UUID
    let element: Element

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace, !reduceMotion {
            content.matchedGeometryEffect(id: "\(postID)-\(element.rawValue)", in: namespace, anchor: .topLeading)
        } else {
            content
        }
    }
}

/// Presented posts use the same comfortable column as the portrait home feed.
/// Constrain both the sheet and its content: compact presentations can ignore
/// a sheet's preferred width when they adapt to the available window.
struct PostDetailPresentation: ViewModifier {
    // Keep the Home card's width, with room around its rounded edges.
    static let sheetWidth = AppLayout.phoneColumnMaximumWidth + AppLayout.screenPadding * 2
    @Environment(AppStore.self) private var store
    @Environment(\.duoPresentationWidth) private var paneWidth
    @Environment(\.duoLayoutContinuity) private var continuity

    @ViewBuilder
    func body(content: Content) -> some View {
        if store.isDuoDevice {
            content.presentationSizing(DuoSheetSizing(
                paneWidth: continuity.map { $0.isWide ? $0.pageWidth(in: $0.windowSize.width) : nil } ?? paneWidth,
                compactWidth: Self.sheetWidth
            ))
        } else {
            content
        }
    }
}

/// One stationary backdrop behind the navigation bar, post, and comments.
/// Pages inside this stack use MainPageSurface to keep navigation transparent.
struct DuoSheetSurface: ViewModifier {
    @Environment(AppStore.self) private var store

    @ViewBuilder
    func body(content: Content) -> some View {
        if store.isDuoDevice {
            content
                .background { AmbientBackground().ignoresSafeArea() }
                .presentationBackground(.clear)
        } else {
            content
        }
    }
}

struct PostDetailColumn: ViewModifier {
    @Environment(AppStore.self) private var store
    var maximumWidth: CGFloat = AppLayout.phoneColumnMaximumWidth

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: store.isDuoDevice ? maximumWidth : .infinity)
            .frame(maxWidth: .infinity)
    }
}

