import SwiftUI
import UIKit

/// Keep the native prominent camera tab's glass platter in the new display's
/// coordinate space after a fold. Reconfigure only the tab-bar treatment;
/// rebuilding the TabView would also discard scroll positions and open panels.
struct DuoTabBarLayoutRecovery: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        #if canImport(SwiftUICore, _version: 8.1)
        if #available(iOS 27.1, *) { return FoldAwareTabBarProbe() }
        #endif
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

#if canImport(SwiftUICore, _version: 8.1)
@available(iOS 27.1, *)
private final class FoldAwareTabBarProbe: UIView {
    private var lastWindowSize: CGSize?
    private var lastHingeStatus: UIHinge.Status?
    private var revision = 0
    private var pendingRepair: Task<Void, Never>?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        addInteraction(UIHingeInteraction { [weak self] _, update in
            guard let self, let status = update.hinge?.status else { return }
            let previous = lastHingeStatus
            lastHingeStatus = status
            if let previous, previous != status { scheduleRepair() }
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            revision += 1
            pendingRepair?.cancel()
            pendingRepair = nil
        } else {
            observeWindowSize()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        observeWindowSize()
    }

    private func observeWindowSize() {
        guard let size = window?.bounds.size, size.width > 0, size.height > 0 else { return }
        let previous = lastWindowSize
        lastWindowSize = size
        if let previous, previous != size { scheduleRepair() }
    }

    private func scheduleRepair() {
        revision += 1
        let requestedRevision = revision
        pendingRepair?.cancel()
        pendingRepair = Task { @MainActor [weak self] in
            // Coalesce rapid hinge and geometry updates. Never apply a repair
            // captured for the previous display while another fold is underway.
            do { try await Task.sleep(for: .milliseconds(120)) }
            catch { return }
            guard let self, revision == requestedRevision,
                  let root = window?.rootViewController else { return }
            if let transition = root.transitionCoordinator,
               transition.animate(alongsideTransition: nil, completion: { [weak self] _ in
                    self?.repair(revision: requestedRevision)
               }) {
                return
            }
            repair(revision: requestedRevision)
        }
    }

    private func repair(revision requestedRevision: Int) {
        guard revision == requestedRevision, let window,
              let root = window.rootViewController,
              let tabs = tabController(in: root), tabs.viewIfLoaded?.window === window,
              let prominentID = tabs.prominentTabIdentifier else { return }

        #if DEBUG
        let selectedTab = tabs.selectedTab
        let controllers = tabs.viewControllers ?? []
        #endif

        // Public UIKit APIs recreate the prominent treatment at the settled
        // size without replacing any tab controller, selection, or app state.
        UIView.performWithoutAnimation {
            tabs.setProminentTabIdentifier(nil, animated: false)
            tabs.view.setNeedsLayout()
            tabs.view.layoutIfNeeded()
            tabs.setProminentTabIdentifier(prominentID, animated: false)
            tabs.view.setNeedsLayout()
            tabs.view.layoutIfNeeded()
        }

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--duo-tab-bar-layout-checks") {
            assert(tabs.selectedTab === selectedTab, "Fold repair changed the selected tab")
            assert(controllers.elementsEqual(tabs.viewControllers ?? [], by: { $0 === $1 }),
                   "Fold repair replaced a page controller")
            NSLog("[DuoTabBarLayout] repaired at %@; selection and page controllers preserved",
                  String(describing: window.bounds.size))
        }
        #endif
    }

    private func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        for child in controller.children {
            if let tabs = tabController(in: child) { return tabs }
        }
        return nil
    }
}
#endif
