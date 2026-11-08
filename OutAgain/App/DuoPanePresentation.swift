import SwiftUI

/// Sheet destinations inherit the half that owns them, including nested
/// profiles and comment threads. A single-column layout uses normal sheets.
enum DuoPresentationPane: Sendable {
    case leading
    case trailing
}

private struct DuoPresentationPaneKey: EnvironmentKey {
    static let defaultValue: DuoPresentationPane? = nil
}

private struct IsAppSheetKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isAppSheet: Bool {
        get { self[IsAppSheetKey.self] }
        set { self[IsAppSheetKey.self] = newValue }
    }

    var duoPresentationPane: DuoPresentationPane? {
        get { self[DuoPresentationPaneKey.self] }
        set { self[DuoPresentationPaneKey.self] = newValue }
    }
}

struct DuoPanePresentation: ViewModifier {
    var compactWidth: CGFloat = AppLayout.phoneColumnMaximumWidth
    @Environment(AppStore.self) private var store
    @Environment(\.duoPresentationPane) private var pane
    @Environment(\.duoPresentationWidth) private var paneWidth
    @Environment(\.duoLayoutContinuity) private var continuity

    private var isWide: Bool { continuity?.isWide ?? (pane != nil) }
    private var presentationWidth: CGFloat? {
        guard isWide else { return nil }
        return continuity.map { $0.pageWidth(in: $0.windowSize.width) } ?? paneWidth
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if canImport(SwiftUICore, _version: 8.1)
        if #available(iOS 27.1, *), store.isDuoDevice {
            content
                .environment(\.isAppSheet, true)
                .presentationSizing(DuoSheetSizing(paneWidth: presentationWidth, compactWidth: compactWidth))
                .presentationPlacement(placement)
                .presentationBackgroundInteraction(isWide ? .enabled : .automatic)
                .background(DuoSheetBackgroundInteraction(
                    isEnabled: isWide, paneWidth: presentationWidth, isLeading: pane == .leading,
                    compactWidth: compactWidth
                ))
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if canImport(SwiftUICore, _version: 8.1)
    @available(iOS 27.1, *)
    private var placement: PresentationPlacement {
        guard isWide else { return .automatic }
        switch pane {
        case .leading: return .leading
        case .trailing, nil: return .trailing
        }
    }
    #endif
}

/// Match the compact window's sheet, including the system's outer margins.
/// The native toolbar reserves its own space inside this presentation once.
struct DuoSheetSizing: PresentationSizing {
    var paneWidth: CGFloat?
    var compactWidth: CGFloat = AppLayout.phoneColumnMaximumWidth

    func proposedSize(for root: PresentationSizingRoot, context: PresentationSizingContext) -> ProposedViewSize {
        let page = PagePresentationSizing.page.proposedSize(for: root, context: context)
        return ProposedViewSize(
            width: paneWidth.map { max(1, $0 - 16) } ?? min(page.width ?? compactWidth, compactWidth),
            height: page.height
        )
    }
}

/// Reconcile native sheet sizing, placement, and background interaction after
/// a display handoff. UIKit retains the presentation and its interactive fold
/// animation; this only updates its public preferred layout properties.
private struct DuoSheetBackgroundInteraction: UIViewRepresentable {
    let isEnabled: Bool
    let paneWidth: CGFloat?
    let isLeading: Bool
    let compactWidth: CGFloat

    func makeUIView(context: Context) -> InteractionView {
        let view = InteractionView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: InteractionView, context: Context) {
        view.isEnabled = isEnabled
        view.paneWidth = paneWidth
        view.isLeading = isLeading
        view.compactWidth = compactWidth
        view.scheduleUpdate()
    }

    static func dismantleUIView(_ view: InteractionView, coordinator: ()) {
        view.isEnabled = false
        view.updateInteraction()
    }

    final class InteractionView: UIView {
        var isEnabled = false
        var paneWidth: CGFloat?
        var isLeading = false
        var compactWidth: CGFloat = AppLayout.phoneColumnMaximumWidth
        private weak var managedSheet: UISheetPresentationController?
        private var originalUndimmedDetent: UISheetPresentationController.Detent.Identifier?
        private var restorePresentation: (() -> Void)?
        private var updatePending = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleUpdate()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            scheduleUpdate()
        }

        func scheduleUpdate() {
            guard !updatePending else { return }
            updatePending = true
            DispatchQueue.main.async { [weak self] in
                self?.updatePending = false
                self?.updateInteraction()
            }
        }

        func updateInteraction() {
            guard isEnabled else {
                if let managedSheet {
                    managedSheet.largestUndimmedDetentIdentifier = originalUndimmedDetent
                }
                restorePresentation?()
                // A sheet first opened in landscape captured a trailing
                // preference. Returning to a single pane must release that
                // placement instead of restoring the stale landscape value.
                if #available(iOS 27.0, *), let managedSheet {
                    managedSheet.preferredPlacement = .automatic
                    managedSheet.presentedViewController.preferredContentSize.width = compactWidth
                }
                restorePresentation = nil
                managedSheet = nil
                return
            }
            guard window != nil else { return }
            var candidate = window?.rootViewController
            while let controller = candidate {
                if let sheet = controller.presentationController as? UISheetPresentationController,
                   isDescendant(of: controller.view) {
                    if managedSheet !== sheet {
                        restorePresentation?()
                        managedSheet = sheet
                        originalUndimmedDetent = sheet.largestUndimmedDetentIdentifier
                        if #available(iOS 27.0, *) {
                            let originalSize = controller.preferredContentSize
                            let originalPlacement = sheet.preferredPlacement
                            let originalPageSizing = sheet.prefersPageSizing
                            let originalWidthFollowsContent = sheet.widthFollowsPreferredContentSizeWhenEdgeAttached
                            let originalSource = sheet.sourceView
                            restorePresentation = { [weak sheet, weak controller, weak originalSource] in
                                sheet?.preferredPlacement = originalPlacement
                                sheet?.prefersPageSizing = originalPageSizing
                                sheet?.widthFollowsPreferredContentSizeWhenEdgeAttached = originalWidthFollowsContent
                                sheet?.sourceView = originalSource
                                controller?.preferredContentSize = originalSize
                            }
                        }
                    }
                    if let largest = sheet.detents.last?.identifier,
                       sheet.largestUndimmedDetentIdentifier != largest {
                        sheet.largestUndimmedDetentIdentifier = largest
                    }
                    // SwiftUI can leave compact-origin sheets at their old
                    // automatic placement after a display handoff. Reconcile
                    // the public presentation settings on the active sheet.
                    if #available(iOS 27.0, *), let paneWidth {
                        if sheet.sourceView != nil { sheet.sourceView = nil }
                        let placement: UISheetPresentationController.Placement = isLeading ? .leading : .trailing
                        if sheet.preferredPlacement != placement { sheet.preferredPlacement = placement }
                        if sheet.prefersPageSizing { sheet.prefersPageSizing = false }
                        if !sheet.widthFollowsPreferredContentSizeWhenEdgeAttached {
                            sheet.widthFollowsPreferredContentSizeWhenEdgeAttached = true
                        }
                        let width = max(1, paneWidth - 16)
                        if abs(controller.preferredContentSize.width - width) > 0.5 {
                            controller.preferredContentSize.width = width
                            sheet.invalidateDetents()
                        }
                    }
                    return
                }
                candidate = controller.presentedViewController
            }
        }
    }
}
